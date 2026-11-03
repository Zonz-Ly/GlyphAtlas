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
- (instancetype)initWithRepresentation:(NSDictionary<NSString *, NSData *> *)representation {
    self = [self init];
    if (self) {
        for (NSInteger role = GAPreviewColorGlyph; role <= GAPreviewColorBoundingBox; role++) {
            NSData *data = representation[@(role).stringValue];
            NSColor *color = data ? [NSKeyedUnarchiver unarchivedObjectOfClass:NSColor.class
                fromData:data error:NULL] : nil;
            if (color) _overrides[@(role)] = color;
        }
    }
    return self;
}
- (NSDictionary<NSString *, NSData *> *)representation {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [_overrides enumerateKeysAndObjectsUsingBlock:^(NSNumber *role, NSColor *color, BOOL *stop) {
        (void)stop;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color
            requiringSecureCoding:YES error:NULL];
        if (data) result[role.stringValue] = data;
    }];
    return result;
}
- (NSControlStateValue)systemState {
    if (_overrides.count == 0) return NSControlStateValueOn;
    return _overrides.count == 3 ? NSControlStateValueOff : NSControlStateValueMixed;
}
- (NSColor *)colorForRole:(GAPreviewColorRole)role {
    if (_overrides[@(role)]) return _overrides[@(role)];
    if (role == GAPreviewColorGlyph) return GAGlyphForegroundColor();
    return role == GAPreviewColorBoundingBox ? GABoundingBoxShadowColor() : GABoundingBoxBackgroundColor();
}
- (void)setColor:(NSColor *)color forRole:(GAPreviewColorRole)role {
    _overrides[@(role)] = role == GAPreviewColorBoundingBox ? color : [color colorWithAlphaComponent:1.0];
}
- (void)followSystem {
    [_overrides removeAllObjects];
}
@end
