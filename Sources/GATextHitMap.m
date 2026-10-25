#import "GATextHitMap.h"
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
            hit.glyphIDs = @[];
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
        if (lo)
            [glyphs[lo - 1] addObjectsFromArray:atom.glyphIDs];
    }
    for (NSUInteger i = 0; i < result.count; i++)
        result[i].glyphIDs = glyphs[i];
    return result;
}
NSArray<GAGlyphLayoutRun *> *GAMapGlyphLayoutRuns(NSArray<GAGlyphLayoutRun *> *hits,
                                                  NSArray<NSNumber *> *sourceIndices,
                                                  NSArray<NSValue *> *atomicRanges,
                                                  NSString *sourceText) {
    NSArray *ordered = [hits
        sortedArrayUsingComparator:^NSComparisonResult(GAGlyphLayoutRun *a, GAGlyphLayoutRun *b) {
          return a.range.location < b.range.location   ? NSOrderedAscending
                 : a.range.location > b.range.location ? NSOrderedDescending
                                                       : NSOrderedSame;
        }];
    NSMutableArray *atoms = [NSMutableArray array];
    for (GAGlyphLayoutRun *display in ordered) {
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

NSArray<GAGlyphLayoutRun *> *GAPredictDisplayGlyphRuns(NSTextLayoutManager *layout, NSArray *pins,
                                                       GAFontDocument *document, BOOL contextual,
                                                       BOOL ligatures, BOOL vertical) {
    NSTextContentManager *content = layout.textContentManager;
    id<NSTextLocation> start = content.documentRange.location;
    NSMutableArray *result = [NSMutableArray array];
    [layout
        enumerateTextLayoutFragmentsFromLocation:nil
                                         options:0
                                      usingBlock:^BOOL(NSTextLayoutFragment *fragment) {
                                        NSInteger offset = [content
                                            offsetFromLocation:start
                                                    toLocation:fragment.rangeInElement.location];
                                        for (NSTextLineFragment *line in fragment
                                                 .textLineFragments) {
                                            if (!line.characterRange.length)
                                                continue;
                                            NSUInteger first =
                                                offset + line.characterRange.location;
                                            NSUInteger end = offset + line.attributedString.length;
                                            NSUInteger visibleEnd =
                                                offset + NSMaxRange(line.characterRange);
                                            // TextKit keeps lookahead past a soft line end, while
                                            // the line start resets preceding context. Explicit
                                            // NSGlyphInfo overrides are fixed glyph atoms, not
                                            // inputs to another GSUB pass.
                                            for (NSUInteger i = first; i < visibleEnd;) {
                                                id pin = i < pins.count ? pins[i] : NSNull.null;
                                                NSUInteger next = i + 1;
                                                while (next < end &&
                                                       (next < pins.count ? pins[next]
                                                                          : NSNull.null) == pin)
                                                    next++;
                                                if ([pin isKindOfClass:GAGlyphSelection.class]) {
                                                    if (i < visibleEnd) {
                                                        GAGlyphLayoutRun *hit =
                                                            [GAGlyphLayoutRun new];
                                                        hit.range = NSMakeRange(
                                                            i, MIN(next, visibleEnd) - i);
                                                        hit.glyphIDs = [pin glyphIDs];
                                                        [result addObject:hit];
                                                    }
                                                } else {
                                                    NSString *text = [line.attributedString.string
                                                        substringWithRange:NSMakeRange(i - offset,
                                                                                       next - i)];
                                                    for (GAGlyphLayoutRun *hit in
                                                         [document layoutRunsForText:text
                                                                          contextual:contextual
                                                                           ligatures:ligatures
                                                                            vertical:vertical]) {
                                                        if (i + NSMaxRange(hit.range) > visibleEnd)
                                                            continue;
                                                        hit.range =
                                                            NSMakeRange(i + hit.range.location,
                                                                        hit.range.length);
                                                        [result addObject:hit];
                                                    }
                                                }
                                                i = next;
                                            }
                                        }
                                        return YES;
                                      }];
    return result;
}
