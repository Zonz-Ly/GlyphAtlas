#import "GAAAT.h"
#import "GACmap.h"
#import "GAKerning.h"
#import <CoreText/CoreText.h>

@interface GAQueryDomain : NSObject
@property(nonatomic) BOOL apple;
@property(nonatomic) NSUInteger branch;
@property(nonatomic, strong) GAAATSelector *selector;
@end
/// Shared, parsed resource. Coordinates and execution buffers belong to the
/// caller.
@interface GAFontProgram : NSObject
- (instancetype)initWithFont:(CTFontRef)font;
@property(nonatomic, readonly) GACmap *cmap;
@property(nonatomic, readonly) GAGDEF *gdef;
@property(nonatomic, readonly) GAOpenType *gsub, *gpos;
@property(nonatomic, readonly) GAAAT *aat;
@property(nonatomic, readonly) GAKerning *kerning;
@property(nonatomic, readonly) GATableView *fvar, *avar;
@property(nonatomic, readonly) BOOL verticalAAT;
@property(nonatomic, readonly) unsigned glyphCount;
@property(nonatomic, readonly) double unitsPerEm;
@property(nonatomic, readonly) NSArray<GAQueryDomain *> *domains;
@property(nonatomic, readonly) NSArray<GAOTFeature *> *specifications;
@property(nonatomic, readonly) NSCache<id, NSDictionary *> *cache;
@property(nonatomic, readonly) NSCache<NSNumber *, NSArray<NSDictionary *> *> *relatedCache;
@property(nonatomic, readonly) NSMutableOrderedSet<NSString *> *errors;
- (void)substitute:(NSMutableArray<GALayoutItem *> *)items
            domain:(GAQueryDomain *)domain
          settings:(GALayoutSettings *)settings
             trace:(GALayoutTrace *)trace;
@end
