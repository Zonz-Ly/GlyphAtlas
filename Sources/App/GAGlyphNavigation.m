#import "GAGlyphNavigation.h"

@implementation GAGlyphNavigationStep

- (id)copyWithZone:(NSZone *)zone {
    GAGlyphNavigationStep *step = [[[self class] allocWithZone:zone] init];
    step.mode = self.mode;
    step.locationSource = self.locationSource;
    step.glyphIDs = self.glyphIDs;
    step.range = self.range;
    step.sourceText = self.sourceText;
    step.glyphLabel = self.glyphLabel;
    step.sourceRecoveryRanges = [self.sourceRecoveryRanges mutableCopy];
    return step;
}

- (BOOL)matchesLocation:(GAGlyphNavigationStep *)other {
    if (!other || self.mode != other.mode) return NO;
    if (!self.glyphIDs && !other.glyphIDs) return YES;
    return [self.glyphIDs isEqualToArray:other.glyphIDs] &&
        NSEqualRanges(self.range, other.range) &&
        (self.sourceText == other.sourceText || [self.sourceText isEqualToString:other.sourceText]);
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

@implementation GAGlyphNavigationHistory

- (instancetype)init {
    self = [super init];
    if (self) {
        _backSteps = [NSMutableArray array];
        _forwardSteps = [NSMutableArray array];
    }
    return self;
}

- (GAGlyphNavigationStep *)adjacentForwardStep {
    return self.forwardSteps.count == 1 ? self.forwardSteps.lastObject : nil;
}

- (void)recordStep:(GAGlyphNavigationStep *)step {
    GAGlyphNavigationStep *forward = self.adjacentForwardStep;
    if (forward) {
        if (self.restoredStep) [self.backSteps addObject:self.restoredStep];
        [self.backSteps addObject:forward];
    }
    _restoredStep = nil;
    [self.forwardSteps removeAllObjects];
    GAGlyphNavigationStep *last = self.backSteps.lastObject;
    if (![step matchesLocation:last])
        [self.backSteps addObject:step];
    else if (step.locationSource == GANavigationLocationExplicit)
        last.locationSource = GANavigationLocationExplicit;
}

- (BOOL)moveToStep:(GAGlyphNavigationStep *)step leavingStep:(GAGlyphNavigationStep *)current {
    NSUInteger index = [self.forwardSteps indexOfObjectIdenticalTo:step];
    BOOL forward = index != NSNotFound;
    NSMutableArray *source = forward ? self.forwardSteps : self.backSteps;
    if (!forward) index = [source indexOfObjectIdenticalTo:step];
    if (index == NSNotFound) return NO;

    NSMutableArray *destination = forward ? self.backSteps : self.forwardSteps;
    // View-only navigation can retain a different selection in the sidebar.
    [destination addObject:self.restoredStep ?: current];
    for (NSUInteger i = source.count; i > index + 1; i--)
        [destination addObject:source[i - 1]];
    [source removeObjectsInRange:NSMakeRange(index, source.count - index)];
    _restoredStep = step;
    return YES;
}

- (void)clear {
    [self.backSteps removeAllObjects];
    [self.forwardSteps removeAllObjects];
    _restoredStep = nil;
}

@end
