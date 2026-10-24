#import "GASeedDisplay.h"
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
static NSUInteger checks = 0;
static void Check(BOOL ok, const char *message) {
    checks++;
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}
int main(void) {
    @autoreleasepool {
        CTFontRef ct = CTFontCreateWithName(CFSTR("TimesNewRomanPSMT"), 32, NULL);
        NSFont *font = (__bridge NSFont *)ct;
        NSAttributedString *fragment = GACreateSeedDisplayString(
            @[ @20, @21, @22 ], @"a", font,
            @{NSFontAttributeName : font,
              NSLigatureAttributeName : @0},
            nil);
        Check(fragment.length == 3, "every GID has a display component");
        // On macOS 14 NSGlyphInfo.glyphID reports zero even for a valid override.
        // Check the actual CoreText output instead of inspecting that property.
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)fragment);
        NSMutableArray *drawn = [NSMutableArray array];
        for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
            CTRunRef run = (__bridge CTRunRef)object;
            CFIndex count = CTRunGetGlyphCount(run);
            CGGlyph *glyphs = calloc(count, sizeof(*glyphs));
            CTRunGetGlyphs(run, CFRangeMake(0, count), glyphs);
            for (CFIndex i = 0; i < count; i++)
                [drawn addObject:@(glyphs[i])];
            free(glyphs);
        }
        Check([drawn isEqual:@[ @20, @21, @22 ]],
              "actual text output contains every selected GID in order");
        CFRelease(line);
        NSMutableAttributedString *display =
            [[NSMutableAttributedString alloc] initWithString:@"a😀b"];
        NSMutableArray *map = [@[ @0, @1, @2, @3 ] mutableCopy];
        GAReplaceSeedDisplayRange(display, map, NSMakeRange(3, 1), fragment);
        Check([map isEqual:@[ @0, @1, @2, @3, @3, @3 ]],
              "later seed maps each component to original source");
        NSAttributedString *two = GACreateSeedDisplayString(
            @[ @21, @22 ], @"😀", font,
            @{NSFontAttributeName : font,
              NSLigatureAttributeName : @0},
            nil);
        GAReplaceSeedDisplayRange(display, map, NSMakeRange(1, 2), two);
        Check([map isEqual:@[ @0, @1, @1, @1, @1, @3, @3, @3 ]],
              "supplementary source mapping survives changed display length");
        GAReplaceSeedDisplayRange(display, map, NSMakeRange(0, 1), fragment);
        Check(display.length == 10 && map.count == 10 && [map[5] isEqual:@1] && [map[9] isEqual:@3],
              "descending expansion preserves later hit indices");
        NSAttributedString *vertical = GACreateSeedDisplayString(
            @[ @1, @2 ], @"a", font,
            @{NSFontAttributeName : font,
              NSLigatureAttributeName : @0},
            ^NSString *(CGGlyph glyph) {
              return glyph == 1 ? @"字" : @"A";
            });
        Check([vertical.string isEqual:@"字A"],
              "each vertical component receives its own orientation base");
        Check(NSApp == nil, "display-data tests do not initialize the GUI");
        CFRelease(ct);
        printf("OK: %lu seed-display data assertions; no GUI initialized\n", (unsigned long)checks);
        return 0;
    }
}
