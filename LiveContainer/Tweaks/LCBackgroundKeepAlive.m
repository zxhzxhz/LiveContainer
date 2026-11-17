//
//  LCBackgroundKeepAlive.m
//  LiveContainer
//
//  Keeps guest apps or the LiveContainer host app (for the HTTP API server)
//  alive in the background. Uses iOS 26+ BGContinuedProcessingTask as primary
//  channel (registering and submitting while active in foreground, with a
//  targeted _BGTaskIdentifierRegistry hook when sideloading/guest mode alters
//  CFBundleIdentifier relative to Info.plist), and automatically falls back
//  to a silent AVAudioEngine + auto-renewing UIBackgroundTask assertion if
//  BGContinuedProcessingTask cannot register, fails to submit, or hasn't
//  launched before entering the background.
//

#import "LCBackgroundKeepAlive.h"
#import "../utils.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <dlfcn.h>
#include <string.h>
#include "../../litehook/src/litehook.h"

NSNotificationName const LCBackgroundKeepAliveStatusDidChangeNotification = @"LCBackgroundKeepAliveStatusDidChangeNotification";

static atomic_bool gLCIsInBackground = ATOMIC_VAR_INIT(false);
static atomic_bool gKeepAliveEnabledForGuestApp = ATOMIC_VAR_INIT(false);
static atomic_bool gHostBackgroundKeepAliveEnabled = ATOMIC_VAR_INIT(false);
static atomic_int gHostHTTPPort = ATOMIC_VAR_INIT(8080);

static os_unfair_lock gLCPermittedIdLock = OS_UNFAIR_LOCK_INIT;
static NSString *gLCPermittedOwnTaskIdentifier = nil;
static BOOL (*orig_isPermissibleIdentifier)(id, SEL, NSString *) = NULL;

static BOOL LCIsAnyKeepAliveEnabled(void) {
    return atomic_load_explicit(&gKeepAliveEnabledForGuestApp, memory_order_relaxed)
        || atomic_load_explicit(&gHostBackgroundKeepAliveEnabled, memory_order_relaxed);
}

BOOL LCIsBackgroundKeepAliveEnabled(void) {
    return LCIsAnyKeepAliveEnabled();
}

BOOL LCIsBackgroundKeepAliveActive(void) {
    return atomic_load_explicit(&gKeepAliveEnabledForGuestApp, memory_order_relaxed)
        && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed);
}

BOOL LCIsHostBackgroundKeepAliveEnabled(void) {
    return atomic_load_explicit(&gHostBackgroundKeepAliveEnabled, memory_order_relaxed);
}

#pragma mark - Rendering Guard

// Returning nil from nextDrawable makes a render loop skip the frame instead of
// blocking forever once the three drawables of the layer are exhausted.
static id<CAMetalDrawable> (*orig_CAMetalLayer_nextDrawable)(CAMetalLayer *self, SEL _cmd);
static id<CAMetalDrawable> hook_CAMetalLayer_nextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (LCIsBackgroundKeepAliveActive()) {
        return nil;
    }
    return orig_CAMetalLayer_nextDrawable ? orig_CAMetalLayer_nextDrawable(self, _cmd) : nil;
}

// Presenting an OpenGL ES renderbuffer in the background kills the process with
// gpus_ReturnNotPermittedKillClient.
typedef BOOL (*LCPresentRenderbufferIMP)(id receiver, SEL _cmd, NSUInteger target);
static LCPresentRenderbufferIMP orig_EAGLContext_presentRenderbuffer;
static BOOL hook_EAGLContext_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    if (LCIsBackgroundKeepAliveActive()) {
        return YES;
    }
    return orig_EAGLContext_presentRenderbuffer ? orig_EAGLContext_presentRenderbuffer(self, _cmd, target) : YES;
}

static void (*orig_glFinish)(void);
static void hook_glFinish(void) {
    if (LCIsBackgroundKeepAliveActive()) {
        return;
    }
    if (orig_glFinish) {
        orig_glFinish();
    }
}

static void (*orig_glFlush)(void);
static void hook_glFlush(void) {
    if (LCIsBackgroundKeepAliveActive()) {
        return;
    }
    if (orig_glFlush) {
        orig_glFlush();
    }
}

static void installRenderingGuardHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class metalLayerClass = [CAMetalLayer class];
        if (metalLayerClass) {
            Method method = class_getInstanceMethod(metalLayerClass, @selector(nextDrawable));
            if (method) {
                orig_CAMetalLayer_nextDrawable = (id<CAMetalDrawable>(*)(CAMetalLayer *, SEL))method_setImplementation(method, (IMP)hook_CAMetalLayer_nextDrawable);
            }
        }

        Class eaglClass = NSClassFromString(@"EAGLContext");
        if (eaglClass) {
            Method method = class_getInstanceMethod(eaglClass, NSSelectorFromString(@"presentRenderbuffer:"));
            if (method) {
                orig_EAGLContext_presentRenderbuffer = (LCPresentRenderbufferIMP)method_setImplementation(method, (IMP)hook_EAGLContext_presentRenderbuffer);
            }
        }

        // Resolve through dlsym so the binary never links OpenGL ES directly.
        void *glFinishSymbol = dlsym(RTLD_DEFAULT, "glFinish");
        void *glFlushSymbol = dlsym(RTLD_DEFAULT, "glFlush");
        orig_glFinish = (void (*)(void))glFinishSymbol;
        orig_glFlush = (void (*)(void))glFlushSymbol;
        if (glFinishSymbol) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, glFinishSymbol, (void *)hook_glFinish, nil);
        }
        if (glFlushSymbol) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, glFlushSymbol, (void *)hook_glFlush, nil);
        }
    });
}

#pragma mark - BackgroundTasks Client Registry Hook

// SideStore / personal-team sideloading rewrites CFBundleIdentifier in Info.plist
// (e.g. appending .<TEAMID>) without rewriting BGTaskSchedulerPermittedIdentifiers,
// and in guest mode NSBundle.mainBundle points to the guest app rather than the host.
// Meanwhile iOS 26 dasd validates hostApplicationBundleIdentifier and skips
// LSApplicationRecord permitted-identifier lookup for BGContinuedProcessingTask.
// Permitting our own resolved host-prefixed task identifier keeps client-side
// registration aligned with the actual signed bundle ID.
static BOOL hook_LC_isPermissibleIdentifier(id self, SEL _cmd, NSString *identifier) {
    NSString *permittedId = nil;
    os_unfair_lock_lock(&gLCPermittedIdLock);
    permittedId = gLCPermittedOwnTaskIdentifier;
    os_unfair_lock_unlock(&gLCPermittedIdLock);
    if (permittedId.length > 0
        && [identifier isKindOfClass:[NSString class]]
        && identifier.length <= 128
        && ![identifier containsString:@"*"]
        && [identifier isEqualToString:permittedId]) {
        return YES;
    }
    return orig_isPermissibleIdentifier ? orig_isPermissibleIdentifier(self, _cmd, identifier) : NO;
}

static void installBackgroundTaskRegistryHookIfNeeded(NSString *ownIdentifier) {
    os_unfair_lock_lock(&gLCPermittedIdLock);
    gLCPermittedOwnTaskIdentifier = [ownIdentifier copy];
    os_unfair_lock_unlock(&gLCPermittedIdLock);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY);
        Class registryClass = NSClassFromString(@"_BGTaskIdentifierRegistry");
        Method permissibleMethod = registryClass
            ? class_getInstanceMethod(registryClass, NSSelectorFromString(@"isPermissibleFullyComposedIdentifier:"))
            : NULL;
        if (permissibleMethod) {
            orig_isPermissibleIdentifier = (BOOL (*)(id, SEL, NSString *))method_setImplementation(
                permissibleMethod,
                (IMP)hook_LC_isPermissibleIdentifier
            );
        }
    });
}

#pragma mark - Background task application helpers

static const NSUInteger LCBackgroundTaskInvalid = NSUIntegerMax;

@protocol LCBackgroundTaskApplication <NSObject>
@property (nonatomic, readonly) UIApplicationState applicationState;
- (NSUInteger)beginBackgroundTaskWithName:(NSString *)taskName expirationHandler:(void (^)(void))handler;
- (void)endBackgroundTask:(NSUInteger)identifier;
@end

static id<LCBackgroundTaskApplication> LCSharedApplication(void) {
    Class appClass = NSClassFromString(@"UIApplication");
    if (!appClass) {
        return nil;
    }
    SEL selector = NSSelectorFromString(@"sharedApplication");
    if (![appClass respondsToSelector:selector]) {
        return nil;
    }
    IMP implementation = [appClass methodForSelector:selector];
    if (!implementation) {
        return nil;
    }
    id (*call)(id, SEL) = (id (*)(id, SEL))implementation;
    return (id<LCBackgroundTaskApplication>)call(appClass, selector);
}

static BOOL LCShouldUseContinuedProcessingAPI(void) {
    // Apple's BGContinuedProcessingTask does not keep app extensions alive
    // (submissions from extensions wake/retain the host app instead), so
    // LiveProcess.appex falls back to the silent audio session.
    if (NSUserDefaults.isLiveProcess) {
        return NO;
    }
#if !TARGET_OS_MACCATALYST
    if (@available(iOS 26.0, *)) {
        return [BGContinuedProcessingTaskRequest class] != nil;
    }
#endif
    return NO;
}

#pragma mark - Keep-alive manager

@interface LCBackgroundKeepAliveManager : NSObject
@property (nonatomic, assign) NSUInteger bgTaskId;
@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *registeredTaskIdentifiers;
@property (nonatomic, assign) BOOL pendingContinuedSubmission;
@property (nonatomic, strong, nullable) id activeContinuedTask;
@property (nonatomic, strong, nullable) dispatch_source_t progressHeartbeatTimer;
@property (nonatomic, strong, nullable) NSDate *continuedTaskStartDate;
@property (nonatomic, strong, nullable) NSDate *lastSubmitAttemptDate;
@property (nonatomic, copy, nullable) NSString *lastContinuedFailureReason;

@property (nonatomic, copy) NSString *statusDescription;
@property (nonatomic, strong) NSObject *statusLock;

@property (nonatomic, strong, nullable) AVAudioEngine *audioEngine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioPCMBuffer *silentBuffer;
@end

@implementation LCBackgroundKeepAliveManager

+ (instancetype)shared {
    static LCBackgroundKeepAliveManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _bgTaskId = LCBackgroundTaskInvalid;
        _taskQueue = dispatch_queue_create("com.kdt.livecontainer.keepalive.bg", DISPATCH_QUEUE_SERIAL);
        _registeredTaskIdentifiers = [NSMutableSet set];
        _statusLock = [[NSObject alloc] init];
        _statusDescription = @"Idle";
    }
    return self;
}

- (void)updateStatusDescription:(NSString *)status {
    NSString *next = status.length > 0 ? [status copy] : @"Idle";
    BOOL changed = NO;
    @synchronized(self.statusLock) {
        if (![_statusDescription isEqualToString:next]) {
            _statusDescription = next;
            changed = YES;
        }
    }
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:LCBackgroundKeepAliveStatusDidChangeNotification object:nil];
        });
    }
}

- (NSString *)currentStatusDescription {
    @synchronized(self.statusLock) {
        return _statusDescription ?: @"Idle";
    }
}

- (void)installObserversIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onAppWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        if (NSUserDefaults.isLiveProcess) {
            [nc addObserver:self selector:@selector(onAppDidEnterBackground:) name:NSExtensionHostDidEnterBackgroundNotification object:nil];
            [nc addObserver:self selector:@selector(onAppWillEnterForeground:) name:NSExtensionHostWillEnterForegroundNotification object:nil];
        }

        [nc addObserverForName:AVAudioSessionInterruptionNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            if (LCIsAnyKeepAliveEnabled() && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
                __block BOOL hasActiveContinued = NO;
                dispatch_sync(self.taskQueue, ^{
                    hasActiveContinued = (self.activeContinuedTask != nil);
                });
                if (!hasActiveContinued) {
                    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                    if (type == (NSUInteger)AVAudioSessionInterruptionTypeEnded) {
                        [self startSilentAudioSession];
                    }
                }
            }
        }];
    });
}

#pragma mark - Lifecycle Notifications

- (void)armContinuedTaskFromMainThreadWithCooldown:(BOOL)respectCooldown {
    if (!LCIsAnyKeepAliveEnabled()) {
        return;
    }
    if (!LCShouldUseContinuedProcessingAPI()) {
        if (NSUserDefaults.isLiveProcess) {
            [self updateStatusDescription:@"Standby (Silent Audio for Multitask extension)"];
        } else {
            [self updateStatusDescription:@"Standby (Silent Audio on iOS < 26)"];
        }
        return;
    }

    id<LCBackgroundTaskApplication> app = LCSharedApplication();
    if (!app) {
        [self updateStatusDescription:@"Waiting for UIApplication activation"];
        return;
    }
    UIApplicationState state = app.applicationState;
    if (state == UIApplicationStateBackground) {
        return;
    }
    [self submitContinuedProcessingTaskIfNeededRespectingCooldown:respectCooldown allowInactive:NO isActive:(state == UIApplicationStateActive)];
}

- (void)onAppWillResignActive:(NSNotification *)notification {
    if (!LCIsAnyKeepAliveEnabled()) {
        return;
    }
    if (LCShouldUseContinuedProcessingAPI()) {
        id<LCBackgroundTaskApplication> app = LCSharedApplication();
        UIApplicationState state = app ? app.applicationState : UIApplicationStateInactive;
        // Acquire a temporary UIBackgroundTask transition bridge only when no
        // BGContinuedProcessingTask is already active yet.
        __block BOOL needSubmit = NO;
        __block BOOL needBridge = NO;
        dispatch_sync(self.taskQueue, ^{
            needBridge = (self.activeContinuedTask == nil);
            needSubmit = (self.activeContinuedTask == nil && !self.pendingContinuedSubmission);
        });
        if (needBridge) {
            [self acquireSystemBackgroundTaskAssertionWithAutoRenew:NO];
        }
        if (needSubmit && state != UIApplicationStateBackground) {
            // Last-chance submission while transitioning before DidEnterBackground.
            [self submitContinuedProcessingTaskIfNeededRespectingCooldown:YES allowInactive:YES isActive:(state == UIApplicationStateActive)];
        }
    }
}

- (void)onAppDidEnterBackground:(NSNotification *)notification {
    if (!LCIsAnyKeepAliveEnabled()) {
        return;
    }
    atomic_store_explicit(&gLCIsInBackground, true, memory_order_release);

    if (LCShouldUseContinuedProcessingAPI()) {
        __block BOOL hasContinued = NO;
        __block BOOL pendingContinued = NO;
        __block NSString *failureReason = nil;
        dispatch_sync(self.taskQueue, ^{
            hasContinued = (self.activeContinuedTask != nil);
            pendingContinued = self.pendingContinuedSubmission;
            failureReason = [self.lastContinuedFailureReason copy];
        });

        if (hasContinued) {
            // Reset elapsed timer at actual background transition so the Live Activity
            // reflects background runtime accurately.
            dispatch_async(self.taskQueue, ^{
                self.continuedTaskStartDate = [NSDate date];
                [self refreshActiveContinuedTaskMetadataOnQueue];
            });
            [self releaseSystemBackgroundTaskAssertion];
            [self stopSilentAudioSession];
            [self updateStatusDescription:[NSString stringWithFormat:@"iOS 26 BGContinuedProcessingTask active (%@)", [self resolvedContinuedTaskIdentifier]]];
        } else {
            // Fail-safe: if BGContinuedProcessingTask failed, was rejected by dasd, or has not
            // launched before entering background, engage silent audio + auto-renewing UIBackgroundTask
            // synchronously while transitioning so the HTTP server never drops after ~30s.
            [self acquireSystemBackgroundTaskAssertionWithAutoRenew:YES];
            [self startSilentAudioSession];
            if (failureReason.length > 0) {
                [self updateStatusDescription:[NSString stringWithFormat:@"Silent Audio fallback (%@)", failureReason]];
            } else if (pendingContinued) {
                [self updateStatusDescription:@"Silent Audio bridge (BGContinuedProcessingTask pending launch)"];
            } else {
                [self updateStatusDescription:@"Silent Audio fallback (BGContinuedProcessingTask inactive)"];
            }
        }
    } else {
        [self acquireSystemBackgroundTaskAssertionWithAutoRenew:YES];
        [self startSilentAudioSession];
        [self updateStatusDescription:@"Silent Audio active"];
    }
}

- (void)onAppWillEnterForeground:(NSNotification *)notification {
    BOOL wasInBackground = atomic_exchange_explicit(&gLCIsInBackground, false, memory_order_acq_rel);
    [self stopSilentAudioSession];
    [self releaseSystemBackgroundTaskAssertion];

    if (wasInBackground) {
        // Retire the previous background session so the next foreground-armed task gets a fresh budget.
        [self stopContinuedProcessingTaskWithSuccess:YES];
        if (LCIsAnyKeepAliveEnabled()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
                    [self armContinuedTaskFromMainThreadWithCooldown:NO];
                }
            });
        }
    }
}

- (void)onAppDidBecomeActive:(NSNotification *)notification {
    atomic_store_explicit(&gLCIsInBackground, false, memory_order_release);
    [self stopSilentAudioSession];
    [self releaseSystemBackgroundTaskAssertion];

    if (!LCIsAnyKeepAliveEnabled()) {
        [self stopContinuedProcessingTaskWithSuccess:YES];
        [self updateStatusDescription:@"Disabled"];
        return;
    }

    __block BOOL needsArm = NO;
    dispatch_sync(self.taskQueue, ^{
        needsArm = (self.activeContinuedTask == nil && !self.pendingContinuedSubmission);
        if (self.activeContinuedTask != nil) {
            [self refreshActiveContinuedTaskMetadataOnQueue];
        }
    });

    if (needsArm) {
        [self armContinuedTaskFromMainThreadWithCooldown:NO];
    }
}

- (void)endAllKeepAliveSessions {
    atomic_store_explicit(&gLCIsInBackground, false, memory_order_release);
    [self stopContinuedProcessingTaskWithSuccess:YES];
    [self stopSilentAudioSession];
    [self releaseSystemBackgroundTaskAssertion];
    [self updateStatusDescription:@"Disabled"];
}

- (void)handleConfigurationChanged {
    dispatch_block_t block = ^{
        if (!LCIsAnyKeepAliveEnabled()) {
            [self endAllKeepAliveSessions];
            return;
        }
        dispatch_async(self.taskQueue, ^{
            [self refreshActiveContinuedTaskMetadataOnQueue];
        });
        if (!atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
            [self armContinuedTaskFromMainThreadWithCooldown:NO];
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - iOS 26+ BGContinuedProcessingTask

- (NSString *)resolvedContinuedTaskIdentifier {
    NSBundle *hostBundle = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    NSString *bundleId = hostBundle.bundleIdentifier;
    if (bundleId.length == 0) {
        bundleId = @"com.kdt.livecontainer";
    }
    NSString *expectedPrefix = [bundleId stringByAppendingString:@"."];
    NSString *matchedPrefix = nil;
    id permitted = hostBundle.infoDictionary[@"BGTaskSchedulerPermittedIdentifiers"];
    if ([permitted isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)permitted) {
            if (![entry isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *pattern = (NSString *)entry;
            if ([pattern hasPrefix:expectedPrefix] && [pattern hasSuffix:@".*"] && pattern.length > 2) {
                NSString *candidate = [pattern substringToIndex:pattern.length - 1];
                if ([pattern containsString:@".bgtask."]) {
                    matchedPrefix = candidate;
                    break;
                }
                if (!matchedPrefix) {
                    matchedPrefix = candidate;
                }
            }
        }
    }
    if (!matchedPrefix) {
        matchedPrefix = [bundleId stringByAppendingString:@".bgtask."];
    }
    NSString *identifier = [matchedPrefix stringByAppendingString:@"keepalive"];
    if (identifier.length > 128) {
        NSUInteger maxPrefixLen = MIN(bundleId.length, (NSUInteger)(128 - @".keepalive".length));
        identifier = [NSString stringWithFormat:@"%@.keepalive", [bundleId substringToIndex:maxPrefixLen]];
    }
    return identifier;
}

- (NSString *)currentTaskTitle {
    if (atomic_load_explicit(&gHostBackgroundKeepAliveEnabled, memory_order_relaxed)
        && !atomic_load_explicit(&gKeepAliveEnabledForGuestApp, memory_order_relaxed)) {
        return @"LiveContainer HTTP API";
    }
    NSDictionary *guestInfo = NSUserDefaults.guestAppInfo;
    NSString *guestName = guestInfo[@"CFBundleDisplayName"] ?: guestInfo[@"CFBundleName"];
    if ([guestName isKindOfClass:[NSString class]] && guestName.length > 0) {
        return guestName;
    }
    return @"LiveContainer";
}

- (NSString *)currentBaseSubtitle {
    BOOL inBackground = atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed);
    BOOL hostHTTP = atomic_load_explicit(&gHostBackgroundKeepAliveEnabled, memory_order_relaxed);
    BOOL guestKeepAlive = atomic_load_explicit(&gKeepAliveEnabledForGuestApp, memory_order_relaxed);
    if (hostHTTP && !guestKeepAlive) {
        int port = atomic_load_explicit(&gHostHTTPPort, memory_order_relaxed);
        return inBackground
            ? [NSString stringWithFormat:@"Port %d active in background", port]
            : [NSString stringWithFormat:@"Port %d background keep-alive armed", port];
    }
    return inBackground ? @"Running in background" : @"Background keep-alive armed";
}

- (NSString *)formattedSubtitleWithElapsed:(NSTimeInterval)elapsed {
    NSString *base = [self currentBaseSubtitle];
    if (!atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
        return base;
    }
    NSInteger totalSeconds = MAX(0, (NSInteger)elapsed);
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger seconds = totalSeconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%@ • %ld:%02ld:%02ld", base, (long)hours, (long)minutes, (long)seconds];
    }
    return [NSString stringWithFormat:@"%@ • %02ld:%02ld", base, (long)minutes, (long)seconds];
}

#if !TARGET_OS_MACCATALYST
- (BOOL)ensureRegisteredForIdentifierOnQueue:(NSString *)taskIdentifier API_AVAILABLE(ios(26.0)) {
    installBackgroundTaskRegistryHookIfNeeded(taskIdentifier);
    if ([self.registeredTaskIdentifiers containsObject:taskIdentifier]) {
        return YES;
    }
    __weak typeof(self) weakSelf = self;
    BOOL registered = [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:taskIdentifier
                                                                            usingQueue:self.taskQueue
                                                                         launchHandler:^(BGTask * _Nonnull task) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [task setTaskCompletedWithSuccess:YES];
            return;
        }
        if ([task isKindOfClass:[BGContinuedProcessingTask class]]) {
            [strongSelf handleContinuedTaskLaunch:(BGContinuedProcessingTask *)task];
        } else {
            [task setTaskCompletedWithSuccess:YES];
        }
    }];
    if (registered) {
        [self.registeredTaskIdentifiers addObject:taskIdentifier];
    } else {
        NSLog(@"[LCBackgroundKeepAlive] Failed to register BGContinuedProcessingTask identifier '%@'", taskIdentifier);
        self.lastContinuedFailureReason = [NSString stringWithFormat:@"register rejected (%@)", taskIdentifier];
    }
    return registered;
}

- (void)handleContinuedTaskLaunch:(BGContinuedProcessingTask *)task API_AVAILABLE(ios(26.0)) {
    self.pendingContinuedSubmission = NO;
    if (!LCIsAnyKeepAliveEnabled()) {
        [task setTaskCompletedWithSuccess:YES];
        return;
    }

    [self stopHeartbeatTimerOnQueue];
    if (self.activeContinuedTask && self.activeContinuedTask != task) {
        [(BGContinuedProcessingTask *)self.activeContinuedTask setTaskCompletedWithSuccess:YES];
        self.activeContinuedTask = nil;
    }

    self.activeContinuedTask = task;
    self.lastContinuedFailureReason = nil;
    self.continuedTaskStartDate = [NSDate date];
    task.progress.totalUnitCount = 10000;
    task.progress.completedUnitCount = 1;
    [task updateTitle:[self currentTaskTitle] subtitle:[self formattedSubtitleWithElapsed:0]];

    __weak typeof(self) weakSelf = self;
    __weak BGContinuedProcessingTask *weakTask = task;
    task.expirationHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        __strong BGContinuedProcessingTask *strongTask = weakTask;
        if (strongSelf) {
            dispatch_async(strongSelf.taskQueue, ^{
                [strongSelf handleContinuedTaskExpiredOnQueue:strongTask];
            });
        } else if (strongTask) {
            [strongTask setTaskCompletedWithSuccess:NO];
        }
    };

    [self startHeartbeatTimerOnQueue];

    // If the transition bridge/silent audio fallback had kicked in while waiting for
    // launchHandler, release them now that BGContinuedProcessingTask owns background lifetime.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopSilentAudioSession];
        [self releaseSystemBackgroundTaskAssertion];
    });

    NSString *taskId = task.identifier ?: [self resolvedContinuedTaskIdentifier];
    [self updateStatusDescription:[NSString stringWithFormat:@"iOS 26 BGContinuedProcessingTask active (%@)", taskId]];
}

- (void)handleContinuedTaskExpiredOnQueue:(BGContinuedProcessingTask *)task API_AVAILABLE(ios(26.0)) {
    [self stopHeartbeatTimerOnQueue];
    BOOL wasCurrent = (self.activeContinuedTask == task);
    if (wasCurrent) {
        self.activeContinuedTask = nil;
    }
    self.pendingContinuedSubmission = NO;
    if (task) {
        [task setTaskCompletedWithSuccess:NO];
    }
    if (!wasCurrent) {
        return;
    }
    self.lastContinuedFailureReason = @"task expired or cancelled";

    dispatch_async(dispatch_get_main_queue(), ^{
        [self releaseSystemBackgroundTaskAssertion];
        id<LCBackgroundTaskApplication> app = LCSharedApplication();
        if (LCIsAnyKeepAliveEnabled() && app && app.applicationState == UIApplicationStateActive) {
            [self updateStatusDescription:@"BGContinuedProcessingTask expired in foreground; re-arming"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (LCIsAnyKeepAliveEnabled() && !atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
                    [self armContinuedTaskFromMainThreadWithCooldown:YES];
                }
            });
        } else if (LCIsAnyKeepAliveEnabled()) {
            [self updateStatusDescription:@"BGContinuedProcessingTask ended in background"];
        }
    });
}

- (void)startHeartbeatTimerOnQueue API_AVAILABLE(ios(26.0)) {
    [self stopHeartbeatTimerOnQueue];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.taskQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)strongSelf.activeContinuedTask;
        if (!task) {
            [strongSelf stopHeartbeatTimerOnQueue];
            return;
        }
        if (!LCIsAnyKeepAliveEnabled()) {
            [strongSelf stopHeartbeatTimerOnQueue];
            strongSelf.activeContinuedTask = nil;
            [task setTaskCompletedWithSuccess:YES];
            return;
        }
        // Keep progress advancing monotonically (< 30s cadence) so iOS 26 dasd
        // never marks the task stalled.
        int64_t completed = task.progress.completedUnitCount + 1;
        if (completed + 10 >= task.progress.totalUnitCount) {
            task.progress.totalUnitCount += 3600;
        }
        task.progress.completedUnitCount = completed;
        NSTimeInterval elapsed = strongSelf.continuedTaskStartDate ? -[strongSelf.continuedTaskStartDate timeIntervalSinceNow] : 0;
        [task updateTitle:[strongSelf currentTaskTitle] subtitle:[strongSelf formattedSubtitleWithElapsed:elapsed]];
    });
    self.progressHeartbeatTimer = timer;
    dispatch_resume(timer);
}
#endif

- (void)stopHeartbeatTimerOnQueue {
    if (self.progressHeartbeatTimer) {
        dispatch_source_cancel(self.progressHeartbeatTimer);
        self.progressHeartbeatTimer = nil;
    }
}

- (void)submitContinuedProcessingTaskIfNeededRespectingCooldown:(BOOL)respectCooldown
                                                   allowInactive:(BOOL)allowInactive
                                                        isActive:(BOOL)isActive {
#if !TARGET_OS_MACCATALYST
    if (@available(iOS 26.0, *)) {
        if (!isActive && !allowInactive) {
            [self updateStatusDescription:@"Waiting for active foreground to arm BGContinuedProcessingTask"];
            return;
        }
        NSString *taskIdentifier = [self resolvedContinuedTaskIdentifier];
        NSString *title = [self currentTaskTitle];
        NSString *subtitle = [self currentBaseSubtitle];
        dispatch_sync(self.taskQueue, ^{
            if (!LCIsAnyKeepAliveEnabled()) {
                return;
            }
            if (self.activeContinuedTask != nil) {
                return;
            }
            if (self.pendingContinuedSubmission) {
                NSTimeInterval age = self.lastSubmitAttemptDate ? -[self.lastSubmitAttemptDate timeIntervalSinceNow] : 999;
                if (age < 10.0) {
                    return;
                }
                self.pendingContinuedSubmission = NO;
            }
            if (respectCooldown && self.lastSubmitAttemptDate && -[self.lastSubmitAttemptDate timeIntervalSinceNow] < 3.0) {
                return;
            }
            self.lastSubmitAttemptDate = [NSDate date];

            if (![self ensureRegisteredForIdentifierOnQueue:taskIdentifier]) {
                [self updateStatusDescription:[NSString stringWithFormat:@"Silent Audio fallback (%@)", self.lastContinuedFailureReason ?: @"register failed"]];
                return;
            }

            BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:taskIdentifier
                                                                                                             title:title
                                                                                                          subtitle:subtitle];
            request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyQueue;
            request.requiredResources = BGContinuedProcessingTaskRequestResourcesDefault;

            NSError *error = nil;
            if ([[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error]) {
                self.pendingContinuedSubmission = YES;
                self.lastContinuedFailureReason = nil;
                [self updateStatusDescription:[NSString stringWithFormat:@"iOS 26 BGContinuedProcessingTask submitted (%@)", taskIdentifier]];
            } else {
                self.pendingContinuedSubmission = NO;
                NSString *errSummary = error
                    ? [NSString stringWithFormat:@"%@ #%ld", error.domain ?: @"Error", (long)error.code]
                    : @"submit returned NO";
                self.lastContinuedFailureReason = errSummary;
                NSLog(@"[LCBackgroundKeepAlive] Failed to submit BGContinuedProcessingTaskRequest (%@): %@", taskIdentifier, error);
                [self updateStatusDescription:[NSString stringWithFormat:@"Silent Audio fallback (submit failed: %@)", errSummary]];
            }
        });
    }
#endif
}

- (void)stopContinuedProcessingTaskWithSuccess:(BOOL)success {
#if !TARGET_OS_MACCATALYST
    if (@available(iOS 26.0, *)) {
        NSString *taskIdentifier = [self resolvedContinuedTaskIdentifier];
        dispatch_sync(self.taskQueue, ^{
            self.pendingContinuedSubmission = NO;
            [self stopHeartbeatTimerOnQueue];
            if (self.activeContinuedTask) {
                BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)self.activeContinuedTask;
                self.activeContinuedTask = nil;
                [task setTaskCompletedWithSuccess:success];
            }
            [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:taskIdentifier];
        });
    }
#endif
}

- (void)refreshActiveContinuedTaskMetadataOnQueue {
#if !TARGET_OS_MACCATALYST
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)self.activeContinuedTask;
        if (!task) {
            return;
        }
        NSTimeInterval elapsed = self.continuedTaskStartDate ? -[self.continuedTaskStartDate timeIntervalSinceNow] : 0;
        [task updateTitle:[self currentTaskTitle] subtitle:[self formattedSubtitleWithElapsed:elapsed]];
    }
#endif
}

#pragma mark - UIBackgroundTask Bridge / Fallback

- (void)acquireSystemBackgroundTaskAssertionWithAutoRenew:(BOOL)autoRenew {
    dispatch_block_t acquireBlock = ^{
        id<LCBackgroundTaskApplication> app = LCSharedApplication();
        if (!app) {
            return;
        }
        if (self.bgTaskId != LCBackgroundTaskInvalid) {
            [app endBackgroundTask:self.bgTaskId];
            self.bgTaskId = LCBackgroundTaskInvalid;
        }
        __weak typeof(self) weakSelf = self;
        self.bgTaskId = [app beginBackgroundTaskWithName:@"com.kdt.livecontainer.keepalive" expirationHandler:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (strongSelf.bgTaskId != LCBackgroundTaskInvalid) {
                [app endBackgroundTask:strongSelf.bgTaskId];
                strongSelf.bgTaskId = LCBackgroundTaskInvalid;
            }
            if (autoRenew && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed) && LCIsAnyKeepAliveEnabled()) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) innerSelf = weakSelf;
                    if (innerSelf && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed) && LCIsAnyKeepAliveEnabled()) {
                        [innerSelf acquireSystemBackgroundTaskAssertionWithAutoRenew:YES];
                    }
                });
            }
        }];
    };
    if ([NSThread isMainThread]) {
        acquireBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), acquireBlock);
    }
}

- (void)releaseSystemBackgroundTaskAssertion {
    dispatch_block_t releaseBlock = ^{
        id<LCBackgroundTaskApplication> app = LCSharedApplication();
        if (!app) {
            return;
        }
        if (self.bgTaskId != LCBackgroundTaskInvalid) {
            [app endBackgroundTask:self.bgTaskId];
            self.bgTaskId = LCBackgroundTaskInvalid;
        }
    };
    if ([NSThread isMainThread]) {
        releaseBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), releaseBlock);
    }
}

#pragma mark - Silent Audio Fallback

- (void)ensureSilentAudioEngine {
    if (_audioEngine) {
        return;
    }
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:8000.0 channels:1];
    AVAudioFrameCount frameCount = 8000;
    _silentBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
    _silentBuffer.frameLength = frameCount;
    if (_silentBuffer.floatChannelData && _silentBuffer.floatChannelData[0]) {
        memset(_silentBuffer.floatChannelData[0], 0, frameCount * sizeof(float));
    }

    _audioEngine = [[AVAudioEngine alloc] init];
    _playerNode = [[AVAudioPlayerNode alloc] init];
    [_audioEngine attachNode:_playerNode];
    [_audioEngine connect:_playerNode to:_audioEngine.mainMixerNode format:format];
    _audioEngine.mainMixerNode.outputVolume = 0.0f;
}

- (void)startSilentAudioSession {
    [self ensureSilentAudioEngine];

    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if ([session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        AVAudioSessionCategoryOptions options = session.categoryOptions
            | AVAudioSessionCategoryOptionMixWithOthers
            | AVAudioSessionCategoryOptionDefaultToSpeaker;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:options
                       error:&error];
    } else {
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&error];
    }
    [session setActive:YES error:&error];

    @try {
        if (!self.audioEngine.isRunning) {
            [self.audioEngine prepare];
            [self.audioEngine startAndReturnError:&error];
        }
        if (self.audioEngine.isRunning && !self.playerNode.isPlaying && self.silentBuffer) {
            [self.playerNode scheduleBuffer:self.silentBuffer
                                     atTime:nil
                                    options:AVAudioPlayerNodeBufferLoops
                          completionHandler:nil];
            [self.playerNode play];
        }
    } @catch (NSException *exception) {
        NSLog(@"[LCBackgroundKeepAlive] Failed to start silent audio engine: %@", exception);
    }
}

- (void)stopSilentAudioSession {
    if (!_audioEngine) {
        return;
    }
    @try {
        if (self.playerNode.isPlaying) {
            [self.playerNode stop];
        }
        if (self.audioEngine.isRunning) {
            [self.audioEngine pause];
        }
    } @catch (NSException *exception) {
        NSLog(@"[LCBackgroundKeepAlive] Failed to stop silent audio engine: %@", exception);
    }
}

@end

#pragma mark - Public Entry Points

void initBackgroundKeepAlive(void) {
    BOOL globalEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCBackgroundKeepAliveEnabled"];
    id appValue = NSUserDefaults.guestAppInfo[@"enableBackgroundKeepAlive"];
    BOOL appEnabled = [appValue respondsToSelector:@selector(boolValue)] ? [appValue boolValue] : NO;
    if (!globalEnabled || !appEnabled) {
        atomic_store_explicit(&gKeepAliveEnabledForGuestApp, false, memory_order_release);
        return;
    }

    atomic_store_explicit(&gKeepAliveEnabledForGuestApp, true, memory_order_release);
    installRenderingGuardHooks();

    LCBackgroundKeepAliveManager *manager = [LCBackgroundKeepAliveManager shared];
    [manager installObserversIfNeeded];
    [manager handleConfigurationChanged];
}

void LCSetHostBackgroundKeepAliveEnabled(BOOL enabled, NSInteger port) {
    if (port > 0) {
        atomic_store_explicit(&gHostHTTPPort, (int)port, memory_order_relaxed);
    }
    atomic_store_explicit(&gHostBackgroundKeepAliveEnabled, enabled ? true : false, memory_order_release);
    LCBackgroundKeepAliveManager *manager = [LCBackgroundKeepAliveManager shared];
    if (enabled) {
        [manager installObserversIfNeeded];
    }
    [manager handleConfigurationChanged];
}

NSString *LCGetBackgroundKeepAliveStatusDescription(void) {
    return [[LCBackgroundKeepAliveManager shared] currentStatusDescription];
}
