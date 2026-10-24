#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// A discovered literal glyph sequence. Ranges use UTF-16 in the supplied text.
@interface GASubstitutionMatch : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property(nonatomic, copy) NSArray<NSString *> *sources;
@property(nonatomic) NSRange sourceRange;
@property(nonatomic) BOOL base;
@end

/// GSUB and AAT morx/mort discovery. Substitution execution, Unicode
/// preprocessing, cluster tracking and glyph positioning are performed by statically linked
/// HarfBuzz. CoreText is used solely to obtain the selected resource's table bytes.
@interface GASubstitutionEngine : NSObject
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(nullable NSDictionary<NSNumber *, NSNumber *> *)coordinates
                     sharing:(nullable GASubstitutionEngine *)source;
@property(nonatomic, readonly) BOOL hasFeatureVariations;
@property(nonatomic, readonly) NSArray<NSDictionary *> *featureSpecifications;
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text;
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs;
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs;
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content;
- (nullable NSNumber *)verticalGlyph:(uint16_t)glyph;
/// Raw execution for command-line conformance tests (not a scan or UI fallback).
- (NSDictionary *)shapeText:(NSString *)text
                   features:(NSDictionary<NSString *, NSNumber *> *)features
                     script:(nullable NSString *)script
                   language:(nullable NSString *)language
                     branch:(NSUInteger)branch;
@end
NS_ASSUME_NONNULL_END
