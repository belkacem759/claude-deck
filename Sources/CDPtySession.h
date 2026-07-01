// A shell command running on a pty owned by ClaudeDeck (used to host
// interactive `claude` sessions inside the app).

#import <Foundation/Foundation.h>

@class CDPtySession;

@protocol CDPtySessionDelegate <NSObject>
// Called on the main queue.
- (void)ptySession:(CDPtySession *)session didReceiveData:(NSData *)data;
- (void)ptySessionDidExit:(CDPtySession *)session;
@end

@interface CDPtySession : NSObject

@property (nonatomic, weak) id<CDPtySessionDelegate> delegate;
@property (nonatomic, readonly) pid_t childPid; // == the claude pid once exec'd
@property (nonatomic, readonly, copy) NSString *cwd;
@property (nonatomic, readonly) BOOL running;

// command is run as: zsh -il -c "exec <command>" so the user's login
// environment (PATH etc.) applies and the child keeps our forked pid.
- (instancetype)initWithCommand:(NSString *)command cwd:(NSString *)cwd;

- (BOOL)start;
- (void)writeData:(NSData *)data;
- (void)resizeToCols:(int)cols rows:(int)rows;
- (void)terminate;

@end
