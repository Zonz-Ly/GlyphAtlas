#import <AppKit/AppKit.h>

@class GAFontResource;

NS_ASSUME_NONNULL_BEGIN
@interface GAVariationViewController : NSViewController
@property (nonatomic, copy, nullable) void (^onCoordinatesChanged)(NSDictionary<NSNumber *, NSNumber *> *coordinates);
- (instancetype)initWithResource:(GAFontResource *)resource
                    coordinates:(NSDictionary<NSNumber *, NSNumber *> *)coordinates;
/// Keep numeric input unfocused when the popover is presented.
- (void)prepareWindowFocus;
/// End editing through AppKit and return focus to this popover's NSWindow.
- (void)focusWindow;
@end
NS_ASSUME_NONNULL_END
