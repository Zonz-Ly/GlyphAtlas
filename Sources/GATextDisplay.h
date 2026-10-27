#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Display copy

/// Native AAT display settings only; candidate discovery is independent.
/// Contextual Alternates controls the three contextual/swash alternate selectors;
/// Ligatures controls the eleven ligature selectors. Disabled groups send
/// Off selectors; enabled groups omit settings and preserve the font defaults.
FOUNDATION_EXPORT
CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
                                BOOL ligatures) CF_RETURNS_RETAINED;

/// Builds fixed-GID display text for explicit selections and vertical quotes.
/// Each component keeps its override; the user's source text is untouched.
FOUNDATION_EXPORT NSAttributedString *_Nullable GACreateGlyphDisplayString(
    NSArray<NSNumber *> *glyphIDs, NSString *baseString, NSFont *font,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    NSString *_Nullable (^baseForGlyph)(CGGlyph glyph));
/// Replaces a source range in a display copy and updates its UTF-16 hit map.
FOUNDATION_EXPORT void
GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                          NSMutableArray<NSNumber *> *sourceIndices,
                          NSRange sourceRange, NSAttributedString *replacement);

#pragma mark - Hit mapping

/// Native TextKit GIDs for one source span, distinct from sidebar candidates.
@interface GAGlyphLayoutRun : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@end

/// Private TextKit 2 setting: retain CTLine data during native layout.
@interface NSTextLayoutManager (GAGlyphReadback)
@property(nonatomic) BOOL requiresCTLineRef;
@end

/// Reads native GIDs and maps display clusters back to source UTF-16 ranges.
/// Composed characters and explicit selection ranges remain atomic.
FOUNDATION_EXPORT NSArray<GAGlyphLayoutRun *> *
GAReadDisplayGlyphRuns(NSTextLayoutManager *layout, NSArray<NSNumber *> *sourceIndices,
                       NSArray<NSValue *> *atomicRanges, NSString *sourceText);
NS_ASSUME_NONNULL_END
