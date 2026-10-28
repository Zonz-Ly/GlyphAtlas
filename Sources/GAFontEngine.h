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
- (instancetype)initWithFont:(CTFontRef)font;
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
/// Produced by a query containing explicit glyph selections.
@property(nonatomic) BOOL fromGlyphSeed;
@property (nonatomic) NSRange sourceTextRange;
@property (nonatomic, readonly) NSString *glyphKey;
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

/// Splits text into one group per composed character, preserving UTF-16 ranges.
FOUNDATION_EXPORT NSArray<GACharacterGroup *> *GAGroupsForText(NSString *text);

/// One candidate from a complete text query. Source ranges and target group
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
/// Index of the target composed-character group in the full input.
@property (nonatomic) NSUInteger targetGroupIndex;
@end

@interface GARawScanResult : NSObject
@property (nonatomic, copy) NSArray<GAScanCandidate *> *candidates;
@end

@interface GAFontDocument : NSObject
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(nullable NSURL *)url;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, nullable) NSURL *fontURL;
@property (nonatomic, readonly) NSString *fullName;
@property (nonatomic, readonly) GAFontBox *fontBox;
/// Same resource, new coordinates; shares parsed tables and immutable inventory.
- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor;
/// Rebind existing discoveries without enumerating substitutions again.
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content;
- (GAGlyphVariant *)rebindVariant:(GAGlyphVariant *)variant content:(NSString *)content;


/// All GIDs in the font, including glyphs without Unicode mappings.
- (NSArray<GAAllGlyphEntry *> *)allGlyphEntries;

/// Scans the complete input text with its explicit glyph selections.
/// The underlying query cache is keyed by both text and those selections.
- (GARawScanResult *)rawScanContent:(NSString *)content
                         selections:(NSArray<GAGlyphSelectionRun *> *)selections;

/// Applies a full-text result to its composed-character groups in place.
/// Candidates use targetGroupIndex; source ranges already refer to the full text.
- (void)applyRawResult:(GARawScanResult *)result
                groups:(NSArray<GACharacterGroup *> *)groups;

- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs;

/// Single-GID vertical-substitution output from GSUB `vert`/`vrt2` or AAT,
/// if the font's programs produce one.
- (nullable NSNumber *)verticalSubstituteForGlyph:(CGGlyph)glyph;

/// Page, baseline and ink for a variant, in font units. With
/// `usesVerticalMetrics` YES the height is the vmtx/vhea vertical advance and
/// the baseline comes from the top side bearing (single-glyph view). With NO
/// the height is ascent + descent and the baseline is descent (all-glyphs grid
/// and sidebar thumbnails).
+ (GAGlyphPage)pageForVariant:(GAGlyphVariant *)variant
           usesVerticalMetrics:(BOOL)usesVerticalMetrics;

@end

NS_ASSUME_NONNULL_END
