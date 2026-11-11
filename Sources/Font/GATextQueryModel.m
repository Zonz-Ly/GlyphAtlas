#import "GATextQueryModel.h"
#import "GAFontEngine.h"
#import "GAUnicode.h"

#pragma mark - Query state

static NSArray<GACharacterGroup *> *GAProjectScanResult(GAFontDocument *document,
                                                        GARawScanResult *result, NSString *text,
                                                        BOOL (^cancelled)(void)) {
    NSArray<GACharacterGroup *> *groups = GAGroupsForScanResult(text, result);
    return [document applyRawResult:result groups:groups cancelled:cancelled] ? groups : nil;
}

@implementation GATextQueryModel {
    GAFontDocument *_document;
    NSString *_text;
    GAGlyphQueryIdentity *_identity;
    GARawScanResult *_result;
}
- (instancetype)initWithFontDocument:(GAFontDocument *)document {
    self = [super init];
    if (self) {
        _document = document;
        _groups = @[];
    }
    return self;
}
- (BOOL)analyzeText:(NSString *)text
         selections:(NSArray<GAGlyphSelectionRun *> *)selections
          cancelled:(BOOL (^)(void))cancelled {
    if (cancelled && cancelled())
        return NO;
    GAGlyphQueryIdentity *identity = GAGlyphQueryKey(text, selections);
    if ([_identity isEqual:identity])
        return YES;
    GARawScanResult *result = [_document rawScanContent:text
                                            selections:selections
                                             cancelled:cancelled];
    if (!result)
        return NO;
    NSArray<GACharacterGroup *> *groups = GAProjectScanResult(_document, result, text, cancelled);
    if (!groups)
        return NO;
    _text = [text copy];
    _identity = result.incomplete ? nil : identity;
    _result = result;
    _groups = groups;
    return YES;
}
- (BOOL)updateFontDocument:(GAFontDocument *)document cancelled:(BOOL (^)(void))cancelled {
    if (cancelled && cancelled())
        return NO;
    GARawScanResult *result = _result;
    NSArray<GACharacterGroup *> *groups = _groups;
    if (_result) {
        result = [document rebindResult:_result content:_text cancelled:cancelled];
        if (!result)
            return NO;
        groups = GAProjectScanResult(document, result, _text, cancelled);
        if (!groups)
            return NO;
    }
    if (cancelled && cancelled())
        return NO;
    // analysisQueue owns these fields; publish only a completed projection.
    _document = document;
    _result = result;
    _groups = groups;
    return YES;
}
@end

#pragma mark - Display groups

static GACharacterGroup *DisplayCopy(GACharacterGroup *group) {
    GACharacterGroup *copy = [[GACharacterGroup alloc] init];
    copy.text = group.text;
    copy.textRange = group.textRange;
    BOOL hasLigatures = NO;
    for (GAGlyphVariant *variant in group.variants) {
        if (variant.isLigature) {
            hasLigatures = YES;
            break;
        }
    }
    NSArray<GAGlyphVariant *> *variants = group.variants;
    if (hasLigatures) {
        NSMutableArray<GAGlyphVariant *> *filtered = [NSMutableArray array];
        for (GAGlyphVariant *variant in variants) {
            if (!variant.isLigature)
                [filtered addObject:variant];
        }
        variants = filtered;
    }
    copy.variants = variants;
    return copy;
}

static GACharacterGroup *SelectionGroup(GAGlyphSelectionRun *run, GAFontDocument *document,
                                        BOOL (^cancelled)(void)) {
    GAGlyphSelection *selection = run.selection;
    NSArray<GAGlyphVariant *> *variants = [document variantsForGlyphIDs:selection.glyphIDs cancelled:cancelled];
    GAGlyphVariant *base = variants.firstObject;
    if (base == nil) {
        return nil;
    }

    [base addFeatureSources:selection.featureSources];
    if (selection.ligature) {
        base.ligature = YES;
        base.sourceTextRange = run.range;
    }

    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = selection.sourceText;
    group.textRange = run.range;
    group.variants = variants;
    group.seeded = YES;
    return group;
}

static int GACompareSourceEndpoints(const void *a, const void *b) {
    NSUInteger x = *(const NSUInteger *)a, y = *(const NSUInteger *)b;
    return (x > y) - (x < y);
}

static NSUInteger GASourceEndpointCount(const NSUInteger *points, NSUInteger count,
                                         NSUInteger edge, BOOL includeEqual) {
    NSUInteger first = 0;
    while (first < count) {
        NSUInteger mid = (first + count) / 2;
        if (points[mid] < edge || (includeEqual && points[mid] == edge)) first = mid + 1;
        else count = mid;
    }
    return first;
}

static BOOL IntersectsSelection(NSRange range, NSArray<GAGlyphSelectionRun *> *runs,
                                  const NSUInteger *starts, const NSUInteger *ends,
                                  NSUInteger count) {
    if (range.location == NSNotFound || range.length == 0) return NO;
    if (starts && NSMaxRange(range) >= range.location)
        return GASourceEndpointCount(starts, count, NSMaxRange(range), NO) >
               GASourceEndpointCount(ends, count, range.location, YES);
    for (GAGlyphSelectionRun *run in runs)
        if (NSIntersectionRange(range, run.range).length > 0) return YES;
    return NO;
}

static void GAMergeSelectionCandidate(GAGlyphVariant *candidate, NSMutableArray *variants,
                                       GAFontDocument *document, NSString *text) {
    for (GAGlyphVariant *existing in variants)
        if ([existing.glyphIDs isEqual:candidate.glyphIDs]) {
            [existing addFeatureSources:candidate.featureSources];
            return;
        }
    GAGlyphVariant *copy = [document rebindVariant:candidate content:text];
    copy.base = NO;
    [variants addObject:copy];
}

NSArray<GACharacterGroup *> *GABuildDisplayGroups(NSArray<GACharacterGroup *> *groups,
                                                  NSString *text,
                                                  NSArray<GAGlyphSelectionRun *> *selections,
                                                  GAFontDocument *document,
                                                  BOOL (^cancelled)(void)) {
    BOOL indexSelections = groups.count >= 256 && selections.count >= 8;
    NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphVariant *> *> *seedCandidates =
        indexSelections ? [NSMutableDictionary dictionary] : nil;
    if (indexSelections) {
        for (GACharacterGroup *source in groups) {
            if (cancelled && cancelled()) return nil;
            for (GAGlyphVariant *candidate in source.variants) {
                if (cancelled && cancelled()) return nil;
                if (!candidate.fromGlyphSeed || candidate.isLigature ||
                    !NSIntersectionRange(source.textRange, candidate.sourceTextRange).length) continue;
                NSValue *key = [NSValue valueWithRange:candidate.sourceTextRange];
                if (!seedCandidates[key]) seedCandidates[key] = [NSMutableArray array];
                [seedCandidates[key] addObject:candidate];
            }
        }
    }
    NSMutableArray<GAGlyphSelectionRun *> *validSelections = [NSMutableArray array];
    NSMutableArray<GACharacterGroup *> *selectionGroups = [NSMutableArray array];
    for (GAGlyphSelectionRun *run in selections) {
        if (cancelled && cancelled())
            return nil;
        GACharacterGroup *selectionGroup = SelectionGroup(run, document, cancelled);
        if (selectionGroup != nil) {
            NSMutableArray *variants = [selectionGroup.variants mutableCopy];
            if (indexSelections) {
                for (GAGlyphVariant *candidate in seedCandidates[[NSValue valueWithRange:run.range]]) {
                    if (cancelled && cancelled()) return nil;
                    GAMergeSelectionCandidate(candidate, variants, document, selectionGroup.text);
                }
            } else for (GACharacterGroup *source in groups) {
                if (cancelled && cancelled()) return nil;
                if (!NSIntersectionRange(source.textRange, run.range).length) continue;
                for (GAGlyphVariant *candidate in source.variants) {
                    if (cancelled && cancelled()) return nil;
                    if (candidate.fromGlyphSeed && !candidate.isLigature &&
                        NSEqualRanges(candidate.sourceTextRange, run.range))
                        GAMergeSelectionCandidate(candidate, variants, document, selectionGroup.text);
                }
            }
            selectionGroup.variants = variants;
            [validSelections addObject:run];
            [selectionGroups addObject:selectionGroup];
        }
    }

    NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphSelectionRun *> *> *selectedRanges =
        indexSelections ? [NSMutableDictionary dictionary] : nil;
    NSMutableData *selectionStarts = indexSelections
        ? [NSMutableData dataWithLength:validSelections.count * sizeof(NSUInteger)] : nil;
    NSMutableData *selectionEnds = indexSelections
        ? [NSMutableData dataWithLength:validSelections.count * sizeof(NSUInteger)] : nil;
    NSUInteger *selectedStarts = selectionStarts.mutableBytes, *selectedEnds = selectionEnds.mutableBytes;
    NSUInteger selectedCount = 0;
    BOOL validEndpoints = indexSelections;
    if (indexSelections) for (GAGlyphSelectionRun *run in validSelections) {
        NSValue *key = [NSValue valueWithRange:run.range];
        if (!selectedRanges[key]) selectedRanges[key] = [NSMutableArray array];
        [selectedRanges[key] addObject:run];
        NSRange range = run.range;
        if (!range.length) continue;
        if (range.location == NSNotFound || NSMaxRange(range) < range.location) {
            validEndpoints = NO;
            continue;
        }
        selectedStarts[selectedCount] = range.location;
        selectedEnds[selectedCount++] = NSMaxRange(range);
    }
    if (validEndpoints) {
        qsort(selectedStarts, selectedCount, sizeof(NSUInteger), GACompareSourceEndpoints);
        qsort(selectedEnds, selectedCount, sizeof(NSUInteger), GACompareSourceEndpoints);
    } else {
        selectedStarts = selectedEnds = NULL;
    }

    NSMutableArray<GAGlyphVariant *> *ligatureVariants = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        if (cancelled && cancelled())
            return nil;
        for (GAGlyphVariant *variant in group.variants) {
            if (cancelled && cancelled())
                return nil;
            if (variant.isLigature && variant.sourceTextRange.length > 0 &&
                variant.sourceTextRange.location <= text.length &&
                variant.sourceTextRange.length <= text.length - variant.sourceTextRange.location) {
                BOOL sameAsInput = NO;
                NSArray *matchingSelections = indexSelections
                    ? selectedRanges[[NSValue valueWithRange:variant.sourceTextRange]] : validSelections;
                for (GAGlyphSelectionRun *run in matchingSelections)
                    if (NSEqualRanges(run.range, variant.sourceTextRange) &&
                        [run.selection.glyphIDs isEqual:variant.glyphIDs]) {
                        sameAsInput = YES;
                        break;
                    }
                if (sameAsInput)
                    continue;
                // The current scan already positioned this combination for its source text.
                // A separate record lets the sidebar assign its own base variant.
                GAGlyphVariant *copy = variant.fontBox == document.fontBox
                    ? [variant copy]
                    : [document rebindVariant:variant
                                     content:[text substringWithRange:variant.sourceTextRange]];
                [ligatureVariants addObject:copy];
            }
        }
    }

    NSMutableArray<GACharacterGroup *> *sourceGroups = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        if (cancelled && cancelled())
            return nil;
        if (([group.text isEqualToString:@"\n"]) ||
            IntersectsSelection(group.textRange, validSelections,
                                selectedStarts, selectedEnds, selectedCount)) {
            continue;
        }
        [sourceGroups addObject:DisplayCopy(group)];
    }
    [sourceGroups addObjectsFromArray:selectionGroups];
    [sourceGroups sortUsingComparator:^NSComparisonResult(GACharacterGroup *a,
                                                          GACharacterGroup *b) {
      if (a.textRange.location != b.textRange.location) {
          return a.textRange.location < b.textRange.location ? NSOrderedAscending
                                                             : NSOrderedDescending;
      }
      if (a.textRange.length != b.textRange.length) {
          return a.textRange.length < b.textRange.length ? NSOrderedAscending : NSOrderedDescending;
      }
      return NSOrderedSame;
    }];

    NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphVariant *> *> *byRange =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSValue *, NSNumber *> *spanLengths = [NSMutableDictionary dictionary];
    for (GAGlyphVariant *variant in ligatureVariants) {
        if (cancelled && cancelled())
            return nil;
        NSRange range = variant.sourceTextRange;
        NSValue *rangeValue = [NSValue valueWithRange:range];
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        if (variants == nil) {
            variants = [NSMutableArray array];
            byRange[rangeValue] = variants;
        }
        [variants addObject:variant];
    }
    // Counting starts before the range end minus ends at/before its start
    // handles overlapping, unordered and duplicate source groups alike.
    // Small projections retain the cheaper direct scan.
    BOOL indexed = groups.count >= 64 && byRange.count >= 16;
    NSMutableData *startData = indexed
        ? [NSMutableData dataWithLength:groups.count * sizeof(NSUInteger)] : nil;
    NSMutableData *endData = indexed
        ? [NSMutableData dataWithLength:groups.count * sizeof(NSUInteger)] : nil;
    NSUInteger *starts = startData.mutableBytes, *ends = endData.mutableBytes;
    NSUInteger count = 0;
    if (indexed) {
        for (GACharacterGroup *group in groups) {
            NSRange source = group.textRange;
            if (source.location == NSNotFound || !source.length) continue;
            if (NSMaxRange(source) < source.location) { indexed = NO; break; }
            starts[count] = source.location;
            ends[count++] = NSMaxRange(source);
        }
        if (indexed) {
            qsort(starts, count, sizeof(NSUInteger), GACompareSourceEndpoints);
            qsort(ends, count, sizeof(NSUInteger), GACompareSourceEndpoints);
        }
    }
    for (NSValue *rangeValue in byRange) {
        NSRange range = rangeValue.rangeValue;
        NSUInteger spanLength = 0;
        if (indexed) {
            spanLength = GASourceEndpointCount(starts, count, NSMaxRange(range), NO) -
                         GASourceEndpointCount(ends, count, range.location, YES);
        } else {
            for (GACharacterGroup *group in groups)
                if (group.textRange.location != NSNotFound &&
                    NSIntersectionRange(group.textRange, range).length > 0) spanLength++;
        }
        spanLengths[rangeValue] = @(spanLength);
    }
    // Order combination groups by the number of source character groups,
    // then by source position. Each is inserted after its final source
    // character below.
    NSArray<NSValue *> *rangeOrder =
        [byRange.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
          NSUInteger lengthA = spanLengths[a].unsignedIntegerValue;
          NSUInteger lengthB = spanLengths[b].unsignedIntegerValue;
          if (lengthA != lengthB) {
              return lengthA < lengthB ? NSOrderedAscending : NSOrderedDescending;
          }
          NSRange rangeA = a.rangeValue;
          NSRange rangeB = b.rangeValue;
          if (rangeA.location != rangeB.location) {
              return rangeA.location < rangeB.location ? NSOrderedAscending : NSOrderedDescending;
          }
          return NSOrderedSame;
        }];
    if (!rangeOrder.count) return sourceGroups;
    NSMutableDictionary<NSNumber *, NSMutableArray<GACharacterGroup *> *> *ligaturesAtEnd =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *endOrder = [NSMutableArray array];
    for (NSValue *rangeValue in rangeOrder) {
        if (cancelled && cancelled())
            return nil;
        NSRange range = rangeValue.rangeValue;
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        NSMutableArray<GAGlyphVariant *> *unique = [NSMutableArray array];
        NSMutableSet<NSString *> *glyphKeys = [NSMutableSet set];
        for (GAGlyphVariant *variant in variants) {
            NSString *key = variant.glyphKey;
            if ([glyphKeys containsObject:key])
                continue;
            [glyphKeys addObject:key];
            [unique addObject:variant];
        }
        GAGlyphVariant *base = unique.firstObject;
        for (GAGlyphVariant *variant in unique)
            variant.base = (variant == base);

        GACharacterGroup *ligatureGroup = [[GACharacterGroup alloc] init];
        ligatureGroup.text = [text substringWithRange:range];
        ligatureGroup.textRange = range;
        ligatureGroup.variants = unique;
        ligatureGroup.insertedLigature = YES;

        NSNumber *end = @(NSMaxRange(range));
        NSMutableArray<GACharacterGroup *> *atEnd = ligaturesAtEnd[end];
        if (!atEnd) {
            atEnd = [NSMutableArray array];
            ligaturesAtEnd[end] = atEnd;
            [endOrder addObject:end];
        }
        [atEnd addObject:ligatureGroup];
    }

    // The last source group with a matching end anchors the whole bucket.
    // Unanchored combinations keep their first-appearance order at the end.
    NSMutableDictionary<NSNumber *, NSNumber *> *anchors = [NSMutableDictionary dictionary];
    [sourceGroups enumerateObjectsUsingBlock:^(GACharacterGroup *group, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSNumber *end = @(NSMaxRange(group.textRange));
        if (ligaturesAtEnd[end]) anchors[end] = @(index);
    }];
    NSMutableArray<GACharacterGroup *> *display =
        [NSMutableArray arrayWithCapacity:sourceGroups.count + rangeOrder.count];
    for (NSUInteger index = 0; index < sourceGroups.count; ++index) {
        if (cancelled && cancelled()) return nil;
        GACharacterGroup *group = sourceGroups[index];
        [display addObject:group];
        NSNumber *end = @(NSMaxRange(group.textRange));
        NSNumber *anchor = anchors[end];
        if (anchor && anchor.unsignedIntegerValue == index)
            [display addObjectsFromArray:ligaturesAtEnd[end]];
    }
    for (NSNumber *end in endOrder) {
        if (cancelled && cancelled()) return nil;
        if (!anchors[end]) [display addObjectsFromArray:ligaturesAtEnd[end]];
    }

    return display;
}

#pragma mark - Preview projection

@interface GAScanDisplaySnapshot ()
@property(nonatomic, strong) NSMapTable<GACharacterGroup *, NSNumber *> *sourceLocations;
@end

@implementation GAScanDisplaySnapshot

- (NSRange)sourceRangeForMultiGroup:(GACharacterGroup *)group {
    NSRange range = group.textRange;
    NSNumber *location = [self.sourceLocations objectForKey:group];
    if (location) range.location = location.unsignedIntegerValue;
    return range;
}

@end

/// A control attached to supported text can shape it without its own glyph.
static BOOL GAGroupIsDefaultIgnorable(GACharacterGroup *group) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
            @"\\A\\p{Default_Ignorable_Code_Point}+\\z" options:0 error:NULL];
    });
    return [pattern firstMatchInString:group.text options:0 range:NSMakeRange(0, group.text.length)] != nil;
}

/// The sidebar keeps the original text. The preview replaces internal missing
/// spans with layout boundaries so neighboring glyphs cannot shape together.
GAScanDisplaySnapshot *GABuildScanDisplaySnapshot(NSString *text,
    NSArray<GACharacterGroup *> *groups, BOOL (^cancelled)(void)) {
    NSMutableString *multiText = [NSMutableString string];
    NSMutableIndexSet *omissions = [NSMutableIndexSet indexSet];
    NSMutableArray<GACharacterGroup *> *multiGroups = [NSMutableArray array];
    NSMapTable<GACharacterGroup *, NSNumber *> *sourceLocations =
        [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger previousSourceLocation = NSNotFound;
    NSUInteger cursor = 0;
    BOOL previousMissing = NO;
    BOOL pendingOmission = NO;
    NSUInteger inspectedCluster = NSNotFound;
    BOOL clusterHasSupportedText = NO;
    for (NSUInteger index = 0; index < groups.count; index++) {
        if (cancelled && cancelled())
            return nil;
        GACharacterGroup *group = groups[index];
        if (group.insertedLigature) continue;
        NSRange range = group.textRange;
        if (range.location == NSNotFound || range.length == 0 ||
            NSMaxRange(range) > text.length || range.location < cursor) {
            continue;
        }

        GACharacterGroup *previousDisplay = multiGroups.lastObject;
        NSRange previousSourceRange = previousDisplay
            ? NSMakeRange(previousSourceLocation, previousDisplay.textRange.length)
            : NSMakeRange(NSNotFound, 0);
        NSRange cluster = [text rangeOfComposedCharacterSequenceAtIndex:range.location];
        BOOL canMerge = !group.seeded && previousDisplay && !previousDisplay.seeded &&
            NSMaxRange(previousSourceRange) == range.location &&
            previousSourceLocation >= cluster.location;
        GAGlyphVariant *base = group.variants.firstObject;
        BOOL missing = !group.seeded && [base.glyphIDs containsObject:@0];
        BOOL layoutControl = !group.seeded && (missing || previousMissing);
        for (NSUInteger i = range.location; layoutControl && i < NSMaxRange(range); ++i)
            layoutControl = GAIsTextLayoutControl([text characterAtIndex:i]);
        if (layoutControl) missing = NO;
        if (!group.seeded && !layoutControl && !NSEqualRanges(range, cluster) &&
            (missing || (previousMissing && range.location == cursor)) &&
            GAGroupIsDefaultIgnorable(group)) {
            // Keep a control with a surviving component anywhere in its original cluster.
            if (inspectedCluster != cluster.location) {
                inspectedCluster = cluster.location;
                clusterHasSupportedText = previousDisplay &&
                    NSIntersectionRange(previousSourceRange, cluster).length;
                for (NSUInteger next = index + 1; !clusterHasSupportedText && next < groups.count; next++) {
                    GACharacterGroup *candidate = groups[next];
                    if (candidate.insertedLigature) continue;
                    if (!NSLocationInRange(candidate.textRange.location, cluster)) break;
                    NSArray<NSNumber *> *glyphs = candidate.variants.firstObject.glyphIDs;
                    clusterHasSupportedText = candidate.seeded ||
                        (glyphs.count && ![glyphs containsObject:@0] && !GAGroupIsDefaultIgnorable(candidate));
                }
            }
            missing = !clusterHasSupportedText;
        }

        if (range.location > cursor) {
            [multiText appendString:
                [text substringWithRange:NSMakeRange(cursor, range.location - cursor)]];
            pendingOmission = NO;
        }
        cursor = NSMaxRange(range);
        previousMissing = missing;
        if (missing) {
            pendingOmission = YES;
            continue;
        }

        BOOL sameCluster = previousDisplay &&
            NSIntersectionRange(previousSourceRange, cluster).length;
        if (pendingOmission && multiText.length && !sameCluster) {
            unichar left = [multiText characterAtIndex:multiText.length - 1];
            unichar right = [text characterAtIndex:range.location];
            NSCharacterSet *newlines = NSCharacterSet.newlineCharacterSet;
            if (![newlines characterIsMember:left] && ![newlines characterIsMember:right]) {
                [omissions addIndex:multiText.length];
                [multiText appendString:@"\uFFFC"];
            }
        }
        pendingOmission = NO;
        NSString *groupText = [text substringWithRange:range];
        if (canMerge) {
            previousDisplay.textRange = NSMakeRange(previousDisplay.textRange.location,
                previousDisplay.textRange.length + range.length);
            previousDisplay.text = [previousDisplay.text stringByAppendingString:groupText];
            GAGlyphVariant *mergedBase = previousDisplay.variants.firstObject;
            mergedBase.glyphIDs = [mergedBase.glyphIDs arrayByAddingObjectsFromArray:base.glyphIDs];
        } else {
            GAGlyphVariant *layoutBase = [[GAGlyphVariant alloc] init];
            layoutBase.fontBox = base.fontBox;
            layoutBase.glyphIDs = base.glyphIDs;

            GACharacterGroup *display = [[GACharacterGroup alloc] init];
            display.text = groupText;
            display.textRange = NSMakeRange(multiText.length, range.length);
            display.variants = @[layoutBase];
            display.seeded = group.seeded;
            // Merging only extends the group; the original start stays fixed.
            previousSourceLocation = range.location;
            if (range.location != display.textRange.location)
                [sourceLocations setObject:@(range.location) forKey:display];
            [multiGroups addObject:display];
        }
        [multiText appendString:groupText];
    }
    if (cursor < text.length) {
        [multiText appendString:
            [text substringWithRange:NSMakeRange(cursor, text.length - cursor)]];
    }
    GAScanDisplaySnapshot *snapshot = [[GAScanDisplaySnapshot alloc] init];
    snapshot.display = groups;
    snapshot.text = text;
    snapshot.multiText = [multiText copy];
    snapshot.multiOmissions = omissions;
    snapshot.multiGroups = multiGroups;
    snapshot.sourceLocations = sourceLocations;
    return snapshot;
}
