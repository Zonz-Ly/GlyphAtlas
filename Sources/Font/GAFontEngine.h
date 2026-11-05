#import <Foundation/Foundation.h>
#import "GAGlyphSelection.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The point size at which variants are shaped.
FOUNDATION_EXPORT const CGFloat GAFontShapingSize;

/// A small ARC-friendly owner for a CoreText font.
@interface GAFontBox : NSObject
@property (nonatomic, readonly) CTFontRef font;
@end

/// Minimal glyph inventory used by the all-glyphs grid.
@interface GAAllGlyphEntry : NSObject
@property (nonatomic, copy) NSNumber *glyphID;
@property (nonatomic, copy) NSArray<NSNumber *> *unicodeScalars;
@end

@interface GAGlyphVariant : NSObject
@property (nonatomic, strong) GAFontBox *fontBox;
@property (nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
/// Optional shaping origins for drawing. May be empty; drawing consumers treat
/// missing entries as CGPointZero.
@property (nonatomic, copy) NSArray<NSValue *> *positions;
@property (nonatomic, copy, readonly) NSArray<NSString *> *featureSources;
- (void)addFeatureSources:(NSArray<NSString *> *)sources;
@property (nonatomic, getter=isBase) BOOL base;
@property (nonatomic, copy) NSArray<NSNumber *> *unicodeScalars;
@property (nonatomic, copy) NSString *glyphName;
@property (nonatomic, getter=isLigature) BOOL ligature;
/// A lazy sidebar-only row, never part of a group's persistent variants.
@property (nonatomic, getter=isTemporary) BOOL temporary;
/// Produced by a query containing explicit glyph selections.
@property(nonatomic) BOOL fromGlyphSeed;
@property (nonatomic) NSRange sourceTextRange;
@property (nonatomic, readonly) NSString *glyphKey;
@end

@interface GAGlyphResolution : NSObject
@property(nonatomic, strong) GAGlyphVariant *parent;
@property(nonatomic, strong) GAGlyphVariant *variant;
@end

/// Draws a nonempty variant using the context's current drawing state.
/// Missing origins are CGPointZero; callers manage transforms, color and state.
FOUNDATION_EXPORT void GADrawGlyphVariant(GAGlyphVariant *variant, CGContextRef context);

/// The page used to place a glyph, in font units. `size` is the horizontal
/// advance × the page height; `baseline` is measured up from the page's bottom
/// edge; `ink` is the glyph's outline bounds. The height and baseline depend on
/// `usesVerticalMetrics`.
typedef struct {
    CGSize size;
    CGFloat baseline;
    CGRect ink;
} GAGlyphPage;

@interface GACharacterGroup : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSRange textRange;
@property (nonatomic, copy) NSArray<GAGlyphVariant *> *variants;
/// YES when this group stands in for a selection run: variants.firstObject is
/// the glyph the user activated, not the glyph produced by shaping the text.
@property (nonatomic) BOOL seeded;
/// YES for a ligature group added to the display list for browsing only. It
/// overlaps existing source groups and must not be rendered as text.
@property (nonatomic) BOOL insertedLigature;
@end

/// One verified candidate from a text query. Source ranges and target group
/// indices refer to that input; applying the result needs no substring offset.
@interface GAScanCandidate : NSObject
@property (nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property (nonatomic, copy) NSArray<NSValue *> *positions;
@property (nonatomic, copy) NSArray<NSString *> *sources;
@property (nonatomic, getter=isBase) BOOL base;
@property (nonatomic, getter=isLigature) BOOL ligature;
/// Produced by a query containing explicit glyph selections.
@property(nonatomic) BOOL fromGlyphSeed;
/// UTF-16 range of the cluster relative to the scanned content.
@property (nonatomic) NSRange sourceRange;
/// Index of the target nominal source group in the full input.
@property (nonatomic) NSUInteger targetGroupIndex;
@end

@interface GARawScanResult : NSObject
@property (nonatomic, copy) NSArray<GAScanCandidate *> *candidates;
/// YES if substitution discovery reached its safety limit.
@property (nonatomic) BOOL incomplete;
/// Disjoint nominal component ranges after cmap/Unicode preparation. A source
/// that cannot be edited independently remains one atomic range.
@property(nonatomic, copy) NSArray<NSValue *> *sourceRanges;
@end

/// Builds source groups matching the complete scan's nominal component ranges.
FOUNDATION_EXPORT NSArray<GACharacterGroup *> *GAGroupsForScanResult(NSString *text,
                                                                    GARawScanResult *result);

@interface GAFontDocument : NSObject
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(nullable NSURL *)url;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, nullable) NSURL *fontURL;
@property (nonatomic, readonly) NSString *fullName;
@property (nonatomic, readonly) GAFontBox *fontBox;
/// At least one CoreText-supported language has right-to-left character order.
@property(nonatomic, readonly) BOOL hasRightToLeftLanguages;
/// Named GSUB language tags, deduplicated across scripts.
@property(nonatomic, copy, readonly) NSArray<NSString *> *typesettingLanguageTags;
/// Same resource, new coordinates; shares parsed tables and immutable inventory.
- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor;
/// Rebind existing discoveries without enumerating substitutions again.
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content;
- (GAGlyphVariant *)rebindVariant:(GAGlyphVariant *)variant content:(NSString *)content;

/// All GIDs in the font, including glyphs without Unicode mappings.
- (NSArray<GAAllGlyphEntry *> *)allGlyphEntries;
- (NSArray<NSString *> *)glyphFeatureTags;
/// An empty tag returns the glyphs outside the union of the listed feature outputs.
- (nullable NSIndexSet *)glyphOutputsForFeatureTag:(NSString *)tag
                                          cancelled:(BOOL (^_Nullable)(void))cancelled;

/// Scans the complete input text with its explicit glyph selections.
/// The underlying query cache is keyed by both text and those selections.
- (nullable GARawScanResult *)rawScanContent:(NSString *)content
                                  selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                   cancelled:(BOOL (^_Nullable)(void))cancelled;

/// Applies a full-text result to groups made by GAGroupsForScanResult in place.
/// Candidates use targetGroupIndex; source ranges already refer to the full text.
- (BOOL)applyRawResult:(GARawScanResult *)result
                groups:(NSArray<GACharacterGroup *> *)groups
             cancelled:(BOOL (^_Nullable)(void))cancelled;

- (nullable NSArray<GAGlyphVariant *> *)variantsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                                  cancelled:(BOOL (^_Nullable)(void))cancelled;

/// Resolves a missing native glyph against existing rows at the same source
/// range. Returns a decorated temporary row and its existing parent.
- (nullable GAGlyphResolution *)resolveGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     textRange:(NSRange)range
                                          text:(NSString *)text
                                    selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                        groups:(NSArray<GACharacterGroup *> *)groups
                                      vertical:(BOOL)vertical
                          featureSettings:(NSArray<NSDictionary *> *)featureSettings
                     baseWritingDirection:(NSInteger)direction
                              languageTag:(NSString *)languageTag
                                     cancelled:(BOOL (^)(void))cancelled;

/// Single-GID vertical-substitution output from GSUB `vert`/`vrt2` or AAT,
/// if the font's programs produce one.
- (nullable NSNumber *)verticalSubstituteForGlyph:(CGGlyph)glyph;

/// Page, baseline and ink for a variant, in font units. With
/// `usesVerticalMetrics` YES and vmtx/vhea present, the height is the current
/// vertical advance and the baseline is `height - vertical origin`, where the
/// origin comes from CoreText's per-glyph vertical translation (VORG for CFF,
/// a font-wide origin otherwise; single-glyph view). With NO, or without
/// vmtx/vhea, the height is OS/2 sTypoAscender plus the magnitude of
/// sTypoDescender and the baseline is that magnitude (all-glyphs grid and
/// sidebar thumbnails). Fonts without usable OS/2 typographic metrics keep
/// CoreText ascent + descent.
+ (GAGlyphPage)pageForVariant:(GAGlyphVariant *)variant
           usesVerticalMetrics:(BOOL)usesVerticalMetrics;

@end

NS_ASSUME_NONNULL_END
