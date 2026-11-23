#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import "FontLayout/GASubstitutionEngine.h"
#import "Font/GAGlyphSelection.h"

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
