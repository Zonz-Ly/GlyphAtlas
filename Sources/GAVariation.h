#import "GABinary.h"
FOUNDATION_EXPORT NSArray<NSNumber *> *
GANormalizeCoordinates(GATableView *fvar, GATableView *avar,
                       NSDictionary<NSNumber *, NSNumber *> *coordinates);
FOUNDATION_EXPORT double GAVariationDelta(GATableView *store, unsigned outer, unsigned inner,
                                          NSArray<NSNumber *> *normalized);
FOUNDATION_EXPORT double GADeviceDelta(GATableView *device, GATableView *store,
                                       NSArray<NSNumber *> *normalized);
