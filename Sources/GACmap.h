#import "GABinary.h"
@interface GACmap : NSObject
- (instancetype)initWithView:(GATableView *)view;
- (GAGlyph)nominal:(uint32_t)scalar;
/// nil means unsupported UVS, @0 is a valid explicit missing-glyph mapping.
- (NSNumber *)variation:(uint32_t)scalar selector:(uint32_t)selector;
@end
