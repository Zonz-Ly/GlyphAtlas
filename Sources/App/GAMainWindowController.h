#import <AppKit/AppKit.h>
#import "Views/GAViewMode.h"
#import "Views/GAPreviewColors.h"
#import "Font/GAFontFeatures.h"

NS_ASSUME_NONNULL_BEGIN

@interface GAMainWindowController : NSWindowController
@property (nonatomic, readonly, nullable) NSURL *fontURL;
@property(nonatomic, readonly) NSString *inputText;
- (void)replaceInputText:(NSString *)text;
@property (nonatomic, readonly) GAViewMode viewMode;
@property (nonatomic, copy, readonly) NSArray<NSString *> *allGlyphFeatureTags;
@property (nonatomic, copy, readonly, nullable) NSString *allGlyphFeatureTag;
/// Nil shows the full grid. An empty tag shows glyphs without feature outputs.
- (void)filterAllGlyphsByFeature:(nullable NSString *)tag;
@property (nonatomic, readonly) BOOL showsMetrics;
@property (nonatomic, readonly) NSTextAlignment textAlignment;
@property (nonatomic, readonly) BOOL verticalWriting;
@property(nonatomic, strong, readonly, nullable) GAFontFeatures *fontFeatures;
- (void)loadFontAtURL:(NSURL *)url;
- (void)setViewMode:(GAViewMode)viewMode;
- (void)toggleShowsMetrics;
- (void)zoomIn;
- (void)zoomOut;
- (void)zoomMetricsIn;
- (void)zoomMetricsOut;
- (void)adjustLineSpacing:(NSInteger)steps;
@property(nonatomic, readonly) GAPreviewColors *previewColors;
- (void)applyPreviewColorRepresentation:(NSDictionary<NSString *, NSData *> *)representation;
- (void)setPreviewColor:(NSColor *)color forRole:(GAPreviewColorRole)role;
- (void)followSystemColors;
- (void)resetZoom;
- (void)saveOpeningSettings;
+ (void)restoreOpeningSettings;
@property(nonatomic, readonly) BOOL underlined;
@property(nonatomic, readonly) BOOL struckThrough;
@property(nonatomic, readonly) BOOL outlined;
@property(nonatomic, readonly) NSWritingDirection baseWritingDirection;
@property(nonatomic, readonly) BOOL hasRightToLeftLanguages;
@property(nonatomic, copy, readonly) NSArray<NSString *> *typesettingLanguageTags;
@property(nonatomic, copy, readonly) NSString *typesettingLanguageTag;
- (void)setUnderlined:(BOOL)enabled;
- (void)setStruckThrough:(BOOL)enabled;
- (void)setOutlined:(BOOL)enabled;
- (void)setBaseWritingDirection:(NSWritingDirection)direction;
- (void)setTypesettingLanguageTag:(NSString *)tag;
- (void)setTextAlignment:(NSTextAlignment)alignment;
- (void)setVerticalWriting:(BOOL)vertical;
- (void)applyFontFeatureChoices;
@property (nonatomic, copy, nullable) void (^onFontLoaded)(NSURL *url);
@property (nonatomic, copy, nullable) void (^onFontDropRequest)(NSURL *url);
@end

NS_ASSUME_NONNULL_END
