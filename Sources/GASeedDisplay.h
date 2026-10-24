#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
/// Expands a fixed GID sequence in the private TextKit display string. Each
/// component keeps its own glyph override; the user's source text is untouched.
FOUNDATION_EXPORT NSAttributedString *_Nullable GACreateSeedDisplayString(
    NSArray<NSNumber *> *glyphIDs, NSString *baseString, NSFont *font,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    NSString *_Nullable (^_Nullable baseForGlyph)(CGGlyph glyph));
/// Replaces a source range in a display copy and updates its UTF-16 hit map.
FOUNDATION_EXPORT void GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                                                 NSMutableArray<NSNumber *> *sourceIndices,
                                                 NSRange sourceRange,
                                                 NSAttributedString *replacement);
NS_ASSUME_NONNULL_END
