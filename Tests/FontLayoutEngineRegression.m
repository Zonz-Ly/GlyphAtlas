#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import "FontLayout/GASubstitutionEngine.h"
#import "Font/GAGlyphSelection.h"
#import "Font/GAFontEngine.h"
#import "Font/GATextQueryModel.h"

static id displayGroups(NSArray<GACharacterGroup *> *groups) {
    NSMutableArray *result = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        NSMutableArray *variants = [NSMutableArray array];
        for (GAGlyphVariant *variant in group.variants) {
            NSMutableArray *positions = [NSMutableArray array];
            for (NSValue *point in variant.positions) [positions addObject:NSStringFromPoint(point.pointValue)];
            [variants addObject:@[variant.glyphIDs, variant.glyphName, variant.featureSources,
                                  variant.unicodeScalars, positions, @(variant.base), @(variant.ligature),
                                  NSStringFromRange(variant.sourceTextRange)]];
        }
        [result addObject:@[group.text, NSStringFromRange(group.textRange), @(group.seeded),
                            @(group.insertedLigature), variants]];
    }
    return result;
}
static GAGlyphVariant *variant(GAFontDocument *document, NSArray<NSNumber *> *ids, NSUInteger index) {
    GAGlyphVariant *v = [GAGlyphVariant new];
    v.fontBox = document.fontBox; v.glyphIDs = ids;
    v.glyphName = [NSString stringWithFormat:@"candidate-%lu", (unsigned long)index];
    v.positions = @[[NSValue valueWithPoint:NSMakePoint(index + 0.25, index + 0.5)]];
    [v addFeatureSources:@[index % 2 ? @"liga" : @"calt"]];
    return v;
}
static id combinationCases(GAFontDocument *document) {
    NSMutableArray *results = [NSMutableArray array];
    uint32_t state = 0x172dd79;
    NSArray *fixed = @[@[], @[@0], @[@1], @[@65535], @[@1,@2], @[@12,@3], @[@1,@23],
                       @[@2,@1], @[@0,@0], @[@1,@2,@3], @[@(-1),@2], @[@1,@2]];
    // Signed test-only values also exercise Foundation number-hash collisions;
    // no font shaping or drawing uses these synthetic candidate arrays.
    for (NSUInteger test = 0; test < 180; ++test) {
        NSString *text = @"abcd";
        NSMutableArray<GACharacterGroup *> *groups = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; ++i) {
            GACharacterGroup *g = [GACharacterGroup new];
            g.textRange = NSMakeRange(i, 1); g.text = [text substringWithRange:g.textRange];
            g.variants = @[variant(document, @[@(100 + i)], i)];
            [groups addObject:g];
        }
        NSMutableArray *candidates = [groups.lastObject.variants mutableCopy];
        NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphVariant *> *> *expected = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 90; ++i) {
            state = state * 1664525u + 1013904223u;
            NSRange range = i % 3 == 0 ? NSMakeRange(0,2) : i % 3 == 1 ? NSMakeRange(0,4) : NSMakeRange(1,3);
            NSArray *ids = fixed[state % fixed.count];
            if (i > fixed.count && state % 3 == 0) {
                NSMutableArray *randomIDs = [NSMutableArray array];
                for (NSUInteger j = 0, length = 2 + state % 7; j < length; ++j) {
                    state = state * 1664525u + 1013904223u;
                    [randomIDs addObject:@(state % 16)];
                }
                ids = randomIDs;
            }
            GAGlyphVariant *v = variant(document, ids, i);
            v.ligature = YES; v.sourceTextRange = range;
            [candidates addObject:v];
            NSValue *key = [NSValue valueWithRange:range];
            if (!expected[key]) expected[key] = [NSMutableArray array];
            BOOL duplicate = NO;
            for (GAGlyphVariant *old in expected[key])
                if ([old.glyphIDs isEqualToArray:ids]) { duplicate = YES; break; }
            if (!duplicate) [expected[key] addObject:v];
        }
        groups.lastObject.variants = candidates;
        NSArray<GACharacterGroup *> *display = GABuildDisplayGroups(groups, text, @[], document, nil);
        NSCAssert(display.count == 7, @"Missing source/combination groups");
        for (GACharacterGroup *g in display) {
            if (!g.insertedLigature) continue;
            NSArray<GAGlyphVariant *> *wanted = expected[[NSValue valueWithRange:g.textRange]];
            NSCAssert(g.variants.count == wanted.count, @"Combination deduplication changed count");
            for (NSUInteger i = 0; i < wanted.count; ++i) {
                GAGlyphVariant *actual = g.variants[i], *first = wanted[i];
                NSCAssert([actual.glyphIDs isEqualToArray:first.glyphIDs] &&
                          [actual.glyphName isEqual:first.glyphName] &&
                          [actual.featureSources isEqual:first.featureSources] &&
                          [actual.positions isEqual:first.positions] && actual.base == (i == 0),
                          @"Combination identity, order or first-candidate metadata changed");
            }
        }
        __block NSUInteger polls = 0;
        NSCAssert(GABuildDisplayGroups(groups, text, @[], document, ^BOOL { return ++polls >= 4; }) == nil,
                  @"Cancelled projection must not publish");
        [results addObject:displayGroups(display)];
    }
    return results;
}

static id matches(NSArray<GASubstitutionMatch *> *items) {
    if (!items) return NSNull.null;
    NSMutableArray *out = [NSMutableArray array];
    for (GASubstitutionMatch *m in items)
        [out addObject:@[m.glyphIDs, m.sources, NSStringFromRange(m.sourceRange), @(m.base)]];
    return out;
}
static GASubstitutionEngine *engine(CTFontRef font) {
    return [[GASubstitutionEngine alloc] initWithFont:font coordinates:nil sharing:nil];
}
int main(void) {
    @autoreleasepool {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *name in @[@"Helvetica", @"HoeflerText-Regular", @"TimesNewRomanPSMT",
                                @"PingFangSC-Regular", @"GeezaPro", @"DevanagariSangamMN",
                                @"AppleMyungjo", @"Zapfino"]) {
            CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, 200, NULL);
            NSString *actual = CFBridgingRelease(CTFontCopyPostScriptName(font));
            NSCAssert([actual isEqualToString:name], @"Requested font unavailable: %@ (%@)", name, actual);
            GASubstitutionEngine *e = engine(font);
            CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
            GAFontDocument *document = [[GAFontDocument alloc] initWithDescriptor:descriptor URL:nil];
            CFRelease(descriptor);
            GATextQueryModel *model = [[GATextQueryModel alloc] initWithFontDocument:document];
            NSCAssert([model analyzeText:@"fi ffi A\u0301" selections:@[] cancelled:nil], @"Model query failed");
            NSArray *display = GABuildDisplayGroups(model.groups, @"fi ffi A\u0301", @[], document, nil);
            NSCAssert(display != nil, @"Model display projection failed");
            [out addObject:@[name, @"model-display", displayGroups(display)]];
            if ([name isEqualToString:@"Helvetica"])
                [out addObject:@[name, @"combination-identities", combinationCases(document)]];
            for (NSString *text in @[@"fi ffi AV", @"A\u0301g\u0323", @"天地玄黃", @"السلام",
                                    @"किरण", @"fi\nffi"]) {
                BOOL incomplete = NO;
                NSArray<GASubstitutionMatch *> *found = [e discoverText:text selections:@[]
                                                            incomplete:&incomplete cancelled:nil];
                NSCAssert(found != nil, @"Uncancelled text query returned nil");
                NSCAssert(found.count > 0 && found.firstObject.base, @"Missing nominal text roots");
                for (GASubstitutionMatch *match in found)
                    NSCAssert(NSMaxRange(match.sourceRange) <= text.length, @"Invalid source range");
                id result = matches(found);
                BOOL cachedIncomplete = NO;
                NSArray *cachedMatches = [e discoverText:text selections:@[] incomplete:&cachedIncomplete cancelled:nil];
                NSCAssert(cachedMatches != nil, @"Uncancelled cached text query returned nil");
                id cached = matches(cachedMatches);
                NSCAssert([result isEqual:cached] && incomplete == cachedIncomplete, @"Cache changed result");
                NSMutableArray *positions = [NSMutableArray array];
                for (NSUInteger i = 0; i < MIN(found.count, 12); ++i) {
                    NSArray *points = [e positionsForGlyphIDs:found[i].glyphIDs content:text];
                    NSMutableArray *formatted = [NSMutableArray array];
                    for (NSValue *point in points) [formatted addObject:NSStringFromPoint(point.pointValue)];
                    [positions addObject:formatted];
                }
                [out addObject:@[name, @"text", text, result, @(incomplete), positions]];
            }
            UniChar chars[] = {'f', 'i', 'A'};
            CGGlyph glyphs[3] = {};
            CTFontGetGlyphsForCharacters(font, chars, glyphs, 3);
            for (NSArray *ids in @[@[], @[@0], @[@(glyphs[0])], @[@(glyphs[0]), @(glyphs[1])],
                                   @[@(glyphs[2])], @[@65535]]) {
                NSArray<GASubstitutionMatch *> *found = [e discoverGlyphIDs:ids cancelled:nil];
                NSCAssert(found != nil, @"Uncancelled GID query returned nil");
                if (ids.count)
                    NSCAssert(found.count && found.firstObject.base && [found.firstObject.glyphIDs isEqual:ids],
                              @"Missing literal GID root");
                else
                    NSCAssert(found.count == 0, @"Empty GID query must be empty");
                id result = matches(found);
                NSArray *cachedMatches = [e discoverGlyphIDs:ids cancelled:nil];
                NSCAssert(cachedMatches != nil, @"Uncancelled cached GID query returned nil");
                id cached = matches(cachedMatches);
                NSCAssert([result isEqual:cached], @"GID cache changed result");
                [out addObject:@[name, @"gids", ids, result]];
            }
            for (NSNumber *limit in @[@1, @2, @5, @20]) {
                GASubstitutionEngine *fresh = engine(font);
                __block NSUInteger polls = 0;
                BOOL incomplete = NO;
                NSArray *found = [fresh discoverText:@"fi ffi AV A\u0301" selections:@[] incomplete:&incomplete
                    cancelled:^BOOL { return ++polls >= limit.unsignedIntegerValue; }];
                NSCAssert(polls < limit.unsignedIntegerValue ? found != nil : found == nil,
                          @"Text cancellation result does not match the cancellation signal");
                NSCAssert(found != nil || !incomplete, @"Cancellation is not incomplete discovery");
                [out addObject:@[name, @"cancel-text", limit, @(polls), matches(found), @(incomplete)]];
                fresh = engine(font); polls = 0;
                found = [fresh discoverGlyphIDs:@[@(glyphs[0]), @(glyphs[1])]
                    cancelled:^BOOL { return ++polls >= limit.unsignedIntegerValue; }];
                NSCAssert(polls < limit.unsignedIntegerValue ? found != nil : found == nil,
                          @"GID cancellation result does not match the cancellation signal");
                [out addObject:@[name, @"cancel-gids", limit, @(polls), matches(found)]];
            }
            CFRelease(font);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:NULL];
        NSCAssert(json != nil, @"Invalid result serialization");
        fwrite(json.bytes, 1, json.length, stdout);
        putchar('\n');
    }
}
