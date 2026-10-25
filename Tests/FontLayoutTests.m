#import "GAAAT.h"
#import "GACmap.h"
#import "GAKerning.h"
#import "GAOpenType.h"
#import "GAVariation.h"
static NSUInteger checks, mutations;
static void Check(BOOL value, NSString *message) {
    checks++;
    if (!value)
        @throw [NSException exceptionWithName:@"GATestFailure" reason:message userInfo:nil];
}
static void Put16(NSMutableData *bytes, unsigned value) {
    uint8_t b[] = {value >> 8, value};
    [bytes appendBytes:b length:2];
}
static void Put32(NSMutableData *bytes, uint32_t value) {
    Put16(bytes, value >> 16);
    Put16(bytes, value);
}
static NSMutableData *Words(NSArray<NSNumber *> *values) {
    NSMutableData *data = [NSMutableData data];
    for (NSNumber *v in values)
        Put16(data, v.unsignedIntValue);
    return data;
}
static GATableView *View(NSArray<NSNumber *> *values) { return [GATableView data:Words(values)]; }
static void Invalid(void (^operation)(void)) {
    BOOL rejected = NO;
    @try {
        operation();
    } @catch (NSException *error) {
        if (![error.name isEqual:@"GAInvalidFontTable"])
            @throw;
        rejected = YES;
    }
    Check(rejected, @"malformed data accepted");
}
static GATableView *CmapTable(NSData *sub, unsigned platform, unsigned encoding) {
    NSMutableData *bytes = Words(@[ @0, @1, @(platform), @(encoding) ]);
    Put32(bytes, 12);
    [bytes appendData:sub];
    return [GATableView data:bytes];
}
static void BinaryTests(void) {
    GATableView *data = View(@[ @0x1234, @0xfffe, @0xabcd ]);
    Check([data u16:0] == 0x1234 && [data s16:2] == -2, @"big endian signed reads");
    Invalid(^{
        [data u32:4];
    });
    Invalid(^{
        [data slice:NSUIntegerMax length:2];
    });
    Invalid(^{
        [data array:0 count:NSUIntegerMax stride:8];
    });
    GACoverage *c1 = [[GACoverage alloc] initWithView:View(@[ @1, @3, @2, @5, @7 ])];
    Check([c1 index:5] == 1 && [c1 index:4] == -1, @"coverage 1 search");
    GACoverage *c2 = [[GACoverage alloc] initWithView:View(@[ @2, @2, @2, @4, @0, @7, @8, @3 ])];
    Check([c2 index:8] == 4 && c2.glyphs.count == 5, @"coverage 2 ranges");
    Invalid(^{
        (void)[[GACoverage alloc] initWithView:View(@[ @2, @1, @9, @3, @0 ])];
    });
    Invalid(^{
        (void)[[GACoverage alloc] initWithView:View(@[ @1, @2, @5, @5 ])];
    });
    GAClassDef *d1 = [[GAClassDef alloc] initWithView:View(@[ @1, @2, @3, @1, @2, @3 ])];
    Check([d1 value:3] == 2 && [d1 value:1] == 0, @"class definition 1");
    GAClassDef *d2 = [[GAClassDef alloc] initWithView:View(@[ @2, @1, @2, @5, @7 ])];
    Check([d2 value:4] == 7 && [d2 value:6] == 0, @"class definition 2");
    Invalid(^{
        (void)[[GAClassDef alloc] initWithView:View(@[ @2, @2, @2, @5, @1, @4, @6, @2 ])];
    });
    GALayoutItem *prefix = [GALayoutItem new], *ligature = [GALayoutItem new];
    prefix.glyph = 2;
    prefix.source = GASpanMake(0, 1);
    ligature.glyph = 22;
    ligature.source = GASpanMake(0, 2);
    NSArray<GALayoutCluster *> *result = GAClusters(@[ prefix, ligature ]);
    Check(result.count == 1 && GASpanEqual(result[0].source, GASpanMake(0, 2)) &&
              [result[0].glyphs isEqual:@[ @2, @22 ]],
          @"partial seed ligature preserves surviving prefix");
}
static void AppleLookupTests(void) {
    Check([GAAATLookup(View(@[ @0, @0, @0, @7 ]), 2, 2) isEqual:@7], @"Apple lookup 0");
    Check([GAAATLookup(View(@[ @2, @6, @2, @12, @1, @0, @5, @2, @7, @65535, @65535, @0 ]), 3, 2)
              isEqual:@7],
          @"Apple lookup 2");
    Check([GAAATLookup(
              View(@[ @4, @6, @2, @12, @1, @0, @5, @2, @24, @65535, @65535, @0, @7, @8, @9, @10 ]),
              3, 2) isEqual:@8],
          @"Apple lookup 4");
    Check([GAAATLookup(View(@[ @6, @4, @2, @8, @1, @0, @3, @7, @65535, @0 ]), 3, 2) isEqual:@7],
          @"Apple lookup 6");
    Check([GAAATLookup(View(@[ @8, @3, @2, @7, @8 ]), 4, 2) isEqual:@8], @"Apple lookup 8");
    NSMutableData *ten = Words(@[ @10, @4, @3, @1 ]);
    Put32(ten, 70000);
    Check([GAAATLookup([GATableView data:ten], 3, 2) isEqual:@70000],
          @"Apple lookup 10 wide values");
    Check(!GAAATLookup(View(@[ @4, @6, @1, @6, @0, @0, @65535, @65535, @18 ]), 65535, 2),
          @"deleted GID ignores sentinel data");
}
static void CmapTests(void) {
    NSMutableData *zero = Words(@[ @0, @262, @0 ]);
    zero.length = 262;
    ((uint8_t *)zero.mutableBytes)[6 + 65] = 7;
    Check([[[GACmap alloc] initWithView:CmapTable(zero, 0, 4)] nominal:65] == 7, @"cmap 0");
    NSMutableData *two = Words(@[ @2, @528, @0 ]);
    two.length = 518;
    [two appendData:Words(@[ @65, @1, @0, @2, @7 ])];
    Check([[[GACmap alloc] initWithView:CmapTable(two, 0, 4)] nominal:65] == 7, @"cmap 2");
    NSData *four =
        Words(@[ @4, @32, @0, @4, @4, @1, @0, @65, @65535, @0, @65, @65535, @65478, @1, @0, @0 ]);
    Check([[[GACmap alloc] initWithView:CmapTable(four, 0, 4)] nominal:65] == 7, @"cmap 4 delta");
    Check([[[GACmap alloc] initWithView:CmapTable(Words(@[ @6, @12, @0, @65, @1, @7 ]), 0, 4)]
              nominal:65] == 7,
          @"cmap 6");
    NSMutableData *eight = Words(@[ @8, @0 ]);
    Put32(eight, 8220);
    Put32(eight, 0);
    eight.length = 8204;
    Put32(eight, 1);
    Put32(eight, 0xd83dde00);
    Put32(eight, 0xd83dde00);
    Put32(eight, 7);
    Check([[[GACmap alloc] initWithView:CmapTable(eight, 0, 4)] nominal:0x1f600] == 7,
          @"cmap 8 supplementary UTF-16");
    NSMutableData *ten = Words(@[ @10, @0 ]);
    Put32(ten, 22);
    Put32(ten, 0);
    Put32(ten, 0x1f600);
    Put32(ten, 1);
    Put16(ten, 7);
    Check([[[GACmap alloc] initWithView:CmapTable(ten, 0, 4)] nominal:0x1f600] == 7, @"cmap 10");
    for (NSNumber *format in @[ @12, @13 ]) {
        NSMutableData *sub = Words(@[ format, @0 ]);
        Put32(sub, 28);
        Put32(sub, 0);
        Put32(sub, 1);
        Put32(sub, 65);
        Put32(sub, 66);
        Put32(sub, 7);
        Check([[[GACmap alloc] initWithView:CmapTable(sub, 0, 4)] nominal:66] ==
                  (format.unsignedIntValue == 12 ? 8 : 7),
              @"cmap 12/13");
    }
    Check([[[GACmap alloc] initWithView:CmapTable(Words(@[ @6, @12, @0, @0xf041, @1, @7 ]), 3, 0)]
              nominal:65] == 7,
          @"symbol cmap fallback");
    ((uint8_t *)zero.mutableBytes)[6 + 128] = 8;
    Check([[[GACmap alloc] initWithView:CmapTable(zero, 1, 0)] nominal:0xc4] == 8,
          @"MacRoman fallback");
    NSMutableData *uv = Words(@[ @14 ]);
    Put32(uv, 30);
    Put32(uv, 1);
    uint8_t selector[] = {0, 0xfe, 0x0f};
    [uv appendBytes:selector length:3];
    Put32(uv, 0);
    Put32(uv, 21);
    Put32(uv, 1);
    uint8_t scalar[] = {0, 0, 65};
    [uv appendBytes:scalar length:3];
    Put16(uv, 9);
    Check([[[[GACmap alloc] initWithView:CmapTable(uv, 0, 4)] variation:65
                                                               selector:0xfe0f] isEqual:@9],
          @"nondefault cmap 14");
}
static GATableView *VariationStore(BOOL longWords) {
    NSMutableData *store = Words(@[ @1 ]);
    Put32(store, 12);
    Put16(store, 1);
    Put32(store, 22);
    [store appendData:Words(@[ @1, @1, @0, @16384, @16384 ])];
    [store appendData:Words(@[ @1, @(longWords ? 0x8001 : 1), @1, @0 ])];
    if (longWords)
        Put32(store, 100000);
    else
        Put16(store, 200);
    return [GATableView data:store];
}
static void VariationTests(void) {
    GATableView *store = VariationStore(NO);
    Check(GAVariationDelta(store, 0, 0, @[ @0 ]) == 0, @"variation default origin");
    Check(GAVariationDelta(store, 0, 0, @[ @0.5 ]) == 100, @"variation interpolation");
    Check(GAVariationDelta(store, 0, 0, @[ @1 ]) == 200, @"variation peak");
    Check(GAVariationDelta(VariationStore(YES), 0, 0, @[ @0.5 ]) == 50000, @"long variation words");
    Check(GADeviceDelta(View(@[ @0, @0, @0x8000 ]), store, @[ @0.5 ]) == 100,
          @"VariationIndex device");
    Check(GADeviceDelta(View(@[ @10, @12, @1 ]), store, @[ @1 ]) == 0, @"unhinted pixel devices");
    NSMutableData *fvar = Words(@[ @1, @0, @16, @2, @1, @20, @0, @0 ]);
    Put32(fvar, GATagMake('w', 'g', 'h', 't'));
    Put32(fvar, 100 * 65536);
    Put32(fvar, 400 * 65536);
    Put32(fvar, 900 * 65536);
    Put16(fvar, 0);
    Put16(fvar, 256);
    NSDictionary *coordinate = @{@(GATagMake('w', 'g', 'h', 't')) : @650};
    Check([GANormalizeCoordinates([GATableView data:fvar], [GATableView data:nil], coordinate)
              isEqual:@[ @0.5 ]],
          @"fvar normalization");
    Check([GANormalizeCoordinates(
              [GATableView data:fvar], View(@[
                  @1, @0, @0, @1, @4, @0xc000, @0xc000, @0, @0, @0x2000, @0x3000, @0x4000, @0x4000
              ]),
              coordinate) isEqual:@[ @0.75 ]],
          @"avar segment mapping");
}
static NSMutableArray<GALayoutItem *> *Seed(NSArray<NSNumber *> *glyphs) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSNumber *glyph in glyphs) {
        GALayoutItem *item = [GALayoutItem new];
        item.glyph = glyph.unsignedShortValue;
        item.source = GASpanMake((uint32_t)items.count, (uint32_t)items.count + 1);
        [items addObject:item];
    }
    return items;
}
static GATableView *FixtureTable(NSString *file, GATag name) {
    GATableView *sfnt = [GATableView data:[NSData dataWithContentsOfFile:file]];
    for (unsigned i = 0; i < [sfnt u16:4]; i++) {
        NSUInteger p = 12 + i * 16;
        if ([sfnt u32:p] == name)
            return [sfnt slice:[sfnt u32:p + 8] length:[sfnt u32:p + 12]];
    }
    GAInvalidTable(@"fixture table missing");
}
static void RelatedTests(NSString *directory) {
    GATag gsub = GATagMake('G', 'S', 'U', 'B');
    GAGDEF *empty = [[GAGDEF alloc] initWithView:[GATableView data:nil]];
    GAOpenType *program = [[GAOpenType alloc]
        initWithView:FixtureTable([directory stringByAppendingPathComponent:@"alternate.ttf"], gsub)
         positioning:NO];
    NSArray<GARelatedSubstitution *> *outputs = [program relatedSubstitutions:18 gdef:empty];
    Check(outputs.count == 1 && [outputs[0].glyphs isEqual:@[ @19 ]] &&
              outputs[0].feature == GATagMake('t', 'e', 's', 't') && outputs[0].value == 2 &&
              outputs[0].directFamily,
          @"unencoded sibling preserves alternate index");
    GAOpenType *context = [[GAOpenType alloc]
        initWithView:FixtureTable(
                         [directory stringByAppendingPathComponent:@"nested-alternate.ttf"], gsub)
         positioning:NO];
    outputs = [context relatedSubstitutions:2 gdef:empty];
    Check(outputs.count == 2 && !outputs[0].directFamily && !outputs[1].directFamily,
          [NSString stringWithFormat:@"nested output is contextual: %@ %@",
                                     [outputs valueForKey:@"glyphs"],
                                     [outputs valueForKey:@"directFamily"]]);
    Check(![context relatedSubstitutions:18 gdef:empty].count, @"no invented inverse context");
    for (NSString *name in @[ @"ligature.ttf", @"extension.ttf" ]) {
        GAOpenType *lig = [[GAOpenType alloc]
            initWithView:FixtureTable([directory stringByAppendingPathComponent:name], gsub)
             positioning:NO];
        Check(![lig relatedSubstitutions:7 gdef:empty].count &&
                  ![lig relatedSubstitutions:8 gdef:empty].count,
              @"ligatures excluded from component catalogue");
    }
    GATableView *table =
        FixtureTable([directory stringByAppendingPathComponent:@"context3.ttf"], gsub);
    NSMutableData *nested = [NSMutableData dataWithLength:table.length];
    for (NSUInteger i = 0; i < table.length; i++)
        ((uint8_t *)nested.mutableBytes)[i] = [table u8:i];
    NSUInteger list = [table u16:8], root = list + [table u16:list + 2],
               sub = root + [table u16:root + 6];
    void (^set)(NSUInteger, unsigned) = ^(NSUInteger at, unsigned value) {
        uint8_t *bytes = nested.mutableBytes;
        bytes[at] = value >> 8;
        bytes[at + 1] = value;
    };
    set(sub + 10, 0);
    set(sub + [table u16:sub + 6] + 4, 7);
    set(sub + [table u16:sub + 8] + 4, 7);
    NSUInteger child = list + [table u16:list + 4];
    nested.length = child;
    [nested appendData:Words(@[
                @4, @0, @1,  @8,  @1, @8, @1, @14, @1, @1, @7,
                @2, @6, @14, @23, @3, @7, @8, @22, @2, @7
            ])];
    GAOpenType *nestedProgram = [[GAOpenType alloc] initWithView:[GATableView data:nested]
                                                     positioning:NO];
    Check(![nestedProgram relatedSubstitutions:7 gdef:empty].count,
          @"context root excludes nested ligature");
    GALayoutSettings *settings = [GALayoutSettings new];
    settings.features[@(GATagMake('t', 'e', 's', 't'))] = @1;
    NSMutableArray<GALayoutItem *> *complete = Seed(@[ @7, @7, @8 ]);
    [nestedProgram substituteBuffer:complete gdef:empty settings:settings branch:0 trace:nil];
    Check(complete.count == 1 && complete[0].glyph == 23, @"nested longest ligature executes");
    complete = Seed(@[ @7, @7, @8 ]);
    GALayoutTrace *inventory = [GALayoutTrace new];
    inventory.inventory = YES;
    [nestedProgram substituteBuffer:complete gdef:empty settings:settings branch:0 trace:inventory];
    BOOL shortRule = NO, longRule = NO;
    for (GALayoutChange *change in inventory.changes) {
        shortRule |=
            GASpanEqual(change.source, GASpanMake(0, 2)) && [change.glyphs isEqual:@[ @22 ]];
        longRule |=
            GASpanEqual(change.source, GASpanMake(0, 3)) && [change.glyphs isEqual:@[ @23 ]];
    }
    Check(shortRule && longRule, @"inventory preserves overlapping nested ligatures");
    table = FixtureTable([directory stringByAppendingPathComponent:@"alternate.ttf"], gsub);
    NSMutableData *filtered = [NSMutableData dataWithLength:table.length];
    for (NSUInteger i = 0; i < table.length; i++)
        ((uint8_t *)filtered.mutableBytes)[i] = [table u8:i];
    list = [table u16:8];
    NSUInteger lookup = list + [table u16:list + 2];
    ((uint8_t *)filtered.mutableBytes)[lookup + 2] = 0;
    ((uint8_t *)filtered.mutableBytes)[lookup + 3] = 2;
    GAGDEF *gdef = [[GAGDEF alloc] initWithView:View(@[ @1, @0, @12, @0, @0, @0, @1, @2, @1, @1 ])];
    Check(![[[GAOpenType alloc] initWithView:[GATableView data:filtered]
                                 positioning:NO] relatedSubstitutions:18 gdef:gdef]
               .count,
          @"reverse sibling respects original input filtering");
}
static void Exercise(GATag name, NSData *bytes) {
    GATableView *table = [GATableView data:bytes], *empty = [GATableView data:nil];
    NSMutableArray<GALayoutItem *> *buffer = Seed(@[ @2, @3, @7, @8, @14 ]);
    GALayoutSettings *settings = [GALayoutSettings new];
    settings.features[@(GATagMake('t', 'e', 's', 't'))] = @1;
    GALayoutTrace *trace = [GALayoutTrace new];
    trace.inventory = YES;
    GAGDEF *gdef = [[GAGDEF alloc] initWithView:empty];
    GALayoutMetrics *metrics = [GALayoutMetrics new];
    metrics.horizontalAdvance = ^double(GAGlyph g) {
        (void)g;
        return 600;
    };
    metrics.verticalAdvance = ^double(GAGlyph g) {
        (void)g;
        return 1000;
    };
    metrics.normalized = @[];
    if (name == GATagMake('G', 'S', 'U', 'B')) {
        GAOpenType *program = [[GAOpenType alloc] initWithView:table positioning:NO];
        [program substituteBuffer:buffer gdef:gdef settings:settings branch:0 trace:trace];
        for (NSNumber *glyph in @[ @2, @3 ])
            [program relatedSubstitutions:glyph.unsignedShortValue gdef:gdef];
    } else if (name == GATagMake('G', 'P', 'O', 'S'))
        [[[GAOpenType alloc] initWithView:table positioning:YES] positionBuffer:buffer
                                                                           gdef:gdef
                                                                       settings:settings
                                                                        metrics:metrics
                                                                         branch:0];
    else if (name == GATagMake('m', 'o', 'r', 'x') || name == GATagMake('m', 'o', 'r', 't'))
        [[[GAAAT alloc] initWithView:table
                            extended:name == GATagMake('m', 'o', 'r', 'x')] substituteBuffer:buffer
                                                                                    selector:nil
                                                                                         rtl:NO
                                                                                    vertical:NO
                                                                                       trace:trace
                                                                                verticalOnly:NO];
    else if (name == GATagMake('G', 'D', 'E', 'F')) {
        GAGDEF *definition = [[GAGDEF alloc] initWithView:table];
        for (GALayoutItem *item in buffer)
            [definition includes:item.glyph flags:0x10 markSet:0];
    } else if (name == GATagMake('c', 'm', 'a', 'p')) {
        GACmap *map = [[GACmap alloc] initWithView:table];
        for (NSNumber *scalar in @[ @32, @65, @0x301, @0x1f600 ]) {
            [map nominal:scalar.unsignedIntValue];
            [map variation:scalar.unsignedIntValue selector:0xfe0f];
        }
    } else if (name == GATagMake('k', 'e', 'r', 'n') || name == GATagMake('k', 'e', 'r', 'x'))
        [[[GAKerning alloc] initWithKern:name == GATagMake('k', 'e', 'r', 'n') ? table : empty
                                    kerx:name == GATagMake('k', 'e', 'r', 'x') ? table : empty]
            positionBuffer:buffer
                  settings:settings
                      gdef:gdef];
    for (GALayoutItem *item in buffer)
        Check(item.source.start < item.source.end, @"source span lost");
}
static void MutationTests(NSString *directory, BOOL sample) {
    uint32_t random = 1729;
    NSArray *supported =
        @[ @"GSUB", @"GPOS", @"morx", @"mort", @"GDEF", @"cmap", @"kern", @"kerx" ];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory
                                                                          error:NULL]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *file in files) {
        if (sample && ![@[
                @"context-expand.ttf", @"morx2.ttf", @"mort2.ttf", @"position.ttf",
                @"feature-variations.ttf"
            ] containsObject:file])
            continue;
        if (![file.pathExtension isEqual:@"ttf"])
            continue;
        NSData *bytes =
            [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
        GATableView *sfnt = [GATableView data:bytes];
        for (unsigned i = 0; i < [sfnt u16:4]; i++) {
            NSUInteger p = 12 + i * 16;
            GATag name = [sfnt u32:p];
            if (![supported containsObject:GATagName(name)])
                continue;
            NSUInteger offset = [sfnt u32:p + 8], size = [sfnt u32:p + 12];
            [sfnt require:offset count:size];
            NSData *original = [bytes subdataWithRange:NSMakeRange(offset, size)];
            NSUInteger truncated = MIN(size, sample ? 16UL : 80UL);
            for (NSUInteger m = 0; m < truncated + (sample ? 4 : 40); m++)
                @autoreleasepool {
                    NSMutableData *changed = [original mutableCopy];
                    if (m < truncated)
                        changed.length = m;
                    else if (changed.length) {
                        random = random * 1664525u + 1013904223u;
                        NSUInteger index = random % changed.length;
                        random = random * 1664525u + 1013904223u;
                        ((uint8_t *)changed.mutableBytes)[index] ^= (uint8_t)(1u << (random % 8));
                    }
                    @try {
                        Exercise(name, changed);
                    } @catch (NSException *error) {
                        if (![error.name isEqual:@"GAInvalidFontTable"])
                            @throw;
                    }
                    mutations++;
                }
        }
    }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        @try {
            BinaryTests();
            AppleLookupTests();
            CmapTests();
            VariationTests();
            if (argc >= 2)
                RelatedTests(@(argv[1]));
            if (argc >= 3 &&
                ([@(argv[2]) isEqual:@"--mutate"] || [@(argv[2]) isEqual:@"--mutate-sample"]))
                MutationTests(@(argv[1]), [@(argv[2]) isEqual:@"--mutate-sample"]);
            printf("OK: %lu core assertions; %lu deterministic truncated/mutated "
                   "table executions\n",
                   checks, mutations);
            return 0;
        } @catch (NSException *error) {
            fprintf(stderr, "FAIL: %s: %s\n", error.name.UTF8String, error.reason.UTF8String);
            return 1;
        }
    }
}
