#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAMainWindowController : NSWindowController
- (void)loadFontAtURL:(NSURL *)url;
@property (nonatomic, copy, nullable) void (^onFontLoaded)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onFontDropRequest)(NSURL *url);
@end

NS_ASSUME_NONNULL_END
