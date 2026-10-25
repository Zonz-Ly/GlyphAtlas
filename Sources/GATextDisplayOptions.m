#import "GATextDisplayOptions.h"

CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates) {
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    NSDictionary *attributes = @{
        (__bridge NSString *)kCTFontFeatureSettingsAttribute : @[ @{
            (__bridge NSString *)kCTFontOpenTypeFeatureTag : @"calt",
            (__bridge NSString *)kCTFontOpenTypeFeatureValue : @(contextualAlternates)
        } ]
    };
    CTFontDescriptorRef configured =
        CTFontDescriptorCreateCopyWithAttributes(descriptor, (__bridge CFDictionaryRef)attributes);
    CFRelease(descriptor);
    if (!configured)
        return NULL;
    CTFontRef result = CTFontCreateWithFontDescriptor(configured, size, NULL);
    CFRelease(configured);
    return result;
}
