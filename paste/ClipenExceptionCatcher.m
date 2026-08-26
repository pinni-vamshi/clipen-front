#import "ClipenExceptionCatcher.h"

BOOL ClipenCatchingExceptions(void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[Clipen] Caught NSException that would otherwise have crashed the app: %@\n%@",
              exception, exception.callStackSymbols);
        return NO;
    }
}
