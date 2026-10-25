#import <Foundation/Foundation.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN
/// One complete query and its display projection. No per-character jobs,
/// substring queue, or second cache of text results.
@interface GATextQueryModel : NSObject
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, copy, readonly) NSArray<GACharacterGroup *> *groups;
@property(nonatomic, readonly) NSUInteger queryCount;
- (instancetype)initWithFontDocument:(GAFontDocument *)document NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)analyzeText:(NSString *)text
         selections:(NSArray<GAGlyphSelectionRun *> *)selections
          cancelled:(BOOL (^_Nullable)(void))cancelled;
/// Rebinds metrics without querying substitution rules again.
- (void)updateFontDocument:(GAFontDocument *)document;
@end
NS_ASSUME_NONNULL_END
