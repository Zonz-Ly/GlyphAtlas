#import "GAPreviewColors.h"

static BOOL GAAppearanceIsDark(NSAppearance *appearance) {
    NSString *match = [appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

NSColor *GABoundingBoxShadowColor(void) {
    return [NSColor colorWithName:@"GABoundingBoxShadow"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return [NSColor.blackColor colorWithAlphaComponent:GAAppearanceIsDark(appearance) ? 0.58 : 0.18];
    }];
}

NSColor *GABoundingBoxBackgroundColor(void) {
    return [NSColor colorWithName:@"GABoundingBoxBackground"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return GAAppearanceIsDark(appearance)
            ? [NSColor colorWithSRGBRed:(60.0 / 255.0)
                                   green:(60.0 / 255.0)
                                    blue:(60.0 / 255.0)
                                   alpha:1.0]
            : [NSColor whiteColor];
    }];
}

NSColor *GAGlyphForegroundColor(void) {
    return [NSColor colorWithName:@"GAGlyphForeground"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        CGFloat component = GAAppearanceIsDark(appearance)
            ? (0xEE / 255.0) : (0x22 / 255.0);
        return [NSColor colorWithSRGBRed:component
                                   green:component
                                    blue:component
                                   alpha:1.0];
    }];
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
