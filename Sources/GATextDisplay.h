#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

@class GAFontDocument, GAGlyphLayoutRun;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Display copy

/// Native display settings only. Candidate discovery is independent of these
/// switches. Keep the native ligature channel enabled; this font controls the
/// two optional features independently.
FOUNDATION_EXPORT
CTFontRef _Nullable GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
                                          BOOL ligatures) CF_RETURNS_RETAINED;

/// Expands a fixed GID sequence in the private TextKit display string. Each
/// component keeps its own glyph override; the user's source text is untouched.
FOUNDATION_EXPORT NSAttributedString *_Nullable GACreateSeedDisplayString(
    NSArray<NSNumber *> *glyphIDs, NSString *baseString, NSFont *font,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    NSString *_Nullable (^_Nullable baseForGlyph)(CGGlyph glyph));
/// Replaces a source range in a display copy and updates its UTF-16 hit map.
FOUNDATION_EXPORT void
GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                          NSMutableArray<NSNumber *> *sourceIndices,
                          NSRange sourceRange, NSAttributedString *replacement);

#pragma mark - Hit mapping

/// Uses TextKit only for line boundaries. Glyph selection uses our table programs.
FOUNDATION_EXPORT NSArray<GAGlyphLayoutRun *> *
GAPredictDisplayGlyphRuns(NSTextLayoutManager *layout, NSArray *pins, GAFontDocument *document,
                          BOOL contextual, BOOL ligatures, BOOL vertical);
FOUNDATION_EXPORT NSArray<GAGlyphLayoutRun *> *
GAMapGlyphLayoutRuns(NSArray<GAGlyphLayoutRun *> *hits, NSArray<NSNumber *> *sourceIndices,
                     NSArray<NSValue *> *atomicRanges, NSString *sourceText);
NS_ASSUME_NONNULL_END
