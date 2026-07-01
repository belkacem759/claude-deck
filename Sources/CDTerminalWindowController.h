// Main ClaudeDeck window: session sidebar + embedded terminal pane.
// Sessions started here run on ptys owned by the app (CDPtySession);
// external sessions (Terminal.app / Cursor) are listed too and clicking
// them focuses their host window.

#import <Cocoa/Cocoa.h>

@interface CDTerminalWindowController : NSWindowController

+ (instancetype)shared;

- (void)showAndActivate;
- (void)startNewSession;

// Number of app-hosted sessions whose process is still alive.
- (NSInteger)runningSessionCount;

// True if `pid` is one of the app-hosted sessions.
- (BOOL)isInternalPid:(pid_t)pid;
// Open the window and select the app-hosted session with this pid.
- (void)selectInternalPid:(pid_t)pid;

- (void)terminateAllSessions;

// Headless smoke test used by `ClaudeDeck --selftest` and CI: opens the
// window, spawns a short-lived session, verifies the JS bridge came up,
// prints PASS/FAIL and exits the process.
- (void)runSelfTestAndExit;

@end
