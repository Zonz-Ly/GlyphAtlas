#import <AppKit/AppKit.h>

@class GAGlyphVariant;

NS_ASSUME_NONNULL_BEGIN

@interface GAVariantCellView : NSTableCellView
- (void)configureWithVariant:(GAGlyphVariant *)variant;
+ (CGFloat)rowHeightForVariant:(GAGlyphVariant *)variant;
@end

NS_ASSUME_NONNULL_END
