#import <AppKit/AppKit.h>
#import "GAViewMode.h"

NS_ASSUME_NONNULL_BEGIN

@interface GAMainWindowController : NSWindowController
@property (nonatomic, readonly) GAViewMode viewMode;
@property (nonatomic, readonly) BOOL showsMetrics;
@property (nonatomic, readonly) NSTextAlignment textAlignment;
@property (nonatomic, readonly) BOOL verticalWriting;
- (void)loadFontAtURL:(NSURL *)url;
- (void)setViewMode:(GAViewMode)viewMode;
- (void)toggleShowsMetrics;
- (void)zoomIn;
- (void)zoomOut;
- (void)zoomMetricsIn;
- (void)zoomMetricsOut;
- (void)resetZoom;
- (void)setTextAlignment:(NSTextAlignment)alignment;
- (void)setVerticalWriting:(BOOL)vertical;
@property (nonatomic, copy, nullable) void (^onFontLoaded)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onFontDropRequest)(NSURL *url);
@end

NS_ASSUME_NONNULL_END
