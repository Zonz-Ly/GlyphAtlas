#import <AppKit/AppKit.h>
#import "GAFontEngine.h"
#import "GAViewMode.h"

NS_ASSUME_NONNULL_BEGIN

@interface GADetailViewController : NSViewController
@property (nonatomic) GAViewMode viewMode;
@property (nonatomic, copy, nullable) void (^onAllGlyphDoubleClick)(GAAllGlyphEntry *entry);
@property (nonatomic, copy, nullable) void (^onGroupSelected)(GACharacterGroup *group);

- (void)setVariant:(nullable GAGlyphVariant *)variant;
- (void)setFontDocument:(nullable GAFontDocument *)document;
- (void)setShowsMetrics:(BOOL)showsMetrics;
- (void)zoomCanvasIn;
- (void)zoomCanvasOut;
- (void)resetCanvasZoom;
- (void)zoomAllGlyphsIn;
- (void)zoomAllGlyphsOut;
- (void)resetAllGlyphsZoom;
- (void)revealAllGlyphID:(NSNumber *)glyphID quick:(BOOL)quick;
- (void)setMultiText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups;
- (void)setTextAlignment:(NSTextAlignment)alignment;
- (void)setWritingDirectionVertical:(BOOL)vertical;
- (void)setUsesContextualAlternates:(BOOL)enabled;
- (void)setUsesLigatures:(BOOL)enabled;
- (void)zoomMultiTextIn;
- (void)zoomMultiTextOut;
- (void)resetMultiTextZoom;
@end

NS_ASSUME_NONNULL_END
