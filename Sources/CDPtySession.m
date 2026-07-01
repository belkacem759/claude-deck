#import "CDPtySession.h"
#import <util.h>
#import <sys/ioctl.h>
#import <sys/wait.h>
#import <signal.h>

@implementation CDPtySession {
    int _masterFd;
    dispatch_source_t _readSource;
    dispatch_source_t _exitSource;
    NSString *_command;
}

- (instancetype)initWithCommand:(NSString *)command cwd:(NSString *)cwd {
    if ((self = [super init])) {
        _command = [command copy];
        _cwd = [cwd copy];
        _masterFd = -1;
        _childPid = -1;
    }
    return self;
}

- (BOOL)start {
    int master = -1, slave = -1;
    struct winsize ws = { .ws_row = 30, .ws_col = 100 };
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) return NO;

    NSString *shellCmd = [NSString stringWithFormat:@"exec %@", _command];
    const char *cwd = _cwd.fileSystemRepresentation;
    const char *cmd = shellCmd.UTF8String;
    const char *home = NSHomeDirectory().fileSystemRepresentation;
    const char *user = NSUserName().UTF8String;

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        close(slave);
        return NO;
    }
    if (pid == 0) {
        // Child: async-signal-safe calls only until exec.
        close(master);
        login_tty(slave); // setsid + controlling tty + stdio on the pty
        if (chdir(cwd) != 0) chdir(home);
        const char *env[] = {
            "TERM=xterm-256color",
            "LANG=en_US.UTF-8",
            "COLORTERM=truecolor",
            NULL, NULL, NULL, // HOME, USER filled below
        };
        char homeBuf[1024], userBuf[256];
        snprintf(homeBuf, sizeof(homeBuf), "HOME=%s", home);
        snprintf(userBuf, sizeof(userBuf), "USER=%s", user);
        env[3] = homeBuf;
        env[4] = userBuf;
        execle("/bin/zsh", "zsh", "-il", "-c", cmd, NULL, env);
        _exit(127);
    }

    // Parent
    close(slave);
    _masterFd = master;
    _childPid = pid;
    _running = YES;

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    __weak typeof(self) weakSelf = self;

    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)master, 0, queue);
    dispatch_source_set_event_handler(_readSource, ^{
        char buf[65536];
        ssize_t n = read(master, buf, sizeof(buf));
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        if (n > 0) {
            NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self_.delegate ptySession:self_ didReceiveData:data];
            });
        } else {
            [self_ handleHangup];
        }
    });
    dispatch_resume(_readSource);

    _exitSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                         DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(_exitSource, ^{
        int status = 0;
        waitpid(pid, &status, WNOHANG);
        typeof(self) self_ = weakSelf;
        if (self_) [self_ handleHangup];
    });
    dispatch_resume(_exitSource);

    return YES;
}

- (void)handleHangup {
    @synchronized (self) {
        if (!_running) return;
        _running = NO;
    }
    if (_readSource) { dispatch_source_cancel(_readSource); _readSource = nil; }
    if (_exitSource) { dispatch_source_cancel(_exitSource); _exitSource = nil; }
    if (_masterFd >= 0) { close(_masterFd); _masterFd = -1; }
    waitpid(_childPid, NULL, WNOHANG); // reap if not already
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (self_) [self_.delegate ptySessionDidExit:self_];
    });
}

- (void)writeData:(NSData *)data {
    @synchronized (self) {
        if (!_running || _masterFd < 0) return;
        const char *bytes = data.bytes;
        NSUInteger remaining = data.length;
        while (remaining > 0) {
            ssize_t n = write(_masterFd, bytes, remaining);
            if (n <= 0) break;
            bytes += n;
            remaining -= (NSUInteger)n;
        }
    }
}

- (void)resizeToCols:(int)cols rows:(int)rows {
    @synchronized (self) {
        if (!_running || _masterFd < 0 || cols <= 0 || rows <= 0) return;
        struct winsize ws = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
        ioctl(_masterFd, TIOCSWINSZ, &ws);
    }
}

- (void)terminate {
    pid_t pid;
    @synchronized (self) {
        if (!_running) return;
        pid = _childPid;
    }
    // SIGHUP first (what closing a terminal window sends), escalate if ignored.
    kill(pid, SIGHUP);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        kill(pid, SIGKILL);
    });
}

- (void)dealloc {
    if (_running) [self terminate];
}

@end
