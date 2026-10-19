#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The point size at which variants are shaped.
FOUNDATION_EXPORT const CGFloat GAFontShapingSize;

/// A small ARC-friendly owner for a CoreText font.
@interface GAFontBox : NSObject
@property (nonatomic, readonly) CTFontRef font;
- (instancetype)initWithFont:(CTFontRef)font;
@end

@interface GAGlyphVariant : NSObject
@property (nonatomic, strong) GAFontBox *fontBox;
@property (nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property (nonatomic, copy) NSArray<NSValue *> *positions;
@property (nonatomic, copy) NSArray<NSString *> *featureSources;
@property (nonatomic, getter=isBase) BOOL base;
@property (nonatomic, copy) NSArray<NSNumber *> *unicodeScalars;
@property (nonatomic, copy) NSString *glyphName;
@property (nonatomic, getter=isLigature) BOOL ligature;
@property (nonatomic) NSRange sourceTextRange;
@property (nonatomic, readonly) NSString *glyphKey;
@end

@interface GACharacterGroup : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSRange textRange;
@property (nonatomic) NSUInteger groupIndex;
@property (nonatomic) NSUInteger seedSpanLength;
@property (nonatomic) BOOL ligatureGroup;
@property (nonatomic) NSUInteger seedOccurrence;
@property (nonatomic, copy) NSArray<GAGlyphVariant *> *variants;
@end

@interface GAFontDocument : NSObject
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(nullable NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, nullable) NSURL *fontURL;
@property (nonatomic, readonly) NSString *fullName;

/// Thread-safe. Returns one group per composed character, in text order.
/// Cancelling \c progress aborts between characters and substrings.
- (NSArray<GACharacterGroup *> *)analyzeText:(NSString *)text
                                    progress:(nullable NSProgress *)progress;
- (NSArray<GACharacterGroup *> *)analyzeText:(NSString *)text;
- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs;

/// Raw ink bounding box of a variant, from glyf/CFF through
/// CTFontGetBoundingRectsForGlyphs. Returns CGRectZero for zero-ink glyphs.
+ (CGRect)inkBoundsForVariant:(GAGlyphVariant *)variant;

/// Advance width/height in font units. Width is the horizontal advance.
/// Height is the vmtx/vhea vertical advance, with ascent + descent as fallback.
+ (CGSize)advanceInFontUnitsForVariant:(GAGlyphVariant *)variant;

/// Whether the font has both vmtx and vhea tables.
+ (BOOL)variantHasVerticalMetrics:(GAGlyphVariant *)variant;
+ (CGFloat)verticalTopSideBearingForVariant:(GAGlyphVariant *)variant;

@end

NS_ASSUME_NONNULL_END
