#import "GAPreviewColors.h"

static BOOL GAAppearanceIsDark(NSAppearance *appearance) {
    NSString *match = [appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

static NSColor *GABoundingBoxShadowColor(void) {
    return [NSColor colorWithName:@"GABoundingBoxShadow"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return [NSColor.blackColor colorWithAlphaComponent:GAAppearanceIsDark(appearance) ? 0.58 : 0.18];
    }];
}

static NSColor *GAAdaptiveGrayColor(NSString *name, CGFloat light, CGFloat dark) {
    return [NSColor colorWithName:name dynamicProvider:^NSColor *(NSAppearance *appearance) {
        CGFloat component = GAAppearanceIsDark(appearance) ? dark : light;
        return [NSColor colorWithSRGBRed:component green:component blue:component alpha:1.0];
    }];
}

NSColor *GABoundingBoxBackgroundColor(void) {
    return GAAdaptiveGrayColor(@"GABoundingBoxBackground", 253.0 / 255.0, 60.0 / 255.0);
}

static NSColor *GAGlyphForegroundColor(void) {
    return GAAdaptiveGrayColor(@"GAGlyphForeground", 0x22 / 255.0, 0xEE / 255.0);
}

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
- (BOOL)matchesColors:(GAPreviewColors *)colors {
    return [_overrides isEqualToDictionary:colors->_overrides];
}
- (BOOL)followsSystemForRole:(GAPreviewColorRole)role {
    return _overrides[@(role)] == nil;
}
- (NSColor *)colorForRole:(GAPreviewColorRole)role {
    NSColor *color = _overrides[@(role)];
    if (color) return color;
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
