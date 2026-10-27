#import "GATextQueryModel.h"
#import "GAFontEngine.h"

#pragma mark - Query state

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
        _text = @"";
        _groups = @[];
    }
    return self;
}
- (void)projectResult {
    NSArray *groups = GAGroupsForText(_text);
    [_document applyRawResult:_result groups:groups];
    _groups = groups;
}
- (BOOL)analyzeText:(NSString *)text
         selections:(NSArray<GAGlyphSelectionRun *> *)selections
          cancelled:(BOOL (^)(void))cancelled {
    if (cancelled && cancelled())
        return NO;
    GAGlyphQueryIdentity *identity = GAGlyphQueryKey(text, selections);
    if ([_identity isEqual:identity])
        return YES;
    GARawScanResult *result = [_document rawScanContent:text selections:selections];
    if (cancelled && cancelled())
        return NO;
    _text = [text copy];
    _identity = identity;
    _result = result;
    [self projectResult];
    return YES;
}
- (void)updateFontDocument:(GAFontDocument *)document {
    _document = document;
    if (_result) {
        _result = [document rebindResult:_result content:_text];
        [self projectResult];
    }
}
@end

#pragma mark - Display groups

static GACharacterGroup *DisplayCopy(GACharacterGroup *group) {
    GACharacterGroup *copy = [[GACharacterGroup alloc] init];
    copy.text = group.text;
    copy.textRange = group.textRange;
    NSMutableArray<GAGlyphVariant *> *variants = [NSMutableArray array];
    for (GAGlyphVariant *variant in group.variants) {
        if (!variant.isLigature)
            [variants addObject:variant];
    }
    copy.variants = variants;
    return copy;
}

static BOOL IntersectsSelection(NSRange range, NSArray<GAGlyphSelectionRun *> *runs) {
    if (range.location == NSNotFound || range.length == 0) {
        return NO;
    }
    for (GAGlyphSelectionRun *run in runs) {
        if (NSIntersectionRange(range, run.range).length > 0) {
            return YES;
        }
    }
    return NO;
}

static GACharacterGroup *SelectionGroup(GAGlyphSelectionRun *run, GAFontDocument *document) {
    GAGlyphSelection *selection = run.selection;
    GACharacterGroup *storedGroup = [document analyzeGlyphIDs:selection.glyphIDs].firstObject;
    GAGlyphVariant *base = storedGroup.variants.firstObject;
    if (base == nil) {
        return nil;
    }

    [base addFeatureSources:selection.featureSources];
    for (GAGlyphVariant *variant in storedGroup.variants) {
        variant.base = (variant == base);
    }
    if (selection.ligature) {
        base.ligature = YES;
        base.sourceTextRange = run.range;
    }

    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = selection.sourceText;
    group.textRange = run.range;
    group.variants = storedGroup.variants;
    group.seeded = YES;
    return group;
}

NSArray<GACharacterGroup *> *GABuildDisplayGroups(NSArray<GACharacterGroup *> *groups,
                                                  NSString *text,
                                                  NSArray<GAGlyphSelectionRun *> *selections,
                                                  GAFontDocument *document) {
    NSMutableArray<GAGlyphSelectionRun *> *validSelections = [NSMutableArray array];
    NSMutableArray<GACharacterGroup *> *selectionGroups = [NSMutableArray array];
    for (GAGlyphSelectionRun *run in selections) {
        GACharacterGroup *selectionGroup = SelectionGroup(run, document);
        if (selectionGroup != nil) {
            NSMutableArray *variants = [selectionGroup.variants mutableCopy];
            for (GACharacterGroup *source in groups)
                for (GAGlyphVariant *candidate in source.variants) {
                    if (!candidate.fromGlyphSeed || candidate.isLigature ||
                        !NSEqualRanges(candidate.sourceTextRange, run.range))
                        continue;
                    GAGlyphVariant *existing = nil;
                    for (GAGlyphVariant *v in variants)
                        if ([v.glyphIDs isEqual:candidate.glyphIDs]) {
                            existing = v;
                            break;
                        }
                    if (existing) {
                        [existing addFeatureSources:candidate.featureSources];
                        continue;
                    }
                    GAGlyphVariant *copy = [document rebindVariant:candidate
                                                           content:selectionGroup.text];
                    copy.base = NO;
                    [variants addObject:copy];
                }
            selectionGroup.variants = variants;
            [validSelections addObject:run];
            [selectionGroups addObject:selectionGroup];
        }
    }

    NSMutableArray<GAGlyphVariant *> *ligatureVariants = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            if (variant.isLigature && variant.sourceTextRange.length > 0 &&
                variant.sourceTextRange.location <= text.length &&
                variant.sourceTextRange.length <= text.length - variant.sourceTextRange.location) {
                BOOL sameAsInput = NO;
                for (GAGlyphSelectionRun *run in validSelections)
                    if (NSEqualRanges(run.range, variant.sourceTextRange) &&
                        [run.selection.glyphIDs isEqual:variant.glyphIDs]) {
                        sameAsInput = YES;
                        break;
                    }
                if (sameAsInput)
                    continue;
                [ligatureVariants
                    addObject:[document
                                  rebindVariant:variant
                                        content:[text substringWithRange:variant.sourceTextRange]]];
            }
        }
    }

    NSMutableArray<GACharacterGroup *> *sourceGroups = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        if (([group.text isEqualToString:@"\n"]) ||
            IntersectsSelection(group.textRange, validSelections)) {
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
        NSRange range = variant.sourceTextRange;
        NSValue *rangeValue = [NSValue valueWithRange:range];
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        if (variants == nil) {
            variants = [NSMutableArray array];
            byRange[rangeValue] = variants;
            NSUInteger spanLength = 0;
            for (GACharacterGroup *group in groups) {
                if (group.textRange.location != NSNotFound &&
                    NSIntersectionRange(group.textRange, range).length > 0) {
                    spanLength++;
                }
            }
            spanLengths[rangeValue] = @(spanLength);
        }
        [variants addObject:variant];
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
    NSMutableArray<GACharacterGroup *> *display = [sourceGroups mutableCopy];
    for (NSValue *rangeValue in rangeOrder) {
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

        // A combination belongs after its last source character. Insert after
        // the last display item ending at this range's end so earlier results
        // with the same anchor stay ahead of later ones.
        NSUInteger insertIndex = display.count;
        NSUInteger rangeEnd = NSMaxRange(range);
        for (NSInteger index = (NSInteger)display.count - 1; index >= 0; index--) {
            GACharacterGroup *item = display[(NSUInteger)index];
            if (NSMaxRange(item.textRange) == rangeEnd) {
                insertIndex = (NSUInteger)index + 1;
                break;
            }
        }
        [display insertObject:ligatureGroup atIndex:insertIndex];
    }

    return display;
}
