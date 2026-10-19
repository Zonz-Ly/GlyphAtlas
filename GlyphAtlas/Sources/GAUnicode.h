#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the Unicode character name through the system ICU library.
NSString *GAUnicodeNameForScalar(uint32_t scalar);

/// The actual characters represented by the scalars.
NSString *GAStringFromUnicodeScalars(NSArray<NSNumber *> *scalars);

NS_ASSUME_NONNULL_END
