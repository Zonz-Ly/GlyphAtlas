#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

@class GAGlyphSelectionRun;

NS_ASSUME_NONNULL_BEGIN
/// A discovered literal glyph sequence. Ranges use UTF-16 in the supplied text.
@interface GASubstitutionMatch : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property(nonatomic, copy) NSArray<NSString *> *sources;
@property(nonatomic) NSRange sourceRange;
@property(nonatomic) BOOL base;
@end

/// One upstream row and the substitution labels from that row to the target.
@interface GASubstitutionOrigin : NSObject
@property(nonatomic) NSUInteger sourceIndex;
@property(nonatomic, copy) NSArray<NSString *> *sources;
@end

/// GSUB and AAT morx/mort discovery using the application's own table programs.
/// CoreText supplies selected-resource bytes and native glyph metrics; Unicode
/// properties and bidi levels come from the system ICU. No shaping scans.
@interface GASubstitutionEngine : NSObject
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(nullable NSDictionary<NSNumber *, NSNumber *> *)coordinates
                     sharing:(nullable GASubstitutionEngine *)source;
/// nil indicates cancellation, distinct from a completed empty result.
/// Incomplete results retain verified candidates but may be retried.
- (nullable NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                                selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                                incomplete:(BOOL * _Nullable)incomplete
                                                 cancelled:(BOOL (^_Nullable)(void))cancelled;
- (nullable NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                                        cancelled:(BOOL (^_Nullable)(void))cancelled;
- (NSArray<NSString *> *)languageTags;
- (NSArray<NSString *> *)glyphFeatureTags;
- (nullable NSIndexSet *)glyphOutputsForFeatureTag:(NSString *)tag
                                          cancelled:(BOOL (^_Nullable)(void))cancelled;
/// Lazy reverse lookup for a missing native layout GID/sequence. Candidate
/// rows all belong to sourceRange, in their existing sidebar order.
- (nullable GASubstitutionOrigin *)originForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                         sourceRange:(NSRange)sourceRange
                                                text:(NSString *)text
                                          selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                          candidates:(NSArray<NSArray<NSNumber *> *> *)candidates
                                            vertical:(BOOL)vertical
                                featureSettings:(NSArray<NSDictionary *> *)featureSettings
                            baseWritingDirection:(NSInteger)direction
                                     languageTag:(NSString *)languageTag
                                           cancelled:(BOOL (^)(void))cancelled;
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content;

- (nullable NSNumber *)verticalGlyph:(uint16_t)glyph;
/// OS/2 sTypo ascender/descender in font units for this coordinate instance,
/// with MVAR hasc/hdsc deltas applied. Descender keeps the font's sign.
/// Returns NO when the font has no usable OS/2 typographic metrics.
- (BOOL)typoMetricsAscender:(CGFloat *)ascender descender:(CGFloat *)descender;
@end
NS_ASSUME_NONNULL_END
