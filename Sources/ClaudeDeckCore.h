// ClaudeDeck core — session scanning, status model, terminal-host detection.
// UI-free so it can be exercised by the test binary.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CDStatus) {
    CDStatusWaiting = 0, // needs input — sorts first
    CDStatusBusy    = 1, // running
    CDStatusIdle    = 2, // finished / awaiting next prompt
};

@interface CDSession : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *cwd;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CDStatus status;
@property (nonatomic) double updatedAtMs;
@property (nonatomic) NSInteger tasksDone;
@property (nonatomic) NSInteger tasksTotal;

- (NSString *)title;
- (NSString *)statusLabel;
- (NSString *)updatedAgo;
@end

// Base directory holding sessions/ and tasks/. Defaults to ~/.claude;
// override with the CLAUDE_DECK_HOME environment variable (used by tests).
NSString *CDClaudeDir(void);

// All live interactive sessions, sorted: needs-input, running, idle;
// then most recently updated first. Sessions whose pid is gone are skipped.
NSArray<CDSession *> *CDScanSessions(void);

// Run a CLI tool, return trimmed stdout ("" on failure).
NSString *CDRunTool(NSString *path, NSArray<NSString *> *args);

typedef NS_ENUM(NSInteger, CDHost) { CDHostTerminalApp, CDHostCursor, CDHostUnknown };

// Walk the process tree to find which terminal app hosts `pid`.
// On return *ttyOut holds the controlling tty ("/dev/ttysNNN", or "").
CDHost CDHostOfPid(pid_t pid, NSString **ttyOut);

// Compare dotted version strings ("1.2.3", tolerates a leading "v").
// Returns <0 if a<b, 0 if equal, >0 if a>b.
NSInteger CDCompareVersions(NSString *a, NSString *b);
