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
- (BOOL)updateFontDocument:(GAFontDocument *)document
                cancelled:(BOOL (^_Nullable)(void))cancelled;
@end

#pragma mark - Display groups

/// Build sidebar rows from current scan data and literal selections. This data
/// path is independent of windows and never excludes a result for crossing a seed.
FOUNDATION_EXPORT NSArray<GACharacterGroup *> * _Nullable
GABuildDisplayGroups(NSArray<GACharacterGroup *> *groups, NSString *text,
                     NSArray<GAGlyphSelectionRun *> *selections, GAFontDocument *document,
                     BOOL (^_Nullable cancelled)(void));
/// A complete sidebar and native-preview projection of one query.
@interface GAScanDisplaySnapshot : NSObject
@property (nonatomic, strong) NSArray<GACharacterGroup *> *display;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<GAGlyphSelectionRun *> *selections;
@property (nonatomic, copy, nonnull) NSString *multiText;
/// Locations of zero-width shaping boundaries in multiText.
@property (nonatomic, copy, nonnull) NSIndexSet *multiOmissions;
@property (nonatomic, strong, nonnull) NSArray<GACharacterGroup *> *multiGroups;
@property (nonatomic, strong, nonnull) NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiGroupSources;
@end

FOUNDATION_EXPORT GAScanDisplaySnapshot * _Nullable GABuildScanDisplaySnapshot(NSString *text,
    NSArray<GACharacterGroup *> *groups, BOOL (^_Nullable cancelled)(void));

NS_ASSUME_NONNULL_END
