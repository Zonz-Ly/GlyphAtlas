#import "GAUnicode.h"
#include <stdint.h>

// Use the system ICU data without requiring external headers.
extern int32_t u_charName(int32_t code, int32_t nameChoice, char *buffer,
                         int32_t bufferLength, int32_t *errorCode);
extern int32_t u_getPropertyEnum(const char *alias);
extern int32_t u_getPropertyValueEnum(int32_t property, const char *alias);
extern int32_t u_getIntPropertyValue(int32_t code, int32_t property);

NSString *GAUnicodeNameForScalar(uint32_t scalar) {
    if (scalar > 0x10FFFF) return nil;
    char buffer[512];
    int32_t error = 0;
    int32_t length = u_charName((int32_t)scalar, 0 /* U_UNICODE_CHAR_NAME */,
                                buffer, (int32_t)sizeof(buffer), &error);
    if (error > 0 || length <= 0 || length >= (int32_t)sizeof(buffer)) return nil;
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

BOOL GAVerticalScalarRotates(uint32_t scalar) {
    static int32_t property = -2;
    static int32_t rotated = -1;
    static int32_t transformedRotated = -1;
    if (property == -2) {
        property = u_getPropertyEnum("Vertical_Orientation");
        if (property >= 0) {
            rotated = u_getPropertyValueEnum(property, "R");
            transformedRotated = u_getPropertyValueEnum(property, "Tr");
        }
    }
    if (property < 0) {
        return NO;
    }
    int32_t value = u_getIntPropertyValue((int32_t)scalar, property);
    return value == rotated || value == transformedRotated;
}

NSString *GAStringFromUnicodeScalars(NSArray<NSNumber *> *scalars) {
    NSMutableString *result = [NSMutableString string];
    for (NSNumber *number in scalars) {
        uint32_t value = number.unsignedIntValue;
        if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
            continue;
        }
        unichar characters[2];
        NSUInteger length = CFStringGetSurrogatePairForLongCharacter(value, characters) ? 2 : 1;
        [result appendString:[NSString stringWithCharacters:characters length:length]];
    }
    return result;
}


BOOL GAIsTextLayoutControl(unichar character) {
    switch (character) {
        case 0x0009: // Tab.
        case 0x00AD: // Soft hyphen.
        case 0x061C: // Arabic letter mark.
        case 0x200B: // Zero width space.
        case 0x200C: // Zero width non-joiner.
        case 0x200E: // Left-to-right mark.
        case 0x200F: // Right-to-left mark.
        case 0x2060: // Word joiner.
        case 0xFEFF: // Zero width no-break space.
            return YES;
        default:
            return (character >= 0x202A && character <= 0x202E) ||
                   (character >= 0x2066 && character <= 0x2069) ||
                   [NSCharacterSet.newlineCharacterSet characterIsMember:character];
    }
}
