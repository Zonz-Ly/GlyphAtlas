#import <AppKit/AppKit.h>
#import "Font/GAFontEngine.h"
#import "GAPreviewColors.h"

NS_ASSUME_NONNULL_BEGIN

/// Multi-character view with a bounding box. The text is laid out by an
/// NSTextView (TextKit 2): horizontal and vertical writing, line breaking,
/// vertical forms, per-character orientation and the page size all come from
/// the text system. The view only draws the page behind the text and owns the
/// scroll/zoom geometry.
@interface GAMultiGlyphView : NSView
@property(nonatomic, strong) GAPreviewColors *previewColors;
/// Native paragraph line-height multiplier; 1.0 uses the natural line height.
@property(nonatomic) CGFloat lineHeightMultiple;
@property(nonatomic) CGFloat textScale;
/// Inactive previews retain state and lay out once before becoming visible.
@property(nonatomic) BOOL layoutActive;
- (void)refreshPreviewColors;
@property (nonatomic, strong, nullable) GAFontDocument *document;
/// Fraction of the viewport used as the page margin. Shares the single-glyph
/// view default: two zoom-outs from a full page.
@property (nonatomic) CGFloat sideInsetFraction;
/// Whether the definition page and its shadow are drawn. Default YES.
@property (nonatomic) BOOL showsMetrics;
/// Called after the inset changes so sibling views can share one zoom state.
@property (nonatomic, copy, nullable) void (^onSideInsetFractionChanged)(CGFloat fraction);
@property (nonatomic) NSTextAlignment textAlignment;
@property(nonatomic) NSWritingDirection baseWritingDirection;
@property(nonatomic, copy) NSString *typesettingLanguage;
@property (nonatomic) BOOL vertical;
@property(nonatomic, copy) NSArray<NSDictionary *> *featureSettings;
@property(nonatomic) BOOL underlined;
@property(nonatomic) BOOL struckThrough;
@property(nonatomic) BOOL outlined;
- (void)resetLayoutScale;
/// Viewport including the area beneath the toolbar; drives wrapping and margins.
@property (nonatomic) NSSize viewportSize;
/// Height of the toolbar over the scroll view.
@property (nonatomic) CGFloat toolbarTopInset;
@property (nonatomic, readonly) NSRect pageRect;
/// Size needed to show the whole page plus its margins.
@property (nonatomic, readonly) NSSize documentSize;
/// Called when the text layout changes the required document size.
@property (nonatomic, copy, nullable) void (^onContentSizeChanged)(void);
@property(nonatomic, copy, nullable) void (^onGlyphSelected)
    (NSArray<NSNumber *> *glyphIDs, NSRange range, NSArray<NSNumber *> * _Nullable leadingGlyphIDs,
     NSRange leadingRange);

- (void)setText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups
      omissions:(NSIndexSet *)omissions;
- (void)zoomTextIn;
- (void)zoomTextOut;

@end

NS_ASSUME_NONNULL_END
