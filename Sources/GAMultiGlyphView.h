#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Multi-character view with a bounding box. The text is laid out by an
/// NSTextView (TextKit 2): horizontal and vertical writing, line breaking,
/// vertical forms, per-character orientation and the page size all come from
/// the text system. The view only draws the page behind the text and owns the
/// scroll/zoom geometry.
@interface GAMultiGlyphView : NSView
@property (nonatomic, strong, nullable) GAFontDocument *document;
/// Fraction of the viewport used as the page margin. Shares the single-glyph
/// view default: two zoom-outs from a full page.
@property (nonatomic) CGFloat sideInsetFraction;
/// Whether the definition page and its shadow are drawn. Default YES.
@property (nonatomic) BOOL showsMetrics;
/// Called after the inset changes so sibling views can share one zoom state.
@property (nonatomic, copy, nullable) void (^onSideInsetFractionChanged)(CGFloat fraction);
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic) BOOL vertical;
/// Both optional native shaping switches default to YES.
@property(nonatomic) BOOL usesContextualAlternates;
@property(nonatomic) BOOL usesLigatures;
/// Visible size of the enclosing scroll view; drives wrapping and margins.
@property (nonatomic) NSSize viewportSize;
/// Size needed to show the whole page plus its margins.
@property (nonatomic, readonly) NSSize documentSize;
/// Called when the text layout changes the required document size.
@property (nonatomic, copy, nullable) void (^onContentSizeChanged)(void);
@property(nonatomic, copy, nullable) void (^onGlyphSelected)
    (NSArray<NSNumber *> *glyphIDs, NSRange range);

- (void)setText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups;
- (void)zoomTextIn;
- (void)zoomTextOut;
- (void)resetTextZoom;

@end

NS_ASSUME_NONNULL_END
