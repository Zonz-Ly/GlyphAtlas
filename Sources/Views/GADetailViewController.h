#import <AppKit/AppKit.h>
#import "Font/GAFontEngine.h"
#import "GAViewMode.h"
#import "GAPreviewColors.h"

NS_ASSUME_NONNULL_BEGIN

@interface GADetailViewController : NSViewController
@property(nonatomic, strong, readonly) GAPreviewColors *previewColors;
- (void)applyPreviewColorRepresentation:(NSDictionary<NSString *, NSData *> *)representation;
- (void)refreshPreviewColors;
- (void)adjustLineSpacing:(NSInteger)steps;
- (NSDictionary *)currentPreviewSettings;
- (void)applyOpeningSettings:(nullable NSDictionary *)settings;
@property (nonatomic) GAViewMode viewMode;
@property (nonatomic, copy, nullable) void (^onAllGlyphDoubleClick)(GAAllGlyphEntry *entry);
@property(nonatomic, copy, nullable) void (^onGlyphSelected)
    (NSArray<NSNumber *> *glyphIDs, NSRange range);

- (void)setVariant:(nullable GAGlyphVariant *)variant;
- (void)setFontDocument:(nullable GAFontDocument *)document;
- (void)setShowsMetrics:(BOOL)showsMetrics;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (void)zoomBoundingBoxIn;
- (void)zoomBoundingBoxOut;
- (void)revealAllGlyphID:(NSNumber *)glyphID quick:(BOOL)quick;
- (void)setAllGlyphVisibleIDs:(nullable NSIndexSet *)glyphIDs;
- (BOOL)containsAllGlyphAtWindowPoint:(NSPoint)point;
- (void)setMultiText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups
           omissions:(NSIndexSet *)omissions;
- (void)setTextAlignment:(NSTextAlignment)alignment;
- (void)setBaseWritingDirection:(NSWritingDirection)direction;
- (void)setTypesettingLanguage:(NSString *)language;
- (void)setWritingDirectionVertical:(BOOL)vertical;
- (void)setFeatureSettings:(NSArray<NSDictionary *> *)settings;
- (void)setUnderlined:(BOOL)enabled;
- (void)setStruckThrough:(BOOL)enabled;
- (void)setOutlined:(BOOL)enabled;
@end

NS_ASSUME_NONNULL_END
