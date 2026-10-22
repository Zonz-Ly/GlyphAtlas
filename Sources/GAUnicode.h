#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the Unicode character name through the system ICU library.
NSString *GAUnicodeNameForScalar(uint32_t scalar);

/// The actual characters represented by the scalars.
NSString *GAStringFromUnicodeScalars(NSArray<NSNumber *> *scalars);

/// YES when Unicode's vertical-orientation property (UAX #50) says the scalar
/// is rotated a quarter turn in vertical text (values R and Tr).
BOOL GAVerticalScalarRotates(uint32_t scalar);

NS_ASSUME_NONNULL_END
