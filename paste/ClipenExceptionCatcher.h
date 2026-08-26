#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch, swallowing (and logging)
/// any NSException raised inside it instead of letting it propagate to an
/// uncaught-exception abort. Swift's try?/do-catch cannot intercept a raw
/// NSException — only NSError-bridged throws — so this is the only way to
/// guard calls into system frameworks (like NLContextualEmbedding, which has
/// been observed to raise a bare exception from deep inside its tokenizer
/// for certain input text instead of returning an NSError through its own
/// `throws` API) without a single bad string being able to crash the whole
/// app. Returns YES if `block` completed normally, NO if an exception was
/// caught.
BOOL ClipenCatchingExceptions(void (^block)(void));

NS_ASSUME_NONNULL_END
