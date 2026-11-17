//
//  LCBackgroundKeepAlive.h
//  LiveContainer
//
//  Native background keep-alive for guest apps (opt-in per app).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue whenever the diagnostic keep-alive status string updates.
extern NSNotificationName const LCBackgroundKeepAliveStatusDidChangeNotification;

/// Installs the keep-alive engine if both the global switch and the current
/// guest app switch are enabled. Safe to call once per guest launch.
void initBackgroundKeepAlive(void);

/// Enables or disables background keep-alive for the LiveContainer host app
/// (for example while the built-in HTTP API server is running).
void LCSetHostBackgroundKeepAliveEnabled(BOOL enabled, NSInteger port);

/// YES when keep-alive is enabled for either the current guest app or the host app.
BOOL LCIsBackgroundKeepAliveEnabled(void);

/// YES when guest app keep-alive is enabled and the process is in the background
/// (used by the Metal/OpenGL rendering guard).
BOOL LCIsBackgroundKeepAliveActive(void);

/// YES when host HTTP background keep-alive is enabled.
BOOL LCIsHostBackgroundKeepAliveEnabled(void);

/// Returns a concise, user-visible status describing which keep-alive channel is
/// active or why BGContinuedProcessingTask fell back to silent audio.
NSString *LCGetBackgroundKeepAliveStatusDescription(void);

NS_ASSUME_NONNULL_END
