#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, GAPreviewColorRole) {
    GAPreviewColorGlyph,
    GAPreviewColorBackground,
    GAPreviewColorBoundingBox,
};

/// Per-window preview overrides. Sidebar controls retain their system colors.
@interface GAPreviewColors : NSObject
@property(nonatomic, readonly) NSControlStateValue systemState;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSData *> *representation;
- (instancetype)initWithRepresentation:(nullable NSDictionary<NSString *, NSData *> *)representation;
- (NSColor *)colorForRole:(GAPreviewColorRole)role;
- (void)setColor:(NSColor *)color forRole:(GAPreviewColorRole)role;
- (void)followSystem;
@end
NS_ASSUME_NONNULL_END
