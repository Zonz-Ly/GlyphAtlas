#import "GATextDisplay.h"
#import <CoreText/SFNTLayoutTypes.h>

static NSDictionary *GAOpenTypeDisplaySetting(NSString *tag, BOOL enabled) {
    return @{
        (__bridge NSString *)kCTFontOpenTypeFeatureTag : tag,
        (__bridge NSString *)kCTFontOpenTypeFeatureValue : @(enabled)
    };
}

static NSDictionary *GAAATDisplaySetting(NSInteger type, NSInteger selector) {
    return @{
        (__bridge NSString *)kCTFontFeatureTypeIdentifierKey : @(type),
        (__bridge NSString *)kCTFontFeatureSelectorIdentifierKey : @(selector)
    };
}

CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
                                BOOL ligatures) {
    NSArray *settings;
    // The native AAT path uses feature selectors; no font table bytes are read.
    if (CTFontHasTable(font, kCTFontTableMorx) || CTFontHasTable(font, kCTFontTableMort)) {
        settings = @[
            GAAATDisplaySetting(kContextualAlternatesType, contextualAlternates
                                                               ? kContextualAlternatesOnSelector
                                                               : kContextualAlternatesOffSelector),
            GAAATDisplaySetting(kLigaturesType, ligatures ? kCommonLigaturesOnSelector
                                                          : kCommonLigaturesOffSelector)
        ];
    } else {
        settings = @[
            GAOpenTypeDisplaySetting(@"calt", contextualAlternates),
            GAOpenTypeDisplaySetting(@"liga", ligatures),
            GAOpenTypeDisplaySetting(@"clig", ligatures)
        ];
    }
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    NSDictionary *attributes = @{(__bridge NSString *)kCTFontFeatureSettingsAttribute : settings};
    CTFontDescriptorRef configured =
        CTFontDescriptorCreateCopyWithAttributes(descriptor, (__bridge CFDictionaryRef)attributes);
    CFRelease(descriptor);
    if (!configured)
        return NULL;
    CTFontRef result = CTFontCreateWithFontDescriptor(configured, size, NULL);
    CFRelease(configured);
    return result;
}

NSAttributedString *
GACreateSeedDisplayString(NSArray<NSNumber *> *glyphIDs, NSString *baseString,
                          NSFont *font,
                          NSDictionary<NSAttributedStringKey, id> *attributes,
                          NSString * (^baseForGlyph)(CGGlyph)) {
  NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
  for (NSNumber *number in glyphIDs) {
    CGGlyph glyph = number.unsignedShortValue;
    NSString *base = baseForGlyph ? baseForGlyph(glyph) : nil;
    if (!base.length)
      base = baseString;
    if (!base.length)
      return nil;
    NSGlyphInfo *info = [NSGlyphInfo glyphInfoWithCGGlyph:glyph
                                                  forFont:font
                                               baseString:base];
    if (!info)
      return nil;
    NSMutableAttributedString *component =
        [[NSMutableAttributedString alloc] initWithString:base
                                               attributes:attributes];
    [component addAttribute:NSGlyphInfoAttributeName
                      value:info
                      range:NSMakeRange(0, component.length)];
    [result appendAttributedString:component];
  }
  return result;
}
void GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                               NSMutableArray<NSNumber *> *sourceIndices,
                               NSRange sourceRange,
                               NSAttributedString *replacement) {
  NSCParameterAssert(sourceRange.length > 0);
  NSCParameterAssert(display.length == sourceIndices.count);
  NSCParameterAssert(NSMaxRange(sourceRange) <= display.length);
  NSNumber *source = sourceIndices[sourceRange.location];
  NSMutableArray *indices =
      [NSMutableArray arrayWithCapacity:replacement.length];
  for (NSUInteger i = 0; i < replacement.length; i++)
    [indices addObject:source];
  [display replaceCharactersInRange:sourceRange
               withAttributedString:replacement];
  [sourceIndices replaceObjectsInRange:sourceRange
                  withObjectsFromArray:indices];
}
