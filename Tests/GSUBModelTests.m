#import "GAFontEngine.h"
#import "GADisplayGroups.h"
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
        [model completeSubitem:s
                        result:[document rawScanContent:s.content selections:s.selections ?: @[]]];
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
static GAGlyphSelectionRun *Seed(NSString *text, NSRange range, NSArray *gids) {
    GAGlyphSelectionRun *run = [[GAGlyphSelectionRun alloc] init];
    run.range = range;
    run.selection = [[GAGlyphSelection alloc] initWithSourceText:[text substringWithRange:range]
                                                        glyphIDs:gids
                                                  featureSources:@[]
                                                        ligature:NO];
    return run;
}
static BOOL HasRow(NSArray<GACharacterGroup *> *groups, NSRange range, NSArray *gids) {
    for (GACharacterGroup *group in groups)
        if (NSEqualRanges(group.textRange, range) && Has(group, gids))
            return YES;
    return NO;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2)
            return 2;
        NSString *root = @(argv[1]);
        GAFontDocument *plain = Document([root stringByAppendingPathComponent:@"plain.ttf"]);
        GATextScanModel *sparse = [[GATextScanModel alloc] initWithFontDocument:plain];
        [sparse updateText:[@"" stringByPaddingToLength:10000 withString:@"a" startingAtIndex:0]];
        Check(sparse.scanGroups.count == 2 && sparse.scanGroups[0].length == 1 &&
                  sparse.scanGroups[1].length == 10000,
              @"long paragraph allocates only single and paragraph buckets");
        sparse = [[GATextScanModel alloc] initWithFontDocument:plain];
        [sparse updateText:@"abc\nab"];
        GATextScanSubitem *kept = [sparse startNextSubitemWithMaximumLength:1];
        GATextScanItem *oldBatch = sparse.scanGroups.firstObject.items.firstObject;
        [sparse updateText:@"abc\nab\nabcd"];
        Check(sparse.scanGroups.count == 4 && sparse.scanGroups[0].length == 1 &&
                  sparse.scanGroups[1].length == 2 && sparse.scanGroups[2].length == 3 &&
                  sparse.scanGroups[3].length == 4,
              @"sparse buckets retain ascending task priority");
        Check(sparse.scanGroups.firstObject.items.firstObject == oldBatch &&
                  [oldBatch.subitems containsObject:kept] &&
                  kept.state == GATextScanSubitemStateScanning &&
                  sparse.scanGroups.firstObject.items.count == 2,
              @"edit retains in-flight identity and puts old batch before new work");
        Check(Drain(sparse, plain) == 7, @"remaining singles precede three paragraph tasks");
        [sparse completeSubitem:kept result:[plain rawScanContent:kept.content]];
        [sparse updateText:@"ab\nabc"];
        Check(Drain(sparse, plain) == 0, @"sparse bucket edits retain cached paragraph results");
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
        Check(Has(m.groups[1], @[ @20 ]), @"context catalogue survives missing backtrack");
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
        d = Document([root stringByAppendingPathComponent:@"unencoded-neighbor.ttf"]);
        Check([d analyzeGlyphIDs:@[ @19 ]].firstObject.variants.firstObject.unicodeScalars.count ==
                  0,
              @"literal seed is genuinely unencoded");
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"ab"];
        Drain(m, d);
        Check(!Has(m.groups.lastObject, @[ @22 ]),
              @"ligature is absent until its unencoded input is selected");
        GAGlyphSelectionRun *seed = Seed(@"ab", NSMakeRange(0, 1), @[ @19 ]);
        [m updateText:@"ab" selections:@[ seed ]];
        Check(Drain(m, d) == 1, @"changing only the GID schedules one paragraph query");
        NSArray *display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
        Check(HasRow(display, NSMakeRange(0, 2), @[ @22 ]),
              @"sidebar keeps unencoded seed plus encoded neighbor ligature");
        [m updateText:@"ab" selections:@[ seed ]];
        Check(Drain(m, d) == 0, @"identical literal query is cached");
        seed = Seed(@"ab", NSMakeRange(0, 1), @[ @20 ]);
        [m updateText:@"ab" selections:@[ seed ]];
        Check(Drain(m, d) == 1 && !Has(m.groups.lastObject, @[ @22 ]),
              @"different literal GID cannot reuse the same text cache");
        seed = Seed(@"ab", NSMakeRange(0, 1), @[ @9, @19 ]);
        [m updateText:@"ab" selections:@[ seed ]];
        Drain(m, d);
        display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
        Check(HasRow(display, NSMakeRange(0, 2), @[ @9, @22 ]),
              @"sidebar keeps surviving multi-GID prefix with neighbor ligature");
        seed = Seed(@"ca", NSMakeRange(1, 1), @[ @19 ]);
        [m updateText:@"ca" selections:@[ seed ]];
        Drain(m, d);
        display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
        Check(HasRow(display, NSMakeRange(1, 1), @[ @21 ]),
              @"contextual change on selected run is not hidden by its own row");
        seed = Seed(@"ac", NSMakeRange(0, 1), @[ @19 ]);
        [m updateText:@"ac" selections:@[ seed ]];
        Drain(m, d);
        Check(Has(m.groups.lastObject, @[ @21 ]),
              @"unencoded seed participates as contextual back input");
        seed = Seed(@"zab", NSMakeRange(0, 2), @[ @19 ]);
        [m updateText:@"zab" selections:@[ seed ]];
        Drain(m, d);
        display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
        Check(HasRow(display, NSMakeRange(0, 3), @[ @22 ]),
              @"collapsed multi-character seed retains complete replacement range");
        NSString *repeated = @"😀ab ab";
        seed = Seed(repeated, NSMakeRange(2, 1), @[ @19 ]);
        [m updateText:repeated selections:@[ seed ]];
        Drain(m, d);
        display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
        Check(HasRow(display, NSMakeRange(2, 2), @[ @22 ]) &&
                  !HasRow(display, NSMakeRange(5, 2), @[ @22 ]),
              @"literal selection affects its own UTF-16 occurrence only");
        NSString *composed = @"áb";
        seed = Seed(composed, NSMakeRange(0, 2), @[ @19 ]);
        [m updateText:composed selections:@[ seed ]];
        Drain(m, d);
        Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d), NSMakeRange(0, 3),
                     @[ @22 ]),
              @"derived windows never split a selected composed character");
        m = [[GATextScanModel alloc] initWithFontDocument:d];
        [m updateText:@"ab"];
        Drain(m, d);
        seed = Seed(@"ab", NSMakeRange(0, 1), @[ @19 ]);
        [m updateText:@"ab" selections:@[ seed ]];
        GATextScanSubitem *oldSeed = [m startNextSubitem];
        Check(oldSeed.selections.count == 1, @"in-flight paragraph carries a literal snapshot");
        GAGlyphSelectionRun *other = Seed(@"ab", NSMakeRange(0, 1), @[ @20 ]);
        [m updateText:@"ab" selections:@[ other ]];
        [m completeSubitem:oldSeed
                    result:[d rawScanContent:oldSeed.content selections:oldSeed.selections]];
        Drain(m, d);
        Check(!Has(m.groups.lastObject, @[ @22 ]),
              @"old selected-GID result cannot leak into a newer selection");
        for (NSString *name in
             @[ @"morx-unencoded-neighbor.ttf", @"mort-unencoded-neighbor.ttf" ]) {
            d = Document([root stringByAppendingPathComponent:name]);
            m = [[GATextScanModel alloc] initWithFontDocument:d];
            seed = Seed(@"ai", NSMakeRange(0, 1), @[ @19 ]);
            [m updateText:@"ai" selections:@[ seed ]];
            Drain(m, d);
            Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d), NSMakeRange(0, 2),
                         @[ @22 ]),
                  @"AAT literal seed with neighbor reaches sidebar");
        }
        printf("OK: %lu model assertions; no GUI initialized\n", (unsigned long)checks);
        return 0;
    }
}
