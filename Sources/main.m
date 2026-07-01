// ClaudeDeck — menu bar overview of running Claude Code sessions.
//
// Data sources (maintained by Claude Code itself, no hooks needed):
//   ~/.claude/sessions/<pid>.json  -> pid, sessionId, cwd, name, status (busy|waiting|idle), updatedAt
//   ~/.claude/tasks/<sessionId>/*.json -> per-task status, used for "n/m" progress
//
// Click a row to focus the session's terminal: exact tab for Terminal.app
// (AppleScript tty match), project window for Cursor's integrated terminal.

#import <Cocoa/Cocoa.h>
#import "ClaudeDeckCore.h"

#ifndef CLAUDEDECK_VERSION
#define CLAUDEDECK_VERSION "0.0.0-dev"
#endif

static NSString *const kRepoSlug = @"belkacem759/claude-deck";
static NSString *const kDefaultsLastUpdateCheck = @"lastUpdateCheckAt";
static const NSTimeInterval kUpdateCheckInterval = 24 * 60 * 60;

#pragma mark - Focusing the hosting terminal

static BOOL FocusTerminalTab(NSString *tty) {
    if (tty.length == 0) return NO;
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
         "  repeat with w in windows\n"
         "    repeat with t in tabs of w\n"
         "      if tty of t is equal to \"%@\" then\n"
         "        set selected tab of w to t\n"
         "        set index of w to 1\n"
         "        activate\n"
         "        return \"found\"\n"
         "      end if\n"
         "    end repeat\n"
         "  end repeat\n"
         "end tell\n"
         "return \"notfound\"", tty];
    NSString *result = CDRunTool(@"/usr/bin/osascript", @[@"-e", src]);
    return [result isEqualToString:@"found"];
}

static void FocusCursorWindow(NSString *cwd) {
    CDRunTool(@"/usr/bin/open", @[@"-a", @"Cursor", cwd]);
}

static void FocusSession(CDSession *s) {
    pid_t pid = s.pid;
    NSString *cwd = s.cwd;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tty = @"";
        CDHost host = CDHostOfPid(pid, &tty);
        switch (host) {
            case CDHostTerminalApp:
                if (!FocusTerminalTab(tty)) CDRunTool(@"/usr/bin/open", @[@"-a", @"Terminal"]);
                break;
            case CDHostCursor:
                FocusCursorWindow(cwd);
                break;
            case CDHostUnknown:
                if (!FocusTerminalTab(tty)) FocusCursorWindow(cwd);
                break;
        }
    });
}

#pragma mark - App delegate

@interface CDAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSArray<CDSession *> *sessions;
@property (nonatomic, copy) NSString *availableUpdateVersion; // nil when up to date
@property (nonatomic, copy) NSString *availableUpdateURL;
@end

@implementation CDAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];

    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    self.statusItem.menu = menu;

    [self refresh];
    self.timer = [NSTimer timerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];

    // First update check shortly after launch, then daily.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self checkForUpdateIfDue]; });
    NSTimer *updateTimer = [NSTimer timerWithTimeInterval:60 * 60 target:self
                                                 selector:@selector(checkForUpdateIfDue)
                                                 userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:updateTimer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    self.sessions = CDScanSessions();
    [self updateStatusButton];
}

- (void)updateStatusButton {
    NSInteger waiting = 0, busy = 0;
    for (CDSession *s in self.sessions) {
        if (s.status == CDStatusWaiting) waiting++;
        if (s.status == CDStatusBusy) busy++;
    }
    NSStatusBarButton *button = self.statusItem.button;
    NSString *symbol = (busy > 0 || waiting > 0) ? @"terminal.fill" : @"terminal";
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Claude sessions"];
    [img setTemplate:YES];
    button.image = img;
    button.imagePosition = NSImageLeft;

    if (waiting > 0) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont menuBarFontOfSize:0],
            NSForegroundColorAttributeName: NSColor.systemRedColor,
            NSBaselineOffsetAttributeName: @(-1),
        };
        button.attributedTitle = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@" %ld", (long)waiting] attributes:attrs];
    } else {
        button.title = @"";
    }
}

#pragma mark Update check

- (void)checkForUpdateIfDue {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval last = [defaults doubleForKey:kDefaultsLastUpdateCheck];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - last < kUpdateCheckInterval) return;
    [defaults setDouble:now forKey:kDefaultsLastUpdateCheck];

    NSString *api = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepoSlug];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:api]];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    req.timeoutInterval = 15;

    [[NSURLSession.sharedSession dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSString *tag = json[@"tag_name"];
        NSString *url = json[@"html_url"];
        if (![tag isKindOfClass:NSString.class] || tag.length == 0) return;
        if (CDCompareVersions(@CLAUDEDECK_VERSION, tag) >= 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.availableUpdateVersion = tag;
            self.availableUpdateURL = [url isKindOfClass:NSString.class] ? url
                : [NSString stringWithFormat:@"https://github.com/%@/releases/latest", kRepoSlug];
        });
    }] resume];
}

- (void)openUpdatePage:(id)sender {
    if (self.availableUpdateURL.length > 0) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:self.availableUpdateURL]];
    }
}

#pragma mark Menu building

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self refresh];
    [menu removeAllItems];

    if (self.availableUpdateVersion.length > 0) {
        NSString *title = [NSString stringWithFormat:@"⬆ Update available — %@", self.availableUpdateVersion];
        NSMenuItem *update = [[NSMenuItem alloc] initWithTitle:title action:@selector(openUpdatePage:) keyEquivalent:@""];
        update.target = self;
        [menu addItem:update];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    if (self.sessions.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No active sessions" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
    }

    for (CDSession *s in self.sessions) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(sessionClicked:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = s;
        item.attributedTitle = [self rowTitleForSession:s];
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSString *quitTitle = [NSString stringWithFormat:@"Quit ClaudeDeck (v%s)", CLAUDEDECK_VERSION];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:quitTitle action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
}

- (NSColor *)statusColorForSession:(CDSession *)s {
    switch (s.status) {
        case CDStatusBusy:    return NSColor.systemBlueColor;
        case CDStatusWaiting: return NSColor.systemRedColor;
        case CDStatusIdle:
            if (s.tasksTotal > 0 && s.tasksDone == s.tasksTotal) return NSColor.systemGreenColor;
            return NSColor.secondaryLabelColor;
    }
}

- (NSAttributedString *)rowTitleForSession:(CDSession *)s {
    NSFont *bodyFont = [NSFont menuFontOfSize:13];
    NSFont *boldFont = [NSFontManager.sharedFontManager convertFont:bodyFont toHaveTrait:NSBoldFontMask];
    NSFont *smallFont = [NSFont menuFontOfSize:11];
    NSFont *tagFont = [NSFont boldSystemFontOfSize:10];
    NSColor *statusColor = [self statusColorForSession:s];

    NSMutableAttributedString *row = [NSMutableAttributedString new];

    // Line 1: ● name   [n/m] [status]
    [row appendAttributedString:[[NSAttributedString alloc] initWithString:@"● "
        attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:9], NSForegroundColorAttributeName: statusColor,
                     NSBaselineOffsetAttributeName: @(2)}]];
    [row appendAttributedString:[[NSAttributedString alloc] initWithString:s.title
        attributes:@{NSFontAttributeName: boldFont, NSForegroundColorAttributeName: NSColor.labelColor}]];
    [row appendAttributedString:[[NSAttributedString alloc] initWithString:@"   "
        attributes:@{NSFontAttributeName: bodyFont}]];

    if (s.tasksTotal > 0) {
        BOOL allDone = s.tasksDone == s.tasksTotal;
        NSColor *progColor = allDone ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        NSString *prog = [NSString stringWithFormat:@" %ld/%ld ", (long)s.tasksDone, (long)s.tasksTotal];
        [row appendAttributedString:[[NSAttributedString alloc] initWithString:prog
            attributes:@{NSFontAttributeName: tagFont,
                         NSForegroundColorAttributeName: progColor,
                         NSBackgroundColorAttributeName: [progColor colorWithAlphaComponent:0.15]}]];
        [row appendAttributedString:[[NSAttributedString alloc] initWithString:@" "
            attributes:@{NSFontAttributeName: bodyFont}]];
    }

    NSString *tag = [NSString stringWithFormat:@" %@ ", s.statusLabel];
    [row appendAttributedString:[[NSAttributedString alloc] initWithString:tag
        attributes:@{NSFontAttributeName: tagFont,
                     NSForegroundColorAttributeName: statusColor,
                     NSBackgroundColorAttributeName: [statusColor colorWithAlphaComponent:0.15]}]];

    // Line 2: folder · updated ago
    NSString *sub = [NSString stringWithFormat:@"\n    %@ · %@", s.cwd.lastPathComponent, s.updatedAgo];
    [row appendAttributedString:[[NSAttributedString alloc] initWithString:sub
        attributes:@{NSFontAttributeName: smallFont, NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];

    return row;
}

- (void)sessionClicked:(NSMenuItem *)item {
    CDSession *s = item.representedObject;
    if (s) FocusSession(s);
}

@end

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // `--host <pid>` debug mode: report detected terminal host for a pid and exit.
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--host") == 0) {
                NSString *tty = @"";
                CDHost host = CDHostOfPid((pid_t)atoi(argv[i + 1]), &tty);
                const char *name = host == CDHostTerminalApp ? "terminal" : host == CDHostCursor ? "cursor" : "unknown";
                printf("%s\t%s\n", name, tty.UTF8String);
                return 0;
            }
        }
        // `--print` debug mode: dump scanned sessions to stdout and exit.
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--version") == 0) {
                printf("%s\n", CLAUDEDECK_VERSION);
                return 0;
            }
            if (strcmp(argv[i], "--print") == 0) {
                for (CDSession *s in CDScanSessions()) {
                    NSString *prog = s.tasksTotal > 0
                        ? [NSString stringWithFormat:@" %ld/%ld", (long)s.tasksDone, (long)s.tasksTotal] : @"";
                    printf("%d\t%s%s\t%s\t%s\n", s.pid, s.statusLabel.UTF8String, prog.UTF8String,
                           s.title.UTF8String, s.cwd.UTF8String);
                }
                return 0;
            }
        }

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        CDAppDelegate *delegate = [CDAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
