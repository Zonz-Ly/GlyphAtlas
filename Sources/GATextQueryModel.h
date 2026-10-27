#import <Foundation/Foundation.h>

@class GACharacterGroup, GAFontDocument, GAGlyphSelectionRun;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Query state

/// One complete query and its display projection. No per-character jobs,
/// substring queue, or second cache of text results.
@interface GATextQueryModel : NSObject
@property(nonatomic, copy, readonly) NSArray<GACharacterGroup *> *groups;
- (instancetype)initWithFontDocument:(GAFontDocument *)document NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)analyzeText:(NSString *)text
         selections:(NSArray<GAGlyphSelectionRun *> *)selections
          cancelled:(BOOL (^_Nullable)(void))cancelled;
/// Rebinds metrics without querying substitution rules again.
- (void)updateFontDocument:(GAFontDocument *)document;
@end

#pragma mark - Display groups

/// Build sidebar rows from current scan data and literal selections. This data
/// path is independent of windows and never excludes a result for crossing a seed.
FOUNDATION_EXPORT NSArray<GACharacterGroup *> *
GABuildDisplayGroups(NSArray<GACharacterGroup *> *groups, NSString *text,
                     NSArray<GAGlyphSelectionRun *> *selections, GAFontDocument *document);
NS_ASSUME_NONNULL_END
