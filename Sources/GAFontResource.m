#import "GAFontResource.h"

@interface GAFontInstance ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@end
@implementation GAFontInstance
@end

/// Explicit optical coordinates must survive a change in display point size.
static NSDictionary *GAVariationAttributes(NSDictionary *coordinates) {
    return @{
        (__bridge NSString *)kCTFontVariationAttribute: coordinates,
        (__bridge NSString *)kCTFontOpticalSizeAttribute: @"none",
    };
}

/// CoreText can distinguish an implicit default from an explicit default in
/// CFEqual. Passing every descriptor through the same non-default coordinates
/// first makes the final default instances comparable without a CGFont round trip.
static CTFontRef GANormalizedFont(CTFontDescriptorRef descriptor,
                                 NSDictionary *probe, NSDictionary *defaults) {
    CTFontDescriptorRef configured = CTFontDescriptorCreateCopyWithAttributes(
        descriptor, (__bridge CFDictionaryRef)GAVariationAttributes(probe));
    CTFontRef intermediate = CTFontCreateWithFontDescriptor(configured, 16, NULL);
    CFRelease(configured);
    CTFontDescriptorRef final = CTFontDescriptorCreateWithAttributes(
        (__bridge CFDictionaryRef)GAVariationAttributes(defaults));
    CTFontRef font = CTFontCreateCopyWithAttributes(intermediate, 16, NULL, final);
    CFRelease(final);
    CFRelease(intermediate);
    return font;
}

@implementation GAFontResource {
    CTFontDescriptorRef _defaultDescriptor;
}

+ (NSArray<GAFontResource *> *)resourcesFromDescriptors:(NSArray *)descriptors {
    NSMutableArray *remaining = [descriptors mutableCopy];
    NSMutableArray<GAFontResource *> *resources = [NSMutableArray array];
    while (remaining.count > 0) {
        id first = remaining.firstObject;
        CTFontRef original = CTFontCreateWithFontDescriptor(
            (__bridge CTFontDescriptorRef)first, 16, NULL);
        NSArray<NSDictionary *> *axes = CFBridgingRelease(CTFontCopyVariationAxes(original)) ?: @[];
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        NSMutableDictionary *probe = [NSMutableDictionary dictionary];
        for (NSDictionary *axis in axes) {
            NSNumber *identifier = axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey];
            NSNumber *value = axis[(__bridge NSString *)kCTFontVariationAxisDefaultValueKey];
            NSNumber *minimum = axis[(__bridge NSString *)kCTFontVariationAxisMinimumValueKey];
            NSNumber *maximum = axis[(__bridge NSString *)kCTFontVariationAxisMaximumValueKey];
            defaults[identifier] = value;
            probe[identifier] = [minimum isEqualToNumber:value] ? maximum : minimum;
        }
        CTFontRef base = axes.count > 0
            ? GANormalizedFont((__bridge CTFontDescriptorRef)first, probe, defaults)
            : (CTFontRef)CFRetain(original);
        GAFontResource *resource = [[self alloc] init];
        resource->_axes = [axes copy];
        resource->_defaultCoordinates = [defaults copy];
        resource->_defaultDescriptor = CTFontCopyFontDescriptor(base);
        resource->_name = CFBridgingRelease(CTFontCopyFullName(base)) ?: NSLocalizedString(@"Untitled Font", @"Font name fallback");
        NSMutableArray *members = [NSMutableArray arrayWithObject:first];
        [remaining removeObjectAtIndex:0];
        if (axes.count > 0) {
            NSMutableIndexSet *matches = [NSMutableIndexSet indexSet];
            for (NSUInteger i = 0; i < remaining.count; i++) {
                CTFontRef candidate = GANormalizedFont(
                    (__bridge CTFontDescriptorRef)remaining[i], probe, defaults);
                if (CFEqual(base, candidate)) {
                    [members addObject:remaining[i]];
                    [matches addIndex:i];
                }
                CFRelease(candidate);
            }
            [remaining removeObjectsAtIndexes:matches];
        }
        NSMutableArray<GAFontInstance *> *instances = [NSMutableArray array];
        BOOL containsDefault = NO;
        if (axes.count > 0) {
            for (id member in members) {
                CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(
                    (__bridge CTFontDescriptorRef)member,
                    (__bridge CFDictionaryRef)@{(__bridge NSString *)kCTFontOpticalSizeAttribute: @"none"});
                CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 16, NULL);
                CFRelease(descriptor);
                NSMutableDictionary *coordinates = [defaults mutableCopy];
                NSDictionary *variation = CFBridgingRelease(CTFontCopyVariation(font));
                if (variation != nil) [coordinates addEntriesFromDictionary:variation];
                GAFontInstance *instance = [[GAFontInstance alloc] init];
                instance.name = CFBridgingRelease(CTFontCopyName(font, kCTFontStyleNameKey))
                    ?: NSLocalizedString(@"Default", @"Default variable font instance");
                instance.coordinates = coordinates;
                containsDefault |= [coordinates isEqualToDictionary:defaults];
                [instances addObject:instance];
                CFRelease(font);
            }
            if (!containsDefault) {
                GAFontInstance *instance = [[GAFontInstance alloc] init];
                instance.name = NSLocalizedString(@"Default", @"Default variable font instance");
                instance.coordinates = defaults;
                [instances insertObject:instance atIndex:0];
            }
        }
        resource->_instances = [instances copy];
        [resources addObject:resource];
        CFRelease(base);
        CFRelease(original);
    }
    return resources;
}

- (CTFontDescriptorRef)defaultDescriptor { return _defaultDescriptor; }

- (CTFontDescriptorRef)copyDescriptorWithCoordinates:(NSDictionary<NSNumber *,NSNumber *> *)coordinates {
    return CTFontDescriptorCreateCopyWithAttributes(_defaultDescriptor,
        (__bridge CFDictionaryRef)GAVariationAttributes(coordinates));
}

- (void)dealloc { CFRelease(_defaultDescriptor); }
@end
