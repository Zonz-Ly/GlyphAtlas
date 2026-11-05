#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<UTType *> *GAFontContentTypes(void);
FOUNDATION_EXPORT BOOL GAFontURLIsFont(NSURL *url);
/// Inspect the directory entry itself, including broken symlinks.
FOUNDATION_EXPORT mode_t GAFontFileItemType(NSURL *url, NSError * _Nullable *error);
FOUNDATION_EXPORT NSURL * _Nullable GAResolveFontFileReference(NSURL * _Nullable reference,
    NSURL *openedURL, NSError * _Nullable *error);
/// Return the native file error on failure. Stage the copy on the destination volume.
FOUNDATION_EXPORT NSError * _Nullable GACopyFontFile(NSURL * _Nullable reference,
    NSURL *openedURL, NSURL *destination, BOOL replace);

@interface GAFontInstance : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@end

/// One font resource and the named-instance descriptors which resolve to it.
@interface GAFontResource : NSObject
@property (nonatomic, readonly) CTFontDescriptorRef defaultDescriptor;
@property (nonatomic, copy, readonly) NSString *name;
/// Whether this VF uses a localized family name unique among the remaining resources.
@property (nonatomic, readonly) BOOL usesFamilyName;
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *axes;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *defaultCoordinates;
@property (nonatomic, copy, readonly) NSArray<GAFontInstance *> *instances;
+ (NSArray<GAFontResource *> *)resourcesFromDescriptors:(NSArray *)descriptors;
- (CTFontDescriptorRef)copyDescriptorWithCoordinates:(NSDictionary<NSNumber *, NSNumber *> *)coordinates CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
