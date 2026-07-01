// ClaudeDeck test suite. Builds against ClaudeDeckCore and runs as a plain
// binary (no Xcode/XCTest required): ./test.sh
//
// Fixtures are generated at runtime into a temp dir because the "live
// session" cases need a pid that is actually alive (we use our own).

#import <Foundation/Foundation.h>
#import "../Sources/ClaudeDeckCore.h"
#import "../Sources/CDPtySession.h"

static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d  ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
    } \
} while (0)

static NSString *gRoot;

static void WriteJSON(NSString *relPath, NSDictionary *obj) {
    NSString *path = [gRoot stringByAppendingPathComponent:relPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    [data writeToFile:path atomically:YES];
}

static void WriteRaw(NSString *relPath, NSString *content) {
    NSString *path = [gRoot stringByAppendingPathComponent:relPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSDictionary *SessionJSON(pid_t pid, NSString *sid, NSString *status, NSString *name,
                                 double updatedAt, NSString *kind) {
    return @{
        @"pid": @(pid), @"sessionId": sid, @"cwd": @"/tmp/proj-x", @"name": name,
        @"status": status, @"updatedAt": @(updatedAt), @"kind": kind,
    };
}

static void TestVersionCompare(void) {
    CHECK(CDCompareVersions(@"1.0.0", @"1.0.0") == 0, "equal versions");
    CHECK(CDCompareVersions(@"1.0.0", @"v1.0.0") == 0, "leading v ignored");
    CHECK(CDCompareVersions(@"1.0.0", @"1.0.1") < 0, "patch newer");
    CHECK(CDCompareVersions(@"1.9.0", @"1.10.0") < 0, "numeric not lexicographic");
    CHECK(CDCompareVersions(@"2.0.0", @"1.99.99") > 0, "major wins");
    CHECK(CDCompareVersions(@"1.0", @"1.0.0") == 0, "missing components are zero");
    CHECK(CDCompareVersions(@"1.0.0", @"1.0.0-dev") == 0, "suffix tolerated");
}

static void TestScan(void) {
    pid_t me = getpid();

    // Live sessions in each status, one stale (dead pid), one daemon kind,
    // one malformed file, one non-json file.
    WriteJSON(@"sessions/1.json", SessionJSON(me, @"sid-busy", @"busy", @"busy-one", 3000, @"interactive"));
    WriteJSON(@"sessions/2.json", SessionJSON(me, @"sid-wait", @"waiting", @"wait-one", 2000, @"interactive"));
    WriteJSON(@"sessions/3.json", SessionJSON(me, @"sid-idle", @"idle", @"idle-one", 1000, @"interactive"));
    WriteJSON(@"sessions/4.json", SessionJSON(99999999, @"sid-dead", @"busy", @"dead-one", 9000, @"interactive"));
    WriteJSON(@"sessions/5.json", SessionJSON(me, @"sid-daemon", @"busy", @"daemon-one", 9000, @"daemon"));
    WriteJSON(@"sessions/6.json", SessionJSON(me, @"sid-done", @"idle", @"done-one", 500, @"interactive"));
    WriteRaw(@"sessions/7.json", @"{not json");
    WriteRaw(@"sessions/notes.txt", @"ignore me");

    // Tasks: sid-busy has 1/3 done (one cancelled excluded), sid-done all done.
    WriteJSON(@"tasks/sid-busy/1.json", @{@"status": @"completed"});
    WriteJSON(@"tasks/sid-busy/2.json", @{@"status": @"pending"});
    WriteJSON(@"tasks/sid-busy/3.json", @{@"status": @"in_progress"});
    WriteJSON(@"tasks/sid-busy/4.json", @{@"status": @"cancelled"});
    WriteJSON(@"tasks/sid-done/1.json", @{@"status": @"completed"});
    WriteJSON(@"tasks/sid-done/2.json", @{@"status": @"completed"});
    WriteRaw(@"tasks/sid-busy/.lock", @"");

    NSArray<CDSession *> *sessions = CDScanSessions();

    CHECK(sessions.count == 4, "expected 4 sessions, got %lu", (unsigned long)sessions.count);
    if (sessions.count != 4) return;

    // Sort: waiting, busy, idle (recent first).
    CHECK([sessions[0].name isEqualToString:@"wait-one"], "waiting sorts first, got %s", sessions[0].name.UTF8String);
    CHECK([sessions[1].name isEqualToString:@"busy-one"], "busy second, got %s", sessions[1].name.UTF8String);
    CHECK([sessions[2].name isEqualToString:@"idle-one"], "recent idle third, got %s", sessions[2].name.UTF8String);
    CHECK([sessions[3].name isEqualToString:@"done-one"], "older idle last, got %s", sessions[3].name.UTF8String);

    CHECK([sessions[0].statusLabel isEqualToString:@"needs input"], "waiting label");
    CHECK([sessions[1].statusLabel isEqualToString:@"running"], "busy label");
    CHECK([sessions[2].statusLabel isEqualToString:@"idle"], "idle label (no tasks)");
    CHECK([sessions[3].statusLabel isEqualToString:@"completed"], "idle + all tasks done => completed");

    CDSession *busy = sessions[1];
    CHECK(busy.tasksDone == 1 && busy.tasksTotal == 3,
          "task progress 1/3 (cancelled excluded), got %ld/%ld", (long)busy.tasksDone, (long)busy.tasksTotal);

    CDSession *done = sessions[3];
    CHECK(done.tasksDone == 2 && done.tasksTotal == 2, "all done 2/2");
    CHECK([done.title isEqualToString:@"done-one"], "title uses name");
}

static void TestTitleFallback(void) {
    CDSession *s = [CDSession new];
    s.name = @"";
    s.cwd = @"/Users/x/dev/myproj";
    CHECK([s.title isEqualToString:@"myproj"], "title falls back to folder name");
}

// Delegate that collects pty output and signals exit.
@interface PtyCollector : NSObject <CDPtySessionDelegate>
@property (nonatomic, strong) NSMutableString *output;
@property (nonatomic) BOOL exited;
@end
@implementation PtyCollector
- (instancetype)init {
    if ((self = [super init])) _output = [NSMutableString string];
    return self;
}
- (void)ptySession:(CDPtySession *)session didReceiveData:(NSData *)data {
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) [self.output appendString:s];
}
- (void)ptySessionDidExit:(CDPtySession *)session {
    self.exited = YES;
}
@end

static void TestPtyRoundTrip(void) {
    PtyCollector *collector = [PtyCollector new];
    CDPtySession *pty = [[CDPtySession alloc] initWithCommand:@"printf 'marker-%d\\n' 42"
                                                          cwd:NSTemporaryDirectory()];
    pty.delegate = collector;
    CHECK([pty start], "pty starts");
    CHECK(pty.childPid > 0, "child pid assigned");

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!collector.exited && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    CHECK(collector.exited, "pty exited within deadline");
    CHECK([collector.output containsString:@"marker-42"],
          "pty output contains marker, got: %s", collector.output.UTF8String);
    CHECK(!pty.running, "pty not running after exit");
}

static void TestEmptyDir(void) {
    // Point at a directory with no sessions/ at all.
    setenv("CLAUDE_DECK_HOME", "/nonexistent-claude-deck-test", 1);
    CHECK(CDScanSessions().count == 0, "missing dir yields empty list");
    setenv("CLAUDE_DECK_HOME", gRoot.UTF8String, 1);
}

int main(void) {
    @autoreleasepool {
        gRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"claudedeck-tests-%d", getpid()]];
        [NSFileManager.defaultManager createDirectoryAtPath:gRoot
                                withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("CLAUDE_DECK_HOME", gRoot.UTF8String, 1);

        TestVersionCompare();
        TestScan();
        TestTitleFallback();
        TestEmptyDir();
        TestPtyRoundTrip();

        [NSFileManager.defaultManager removeItemAtPath:gRoot error:nil];

        if (failures == 0) {
            printf("OK — all tests passed\n");
            return 0;
        }
        fprintf(stderr, "%d test(s) failed\n", failures);
        return 1;
    }
}
