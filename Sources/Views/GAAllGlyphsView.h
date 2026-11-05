#import <AppKit/AppKit.h>
#import "Font/GAFontEngine.h"
#import "GAPreviewColors.h"

NS_ASSUME_NONNULL_BEGIN

@interface GAAllGlyphsView : NSView
@property(nonatomic) CGFloat cellScale;
- (void)applyPreviewColors:(GAPreviewColors *)colors;
@property (nonatomic, strong, nullable) GAFontDocument *document;
- (void)setVisibleGlyphIDs:(nullable NSIndexSet *)glyphIDs;
@property (nonatomic, copy, nullable) void (^onGlyphDoubleClick)(GAAllGlyphEntry *entry);
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (BOOL)containsGlyphAtWindowPoint:(NSPoint)point;
/// Scrolls the grid so the given glyph ID is visible. `quick` uses the short
/// append flash (0.2 s highlight + 0.8 s fade) instead of the locate animation.
- (void)revealGlyphID:(NSNumber *)glyphID quick:(BOOL)quick;
@end

NS_ASSUME_NONNULL_END
