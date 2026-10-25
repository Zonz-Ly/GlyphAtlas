#import "GADisplayGroups.h"
#import "GAFontEngine.h"
#import "GAFontResource.h"
#import "GATextQueryModel.h"
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
  CFArrayRef a = CTFontManagerCreateFontDescriptorsFromURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
  NSArray *descriptors = CFBridgingRelease(a);
  GAFontResource *resource =
      [GAFontResource resourcesFromDescriptors:descriptors].firstObject;
  Check(resource != nil, @"fixture resource");
  return
      [[GAFontDocument alloc] initWithDescriptor:resource.defaultDescriptor
                                             URL:[NSURL fileURLWithPath:path]];
}
static BOOL Has(GACharacterGroup *group, NSArray *gids) {
  for (GAGlyphVariant *v in group.variants)
    if ([v.glyphIDs isEqual:gids])
      return YES;
  return NO;
}
static NSArray *Keys(GATextQueryModel *m) {
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
  run.selection = [[GAGlyphSelection alloc]
      initWithSourceText:[text substringWithRange:range]
                glyphIDs:gids
          featureSources:@[]
                ligature:NO];
  return run;
}
static BOOL HasRow(NSArray<GACharacterGroup *> *groups, NSRange range,
                   NSArray *gids) {
  for (GACharacterGroup *group in groups)
    if (NSEqualRanges(group.textRange, range) && Has(group, gids))
      return YES;
  return NO;
}
static void Analyze(GATextQueryModel *model, NSString *text,
                    NSArray *selections) {
  Check([model analyzeText:text selections:selections cancelled:nil],
        @"complete atomic query");
}
static GAGlyphVariant *Variant(GACharacterGroup *group, NSArray *glyphs) {
  for (GAGlyphVariant *v in group.variants)
    if ([v.glyphIDs isEqual:glyphs])
      return v;
  return nil;
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2)
      return 2;
    NSString *root = @(argv[1]);
    GAFontDocument *d =
        Document([root stringByAppendingPathComponent:@"ligature.ttf"]);
    GATextQueryModel *m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"😀ffi ffi\nffi", @[]);
    Check(m.queryCount == 1, @"all characters and paragraphs are one query");
    for (GACharacterGroup *group in m.groups)
      for (GAGlyphVariant *variant in group.variants)
        Check(![variant.featureSources containsObject:@"actual"],
              @"no synthetic actual label on plain bases or candidates");
    NSMutableSet *ranges = [NSMutableSet set];
    for (GACharacterGroup *g in m.groups)
      for (GAGlyphVariant *v in g.variants)
        if (v.isLigature && [v.glyphIDs isEqual:@[ @23 ]])
          [ranges addObject:NSStringFromRange(v.sourceTextRange)];
    Check([ranges isEqual:[NSSet setWithArray:@[
                    NSStringFromRange(NSMakeRange(2, 3)),
                    NSStringFromRange(NSMakeRange(6, 3)),
                    NSStringFromRange(NSMakeRange(10, 3))
                  ]]],
          @"repeated ligatures retain exact UTF-16 source locations");
    NSArray *keys = Keys(m);
    Analyze(m, m.text, @[]);
    Check(m.queryCount == 1 && [Keys(m) isEqual:keys],
          @"identical input has no new query");
    Analyze(m, @"", @[]);
    Check(m.groups.count == 0, @"clear removes every row");
    Analyze(m, @"😀ffi ffi\nffi", @[]);
    Check([Keys(m) isEqual:keys],
          @"clear/restore retains all cached candidates");
    __block NSUInteger checksBeforeCancel = 0;
    Check(![m analyzeText:@"fi"
               selections:@[]
                cancelled:^BOOL {
                  return ++checksBeforeCancel > 1;
                }],
          @"superseded result is not committed");
    Check([Keys(m) isEqual:keys],
          @"cancellation leaves previous complete display intact");
    Analyze(m, @"f\nfi", @[]);
    Check(!Has(m.groups.lastObject, @[ @23 ]),
          @"ligatures cannot cross paragraph boundaries");
    d = Document([root stringByAppendingPathComponent:@"chain3.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"xaby xaby", @[]);
    Check(Has(m.groups[2], @[ @20 ]) && Has(m.groups[7], @[ @20 ]) &&
              !Has(m.groups[1], @[ @20 ]),
          @"context candidates attach only to the affected character at every "
          @"occurrence");
    Analyze(m, @"aby", @[]);
    Check(Has(m.groups[1], @[ @20 ]),
          @"context inventory needs no backtrack text");
    d = Document([root stringByAppendingPathComponent:@"ignore-marks.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"f́fi", @[]);
    Check(Has(m.groups.lastObject, @[ @23, @14 ]),
          @"ignored mark survives the complete ligature output");
    d = Document(
        [root stringByAppendingPathComponent:@"variation-metrics.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"a", @[]);
    keys = Keys(m);
    GAGlyphVariant *multiple = Variant(m.groups.firstObject, @[ @18, @20 ]);
    Check(multiple != nil,
          @"multiple substitution is a complete glyph sequence");
    double oldX = [multiple.positions[1] pointValue].x;
    NSUInteger queries = m.queryCount;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(d.fontBox.font);
    CTFontDescriptorRef changed = CTFontDescriptorCreateCopyWithAttributes(
        descriptor, (__bridge CFDictionaryRef) @{
          (__bridge NSString *)
          kCTFontVariationAttribute : @{@(0x77676874) : @900}
        });
    GAFontDocument *newDocument = [d documentWithDescriptor:changed];
    CFRelease(descriptor);
    CFRelease(changed);
    [m updateFontDocument:newDocument];
    Check(m.queryCount == queries && [Keys(m) isEqual:keys],
          @"axis rebinding changes no candidate identity or query count");
    Check([Variant(m.groups.firstObject, @[ @18, @20 ]).positions[1] pointValue]
                  .x > oldX + 30,
          @"axis rebinding updates literal advances");
    d = Document([root stringByAppendingPathComponent:@"morx2.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"fi fi", @[]);
    Check(Has(m.groups[1], @[ @22 ]) && Has(m.groups[4], @[ @22 ]),
          @"AAT results share the same atomic query model");
    d = Document([root stringByAppendingPathComponent:@"deletion.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"bab", @[]);
    Check(Has(m.groups[1], @[]) && !Has(m.groups[0], @[]),
          @"zero output remains on its own source");
    d = Document(
        [root stringByAppendingPathComponent:@"shared-output-ligatures.ttf"]);
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"ffi", @[]);
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
          @"equal outputs keep overlapping ligature ranges and character base");
    d = Document(
        [root stringByAppendingPathComponent:@"unencoded-neighbor.ttf"]);
    Check([d analyzeGlyphIDs:@[ @19 ]]
                  .firstObject.variants.firstObject.unicodeScalars.count == 0,
          @"seed really is unencoded");
    m = [[GATextQueryModel alloc] initWithFontDocument:d];
    Analyze(m, @"ab", @[]);
    Check(!Has(m.groups.lastObject, @[ @22 ]),
          @"unencoded ligature requires actual selected component");
    GAGlyphSelectionRun *seed = Seed(@"ab", NSMakeRange(0, 1), @[ @19 ]);
    Analyze(m, @"ab", @[ seed ]);
    Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d),
                 NSMakeRange(0, 2), @[ @22 ]),
          @"selected unencoded GID matches its neighbor");
    queries = m.queryCount;
    Analyze(m, @"ab", @[ seed ]);
    Check(m.queryCount == queries, @"same literal input is cached");
    seed = Seed(@"ab", NSMakeRange(0, 1), @[ @20 ]);
    Analyze(m, @"ab", @[ seed ]);
    Check(!Has(m.groups.lastObject, @[ @22 ]),
          @"changed literal GID cannot reuse stale text result");
    seed = Seed(@"ab", NSMakeRange(0, 1), @[ @9, @19 ]);
    Analyze(m, @"ab", @[ seed ]);
    Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d),
                 NSMakeRange(0, 2), @[ @9, @22 ]),
          @"partial seed ligature preserves surviving prefix");
    seed = Seed(@"ca", NSMakeRange(1, 1), @[ @19 ]);
    Analyze(m, @"ca", @[ seed ]);
    Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d),
                 NSMakeRange(1, 1), @[ @21 ]),
          @"context change on selected seed remains visible");
    NSString *repeated = @"😀ab ab";
    seed = Seed(repeated, NSMakeRange(2, 1), @[ @19 ]);
    Analyze(m, repeated, @[ seed ]);
    NSArray *display = GABuildDisplayGroups(m.groups, m.text, @[ seed ], d);
    Check(HasRow(display, NSMakeRange(2, 2), @[ @22 ]) &&
              !HasRow(display, NSMakeRange(5, 2), @[ @22 ]),
          @"literal seed affects its exact UTF-16 occurrence only");
    seed = Seed(@"áb", NSMakeRange(0, 2), @[ @19 ]);
    Analyze(m, @"áb", @[ seed ]);
    Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d),
                 NSMakeRange(0, 3), @[ @22 ]),
          @"composed source is never cut");
    for (NSString *name in
         @[ @"morx-unencoded-neighbor.ttf", @"mort-unencoded-neighbor.ttf" ]) {
      d = Document([root stringByAppendingPathComponent:name]);
      m = [[GATextQueryModel alloc] initWithFontDocument:d];
      seed = Seed(@"ai", NSMakeRange(0, 1), @[ @9, @19 ]);
      Analyze(m, @"ai", @[ seed ]);
      Check(HasRow(GABuildDisplayGroups(m.groups, m.text, @[ seed ], d),
                   NSMakeRange(0, 2), @[ @9, @22 ]),
            @"AAT matcher preserves unencoded partial seed with neighbor");
    }
    printf("OK: %lu atomic query/model assertions; no GUI\n",
           (unsigned long)checks);
  }
}
