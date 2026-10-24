#import "GAFontEngine.h"
#import "GAFontResource.h"
#import "GATextScanModel.h"
#import <Foundation/Foundation.h>
static NSUInteger checks = 0;
static void Check(BOOL value, NSString *message) {
    checks++;
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
static GAFontDocument *Document(NSString *path) {
    CFArrayRef a =
        CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    NSArray *descriptors = CFBridgingRelease(a);
    GAFontResource *resource = [GAFontResource resourcesFromDescriptors:descriptors].firstObject;
    Check(resource != nil, @"fixture resource");
    return [[GAFontDocument alloc] initWithDescriptor:resource.defaultDescriptor
                                                  URL:[NSURL fileURLWithPath:path]];
}
static NSUInteger Drain(GATextScanModel *model, GAFontDocument *document) {
    NSUInteger n = 0;
    GATextScanSubitem *s;
    while ((s = [model startNextSubitem])) {
        [model completeSubitem:s result:[document rawScanContent:s.content]];
        n++;
    }
    return n;
}
static BOOL Has(GACharacterGroup *group, NSArray *gids) {
    for (GAGlyphVariant *v in group.variants)
        if ([v.glyphIDs isEqual:gids])
            return YES;
    return NO;
}
static NSArray *Keys(GATextScanModel *m) {
    NSMutableArray *keys = [NSMutableArray array];
    for (GACharacterGroup *g in m.groups) {
        NSMutableArray *v = [NSMutableArray array];
        for (GAGlyphVariant *x in g.variants)
            [v addObject:@[
                x.glyphIDs, x.featureSources, @(x.isBase), @(x.isLigature),
                NSStringFromRange(x.sourceTextRange)
            ]];
        [keys addObject:v];
    }
    return keys;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        NSString *root = @(argv[1]);
        GAFontDocument *d = Document([root stringByAppendingPathComponent:@"ligature.ttf"]);
        GATextScanModel *m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"😀ffi ffi\nffi"];
        Check(Drain(m, d) == 7, @"one paragraph query per line plus distinct graphemes");
        NSMutableSet *ranges = [NSMutableSet set];
        for (GACharacterGroup *g in m.groups)
            for (GAGlyphVariant *v in g.variants)
                if (v.isLigature && [v.glyphIDs isEqual:@[ @23 ]])
                    [ranges addObject:NSStringFromRange(v.sourceTextRange)];
        Check(
            [ranges isEqual:[NSSet setWithArray:@[
                        NSStringFromRange(NSMakeRange(2, 3)), NSStringFromRange(NSMakeRange(6, 3)),
                        NSStringFromRange(NSMakeRange(10, 3))
                    ]]],
            @"repeated ligatures keep exact UTF-16 locations");
        NSArray *keys = Keys(m);
        [m updateText:m.text];
        Check(Drain(m, d) == 0, @"same text uses cache");
        Check([Keys(m) isEqual:keys], @"cache preserves all rows");
        [m updateText:@""];
        Check(m.groups.count == 0 && [m startNextSubitem] == nil,
              @"clear empties queue and groups");
        [m updateText:@"ffi"];
        Check(Drain(m, d) == 0, @"clear and restore reuses content cache");
        Check(Has(m.groups.lastObject, @[ @23 ]), @"restored ligature is applied");
        d = Document([root stringByAppendingPathComponent:@"chain3.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"xaby xaby"];
        Drain(m, d);
        Check(Has(m.groups[2], @[ @20 ]) && Has(m.groups[7], @[ @20 ]),
              @"contextual substitution reaches each repeated source group");
        Check(!Has(m.groups[1], @[ @20 ]),
              @"context does not become a spurious ligature or wrong target");
        [m updateText:@"aby"];
        Drain(m, d);
        Check(!Has(m.groups[1], @[ @20 ]), @"missing backtrack does not reuse stale context");
        [m updateText:@"xaby"];
        GATextScanSubitem *inflight = [m startNextSubitem];
        [m updateText:@"q xaby"];
        if (inflight)
            [m completeSubitem:inflight result:[d rawScanContent:inflight.content]];
        Drain(m, d);
        Check(Has(m.groups[4], @[ @20 ]), @"edit during queued work rebinds range correctly");
        d = Document([root stringByAppendingPathComponent:@"ignore-marks.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"f́fi"];
        Drain(m, d);
        Check(Has(m.groups.lastObject, @[ @23, @14 ]),
              @"ignored mark survives ligature and composed group mapping");
        d = Document([root stringByAppendingPathComponent:@"variation-metrics.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"a"];
        Drain(m, d);
        keys = Keys(m);
        GAGlyphVariant *multiple = m.groups.firstObject.variants.lastObject;
        Check([multiple.glyphIDs isEqual:@[ @18, @20 ]], @"multiple substitution sequence");
        double oldX = [multiple.positions[1] pointValue].x;
        CTFontDescriptorRef desc = CTFontCopyFontDescriptor(d.fontBox.font);
        CTFontDescriptorRef changed = CTFontDescriptorCreateCopyWithAttributes(
            desc, (__bridge CFDictionaryRef)
                      @{(__bridge NSString *)kCTFontVariationAttribute : @{@(0x77676874) : @900}});
        GAFontDocument *newDoc = [d documentWithDescriptor:changed];
        CFRelease(desc);
        CFRelease(changed);
        [m updateFontDocument:newDoc];
        Check([Keys(m) isEqual:keys],
              @"axis change preserves GIDs, tags, selection keys, ranges and order");
        Check([m startNextSubitem] == nil, @"axis change schedules no discovery");
        multiple = m.groups.firstObject.variants.lastObject;
        Check([multiple.positions[1] pointValue].x > oldX + 30,
              @"axis change recomputes literal variable advances");
        d = Document([root stringByAppendingPathComponent:@"morx2.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"fi fi"];
        Drain(m, d);
        Check(Has(m.groups[1], @[ @22 ]) && Has(m.groups[4], @[ @22 ]),
              @"AAT ligatures flow through the same model");
        d = Document([root stringByAppendingPathComponent:@"deletion.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"bab"];
        Drain(m, d);
        Check(Has(m.groups[1], @[]), @"zero-output substitution is an explicit row");
        Check(!Has(m.groups[0], @[]), @"deletion stays on its source group");
        d = Document([root stringByAppendingPathComponent:@"shared-output-ligatures.ttf"]);
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"ffi"];
        Drain(m, d);
        NSMutableSet *sharedRanges = [NSMutableSet set];
        BOOL plainBase = NO;
        for (GAGlyphVariant *v in m.groups.lastObject.variants)
            if ([v.glyphIDs isEqual:@[ @8 ]]) {
                if (v.isLigature)
                    [sharedRanges addObject:NSStringFromRange(v.sourceTextRange)];
                else
                    plainBase |= v.isBase;
            }
        Check(sharedRanges.count == 2 && plainBase,
              @"equal GIDs preserve two source spans and the character base");
        printf("OK: %lu model assertions; no GUI initialized\n", (unsigned long)checks);
        return 0;
    }
}
