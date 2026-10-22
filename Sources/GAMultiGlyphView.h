#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Multi-character canvas. The text is laid out by an NSTextView (TextKit 2):
/// horizontal and vertical writing, line breaking, vertical forms, per-character
/// orientation and the page size all come from the text system. The view only
/// draws the page behind the text and owns the scroll/zoom geometry.
@interface GAMultiGlyphView : NSView
@property (nonatomic, strong, nullable) GAFontDocument *document;
/// Fraction of the viewport used as the page margin. Default 0.11.
@property (nonatomic) CGFloat sideInsetFraction;
/// Whether the definition page and its shadow are drawn. Default YES.
@property (nonatomic) BOOL showsMetrics;
/// Called after the inset changes so sibling views can share one zoom state.
@property (nonatomic, copy, nullable) void (^onSideInsetFractionChanged)(CGFloat fraction);
/// Called after the text scale changes so the controller can keep the page
/// centred in the scroll view.
@property (nonatomic, copy, nullable) void (^onTextScaleChanged)(void);
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic) BOOL vertical;
/// Visible size of the enclosing scroll view; drives wrapping and margins.
@property (nonatomic) NSSize viewportSize;
/// Size needed to show the whole page plus its margins.
@property (nonatomic, readonly) NSSize documentSize;
/// Called when the text layout changes the required document size.
@property (nonatomic, copy, nullable) void (^onContentSizeChanged)(void);
@property (nonatomic, copy, nullable) void (^onGroupSelected)(GACharacterGroup *group);

- (void)setText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups;
- (void)zoomTextIn;
- (void)zoomTextOut;
- (void)resetTextZoom;
/// The page in the view's own coordinates; used to keep the scroll view
/// centred on the page while zooming.
- (NSRect)pageRect;

@end

NS_ASSUME_NONNULL_END
