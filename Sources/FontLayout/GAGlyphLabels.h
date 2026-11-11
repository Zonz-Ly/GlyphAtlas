#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable labels read from one font face. Missing labels are left to the caller.
@interface GAGlyphLabels : NSObject
+ (nullable instancetype)labelsForFont:(CTFontRef)font;
- (nullable NSString *)labelForGlyph:(NSUInteger)glyph;
@end

NS_ASSUME_NONNULL_END
