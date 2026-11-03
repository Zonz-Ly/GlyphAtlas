#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// OpenType tags and BCP 47 language identifiers are different namespaces.
FOUNDATION_EXPORT NSString * _Nullable GAIdentifierForOpenTypeLanguage(NSString *tag);
FOUNDATION_EXPORT NSString *GATitleForOpenTypeLanguage(NSString *tag, NSLocale *locale);

NS_ASSUME_NONNULL_END
