#import "GAUnicode.h"
#include <stdint.h>

// Public ICU function exposed by libicucore on macOS. Declaring it here keeps
// the project free of external headers while still using the system Unicode
// database for character names.
extern int32_t u_charName(int32_t code,
                          int32_t nameChoice,
                          char *buffer,
                          int32_t bufferLength,
                          int32_t *errorCode);

static NSString *GANameForScalar(uint32_t scalar) {
    char buffer[512] = {0};
    int32_t error = 0;
    (void)u_charName((int32_t)scalar, 0 /* U_UNICODE_CHAR_NAME */, buffer,
                     (int32_t)sizeof(buffer) - 1, &error);
    if (error != 0 || buffer[0] == '\0') {
        return @"";
    }

    NSString *name = [NSString stringWithUTF8String:buffer];
    if (name.length == 0) {
        return @"";
    }

    if ([name isEqualToString:@"<control>"]) {
        return @"CONTROL CHARACTER";
    }
    if ([name hasPrefix:@"<"] && [name hasSuffix:@">"]) {
        return @"";
    }
    return name;
}

NSString *GAUnicodeNameForScalar(uint32_t scalar) {
    return GANameForScalar(scalar);
}

NSString *GAStringFromUnicodeScalars(NSArray<NSNumber *> *scalars) {
    NSMutableString *result = [NSMutableString string];
    for (NSNumber *number in scalars) {
        uint32_t value = number.unsignedIntValue;
        if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
            continue;
        }
        if (value <= 0xFFFF) {
            unichar character = (unichar)value;
            [result appendString:[NSString stringWithCharacters:&character length:1]];
        } else {
            uint32_t adjusted = value - 0x10000;
            unichar characters[2] = {
                (unichar)(0xD800 + (adjusted >> 10)),
                (unichar)(0xDC00 + (adjusted & 0x3FF)),
            };
            [result appendString:[NSString stringWithCharacters:characters length:2]];
        }
    }
    return result;
}
