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
@property (nonatomic, copy) NSArray<NSString *> *featureSources;
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

/// A range-independent scan result for one input context. The cache stores
/// these, keyed by text and explicit glyph selections; a range-bound GAGlyphVariant is created only
/// when the result is applied to the current text.
@interface GAScanCandidate : NSObject
@property (nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property (nonatomic, copy) NSArray<NSValue *> *positions;
@property (nonatomic, strong) GAFontBox *fontBox;
@property (nonatomic, copy) NSArray<NSString *> *sources;
@property (nonatomic, getter=isBase) BOOL base;
@property (nonatomic, getter=isLigature) BOOL ligature;
/// Produced by a query containing explicit glyph selections.
@property(nonatomic) BOOL fromGlyphSeed;
/// UTF-16 range of the cluster relative to the scanned content.
@property (nonatomic) NSRange sourceRange;
/// Composed-character index of the target group relative to the content.
@property (nonatomic) NSUInteger targetOffset;
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
@property (nonatomic, readonly) BOOL hasFeatureVariations;
/// Same resource, new coordinates; shares parsed tables and immutable inventory.
- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor;
/// Rebind existing discoveries without enumerating substitutions again.
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content;
- (GAGlyphVariant *)rebindVariant:(GAGlyphVariant *)variant content:(NSString *)content;


/// All GIDs in the font, including glyphs without Unicode mappings.
- (NSArray<GAAllGlyphEntry *> *)allGlyphEntries;

/// Scans one content (a composed character or a multi-character context) and
/// returns range-independent candidates. Safe to cache by content.
- (GARawScanResult *)rawScanContent:(NSString *)content;
- (GARawScanResult *)rawScanContent:(NSString *)content
                         selections:(NSArray<GAGlyphSelectionRun *> *)selections;

/// Applies a raw scan result to the current groups. Each candidate targets the
/// group at startGroupIndex + targetOffset; ligature source ranges are resolved
/// against contentRange. The group variants are updated in place.
- (void)applyRawResult:(GARawScanResult *)result
          contentRange:(NSRange)contentRange
       startGroupIndex:(NSUInteger)startGroupIndex
                groups:(NSArray<GACharacterGroup *> *)groups;

- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs;

/// GSUB `vert` single-substitution output for a glyph, if the font has one.
- (nullable NSNumber *)verticalSubstituteForGlyph:(CGGlyph)glyph;

/// Raw ink bounding box of a variant, from glyf/CFF through
/// CTFontGetBoundingRectsForGlyphs. Returns CGRectZero for zero-ink glyphs.
+ (CGRect)inkBoundsForVariant:(GAGlyphVariant *)variant;

/// Page, baseline and ink for a variant, in font units. With
/// `usesVerticalMetrics` YES the height is the vmtx/vhea vertical advance and
/// the baseline comes from the top side bearing (single-glyph canvas). With NO
/// the height is ascent + descent and the baseline is descent (all-glyphs grid
/// and sidebar thumbnails).
+ (GAGlyphPage)pageForVariant:(GAGlyphVariant *)variant
           usesVerticalMetrics:(BOOL)usesVerticalMetrics;

/// Advance width/height in font units. Width is the horizontal advance.
/// Height is the vmtx/vhea vertical advance, with ascent + descent as fallback.
+ (CGSize)advanceInFontUnitsForVariant:(GAGlyphVariant *)variant;

/// Whether the font has both vmtx and vhea tables.
+ (BOOL)variantHasVerticalMetrics:(GAGlyphVariant *)variant;
+ (CGFloat)verticalTopSideBearingForVariant:(GAGlyphVariant *)variant;

@end

NS_ASSUME_NONNULL_END
