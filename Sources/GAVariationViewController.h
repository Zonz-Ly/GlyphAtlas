#import <AppKit/AppKit.h>
#import "GAFontResource.h"

NS_ASSUME_NONNULL_BEGIN
@interface GAVariationViewController : NSViewController
@property (nonatomic, copy, nullable) void (^onCoordinatesChanged)(NSDictionary<NSNumber *, NSNumber *> *coordinates, BOOL committed);
- (instancetype)initWithResource:(GAFontResource *)resource
                    coordinates:(NSDictionary<NSNumber *, NSNumber *> *)coordinates;
/// Reuse the attached popover's reserved space for the native detached title bar.
- (void)didDetachWithPreviousContentHeight:(CGFloat)height;
@end
NS_ASSUME_NONNULL_END
