#import "GAAAT.h"
#import "GAOpenType.h"
@interface GAKerning : NSObject
- (instancetype)initWithKern:(GATableView *)kern kerx:(GATableView *)kerx;
@property(nonatomic, readonly) BOOL empty;
- (void)positionBuffer:(NSMutableArray<GALayoutItem *> *)buffer
              settings:(GALayoutSettings *)settings
                  gdef:(GAGDEF *)gdef;
@end
