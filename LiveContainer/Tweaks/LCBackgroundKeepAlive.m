//
//  LCBackgroundKeepAlive.m
//  LiveContainer
//
//  Keeps the guest process alive in the background with a silent audio session
//  plus a UIBackgroundTask assertion, and stops GPU presentation while the app
//  is not visible so the render loop cannot deadlock.
//

#import "LCBackgroundKeepAlive.h"
#import "../utils.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <dlfcn.h>
#include <string.h>
#include "../../litehook/src/litehook.h"

static atomic_bool gLCIsInBackground = ATOMIC_VAR_INIT(false);
static BOOL gKeepAliveEnabledForCurrentApp = NO;

BOOL LCIsBackgroundKeepAliveEnabled(void) {
    return gKeepAliveEnabledForCurrentApp;
}

BOOL LCIsBackgroundKeepAliveActive(void) {
    return gKeepAliveEnabledForCurrentApp && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed);
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

#pragma mark - Background task assertion

static const NSUInteger LCBackgroundTaskInvalid = NSUIntegerMax;

@protocol LCBackgroundTaskApplication <NSObject>
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

#pragma mark - Keep-alive manager

@interface LCBackgroundKeepAliveManager : NSObject
@property (nonatomic, assign) NSUInteger bgTaskId;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong) AVAudioPCMBuffer *silentBuffer;
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
        [self setupSilentAudioEngine];
    }
    return self;
}

- (void)setupSilentAudioEngine {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:8000.0 channels:1];
    AVAudioFrameCount frameCount = 8000; // one second of silence, minimal CPU cost
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

- (void)onAppDidEnterBackground:(NSNotification *)notification {
    if (atomic_exchange_explicit(&gLCIsInBackground, true, memory_order_acq_rel)) {
        return;
    }
    [self acquireSystemBackgroundTaskAssertion];
    [self startSilentAudioSession];
}

- (void)onAppWillEnterForeground:(NSNotification *)notification {
    if (!atomic_exchange_explicit(&gLCIsInBackground, false, memory_order_acq_rel)) {
        return;
    }
    [self stopSilentAudioSession];
    [self releaseSystemBackgroundTaskAssertion];
}

- (void)acquireSystemBackgroundTaskAssertion {
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
        // Renew the assertion while the app is still in the background, but
        // throttle the retry so a suspended app cannot spin the CPU.
        if (atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (innerSelf && atomic_load_explicit(&gLCIsInBackground, memory_order_relaxed)) {
                    [innerSelf acquireSystemBackgroundTaskAssertion];
                }
            });
        }
    }];
}

- (void)releaseSystemBackgroundTaskAssertion {
    id<LCBackgroundTaskApplication> app = LCSharedApplication();
    if (!app) {
        return;
    }
    if (self.bgTaskId != LCBackgroundTaskInvalid) {
        [app endBackgroundTask:self.bgTaskId];
        self.bgTaskId = LCBackgroundTaskInvalid;
    }
}

- (void)startSilentAudioSession {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // MixWithOthers keeps the guest app's own audio working and never takes
    // playback focus away from other apps. Preserve PlayAndRecord if the guest
    // app is using microphone input.
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
    // Do not deactivate the shared audio session here: the guest app may still
    // be using it, and deactivating would cut its audio output.
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

void initBackgroundKeepAlive(void) {
    BOOL globalEnabled = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCBackgroundKeepAliveEnabled"];
    id appValue = NSUserDefaults.guestAppInfo[@"enableBackgroundKeepAlive"];
    BOOL appEnabled = [appValue respondsToSelector:@selector(boolValue)] ? [appValue boolValue] : NO;
    if (!globalEnabled || !appEnabled) {
        gKeepAliveEnabledForCurrentApp = NO;
        return;
    }

    gKeepAliveEnabledForCurrentApp = YES;
    installRenderingGuardHooks();

    LCBackgroundKeepAliveManager *manager = [LCBackgroundKeepAliveManager shared];
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:manager selector:@selector(onAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notificationCenter addObserver:manager selector:@selector(onAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    if (NSUserDefaults.isLiveProcess) {
        [notificationCenter addObserver:manager selector:@selector(onAppDidEnterBackground:) name:NSExtensionHostDidEnterBackgroundNotification object:nil];
        [notificationCenter addObserver:manager selector:@selector(onAppWillEnterForeground:) name:NSExtensionHostWillEnterForegroundNotification object:nil];
    }

    [notificationCenter addObserverForName:AVAudioSessionInterruptionNotification
                                    object:nil
                                     queue:[NSOperationQueue mainQueue]
                                usingBlock:^(NSNotification *note) {
        NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == (NSUInteger)AVAudioSessionInterruptionTypeEnded && LCIsBackgroundKeepAliveActive()) {
            [manager startSilentAudioSession];
        }
    }];
}
