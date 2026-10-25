#import "GAFontEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Build sidebar rows from current scan data and literal selections. This data
/// path is independent of windows and never excludes a result for crossing a seed.
FOUNDATION_EXPORT NSArray<GACharacterGroup *> *
GABuildDisplayGroups(NSArray<GACharacterGroup *> *groups, NSString *text,
                     NSArray<GAGlyphSelectionRun *> *selections, GAFontDocument *document);
NS_ASSUME_NONNULL_END
