#import "CDTerminalWindowController.h"
#import "CDPtySession.h"
#import "ClaudeDeckCore.h"
#import <WebKit/WebKit.h>

static NSString *const kDefaultsLastCommand = @"lastSessionCommand";
static NSString *const kDefaultsLastFolder = @"lastSessionFolder";

#pragma mark - Managed (app-hosted) session

@interface CDManagedSession : NSObject
@property (nonatomic, strong) CDPtySession *pty;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *cwd;
@property (nonatomic, copy) NSString *command;
@property (nonatomic) BOOL exited;
@property (nonatomic) BOOL webReady;
@property (nonatomic, strong) NSMutableData *pendingOutput;
@end
@implementation CDManagedSession
@end

#pragma mark - Sidebar row model

typedef NS_ENUM(NSInteger, CDRowKind) { CDRowGroup, CDRowInternal, CDRowExternal };

@interface CDRow : NSObject
@property (nonatomic) CDRowKind kind;
@property (nonatomic, copy) NSString *groupTitle;
@property (nonatomic, strong) CDManagedSession *managed;
@property (nonatomic, strong) CDSession *external; // also set for internal rows when scan data exists
@end
@implementation CDRow
@end

#pragma mark - Window controller

@interface CDTerminalWindowController () <NSTableViewDataSource, NSTableViewDelegate,
                                          WKScriptMessageHandler, CDPtySessionDelegate,
                                          NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSView *terminalContainer;
@property (nonatomic, strong) NSMutableArray<CDManagedSession *> *managed;
@property (nonatomic, copy) NSArray<CDRow *> *rows;
@property (nonatomic, strong) CDManagedSession *selected;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation CDTerminalWindowController

+ (instancetype)shared {
    static CDTerminalWindowController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[CDTerminalWindowController alloc] init]; });
    return instance;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1100, 700)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"ClaudeDeck";
    window.minSize = NSMakeSize(720, 400);
    [window setFrameAutosaveName:@"ClaudeDeckMain"];

    if ((self = [super initWithWindow:window])) {
        _managed = [NSMutableArray array];
        window.delegate = self;
        [self buildUI];
        _refreshTimer = [NSTimer timerWithTimeInterval:2.0 target:self
                                              selector:@selector(refreshSidebar)
                                              userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:content.bounds];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:split];

    // Sidebar: header with + button, then the session table.
    NSView *sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 700)];

    NSButton *addButton = [NSButton buttonWithTitle:@"＋ New Session"
                                             target:self action:@selector(startNewSession)];
    addButton.bezelStyle = NSBezelStyleRounded;
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:addButton];

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"session"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:col];
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 40;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.menu = [self rowContextMenu];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = self.tableView;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [addButton.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:8],
        [addButton.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:8],
        [addButton.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:addButton.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor],
    ]];

    self.terminalContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 820, 700)];
    self.terminalContainer.wantsLayer = YES;
    self.terminalContainer.layer.backgroundColor =
        [NSColor colorWithSRGBRed:0.102 green:0.106 blue:0.118 alpha:1].CGColor;

    [split addArrangedSubview:sidebar];
    [split addArrangedSubview:self.terminalContainer];
    [split setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:0];
    [split setPosition:280 ofDividerAtIndex:0];

    [self showPlaceholder];
    [self refreshSidebar];
}

- (void)showPlaceholder {
    for (NSView *v in self.terminalContainer.subviews.copy) [v removeFromSuperview];
    NSTextField *label = [NSTextField labelWithString:
        @"No session selected.\n\nStart one with ＋ New Session,\nor pick a session from the sidebar."];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = NSColor.tertiaryLabelColor;
    label.font = [NSFont systemFontOfSize:15];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.terminalContainer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.terminalContainer.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.terminalContainer.centerYAnchor],
    ]];
}

#pragma mark Show / activation policy

- (void)showAndActivate {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self refreshSidebar];
}

- (void)windowWillClose:(NSNotification *)note {
    // Sessions keep running; drop back to a menu-bar-only presence.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

#pragma mark New session

- (void)startNewSession {
    [self showAndActivate];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = @"Choose the project folder for the new Claude Code session";
    panel.prompt = @"Start Session";
    NSString *lastFolder = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsLastFolder];
    if (lastFolder) panel.directoryURL = [NSURL fileURLWithPath:lastFolder];

    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *cwd = panel.URL.path;
    [NSUserDefaults.standardUserDefaults setObject:cwd forKey:kDefaultsLastFolder];

    NSString *lastCommand = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsLastCommand]
        ?: @"claude";
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Command";
    alert.informativeText = [NSString stringWithFormat:@"Runs in %@", cwd];
    [alert addButtonWithTitle:@"Start"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.stringValue = lastCommand;
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *command = field.stringValue.length > 0 ? field.stringValue : @"claude";
    [NSUserDefaults.standardUserDefaults setObject:command forKey:kDefaultsLastCommand];

    [self launchCommand:command cwd:cwd];
}

- (void)launchCommand:(NSString *)command cwd:(NSString *)cwd {
    CDManagedSession *m = [CDManagedSession new];
    m.cwd = cwd;
    m.command = command;
    m.pendingOutput = [NSMutableData data];
    m.pty = [[CDPtySession alloc] initWithCommand:command cwd:cwd];
    m.pty.delegate = self;

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"pty"];
    m.webView = [[WKWebView alloc] initWithFrame:self.terminalContainer.bounds configuration:config];
    m.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (@available(macOS 13.3, *)) m.webView.inspectable = YES;

    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSURL *html = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:@"terminal.html"]];
    [m.webView loadFileURL:html allowingReadAccessToURL:[NSURL fileURLWithPath:resources]];

    if (![m.pty start]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Failed to start session";
        [alert runModal];
        return;
    }

    [self.managed addObject:m];
    [self selectManaged:m];
    [self refreshSidebar];
}

#pragma mark Selection

- (void)selectManaged:(CDManagedSession *)m {
    self.selected = m;
    for (NSView *v in self.terminalContainer.subviews.copy) [v removeFromSuperview];
    m.webView.frame = self.terminalContainer.bounds;
    [self.terminalContainer addSubview:m.webView];
    [self.window makeFirstResponder:m.webView];
    [m.webView evaluateJavaScript:@"window.cdFocus && cdFocus()" completionHandler:nil];
    [self syncSelectionHighlight];
}

- (void)syncSelectionHighlight {
    NSInteger idx = -1;
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        if (self.rows[i].kind == CDRowInternal && self.rows[i].managed == self.selected) {
            idx = (NSInteger)i;
            break;
        }
    }
    if (idx >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)idx]
                    byExtendingSelection:NO];
    } else {
        [self.tableView deselectAll:nil];
    }
}

- (BOOL)isInternalPid:(pid_t)pid {
    for (CDManagedSession *m in self.managed) {
        if (m.pty.childPid == pid) return YES;
    }
    return NO;
}

- (void)selectInternalPid:(pid_t)pid {
    [self showAndActivate];
    for (CDManagedSession *m in self.managed) {
        if (m.pty.childPid == pid) { [self selectManaged:m]; return; }
    }
}

- (NSInteger)runningSessionCount {
    NSInteger n = 0;
    for (CDManagedSession *m in self.managed) if (m.pty.running) n++;
    return n;
}

- (void)terminateAllSessions {
    for (CDManagedSession *m in self.managed) [m.pty terminate];
}

#pragma mark Sidebar data

- (void)refreshSidebar {
    if (!self.window.visible && self.managed.count == 0) return;

    NSArray<CDSession *> *scanned = CDScanSessions();
    NSMutableDictionary<NSNumber *, CDSession *> *byPid = [NSMutableDictionary dictionary];
    for (CDSession *s in scanned) byPid[@(s.pid)] = s;

    NSMutableArray<CDRow *> *rows = [NSMutableArray array];

    if (self.managed.count > 0) {
        CDRow *g = [CDRow new];
        g.kind = CDRowGroup;
        g.groupTitle = @"IN CLAUDEDECK";
        [rows addObject:g];
        for (CDManagedSession *m in self.managed) {
            CDRow *r = [CDRow new];
            r.kind = CDRowInternal;
            r.managed = m;
            r.external = m.pty.childPid > 0 ? byPid[@(m.pty.childPid)] : nil;
            [rows addObject:r];
        }
    }

    NSMutableArray<CDRow *> *externals = [NSMutableArray array];
    for (CDSession *s in scanned) {
        if ([self isInternalPid:s.pid]) continue;
        CDRow *r = [CDRow new];
        r.kind = CDRowExternal;
        r.external = s;
        [externals addObject:r];
    }
    if (externals.count > 0) {
        CDRow *g = [CDRow new];
        g.kind = CDRowGroup;
        g.groupTitle = @"EXTERNAL TERMINALS";
        [rows addObject:g];
        [rows addObjectsFromArray:externals];
    }

    self.rows = rows;
    [self.tableView reloadData];
    [self syncSelectionHighlight];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return self.rows[(NSUInteger)row].kind == CDRowGroup;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return self.rows[(NSUInteger)row].kind == CDRowGroup ? 22 : 40;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)rowIdx {
    CDRow *row = self.rows[(NSUInteger)rowIdx];
    NSTextField *label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 2;

    if (row.kind == CDRowGroup) {
        label.stringValue = row.groupTitle;
        label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        label.textColor = NSColor.tertiaryLabelColor;
    } else {
        label.attributedStringValue = [self attributedTitleForRow:row];
    }

    NSView *cell = [[NSView alloc] initWithFrame:NSZeroRect];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (NSColor *)statusColorFor:(CDSession *)s exited:(BOOL)exited {
    if (exited || !s) return NSColor.tertiaryLabelColor;
    switch (s.status) {
        case CDStatusBusy:    return NSColor.systemBlueColor;
        case CDStatusWaiting: return NSColor.systemRedColor;
        case CDStatusIdle:
            if (s.tasksTotal > 0 && s.tasksDone == s.tasksTotal) return NSColor.systemGreenColor;
            return NSColor.secondaryLabelColor;
    }
}

- (NSAttributedString *)attributedTitleForRow:(CDRow *)row {
    CDSession *s = row.external;
    BOOL exited = row.kind == CDRowInternal && row.managed.exited;
    NSString *title = s.title.length > 0 ? s.title
        : (row.kind == CDRowInternal ? row.managed.cwd.lastPathComponent : @"session");
    NSString *statusText = exited ? @"exited" : (s ? s.statusLabel : @"starting");
    NSColor *statusColor = [self statusColorFor:s exited:exited];
    NSString *sub = row.kind == CDRowInternal
        ? row.managed.cwd.lastPathComponent
        : [NSString stringWithFormat:@"%@ · %@", s.cwd.lastPathComponent, s.updatedAgo];

    NSMutableAttributedString *out = [NSMutableAttributedString new];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"● "
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:8],
                     NSForegroundColorAttributeName: statusColor,
                     NSBaselineOffsetAttributeName: @(2)}]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:title
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName: NSColor.labelColor}]];

    if (s && s.tasksTotal > 0) {
        NSString *prog = [NSString stringWithFormat:@"  %ld/%ld", (long)s.tasksDone, (long)s.tasksTotal];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:prog
            attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
                         NSForegroundColorAttributeName:
                             s.tasksDone == s.tasksTotal ? NSColor.systemGreenColor : NSColor.systemOrangeColor}]];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"  %@", statusText]
        attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
                     NSForegroundColorAttributeName: statusColor}]];

    [out appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"\n%@", sub]
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10],
                     NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    return out;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)rowIdx {
    return self.rows[(NSUInteger)rowIdx].kind != CDRowGroup;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    CDRow *row = self.rows[(NSUInteger)idx];
    if (row.kind == CDRowInternal) {
        if (self.selected != row.managed) [self selectManaged:row.managed];
    } else if (row.kind == CDRowExternal) {
        CDFocusSession(row.external);
        [self syncSelectionHighlight]; // keep highlight on the embedded session
    }
}

#pragma mark Row context menu

- (NSMenu *)rowContextMenu {
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    return menu;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger idx = self.tableView.clickedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    CDRow *row = self.rows[(NSUInteger)idx];
    if (row.kind != CDRowInternal) return;
    NSString *title = row.managed.exited ? @"Remove From List" : @"End Session";
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(closeClickedSession:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = row.managed;
    [menu addItem:item];
}

- (void)closeClickedSession:(NSMenuItem *)item {
    CDManagedSession *m = item.representedObject;
    if (!m) return;
    if (m.exited) {
        [m.webView.configuration.userContentController removeScriptMessageHandlerForName:@"pty"];
        [self.managed removeObject:m];
        if (self.selected == m) {
            self.selected = nil;
            [self showPlaceholder];
        }
        [self refreshSidebar];
    } else {
        [m.pty terminate];
    }
}

#pragma mark WKScriptMessageHandler (JS -> pty)

- (CDManagedSession *)managedForWebView:(WKWebView *)webView {
    for (CDManagedSession *m in self.managed) if (m.webView == webView) return m;
    return nil;
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    CDManagedSession *m = [self managedForWebView:(WKWebView *)message.webView];
    if (!m) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:NSDictionary.class]) return;
    NSString *type = body[@"type"];

    if ([type isEqualToString:@"data"]) {
        NSString *data = body[@"data"];
        if ([data isKindOfClass:NSString.class]) {
            [m.pty writeData:[data dataUsingEncoding:NSUTF8StringEncoding]];
        }
    } else if ([type isEqualToString:@"resize"]) {
        [m.pty resizeToCols:[body[@"cols"] intValue] rows:[body[@"rows"] intValue]];
    } else if ([type isEqualToString:@"ready"]) {
        m.webReady = YES;
        if (m.pendingOutput.length > 0) {
            [self writeToWebView:m data:m.pendingOutput];
            m.pendingOutput = [NSMutableData data];
        }
    }
}

#pragma mark CDPtySessionDelegate (pty -> JS)

- (CDManagedSession *)managedForPty:(CDPtySession *)pty {
    for (CDManagedSession *m in self.managed) if (m.pty == pty) return m;
    return nil;
}

- (void)ptySession:(CDPtySession *)session didReceiveData:(NSData *)data {
    CDManagedSession *m = [self managedForPty:session];
    if (!m) return;
    if (!m.webReady) {
        [m.pendingOutput appendData:data];
        return;
    }
    [self writeToWebView:m data:data];
}

- (void)writeToWebView:(CDManagedSession *)m data:(NSData *)data {
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    NSString *js = [NSString stringWithFormat:@"cdWrite('%@')", b64];
    [m.webView evaluateJavaScript:js completionHandler:nil];
}

- (void)runSelfTestAndExit {
    [self showAndActivate];
    [self launchCommand:@"printf 'BRIDGE_OK\\n'; sleep 2" cwd:NSTemporaryDirectory()];
    CDManagedSession *m = self.managed.lastObject;
    if (!m) {
        printf("SELFTEST FAIL: session did not launch\n");
        exit(1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL ready = m.webReady;
        BOOL spawned = m.pty.childPid > 0;
        [m.webView evaluateJavaScript:@"typeof cdWrite"
                    completionHandler:^(id result, NSError *error) {
            BOOL jsOK = [result isKindOfClass:NSString.class] && [result isEqualToString:@"function"];
            if (ready && spawned && jsOK) {
                printf("SELFTEST PASS\n");
                exit(0);
            }
            printf("SELFTEST FAIL: webReady=%d spawned=%d xtermLoaded=%d\n", ready, spawned, jsOK);
            exit(1);
        }];
    });
}

- (void)ptySessionDidExit:(CDPtySession *)session {
    CDManagedSession *m = [self managedForPty:session];
    if (!m) return;
    m.exited = YES;
    [m.webView evaluateJavaScript:@"window.cdNotifyExit && cdNotifyExit()" completionHandler:nil];
    [self refreshSidebar];
}

@end
