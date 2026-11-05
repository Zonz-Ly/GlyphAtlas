#import "GAFontResource.h"
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>

#pragma mark - Font files

NSArray<UTType *> *GAFontContentTypes(void) {
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypeFont];
    for (NSString *identifier in @[@"org.w3c.woff", @"org.w3c.woff2"]) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type != nil) {
            [types addObject:type];
        }
    }
    return types;
}

BOOL GAFontURLIsFont(NSURL *url) {
    id value = nil;
    if (![url getResourceValue:&value forKey:NSURLContentTypeKey error:NULL]) {
        return NO;
    }
    if (![value isKindOfClass:UTType.class]) {
        return NO;
    }
    UTType *type = (UTType *)value;
    if ([type conformsToType:UTTypeFont]) {
        return YES;
    }
    NSString *identifier = type.identifier.lowercaseString;
    return [identifier isEqualToString:@"org.w3c.woff"] ||
           [identifier isEqualToString:@"org.w3c.woff2"];
}

mode_t GAFontFileItemType(NSURL *url, NSError **error) {
    struct stat item;
    if (lstat(url.fileSystemRepresentation, &item) == 0)
        return item.st_mode & S_IFMT;
    int code = errno;
    if (code != ENOENT)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSURLErrorKey: url}];
    return 0;
}

static NSError *GAUnavailableFontError(NSURL *openedURL) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError
                           userInfo:@{NSURLErrorKey: openedURL}];
}

NSURL *GAResolveFontFileReference(NSURL *reference, NSURL *openedURL, NSError **error) {
    NSURL *source = reference.filePathURL;
    if (source && GAFontFileItemType(source, error) == S_IFREG &&
        [source.fileReferenceURL isEqual:reference]) return source;
    if (!*error) *error = GAUnavailableFontError(openedURL);
    return nil;
}

NSError *GACopyFontFile(NSURL *reference, NSURL *openedURL, NSURL *destination, BOOL replace) {
    NSError *error = nil;
    NSURL *source = GAResolveFontFileReference(reference, openedURL, &error);
    if (!source) return error;
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *temporaryDirectory = [files URLForDirectory:NSItemReplacementDirectory
                                              inDomain:NSUserDomainMask
                                     appropriateForURL:destination.URLByDeletingLastPathComponent
                                                create:YES error:&error];
    if (temporaryDirectory) {
        NSURL *copy = [temporaryDirectory URLByAppendingPathComponent:destination.lastPathComponent];
        if ([files copyItemAtURL:source toURL:copy error:&error]) {
            // A fresh path URL avoids reusing the identity cached before the copy.
            NSURL *currentReference = [NSURL fileURLWithPath:source.path].fileReferenceURL;
            if (GAFontFileItemType(copy, &error) != S_IFREG || ![currentReference isEqual:reference]) {
                if (!error)
                    error = GAUnavailableFontError(openedURL);
            } else {
                int result = replace
                    ? rename(copy.fileSystemRepresentation, destination.fileSystemRepresentation)
                    : renamex_np(copy.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL);
                if (result != 0) {
                    int code = errno;
                    error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                            userInfo:@{NSURLErrorKey: destination}];
                }
            }
        }
        [files removeItemAtURL:temporaryDirectory error:NULL];
    }
    return error;
}

#pragma mark - Font resources and instances

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
    NSMutableDictionary<NSString *, NSMutableArray<GAFontResource *> *> *families = [NSMutableDictionary dictionary];
    while (remaining.count > 0) {
        id first = remaining.firstObject;
        CTFontRef original = CTFontCreateWithFontDescriptor(
            (__bridge CTFontDescriptorRef)first, 16, NULL);
        NSMutableArray<NSDictionary *> *axes = [CFBridgingRelease(CTFontCopyVariationAxes(original)) mutableCopy]
            ?: [NSMutableArray array];
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        NSMutableDictionary *probe = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < axes.count; i++) {
            NSDictionary *axis = axes[i];
            NSNumber *identifier = axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey];
            if (![axis[(__bridge NSString *)kCTFontVariationAxisNameKey] length]) {
                NSMutableDictionary *named = [axis mutableCopy];
                uint32_t tag = CFSwapInt32HostToBig(identifier.unsignedIntValue);
                named[(__bridge NSString *)kCTFontVariationAxisNameKey] =
                    [[NSString alloc] initWithBytes:&tag length:sizeof(tag) encoding:NSASCIIStringEncoding];
                axes[i] = named;
            }
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
        resource->_name = CFBridgingRelease(CTFontCopyDisplayName(base));
        if (!resource->_name.length)
            resource->_name = NSLocalizedString(@"Untitled Font", @"Font name fallback");
        NSString *familyName = CFBridgingRelease(CTFontCopyLocalizedName(base, kCTFontFamilyNameKey, NULL));
        if (familyName.length > 0) {
            if (families[familyName] == nil) families[familyName] = [NSMutableArray array];
            [families[familyName] addObject:resource];
        }
        NSMutableArray<GAFontInstance *> *instances = [NSMutableArray array];
        [remaining removeObjectAtIndex:0];
        if (axes.count > 0) {
            NSMutableArray *members = [NSMutableArray arrayWithObject:first];
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
            BOOL containsDefault = NO;
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
                instance.name = CFBridgingRelease(CTFontCopyName(font, kCTFontStyleNameKey));
                if (!instance.name.length)
                    instance.name = NSLocalizedString(@"Default", @"Default variable font instance");
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
    for (NSString *familyName in families) {
        NSArray<GAFontResource *> *members = families[familyName];
        if (members.count != 1) continue;
        GAFontResource *resource = members.firstObject;
        if (resource.axes.count == 0) continue;
        resource->_name = familyName;
        resource->_usesFamilyName = YES;
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
