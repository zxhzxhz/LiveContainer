#import "../LiveContainer/utils.h"
#import <dlfcn.h>
#import <objc/message.h>

__attribute__((constructor))
static void LCHTTPServerGuestHookInit(void) {
    // Only inject into single-app guest processes; skip the main UI process
    // (LCLoadTweaksToSelf), LiveProcess.appex (host already runs the server),
    // SideStore, and apps with Hide LiveContainer enabled.
    if (!NSUserDefaults.lcGuestAppId || NSUserDefaults.isLiveProcess || NSUserDefaults.isSideStore) {
        return;
    }
    if ([NSUserDefaults.guestAppInfo[@"hideLiveContainer"] boolValue]) {
        return;
    }
    if (![NSUserDefaults.lcSharedDefaults boolForKey:@"LCHTTPServerEnabled"]) {
        return;
    }

    // Defer dlopen until after LCBootstrap finishes dlopen_nolock and the guest
    // app enters its main runloop.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![NSUserDefaults.lcSharedDefaults boolForKey:@"LCHTTPServerEnabled"]) {
            return;
        }
        NSBundle *hostBundle = NSUserDefaults.lcMainBundle;
        if (!hostBundle) {
            return;
        }
        NSString *swiftUIPath = [hostBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
        void *handle = dlopen(swiftUIPath.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
        if (!handle) {
            NSLog(@"[LCHTTPServerHook] Failed to load LiveContainerSwiftUI.framework: %s", dlerror() ?: "unknown error");
            return;
        }
        Class bootstrapClass = NSClassFromString(@"LCHTTPGuestBootstrap");
        SEL startSelector = NSSelectorFromString(@"startIfEnabledInGuestMode");
        if (bootstrapClass && [bootstrapClass respondsToSelector:startSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(bootstrapClass, startSelector);
        }
    });
}
