#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The name assigned to a scalar in the system Unicode database, if present.
NSString * _Nullable GAUnicodeNameForScalar(uint32_t scalar);

/// The actual characters represented by the scalars.
NSString *GAStringFromUnicodeScalars(NSArray<NSNumber *> *scalars);

/// YES when Unicode's vertical-orientation property (UAX #50) says the scalar
/// is rotated a quarter turn in vertical text (values R and Tr).
BOOL GAVerticalScalarRotates(uint32_t scalar);

/// Nonprinting characters that affect layout independently of a glyph mapping.
BOOL GAIsTextLayoutControl(unichar character);

NS_ASSUME_NONNULL_END
