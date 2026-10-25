#import "ReferenceNativeTextHit.h"
#import <CoreText/CoreText.h>

@implementation GANativeGlyphHit
@end

static NSArray<GANativeGlyphHit *> *MergeHits(NSArray<GANativeGlyphHit *> *atoms) {
    NSArray *sorted = [atoms
        sortedArrayUsingComparator:^NSComparisonResult(GANativeGlyphHit *a, GANativeGlyphHit *b) {
          if (a.range.location != b.range.location)
              return a.range.location < b.range.location ? NSOrderedAscending : NSOrderedDescending;
          return NSOrderedSame;
        }];
    NSMutableArray<GANativeGlyphHit *> *result = [NSMutableArray array];
    for (GANativeGlyphHit *atom in sorted) {
        GANativeGlyphHit *last = result.lastObject;
        if (last && NSIntersectionRange(last.range, atom.range).length)
            last.range = NSUnionRange(last.range, atom.range);
        else {
            GANativeGlyphHit *hit = [GANativeGlyphHit new];
            hit.range = atom.range;
            hit.glyphIDs = @[];
            [result addObject:hit];
        }
    }
    NSMutableArray<NSMutableArray *> *glyphs = [NSMutableArray arrayWithCapacity:result.count];
    for (NSUInteger i = 0; i < result.count; i++)
        [glyphs addObject:[NSMutableArray array]];
    // Keep caller order and assign in O(log n), even for large glyph atlases.
    for (GANativeGlyphHit *atom in atoms) {
        NSUInteger lo = 0, hi = result.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (result[mid].range.location <= atom.range.location)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo)
            [glyphs[lo - 1] addObjectsFromArray:atom.glyphIDs];
    }
    for (NSUInteger i = 0; i < result.count; i++)
        result[i].glyphIDs = glyphs[i];
    return result;
}
NSArray<GANativeGlyphHit *> *GANativeGlyphHitsForLine(NSTextLineFragment *line, BOOL vertical) {
    if (!line.characterRange.length)
        return @[];
    NSMutableAttributedString *source = [line.attributedString mutableCopy];
    [line.attributedString enumerateAttribute:NSVerticalGlyphFormAttributeName
                                      inRange:NSMakeRange(0, source.length)
                                      options:0
                                   usingBlock:^(id value, NSRange range, BOOL *stop) {
                                     (void)stop;
                                     if (!value && vertical)
                                         [source addAttribute:NSVerticalGlyphFormAttributeName
                                                        value:@YES
                                                        range:range];
                                   }];
    CTTypesetterRef typesetter =
        CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)source);
    CTLineRef nativeLine = CTTypesetterCreateLine(
        typesetter, CFRangeMake(line.characterRange.location, line.characterRange.length));
    CFRelease(typesetter);
    NSMutableArray *glyphs = [NSMutableArray array], *indices = [NSMutableArray array];
    NSMutableSet *starts = [NSMutableSet setWithObject:@(NSMaxRange(line.characterRange))];
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(nativeLine)) {
        CTRunRef run = (__bridge CTRunRef)object;
        CFIndex count = CTRunGetGlyphCount(run);
        CGGlyph *ids = calloc((size_t)count, sizeof(*ids));
        CFIndex *locations = calloc((size_t)count, sizeof(*locations));
        CTRunGetGlyphs(run, CFRangeMake(0, count), ids);
        CTRunGetStringIndices(run, CFRangeMake(0, count), locations);
        for (CFIndex i = 0; i < count; i++)
            if (locations[i] >= 0 &&
                NSLocationInRange((NSUInteger)locations[i], line.characterRange)) {
                [glyphs addObject:@(ids[i])];
                [indices addObject:@(locations[i])];
                [starts addObject:@(locations[i])];
            }
        free(ids);
        free(locations);
    }
    CFRelease(nativeLine);
    NSArray<NSNumber *> *ordered = [starts.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *ends = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < ordered.count; i++)
        ends[ordered[i]] = ordered[i + 1];
    NSMutableArray *atoms = [NSMutableArray array];
    for (NSUInteger i = 0; i < glyphs.count; i++) {
        NSUInteger start = [indices[i] unsignedIntegerValue],
                   end = [ends[indices[i]] unsignedIntegerValue];
        if (end <= start)
            continue;
        GANativeGlyphHit *hit = [GANativeGlyphHit new];
        hit.range = [line.attributedString.string
            rangeOfComposedCharacterSequencesForRange:NSMakeRange(start, end - start)];
        hit.glyphIDs = @[ glyphs[i] ];
        [atoms addObject:hit];
    }
    return MergeHits(atoms);
}
NSArray<GANativeGlyphHit *> *GAMapNativeGlyphHits(NSArray<GANativeGlyphHit *> *hits,
                                                  NSArray<NSNumber *> *sourceIndices,
                                                  NSArray<NSValue *> *atomicRanges,
                                                  NSString *sourceText) {
    NSArray *ordered = [hits
        sortedArrayUsingComparator:^NSComparisonResult(GANativeGlyphHit *a, GANativeGlyphHit *b) {
          return a.range.location < b.range.location   ? NSOrderedAscending
                 : a.range.location > b.range.location ? NSOrderedDescending
                                                       : NSOrderedSame;
        }];
    NSMutableArray *atoms = [NSMutableArray array];
    for (GANativeGlyphHit *display in ordered) {
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
        GANativeGlyphHit *hit = [GANativeGlyphHit new];
        hit.range = range;
        hit.glyphIDs = display.glyphIDs;
        [atoms addObject:hit];
    }
    return MergeHits(atoms);
}
