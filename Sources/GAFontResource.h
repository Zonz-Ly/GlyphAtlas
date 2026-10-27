#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<UTType *> *GAFontContentTypes(void);
FOUNDATION_EXPORT BOOL GAFontURLIsFont(NSURL *url);

@interface GAFontInstance : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@end

/// One font resource and the named-instance descriptors which resolve to it.
@interface GAFontResource : NSObject
@property (nonatomic, readonly) CTFontDescriptorRef defaultDescriptor;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *axes;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *defaultCoordinates;
@property (nonatomic, copy, readonly) NSArray<GAFontInstance *> *instances;
+ (NSArray<GAFontResource *> *)resourcesFromDescriptors:(NSArray *)descriptors;
- (CTFontDescriptorRef)copyDescriptorWithCoordinates:(NSDictionary<NSNumber *, NSNumber *> *)coordinates CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
