#import "GAPreviewColors.h"
#import "GABoundingBoxView.h"

@implementation GAPreviewColors {
    NSMutableDictionary<NSNumber *, NSColor *> *_overrides;
}
- (instancetype)init {
    self = [super init];
    if (self) _overrides = [NSMutableDictionary dictionary];
    return self;
}
- (BOOL)followsSystem {
    return _overrides.count == 0;
}
- (NSColor *)colorForRole:(GAPreviewColorRole)role {
    return _overrides[@(role)] ?: (role == GAPreviewColorGlyph
        ? GAGlyphForegroundColor() : GABoundingBoxBackgroundColor());
}
- (void)setColor:(NSColor *)color forRole:(GAPreviewColorRole)role {
    _overrides[@(role)] = [color colorWithAlphaComponent:1.0];
}
- (void)followSystem {
    [_overrides removeAllObjects];
}
@end
