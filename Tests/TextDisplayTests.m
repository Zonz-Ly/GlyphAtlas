#import "GATextDisplayOptions.h"
#import "GAViewMode.h"
#import <AppKit/AppKit.h>
static NSUInteger checks;
static void Check(BOOL value, const char *message) {
    checks++;
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}
static NSArray *Shape(NSString *path, NSString *text, BOOL contextual, BOOL ligatures) {
    CFArrayRef descriptors =
        CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    Check(descriptors && CFArrayGetCount(descriptors), "native font available");
    CTFontRef base =
        CTFontCreateWithFontDescriptor(CFArrayGetValueAtIndex(descriptors, 0), 32, NULL);
    CTFontRef font = GACopyTextDisplayFont(base, 32, contextual);
    CFRelease(base);
    CFRelease(descriptors);
    NSAttributedString *string = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{
                (__bridge NSString *)kCTFontAttributeName : (__bridge id)font,
                (__bridge NSString *)kCTLigatureAttributeName : @(ligatures ? 1 : 0)
            }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    NSMutableArray *glyphs = [NSMutableArray array];
    for (id item in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)item;
        CFIndex count = CTRunGetGlyphCount(run);
        CGGlyph buffer[count];
        CTRunGetGlyphs(run, CFRangeMake(0, count), buffer);
        for (CFIndex i = 0; i < count; i++)
            [glyphs addObject:@(buffer[i])];
    }
    CFRelease(line);
    CFRelease(font);
    return glyphs;
}
int main(void) {
    @autoreleasepool {
        Check(NSApp == nil, "no GUI application");
        Check(!GAViewModeSupportsTextLayout(GAViewModeAllGlyphs) &&
                  !GAViewModeSupportsTextLayout(GAViewModeSingleGlyph) &&
                  GAViewModeSupportsTextLayout(GAViewModeMultiCharacter),
              "native layout controls are multi-only");
        Check(!GAViewModeSupportsMetrics(GAViewModeAllGlyphs) &&
                  GAViewModeSupportsMetrics(GAViewModeSingleGlyph),
              "metrics capability follows canvas");
        NSString *lucida = @"/Users/zonz/Library/Fonts/LucidaSubmono.otf";
        if ([[NSFileManager defaultManager] fileExistsAtPath:lucida]) {
            NSArray *off = Shape(lucida, @"Wi", NO, NO);
            NSArray *on = Shape(lucida, @"Wi", YES, NO);
            Check(![off isEqual:on] && on.count == 2,
                  "native contextual toggle changes W/i independently");
            Check([Shape(lucida, @"Wi", NO, YES) isEqual:off],
                  "ligature toggle does not enable contextual substitution");
        }
        NSString *zapfino = @"/System/Library/Fonts/Supplemental/Zapfino.ttf";
        if ([[NSFileManager defaultManager] fileExistsAtPath:zapfino]) {
            Check(Shape(zapfino, @"fi", NO, NO).count == 2,
                  "optional ligatures off uses two glyphs");
            Check(Shape(zapfino, @"fi", NO, YES).count == 1,
                  "native ligature toggle forms fi without intervention");
        }
        Check(NSApp == nil, "native display checks did not create GUI");
        printf("OK: %lu native display assertions; CoreText oracle only, no GUI\n",
               (unsigned long)checks);
    }
}
