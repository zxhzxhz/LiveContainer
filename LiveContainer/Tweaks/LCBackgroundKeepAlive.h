//
//  LCBackgroundKeepAlive.h
//  LiveContainer
//
//  Native background keep-alive for guest apps (opt-in per app).
//

#import <Foundation/Foundation.h>

/// Installs the keep-alive engine if both the global switch and the current
/// guest app switch are enabled. Safe to call once per guest launch.
void initBackgroundKeepAlive(void);

/// YES when keep-alive is enabled for the current guest app.
BOOL LCIsBackgroundKeepAliveEnabled(void);

/// YES when keep-alive is enabled and the host is currently in the background.
BOOL LCIsBackgroundKeepAliveActive(void);
