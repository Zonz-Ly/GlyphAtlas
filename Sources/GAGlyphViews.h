#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface GARowItem : NSObject
@property (nonatomic, strong, nullable) GACharacterGroup *group;
@property (nonatomic, strong, nullable) GAGlyphVariant *variant;
@end

/// Draws only the glyph itself. Native table rows provide selection and
/// background; this view deliberately does not draw chrome.
@interface GAGlyphView : NSView
@property (nonatomic, strong, nullable) GAGlyphVariant *variant;
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle;
@end

/// A vertical column of native Unicode code badges. Each badge has its own
/// tooltip with that scalar's Unicode name.
@interface GAUnicodeCodesView : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *unicodeScalars;
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle;
+ (CGFloat)heightForScalars:(NSArray<NSNumber *> *)scalars;
+ (CGFloat)widthForScalars:(NSArray<NSNumber *> *)scalars;
@end

@interface GAVariantCellView : NSTableCellView
- (void)configureWithVariant:(GAGlyphVariant *)variant;
+ (CGFloat)rowHeightForVariant:(GAGlyphVariant *)variant;
@end

NS_ASSUME_NONNULL_END
