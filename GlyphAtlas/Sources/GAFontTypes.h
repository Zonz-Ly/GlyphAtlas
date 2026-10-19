#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<UTType *> *GAFontContentTypes(void);
FOUNDATION_EXPORT BOOL GAFontURLIsFont(NSURL *url);

NS_ASSUME_NONNULL_END
