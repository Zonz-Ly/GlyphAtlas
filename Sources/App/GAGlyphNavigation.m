#import "GAGlyphNavigation.h"
#import "Font/GAFontEngine.h"

@implementation GAGlyphNavigationStep

- (id)copyWithZone:(NSZone *)zone {
    GAGlyphNavigationStep *step = [[[self class] allocWithZone:zone] init];
    step.mode = self.mode;
    step.filterTag = self.filterTag;
    step.filterChange = self.filterChange;
    step.glyphIDs = self.glyphIDs;
    step.glyphIdentity = self.glyphIdentity;
    step.range = self.range;
    step.sourceText = self.sourceText;
    step.glyphLabel = self.glyphLabel;
    step.sourceRecoveryRanges = [self.sourceRecoveryRanges mutableCopy];
    return step;
}

- (BOOL)matchesViewAndGlyphs:(GAGlyphNavigationStep *)other {
    if (!other || self.mode != other.mode) return NO;
    if (self.mode == GAViewModeAllGlyphs && self.filterTag != other.filterTag &&
        ![self.filterTag isEqualToString:other.filterTag]) return NO;
    if (self.glyphIdentity && other.glyphIdentity) return [self.glyphIdentity isEqual:other.glyphIdentity];
    GAGlyphIdentity *known=self.glyphIdentity ?: other.glyphIdentity;
    if (known.markComponents.count || known.markLigatures.count || known.ligatureStructures.count) return NO;
    return self.glyphIDs == other.glyphIDs || [self.glyphIDs isEqualToArray:other.glyphIDs];
}

- (BOOL)matchesLocation:(GAGlyphNavigationStep *)other {
    return [self matchesViewAndGlyphs:other] && (!self.glyphIDs || (
        NSEqualRanges(self.range, other.range) &&
        (self.sourceText == other.sourceText || [self.sourceText isEqualToString:other.sourceText])));
}

- (BOOL)matchesSourceInText:(NSString *)text {
    return [self matchesSourceAtRange:self.range inText:text];
}

- (BOOL)matchesSourceAtRange:(NSRange)range inText:(NSString *)text {
    return text && range.location != NSNotFound && range.length &&
        NSMaxRange(range) <= text.length &&
        [[text substringWithRange:range] isEqualToString:self.sourceText];
}

- (BOOL)allowsViewOnly {
    return self.mode == GAViewModeAllGlyphs || !self.glyphIDs;
}

- (void)rememberSourceRange:(NSRange)range inText:(NSString *)text {
    if (!self.sourceRecoveryRanges) self.sourceRecoveryRanges = [NSMutableDictionary dictionary];
    NSValue *previous = self.sourceRecoveryRanges[text];
    if (previous && !NSEqualRanges(previous.rangeValue, range))
        range = NSMakeRange(NSNotFound, 0);
    self.sourceRecoveryRanges[text] = [NSValue valueWithRange:range];
}

@end

static BOOL GAPairedGlyphViews(GAGlyphNavigationStep *first, GAGlyphNavigationStep *second) {
    return first && second && first.mode != second.mode && first.glyphIDs.count &&
        [first.glyphIDs isEqualToArray:second.glyphIDs] &&
        (!first.glyphIdentity || !second.glyphIdentity || [first.glyphIdentity isEqual:second.glyphIdentity]);
}

@implementation GAGlyphNavigationHistory {
    NSMutableArray<GAGlyphNavigationStep *> *_backSteps;
    NSMutableArray<GAGlyphNavigationStep *> *_forwardSteps;
}
@synthesize backSteps = _backSteps;
@synthesize forwardSteps = _forwardSteps;

- (instancetype)init {
    self = [super init];
    if (self) {
        _backSteps = [NSMutableArray array];
        _forwardSteps = [NSMutableArray array];
    }
    return self;
}

- (GAGlyphNavigationStep *)pairedForwardSingle {
    GAGlyphNavigationStep *visit = self.forwardSteps.lastObject;
    return visit.mode == GAViewModeSingleGlyph && GAPairedGlyphViews(self.restoredStep, visit) ? visit : nil;
}

- (GAGlyphNavigationStep *)restoredOrigin {
    GAGlyphNavigationStep *origin = [self.restoredStep copy];
    // A paired filter already belongs to the completed visit; the returned grid is ordinary.
    if ([self pairedForwardSingle]) origin.filterChange = NO;
    return origin;
}

- (void)recordStep:(GAGlyphNavigationStep *)step {
    BOOL replaceOrigin = self.restoredStep && step.glyphIDs.count && [step matchesLocation:self.restoredStep] &&
        [self canReplaceGridOrigin:step];
    GAGlyphNavigationStep *visit = [self pairedForwardSingle];
    if (visit) {
        [self appendStep:self.restoredStep];
        [self appendStep:visit];
    }
    _restoredStep = nil;
    [_forwardSteps removeAllObjects];
    if (!replaceOrigin) [self appendStep:step];
}

- (void)appendStep:(GAGlyphNavigationStep *)step {
    if (!step) return;
    GAGlyphNavigationStep *last = self.backSteps.lastObject;
    if (step.mode == GAViewModeAllGlyphs && [step matchesViewAndGlyphs:last] &&
        (step.range.location == NSNotFound || last.range.location == NSNotFound)) {
        // A lost input source still points to the same grid glyph. Prefer a live source.
        GAGlyphNavigationStep *merged = step.range.location == NSNotFound ? last : step;
        merged.filterChange = step.filterChange || last.filterChange;
        _backSteps[_backSteps.count - 1] = merged;
    } else if (![step matchesLocation:last])
        [_backSteps addObject:step];
    else if (step.filterChange)
        last.filterChange = YES;
}

- (void)finishAtStep:(GAGlyphNavigationStep *)step {
    if (!self.restoredStep && [step matchesLocation:self.backSteps.lastObject])
        [_backSteps removeLastObject];
}

- (BOOL)canReplaceGridOrigin:(GAGlyphNavigationStep *)origin {
    if (origin.mode != GAViewModeAllGlyphs || origin.filterChange) return NO;
    if (!origin.glyphIDs.count) return YES;
    for (NSArray<GAGlyphNavigationStep *> *steps in @[self.forwardSteps, self.backSteps]) {
        GAGlyphNavigationStep *neighbor = steps.lastObject;
        if (GAPairedGlyphViews(origin, neighbor)) return YES;
    }
    return NO;
}

- (BOOL)moveToStep:(GAGlyphNavigationStep *)step leavingStep:(GAGlyphNavigationStep *)current {
    NSUInteger index = [self.forwardSteps indexOfObjectIdenticalTo:step];
    BOOL forward = index != NSNotFound;
    NSMutableArray *source = forward ? _forwardSteps : _backSteps;
    if (!forward) index = [source indexOfObjectIdenticalTo:step];
    if (index == NSNotFound) return NO;

    NSMutableArray *destination = forward ? _backSteps : _forwardSteps;
    // View-only navigation can retain a different selection in the sidebar.
    [destination addObject:self.restoredStep ?: current];
    for (NSUInteger i = source.count; i > index + 1; i--)
        [destination addObject:source[i - 1]];
    [source removeObjectsInRange:NSMakeRange(index, source.count - index)];
    _restoredStep = step;
    return YES;
}

- (void)clear {
    [_backSteps removeAllObjects];
    [_forwardSteps removeAllObjects];
    _restoredStep = nil;
}

@end
