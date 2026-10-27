#import "GATextDisplay.h"
#import <CoreText/SFNTLayoutTypes.h>

@implementation GAGlyphLayoutRun
@end

@interface NSTextLineFragment (GAGlyphReadback)
@property(nonatomic, readonly, nullable) CTLineRef lineRef;
@end

#pragma mark - Display copy

static NSDictionary *GAAATDisplaySetting(NSInteger type, NSInteger selector) {
    return @{
        (__bridge NSString *)kCTFontFeatureTypeIdentifierKey : @(type),
        (__bridge NSString *)kCTFontFeatureSelectorIdentifierKey : @(selector)
    };
}

CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
                                BOOL ligatures) {
    NSMutableArray *settings = [NSMutableArray array];
    // Enabled menu groups leave the document font's defaults unspecified.
    if (!ligatures) {
        const NSInteger selectors[] = {
            kRequiredLigaturesOffSelector,
            kCommonLigaturesOffSelector,
            kRareLigaturesOffSelector,
            kLogosOffSelector,
            kRebusPicturesOffSelector,
            kDiphthongLigaturesOffSelector,
            kSquaredLigaturesOffSelector,
            kAbbrevSquaredLigaturesOffSelector,
            kSymbolLigaturesOffSelector,
            kContextualLigaturesOffSelector,
            kHistoricalLigaturesOffSelector
        };
        for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++)
            [settings addObject:GAAATDisplaySetting(kLigaturesType, selectors[i])];
    }
    if (!contextualAlternates) {
        const NSInteger selectors[] = {
            kContextualAlternatesOffSelector,
            kSwashAlternatesOffSelector,
            kContextualSwashAlternatesOffSelector
        };
        for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++)
            [settings addObject:GAAATDisplaySetting(kContextualAlternatesType, selectors[i])];
    }
    if (!settings.count)
        return CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
    NSDictionary *attributes = @{(__bridge NSString *)kCTFontFeatureSettingsAttribute : settings};
    CTFontDescriptorRef descriptor =
        CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    CTFontRef result = CTFontCreateCopyWithAttributes(font, size, NULL, descriptor);
    CFRelease(descriptor);
    return result;
}

NSAttributedString *GACreateGlyphDisplayString(
    NSArray<NSNumber *> *glyphIDs, NSString *baseString, NSFont *font,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    NSString *(^baseForGlyph)(CGGlyph)) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    for (NSNumber *number in glyphIDs) {
        CGGlyph glyph = number.unsignedShortValue;
        NSString *base = baseForGlyph(glyph) ?: baseString;
        NSGlyphInfo *info = [NSGlyphInfo glyphInfoWithCGGlyph:glyph forFont:font baseString:base];
        if (!info)
            return nil;
        NSMutableAttributedString *component =
            [[NSMutableAttributedString alloc] initWithString:base attributes:attributes];
        [component addAttribute:NSGlyphInfoAttributeName
                          value:info
                          range:NSMakeRange(0, component.length)];
        [result appendAttributedString:component];
    }
    return result;
}

void GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                              NSMutableArray<NSNumber *> *sourceIndices,
                              NSRange sourceRange, NSAttributedString *replacement) {
    NSCParameterAssert(sourceRange.length > 0);
    NSCParameterAssert(display.length == sourceIndices.count);
    NSCParameterAssert(NSMaxRange(sourceRange) <= display.length);
    NSNumber *source = sourceIndices[sourceRange.location];
    NSMutableArray *indices = [NSMutableArray arrayWithCapacity:replacement.length];
    for (NSUInteger i = 0; i < replacement.length; i++)
        [indices addObject:source];
    [display replaceCharactersInRange:sourceRange withAttributedString:replacement];
    [sourceIndices replaceObjectsInRange:sourceRange withObjectsFromArray:indices];
}

#pragma mark - Hit mapping

static NSArray<GAGlyphLayoutRun *> *MergeHits(NSArray<GAGlyphLayoutRun *> *atoms) {
    NSArray *sorted = [atoms
        sortedArrayUsingComparator:^NSComparisonResult(GAGlyphLayoutRun *a, GAGlyphLayoutRun *b) {
          if (a.range.location != b.range.location)
              return a.range.location < b.range.location ? NSOrderedAscending : NSOrderedDescending;
          return NSOrderedSame;
        }];
    NSMutableArray<GAGlyphLayoutRun *> *result = [NSMutableArray array];
    for (GAGlyphLayoutRun *atom in sorted) {
        GAGlyphLayoutRun *last = result.lastObject;
        if (last && NSIntersectionRange(last.range, atom.range).length)
            last.range = NSUnionRange(last.range, atom.range);
        else {
            GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
            hit.range = atom.range;
            [result addObject:hit];
        }
    }
    NSMutableArray<NSMutableArray *> *glyphs = [NSMutableArray arrayWithCapacity:result.count];
    for (NSUInteger i = 0; i < result.count; i++)
        [glyphs addObject:[NSMutableArray array]];
    // Keep caller order and assign in O(log n), even for large glyph atlases.
    for (GAGlyphLayoutRun *atom in atoms) {
        NSUInteger lo = 0, hi = result.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (result[mid].range.location <= atom.range.location)
                lo = mid + 1;
            else
                hi = mid;
        }
        [glyphs[lo - 1] addObjectsFromArray:atom.glyphIDs];
    }
    for (NSUInteger i = 0; i < result.count; i++)
        result[i].glyphIDs = glyphs[i];
    return result;
}
static NSArray<GAGlyphLayoutRun *> *MapGlyphLayoutRuns(
    NSArray<GAGlyphLayoutRun *> *hits, NSArray<NSNumber *> *sourceIndices,
    NSArray<NSValue *> *atomicRanges, NSString *sourceText) {
    NSMutableArray *atoms = [NSMutableArray array];
    for (GAGlyphLayoutRun *display in hits) {
        if (!display.range.length || NSMaxRange(display.range) > sourceIndices.count)
            continue;
        NSUInteger first = NSUIntegerMax, last = 0;
        for (NSUInteger i = display.range.location; i < NSMaxRange(display.range); i++) {
            NSUInteger source = sourceIndices[i].unsignedIntegerValue;
            first = MIN(first, source);
            last = MAX(last, source);
        }
        if (last >= sourceText.length)
            continue;
        NSRange range = [sourceText
            rangeOfComposedCharacterSequencesForRange:NSMakeRange(first, last - first + 1)];
        for (NSValue *value in atomicRanges)
            if (NSIntersectionRange(range, value.rangeValue).length)
                range = NSUnionRange(range, value.rangeValue);
        GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
        hit.range = range;
        hit.glyphIDs = display.glyphIDs;
        [atoms addObject:hit];
    }
    return MergeHits(atoms);
}

NSArray<GAGlyphLayoutRun *> *GAReadDisplayGlyphRuns(
    NSTextLayoutManager *layout, NSArray<NSNumber *> *sourceIndices,
    NSArray<NSValue *> *atomicRanges, NSString *sourceText) {
    NSTextContentManager *content = layout.textContentManager;
    id<NSTextLocation> start = content.documentRange.location;
    NSMutableArray *result = [NSMutableArray array];
    [layout enumerateTextLayoutFragmentsFromLocation:nil
                                            options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *fragment) {
        NSInteger offset = [content offsetFromLocation:start
                                           toLocation:fragment.rangeInElement.location];
        for (NSTextLineFragment *line in fragment.textLineFragments) {
            CTLineRef native = line.lineRef;
            if (!native || !line.characterRange.length)
                continue;
            NSMutableArray<GAGlyphLayoutRun *> *atoms = [NSMutableArray array];
            NSMutableIndexSet *boundaries =
                [NSMutableIndexSet indexSetWithIndex:NSMaxRange(line.characterRange)];
            for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(native)) {
                CTRunRef run = (__bridge CTRunRef)object;
                CFRange range = CTRunGetStringRange(run);
                [boundaries addIndex:(NSUInteger)(range.location + range.length)];
                CFIndex count = CTRunGetGlyphCount(run);
                if (!count)
                    continue;
                NSMutableData *glyphData = [NSMutableData dataWithLength:count * sizeof(CGGlyph)];
                NSMutableData *indexData = [NSMutableData dataWithLength:count * sizeof(CFIndex)];
                CGGlyph *glyphs = glyphData.mutableBytes;
                CFIndex *indices = indexData.mutableBytes;
                CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
                CTRunGetStringIndices(run, CFRangeMake(0, 0), indices);
                for (CFIndex i = 0; i < count;) {
                    NSUInteger index = (NSUInteger)indices[i];
                    NSMutableArray *ids = [NSMutableArray array];
                    do {
                        [ids addObject:@(glyphs[i++])];
                    } while (i < count && (NSUInteger)indices[i] == index);
                    if (!NSLocationInRange(index, line.characterRange))
                        continue;
                    [boundaries addIndex:index];
                    GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
                    hit.range = NSMakeRange(index, 0);
                    hit.glyphIDs = ids;
                    [atoms addObject:hit];
                }
            }
            // Logical boundaries define source spans; keep native glyph order.
            for (GAGlyphLayoutRun *hit in atoms) {
                NSUInteger index = hit.range.location;
                hit.range = NSMakeRange((NSUInteger)offset + index,
                                       [boundaries indexGreaterThanIndex:index] - index);
                [result addObject:hit];
            }
        }
        return YES;
    }];
    return MapGlyphLayoutRuns(result, sourceIndices, atomicRanges, sourceText);
}
