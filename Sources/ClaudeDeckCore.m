#import "ClaudeDeckCore.h"
#import <signal.h>

@implementation CDSession

- (NSString *)title {
    if (self.name.length > 0) return self.name;
    return self.cwd.lastPathComponent;
}

- (NSString *)statusLabel {
    switch (self.status) {
        case CDStatusBusy:    return @"running";
        case CDStatusWaiting: return @"needs input";
        case CDStatusIdle:
            if (self.tasksTotal > 0 && self.tasksDone == self.tasksTotal) return @"completed";
            return @"idle";
    }
}

- (NSString *)updatedAgo {
    if (self.updatedAtMs <= 0) return @"";
    NSTimeInterval secs = [NSDate date].timeIntervalSince1970 - self.updatedAtMs / 1000.0;
    if (secs < 0) secs = 0;
    if (secs < 60)    return [NSString stringWithFormat:@"%.0fs", secs];
    if (secs < 3600)  return [NSString stringWithFormat:@"%.0fm", secs / 60];
    if (secs < 86400) return [NSString stringWithFormat:@"%.0fh", secs / 3600];
    return [NSString stringWithFormat:@"%.0fd", secs / 86400];
}
@end

NSString *CDClaudeDir(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CLAUDE_DECK_HOME"];
    if (override.length > 0) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
}

static void ScanTaskProgress(CDSession *s) {
    NSString *dir = [[CDClaudeDir() stringByAppendingPathComponent:@"tasks"]
                     stringByAppendingPathComponent:s.sessionId];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSInteger done = 0, total = 0;
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
        if (!data) continue;
        NSDictionary *task = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![task isKindOfClass:NSDictionary.class]) continue;
        NSString *st = task[@"status"];
        if ([st isEqualToString:@"cancelled"] || [st isEqualToString:@"deleted"]) continue;
        total++;
        if ([st isEqualToString:@"completed"]) done++;
    }
    s.tasksDone = done;
    s.tasksTotal = total;
}

NSArray<CDSession *> *CDScanSessions(void) {
    NSString *dir = [CDClaudeDir() stringByAppendingPathComponent:@"sessions"];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<CDSession *> *out = [NSMutableArray array];
    for (NSString *f in files) {
        if (![f.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
        if (!data) continue;
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![d isKindOfClass:NSDictionary.class]) continue;

        pid_t pid = (pid_t)[d[@"pid"] intValue];
        if (pid <= 0 || kill(pid, 0) != 0) continue; // stale file, process gone

        NSString *kind = d[@"kind"];
        if (kind != nil && ![kind isEqualToString:@"interactive"]) continue; // skip daemon/background sessions

        CDSession *s = [CDSession new];
        s.pid = pid;
        s.sessionId = [d[@"sessionId"] isKindOfClass:NSString.class] ? d[@"sessionId"] : @"";
        s.cwd = [d[@"cwd"] isKindOfClass:NSString.class] ? d[@"cwd"] : @"";
        s.name = [d[@"name"] isKindOfClass:NSString.class] ? d[@"name"] : @"";
        s.updatedAtMs = [d[@"updatedAt"] doubleValue];

        NSString *st = d[@"status"];
        if ([st isEqualToString:@"busy"]) s.status = CDStatusBusy;
        else if ([st isEqualToString:@"waiting"]) s.status = CDStatusWaiting;
        else s.status = CDStatusIdle;

        if (s.sessionId.length > 0) ScanTaskProgress(s);
        [out addObject:s];
    }
    [out sortUsingComparator:^NSComparisonResult(CDSession *a, CDSession *b) {
        if (a.status != b.status) return a.status < b.status ? NSOrderedAscending : NSOrderedDescending;
        if (a.updatedAtMs != b.updatedAtMs) return a.updatedAtMs > b.updatedAtMs ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

NSString *CDRunTool(NSString *path, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) return @"";
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

CDHost CDHostOfPid(pid_t pid, NSString **ttyOut) {
    NSString *tty = CDRunTool(@"/bin/ps", @[@"-o", @"tty=", @"-p", @(pid).stringValue]);
    *ttyOut = (tty.length == 0 || [tty isEqualToString:@"??"]) ? @"" : [@"/dev/" stringByAppendingString:tty];

    pid_t current = pid;
    for (int i = 0; i < 20; i++) {
        NSString *line = CDRunTool(@"/bin/ps", @[@"-o", @"ppid=,comm=", @"-p", @(current).stringValue]);
        if (line.length == 0) break;
        NSRange space = [line rangeOfString:@" "];
        NSString *ppidStr = space.location == NSNotFound ? line : [line substringToIndex:space.location];
        NSString *comm = space.location == NSNotFound ? @"" : [line substringFromIndex:space.location + 1];
        pid_t ppid = (pid_t)ppidStr.intValue;
        if ([comm containsString:@"Terminal.app"]) return CDHostTerminalApp;
        if ([comm containsString:@"iTerm"]) return CDHostTerminalApp; // best effort; tty focus script is Terminal-only
        if ([comm containsString:@"Cursor"]) return CDHostCursor;
        if (ppid <= 1) break;
        current = ppid;
    }
    return CDHostUnknown;
}

NSInteger CDCompareVersions(NSString *a, NSString *b) {
    NSCharacterSet *v = [NSCharacterSet characterSetWithCharactersInString:@"vV"];
    a = [a stringByTrimmingCharactersInSet:v];
    b = [b stringByTrimmingCharactersInSet:v];
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = i < pa.count ? pa[i].integerValue : 0;
        NSInteger y = i < pb.count ? pb[i].integerValue : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}
