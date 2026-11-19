#import "GAGlyphNavigation.h"

@implementation GAGlyphNavigationStep

- (id)copyWithZone:(NSZone *)zone {
    GAGlyphNavigationStep *step = [[[self class] allocWithZone:zone] init];
    step.mode = self.mode;
    step.filterTag = self.filterTag;
    step.filterChange = self.filterChange;
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
    if (self.mode == GAViewModeAllGlyphs && self.filterTag != other.filterTag &&
        ![self.filterTag isEqualToString:other.filterTag]) return NO;
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

- (void)recordStep:(GAGlyphNavigationStep *)step {
    if (_forwardSteps.count == 1) {
        if (self.restoredStep) [_backSteps addObject:self.restoredStep];
        [_backSteps addObject:_forwardSteps.lastObject];
    }
    _restoredStep = nil;
    [_forwardSteps removeAllObjects];
    GAGlyphNavigationStep *last = self.backSteps.lastObject;
    if (![step matchesLocation:last])
        [_backSteps addObject:step];
    else {
        if (step.locationSource == GANavigationLocationExplicit)
            last.locationSource = GANavigationLocationExplicit;
        if (step.filterChange) last.filterChange = YES;
    }
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
