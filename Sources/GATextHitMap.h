#import <AppKit/AppKit.h>
#import "GAFontEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Uses TextKit only for line boundaries. Glyph selection uses our table programs.
FOUNDATION_EXPORT NSArray<GAGlyphLayoutRun *> *
GAPredictDisplayGlyphRuns(NSTextLayoutManager *layout, NSArray *pins, GAFontDocument *document,
                          BOOL contextual, BOOL ligatures, BOOL vertical);
FOUNDATION_EXPORT NSArray<GAGlyphLayoutRun *> *
GAMapGlyphLayoutRuns(NSArray<GAGlyphLayoutRun *> *hits, NSArray<NSNumber *> *sourceIndices,
                     NSArray<NSValue *> *atomicRanges, NSString *sourceText);
NS_ASSUME_NONNULL_END
