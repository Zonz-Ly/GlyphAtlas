#import "GAMultiGlyphView.h"
#import "GABoundingBoxView.h"
#import "Font/GAUnicode.h"
#import "Font/GAFontFeatures.h"
#import <CoreText/CoreText.h>
#import <CoreText/SFNTLayoutTypes.h>
#import <math.h>

static const CGFloat GAMultiBaseFontSize = 51.0;

typedef struct {
    CGFloat ascent;
    CGFloat descent;
    CGFloat verticalAscent;
} GAFirstBaselineMetrics;

static GAFirstBaselineMetrics GAReadFirstBaselineMetrics(CTFontRef font, BOOL vertical) {
    GAFirstBaselineMetrics metrics = {CTFontGetAscent(font), 0, 0};
    if (vertical) {
        // Vertical layout can use explicit vertical metrics or derive its
        // centerline from horizontal ascent and descent when those are absent.
        metrics.descent = CTFontGetDescent(font);
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(
            (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCTFontOrientationAttribute: @(kCTFontOrientationVertical),
            });
        CTFontRef verticalFont = CTFontCreateCopyWithAttributes(font, 0, NULL, descriptor);
        metrics.verticalAscent = CTFontGetAscent(verticalFont);
        CFRelease(verticalFont);
        CFRelease(descriptor);
    }
    return metrics;
}

typedef NS_ENUM(NSUInteger, GAMagnificationControl) {
    GAMagnificationText,
    GAMagnificationBoundingBox,
    GAMagnificationLineHeight,
};
/// Twenty zoom-outs and twenty zoom-ins: `1 / 1.12^20` to `1.12^20`.
static CGFloat GAMultiClampTextScale(CGFloat scale) {
    CGFloat maximum = GAGlyphZoomStep10 * GAGlyphZoomStep10;
    return MIN(maximum, MAX(1.0 / maximum, scale));
}

#pragma mark - Display-only text view

/// The text view exists to lay out and draw the text. Clicks and drags belong
/// to the page view so the whole view stays draggable and click-to-select
/// keeps working.
@interface GAMultiTextView : NSTextView
@property(nonatomic) CGFloat firstBaselineOffset;
@end

@implementation GAMultiTextView

- (NSPoint)textContainerOrigin {
    NSPoint origin = super.textContainerOrigin;
    // The container's y axis follows the line progression in either writing orientation.
    origin.y -= self.firstBaselineOffset;
    return origin;
}

- (void)setFirstBaselineOffset:(CGFloat)offset {
    if (_firstBaselineOffset == offset) return;
    _firstBaselineOffset = offset;
    [self invalidateTextContainerOrigin];
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor arrowCursor]];
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)isOpaque {
    return NO;
}

@end

#pragma mark - Color

static NSColor *GAResolvedColor(NSColor *color, NSAppearance *appearance) {
    __block NSColor *resolved = color;
    [(appearance ?: NSApp.effectiveAppearance) performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    }];
    return resolved;
}

#pragma mark - Display declarations

NS_ASSUME_NONNULL_BEGIN

/// Native TextKit GIDs for one source span, distinct from sidebar candidates.
@interface GAGlyphLayoutRun : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@property(nonatomic) NSRange leadingRange;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *leadingGlyphIDs;
@end

@interface NSTextLayoutManager (GAGlyphReadback)
@property(nonatomic) BOOL requiresCTLineRef;
@end

NS_ASSUME_NONNULL_END

@implementation GAGlyphLayoutRun
@end

@interface NSTextLineFragment (GAGlyphReadback)
@property(nonatomic, readonly, nullable) CTLineRef lineRef;
@end

static GAMultiTextView *GACreateMultiTextView(void) {
    GAMultiTextView *textView =
        [[GAMultiTextView alloc] initUsingTextLayoutManager:YES];
    textView.hidden = YES;
    textView.editable = NO;
    textView.selectable = NO;
    textView.drawsBackground = NO;
    textView.textContainer.lineFragmentPadding = 0;
    textView.textContainer.widthTracksTextView = NO;
    textView.verticallyResizable = NO;
    textView.menu = nil;
    textView.textLayoutManager.requiresCTLineRef = YES;
    return textView;
}

static NSTextLineFragment *GAFirstLineBaseline(NSTextLayoutManager *layout, CGFloat *baseline) {
    NSTextLayoutFragment *fragment =
        [layout textLayoutFragmentForLocation:layout.documentRange.location];
    NSTextLineFragment *line = fragment.textLineFragments.firstObject;
    if (line) {
        *baseline = NSMinY(fragment.layoutFragmentFrame) +
                    NSMinY(line.typographicBounds) + line.glyphOrigin.y;
    }
    return line;
}

#pragma mark - Display copy

/// Only these group fields affect the native display copy and source mapping.
/// Copy their values so in-place changes cannot make an old snapshot appear equal.
static NSArray *GAMultiGroupIdentity(NSArray<GACharacterGroup *> *groups) {
    NSMutableArray *identity = [NSMutableArray arrayWithCapacity:groups.count];
    for (GACharacterGroup *group in groups) {
        [identity addObject:@[
            [NSValue valueWithRange:group.textRange], group.text.copy ?: @"",
            @(group.seeded), @(group.insertedLigature),
            group.variants.firstObject.glyphIDs.copy ?: @[],
        ]];
    }
    return identity;
}

/// Builds fixed-GID display text without changing the user's source text.
static NSAttributedString *GACreateGlyphDisplayString(
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

/// Replaces a display range and updates its UTF-16 source map.
static void GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
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
        GAGlyphLayoutRun *hit = result[lo - 1];
        if (!hit.leadingGlyphIDs || atom.leadingRange.location < hit.leadingRange.location) {
            hit.leadingRange = atom.leadingRange;
            hit.leadingGlyphIDs = atom.glyphIDs;
        } else if (NSEqualRanges(hit.leadingRange, atom.leadingRange)) {
            hit.leadingGlyphIDs = [hit.leadingGlyphIDs arrayByAddingObjectsFromArray:atom.glyphIDs];
        }
    }
    for (NSUInteger i = 0; i < result.count; i++)
        result[i].glyphIDs = glyphs[i];
    return result;
}
static NSArray<GAGlyphLayoutRun *> *MapGlyphLayoutRuns(
    NSArray<GAGlyphLayoutRun *> *hits, NSArray<NSNumber *> *sourceIndices,
    NSArray<NSValue *> *atomicRanges, NSString *sourceText) {
    // Ordered, disjoint selections are already an interval index. Keep the
    // original pass for small lists and for overlapping or unordered sources,
    // whose one-pass expansion depends on their original order.
    BOOL indexed = atomicRanges.count >= 8;
    NSUInteger previousEnd = 0;
    if (indexed) for (NSValue *value in atomicRanges) {
        NSRange range = value.rangeValue;
        NSUInteger end = NSMaxRange(range);
        if (range.location == NSNotFound || range.location < previousEnd || end < range.location) {
            indexed = NO;
            break;
        }
        previousEnd = end;
    }
    NSMutableArray *atoms = [NSMutableArray array];
    for (GAGlyphLayoutRun *display in hits) {
        if (!display.range.length || NSMaxRange(display.range) > sourceIndices.count)
            continue;
        NSUInteger first = NSUIntegerMax, last = 0;
        for (NSUInteger i = display.range.location; i < NSMaxRange(display.range); i++) {
            NSUInteger source = sourceIndices[i].unsignedIntegerValue;
            if (source == NSNotFound) continue;
            first = MIN(first, source);
            last = MAX(last, source);
        }
        if (first == NSUIntegerMax || last >= sourceText.length)
            continue;
        NSRange component = NSMakeRange(first, last - first + 1);
        NSRange range = [sourceText rangeOfComposedCharacterSequencesForRange:component];
        NSUInteger start = 0, end = atomicRanges.count;
        if (indexed) {
            while (start < end) {
                NSUInteger mid = (start + end) / 2;
                if (NSMaxRange(atomicRanges[mid].rangeValue) <= range.location) start = mid + 1;
                else end = mid;
            }
            end = atomicRanges.count;
        }
        for (NSUInteger i = start; i < end; i++) {
            NSRange atomic = atomicRanges[i].rangeValue;
            if (indexed && atomic.location >= NSMaxRange(range)) break;
            if (NSIntersectionRange(range, atomic).length) range = NSUnionRange(range, atomic);
            if (NSIntersectionRange(component, atomic).length) component = NSUnionRange(component, atomic);
        }
        GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
        hit.range = range;
        hit.leadingRange = component;
        hit.glyphIDs = display.glyphIDs;
        [atoms addObject:hit];
    }
    return MergeHits(atoms);
}

/// Reads native GIDs, preserving composed characters and explicit selections.
static NSArray<GAGlyphLayoutRun *> *GAReadDisplayGlyphRuns(
    NSTextLayoutManager *layout, NSArray<NSNumber *> *sourceIndices,
    NSArray<NSValue *> *atomicRanges, NSString *sourceText, NSString *fontName,
    NSMutableIndexSet *foreignCharacters) {
    NSTextContentManager *content = layout.textContentManager;
    id<NSTextLocation> start = content.documentRange.location;
    NSMutableArray *result = [NSMutableArray array];
    [layout enumerateTextLayoutFragmentsFromLocation:nil
                                            options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *fragment) {
        NSInteger offset = [content offsetFromLocation:start
                                           toLocation:fragment.rangeInElement.location];
        if (offset < 0) return YES;
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
                CTFontRef runFont = (__bridge CTFontRef)((__bridge NSDictionary *)CTRunGetAttributes(run))
                    [(__bridge NSString *)kCTFontAttributeName];
                if (runFont) {
                    NSString *runName = CFBridgingRelease(CTFontCopyPostScriptName(runFont));
                    if (![runName isEqualToString:fontName]) {
                        if (offset >= 0 && range.location >= 0 && range.length > 0) {
                            NSRange foreignRange = NSIntersectionRange(
                                NSMakeRange(range.location, range.length), line.characterRange);
                            if (foreignRange.length && offset + NSMaxRange(foreignRange) <= sourceIndices.count) {
                                foreignRange.location += offset;
                                [foreignCharacters addIndexesInRange:foreignRange];
                            }
                        }
                        continue;
                    }
                }
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
                    if (!NSLocationInRange(index, line.characterRange) ||
                        index >= sourceIndices.count || (NSUInteger)offset >= sourceIndices.count - index)
                        continue;
                    [boundaries addIndex:index];
                    if (sourceIndices[(NSUInteger)offset + index].unsignedIntegerValue == NSNotFound)
                        continue;
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

#pragma mark - View

@interface GAMultiGlyphView ()
@property (nonatomic, strong) GAMultiTextView *textView;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<NSNumber *> *displaySourceIndices;
@property(nonatomic, copy) NSArray *displayGroupIdentity;
@property (nonatomic, copy, readonly) NSArray<GACharacterGroup *> *groups;
@property (nonatomic, copy) NSIndexSet *omissions;
@property(nonatomic, copy) NSArray<GAGlyphLayoutRun *> *glyphHits;
@property (nonatomic) NSSize pageContentSize;
@property (nonatomic) CGFloat magnificationStartTextScale;
@property(nonatomic) CGFloat magnificationStartPage;
@property(nonatomic) CGFloat magnificationStartLineHeight;
@property(nonatomic) CGFloat naturalFirstBaseline;
@property(nonatomic) BOOL hasNaturalFirstBaseline;
@property(nonatomic) GAFirstBaselineMetrics naturalBaselineMetrics;
@property(nonatomic, strong) NSFont *displayFont;
@property(nonatomic, strong) NSFont *baselineMetricsFont;
@property(nonatomic, strong) NSColor *displayForegroundColor;
@property(nonatomic) BOOL layoutPending;
@property(nonatomic) BOOL pinchHasPair;
@property(nonatomic) GAMagnificationControl pinchCandidate;
@property(nonatomic) GAMagnificationControl magnificationControl;
/// The page in the view's own coordinates, including the current page inset.
- (NSRect)pageRect;
@end

@implementation GAMultiGlyphView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _previewColors = [GAPreviewColors new];
        _sideInsetFraction = GABoundingBoxDefaultSideInsetFraction;
        _showsMetrics = YES;
        _textScale = 1.0;
        _layoutActive = YES;
        _lineHeightMultiple = 1.0;
        _baseWritingDirection = NSWritingDirectionNatural;
        _typesettingLanguage = @"";
        self.allowedTouchTypes = NSTouchTypeMaskIndirect;
        self.wantsRestingTouches = YES;
        _featureSettings = @[];

        GAMultiTextView *textView = GACreateMultiTextView();
        self.textView = textView;
        [self addSubview:textView];

        NSMagnificationGestureRecognizer *magnification =
            [[NSMagnificationGestureRecognizer alloc] initWithTarget:self
                                                               action:@selector(handleMagnification:)];
        [self addGestureRecognizer:magnification];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

#pragma mark - State

- (void)setLayoutActive:(BOOL)active {
    if (_layoutActive == active) return;
    _layoutActive = active;
    if (active && self.layoutPending) [self rebuildLayout];
}

- (void)setDocument:(GAFontDocument *)document {
    // A window keeps its font; variation changes invalidate the baseline only
    // when the applied display font's native baseline metrics change.
    if (_document.fontBox != document.fontBox) self.displayFont = nil;
    _document = document;
    [self rebuildLayout];
}

- (void)setText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups
      omissions:(NSIndexSet *)omissions {
    NSArray *identity = GAMultiGroupIdentity(groups);
    BOOL unchanged = [_text isEqualToString:text] &&
        [self.omissions isEqualToIndexSet:omissions] &&
        [self.displayGroupIdentity isEqualToArray:identity];
    _text = [text copy];
    _groups = [groups copy] ?: @[];
    self.omissions = omissions;
    self.displayGroupIdentity = identity;
    if (!unchanged) [self rebuildLayout];
}

- (void)setSideInsetFraction:(CGFloat)sideInsetFraction {
    CGFloat clamped = GAClampSideInsetFraction(sideInsetFraction);
    if (fabs(clamped - _sideInsetFraction) < 1e-9) {
        return;
    }
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        self->_sideInsetFraction = clamped;
        [self rebuildLayout];
        if (self.onSideInsetFractionChanged) {
            self.onSideInsetFractionChanged(clamped);
        }
    });
}

- (void)setShowsMetrics:(BOOL)showsMetrics {
    _showsMetrics = showsMetrics;
    [self setNeedsDisplay:YES];
}

- (void)setUnderlined:(BOOL)enabled {
    if (_underlined == enabled) return;
    _underlined = enabled;
    [self rebuildLayout];
}

- (void)setStruckThrough:(BOOL)enabled {
    if (_struckThrough == enabled) return;
    _struckThrough = enabled;
    [self rebuildLayout];
}

- (void)setOutlined:(BOOL)enabled {
    if (_outlined == enabled) return;
    _outlined = enabled;
    [self rebuildLayout];
}

- (void)setBaseWritingDirection:(NSWritingDirection)direction {
    if (_baseWritingDirection == direction) return;
    _baseWritingDirection = direction;
    [self rebuildLayout];
}

- (void)setTypesettingLanguage:(NSString *)language {
    if ([_typesettingLanguage isEqualToString:language]) return;
    _typesettingLanguage = language.copy;
    [self rebuildLayout];
}

- (void)resetLayoutScale {
    CGFloat defaultInset = GABoundingBoxDefaultSideInsetFraction;
    BOOL insetChanged = fabs(_sideInsetFraction - defaultInset) >= 1e-9;
    if (!insetChanged && fabs(_textScale - 1.0) < 1e-9 && fabs(_lineHeightMultiple - 1.0) < 1e-9) return;
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        if (fabs(self->_textScale - 1.0) >= 1e-9) {
            self.hasNaturalFirstBaseline = NO;
            self.displayFont = nil;
        }
        self->_textScale = 1.0;
        self->_lineHeightMultiple = 1.0;
        self->_sideInsetFraction = defaultInset;
        [self rebuildLayout];
        if (insetChanged && self.onSideInsetFractionChanged)
            self.onSideInsetFractionChanged(defaultInset);
    });
}

- (void)setTextScale:(CGFloat)textScale {
    CGFloat clamped = GAMultiClampTextScale(textScale);
    if (fabs(clamped - _textScale) < 1e-9) return;
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        self->_textScale = clamped;
        self.displayFont = nil;
        self.hasNaturalFirstBaseline = NO;
        [self rebuildLayout];
    });
}

- (void)setTextAlignment:(NSTextAlignment)textAlignment {
    if (_textAlignment == textAlignment) {
        return;
    }
    _textAlignment = textAlignment;
    [self rebuildLayout];
}

- (void)setLineHeightMultiple:(CGFloat)multiple {
    CGFloat maximum = GAGlyphZoomStep10;
    multiple = MIN(maximum, MAX(1.0 / maximum, multiple));
    if (fabs(_lineHeightMultiple - multiple) < 1e-9) return;
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        self->_lineHeightMultiple = multiple;
        [self rebuildLayout];
    });
}

- (void)refreshPreviewColors {
    NSColor *color = GAResolvedColor([self.previewColors colorForRole:GAPreviewColorGlyph],
                                    self.effectiveAppearance);
    if (![self.displayForegroundColor isEqual:color]) {
        NSTextStorage *storage = self.textView.textStorage;
        [storage beginEditing];
        [storage enumerateAttribute:NSForegroundColorAttributeName
                            inRange:NSMakeRange(0, storage.length) options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
            (void)stop;
            if (value) [storage addAttribute:NSForegroundColorAttributeName value:color range:range];
        }];
        [storage endEditing];
        self.displayForegroundColor = color;
    }
    self.textView.needsDisplay = YES;
    self.needsDisplay = YES;
}

- (void)setFeatureSettings:(NSArray<NSDictionary *> *)settings {
    if ([_featureSettings isEqualToArray:settings]) return;
    _featureSettings = settings.copy;
    self.displayFont = nil;
    [self rebuildLayout];
}

- (void)setVertical:(BOOL)vertical {
    if (_vertical == vertical) {
        return;
    }
    _vertical = vertical;
    self.hasNaturalFirstBaseline = NO;
    [self rebuildLayout];
}

- (void)setViewportSize:(NSSize)viewportSize {
    if (NSEqualSizes(_viewportSize, viewportSize)) {
        return;
    }
    BOOL wrappingChanged = self.vertical
        ? _viewportSize.height != viewportSize.height
        : _viewportSize.width != viewportSize.width;
    _viewportSize = viewportSize;
    if (wrappingChanged || !self.layoutActive || self.layoutPending || self.textView.hidden ||
        viewportSize.width < 1 || viewportSize.height < 1) {
        [self rebuildLayout];
    } else {
        [self updateTextContainerInset];
        self.needsDisplay = YES;
        if (self.onContentSizeChanged) self.onContentSizeChanged();
        [self positionTextView];
    }
}

- (void)setToolbarTopInset:(CGFloat)toolbarTopInset {
    if (_toolbarTopInset == toolbarTopInset) return;
    _toolbarTopInset = toolbarTopInset;
    [self positionTextView];
    self.needsDisplay = YES;
}

- (void)zoomTextIn {
    self.textScale *= GAGlyphZoomStep;
}

- (void)zoomTextOut {
    self.textScale /= GAGlyphZoomStep;
}

- (void)readPinchTouches:(NSEvent *)event {
    NSArray<NSTouch *> *touches = [[event touchesMatchingPhase:NSTouchPhaseTouching inView:self] allObjects];
    self.pinchHasPair = touches.count == 2;
    if (!self.pinchHasPair) return;
    NSTouch *a = touches[0], *b = touches[1];
    self.pinchHasPair = [a.device isEqual:b.device];
    if (!self.pinchHasPair) return;
    CGFloat dx = fabs(a.normalizedPosition.x - b.normalizedPosition.x) * a.deviceSize.width;
    CGFloat dy = fabs(a.normalizedPosition.y - b.normalizedPosition.y) * a.deviceSize.height;
    self.pinchHasPair = dx > 0 || dy > 0;
    if (!self.pinchHasPair) return;
    CGFloat angle = atan2(dy, dx) * 180.0 / M_PI;
    self.pinchCandidate = angle <= 35 ? GAMagnificationBoundingBox
        : angle >= 75 ? GAMagnificationLineHeight : GAMagnificationText;
}

- (void)touchesBeganWithEvent:(NSEvent *)event { [self readPinchTouches:event]; }
- (void)touchesMovedWithEvent:(NSEvent *)event { [self readPinchTouches:event]; }
- (void)touchesEndedWithEvent:(NSEvent *)event { [self readPinchTouches:event]; }
- (void)touchesCancelledWithEvent:(NSEvent *)event {
    (void)event;
    self.pinchHasPair = NO;
}

- (void)handleMagnification:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.magnificationControl = self.pinchHasPair ? self.pinchCandidate : GAMagnificationText;
        self.magnificationStartTextScale = self.textScale;
        self.magnificationStartPage = 1.0 - 2.0 * self.sideInsetFraction;
        self.magnificationStartLineHeight = self.lineHeightMultiple;
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        switch (self.magnificationControl) {
            case GAMagnificationBoundingBox:
                self.sideInsetFraction = 0.5 * (1.0 - GABoundingBoxPageFractionForMagnification(
                    self.magnificationStartPage, recognizer.magnification));
                break;
            case GAMagnificationLineHeight:
                self.lineHeightMultiple = self.magnificationStartLineHeight * (1.0 + recognizer.magnification);
                break;
            case GAMagnificationText:
                self.textScale = self.magnificationStartTextScale * (1.0 + recognizer.magnification);
                break;
        }
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self refreshPreviewColors];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self positionTextView];
}

#pragma mark - Layout

- (void)updateTextContainerInset {
    // The horizontal frame includes the page inset; the rotated vertical
    // frame stays on the page so that its container origin remains aligned.
    NSPoint inset = [self pageArea].origin;
    self.textView.textContainerInset = self.vertical
        ? NSZeroSize : NSMakeSize(inset.x, inset.y);
}

- (CGFloat)horizontalAdvanceForGlyph:(CGGlyph)glyph font:(NSFont *)font {
    CGSize advance = CGSizeZero;
    CTFontGetAdvancesForGlyphs((__bridge CTFontRef)font,
                               kCTFontOrientationHorizontal,
                               &glyph, &advance, 1);
    return advance.width;
}

- (CGGlyph)glyphForCharacter:(unichar)character font:(NSFont *)font {
    CGGlyph glyph = 0;
    return CTFontGetGlyphsForCharacters((__bridge CTFontRef)font,
                                       &character, &glyph, 1) ? glyph : 0;
}

- (BOOL)glyphIsFullWidth:(CGGlyph)glyph font:(NSFont *)font {
    CGFloat advance = [self horizontalAdvanceForGlyph:glyph font:font];
    if (advance <= 0.01) {
        return NO;
    }
    if (fabs(advance - font.pointSize) < 0.01) {
        return YES;
    }
    CGGlyph ideographGlyph = [self glyphForCharacter:0x5B57 font:font];  // 字
    if (ideographGlyph != 0) {
        CGFloat ideographAdvance =
            [self horizontalAdvanceForGlyph:ideographGlyph font:font];
        if (fabs(advance - ideographAdvance) < 0.01) {
            return YES;
        }
    }
    return NO;
}

/// TextKit decides a seed's vertical orientation from its base character. If a
/// full-width GID replaces a rotated character, use 字 as the base so the glyph
/// turns upright; if a narrow GID replaces an upright character, use A as the
/// base so the glyph turns. The GID itself never changes.
- (nullable NSString *)replacementBaseForOriginal:(NSString *)original
                                            glyph:(CGGlyph)glyph
                                             font:(NSFont *)font {
    if (!self.vertical || original.length != 1) {
        return nil;
    }
    unichar character = [original characterAtIndex:0];
    BOOL rotated = GAVerticalScalarRotates((uint32_t)character);
    BOOL fullWidth = [self glyphIsFullWidth:glyph font:font];
    if (rotated && fullWidth && [self glyphForCharacter:0x5B57 font:font] != 0) {
        return @"字";
    }
    if (!rotated && !fullWidth && [self glyphForCharacter:0x41 font:font] != 0) {
        return @"A";
    }
    return nil;
}

// The caller excludes explicit seeds and inserted ligature groups.
- (nullable NSNumber *)verticalQuoteGlyphForGroup:(GACharacterGroup *)group
                                             font:(NSFont *)font {
    // A manually seeded quote must not override a native vertical-forms Off.
    for (NSDictionary *setting in self.featureSettings) {
        NSNumber *type = setting[(__bridge NSString *)kCTFontFeatureTypeIdentifierKey];
        NSNumber *selector = setting[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
        NSString *tag = setting[(__bridge NSString *)kCTFontOpenTypeFeatureTag];
        NSNumber *value = setting[(__bridge NSString *)kCTFontOpenTypeFeatureValue];
        if ((type && type.integerValue == kVerticalSubstitutionType && selector.integerValue == kSubstituteVerticalFormsOffSelector) ||
            (([tag isEqualToString:@"vert"] || [tag isEqualToString:@"vrt2"]) && value && !value.boolValue)) return nil;
    }
    if (!self.vertical || group.text.length != 1) {
        return nil;
    }
    unichar quote = [group.text characterAtIndex:0];
    BOOL opening = quote == 0x2018 || quote == 0x201C;
    BOOL closing = quote == 0x2019 || quote == 0x201D;
    if (!opening && !closing) {
        return nil;
    }
    GAGlyphVariant *variant = group.variants.firstObject;
    NSNumber *baseGlyph = variant.glyphIDs.firstObject;
    if (baseGlyph.unsignedShortValue == 0) {
        return nil;
    }
    NSNumber *vertical = [self.document
        verticalSubstituteForGlyph:(CGGlyph)baseGlyph.unsignedShortValue];
    if (vertical.unsignedShortValue == 0 ||
        vertical.unsignedShortValue == baseGlyph.unsignedShortValue) {
        return nil;
    }
    // Do not replace a glyph that is already the encoded vertical presentation
    // form for this quote: U+FE41/U+FE43 for ‘/“, U+FE42/U+FE44 for ’/”.
    unichar presentation = opening ? 0xFE41 : 0xFE42;
    unichar whitePresentation = opening ? 0xFE43 : 0xFE44;
    CGGlyph verticalGlyph = (CGGlyph)vertical.unsignedShortValue;
    if ([self glyphForCharacter:presentation font:font] == verticalGlyph ||
        [self glyphForCharacter:whitePresentation font:font] == verticalGlyph) {
        return nil;
    }
    return vertical;
}

- (BOOL)groupHasVisibleRange:(GACharacterGroup *)group inLength:(NSUInteger)length {
    if (group.insertedLigature) {
        return NO;
    }
    NSRange range = group.textRange;
    return range.location != NSNotFound && range.length > 0 &&
           NSMaxRange(range) <= length;
}

// A zero-size attachment separates shaping runs without drawing fallback ink.
static NSTextAttachment *GAOmittedGlyphAttachment(void) {
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    // AppKit uses the image size when the attachment bounds are zero.
    attachment.image = [[NSImage alloc] initWithSize:NSZeroSize];
    return attachment;
}

- (NSMutableAttributedString *)displayAttributedStringForFont:(NSFont *)font
                                                sourceIndices:(NSMutableArray<NSNumber *> *)sourceIndices {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = self.textAlignment;
    paragraph.baseWritingDirection = self.baseWritingDirection;
    paragraph.lineHeightMultiple = self.lineHeightMultiple;
    self.displayForegroundColor =
        GAResolvedColor([self.previewColors colorForRole:GAPreviewColorGlyph], self.effectiveAppearance);
    NSMutableDictionary<NSAttributedStringKey, id> *attributes = [@{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : self.displayForegroundColor,
        NSParagraphStyleAttributeName : paragraph,
    } mutableCopy];
    if (self.underlined) attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (self.struckThrough) attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (self.outlined) attributes[NSStrokeWidthAttributeName] = @3;
    if (self.typesettingLanguage.length)
        attributes[(__bridge NSString *)kCTLanguageAttributeName] = self.typesettingLanguage;

    NSMutableAttributedString *display =
        [[NSMutableAttributedString alloc] initWithString:self.text attributes:attributes];
    for (NSUInteger i = 0; i < self.text.length; i++)
        [sourceIndices addObject:@(i)];
    if (self.omissions.count) {
        NSTextAttachment *attachment = GAOmittedGlyphAttachment();
        [self.omissions enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
            if (index >= display.length) { *stop = YES; return; }
            [display addAttribute:NSAttachmentAttributeName value:attachment range:NSMakeRange(index, 1)];
            sourceIndices[index] = @(NSNotFound);
        }];
    }
    // Descending replacements leave earlier source ranges valid even when a
    // multiple substitution expands one source character into several glyphs.
    NSArray *ordered = [self.groups
        sortedArrayUsingComparator:^NSComparisonResult(GACharacterGroup *a, GACharacterGroup *b) {
          return a.textRange.location > b.textRange.location   ? NSOrderedAscending
                 : a.textRange.location < b.textRange.location ? NSOrderedDescending
                                                               : NSOrderedSame;
        }];
    for (GACharacterGroup *group in ordered) {
        if (![self groupHasVisibleRange:group inLength:self.text.length]) {
            continue;
        }
        GAGlyphVariant *variant = group.variants.firstObject;
        if (variant.glyphIDs.count == 0) {
            continue;
        }
        NSArray<NSNumber *> *glyphIDs = variant.glyphIDs;
        NSString *base = [self.text substringWithRange:group.textRange];
        if (group.seeded) {
            if (glyphIDs.count > 1)
                base = [base substringWithRange:[base rangeOfComposedCharacterSequenceAtIndex:0]];
        } else {
            NSNumber *vertical = [self verticalQuoteGlyphForGroup:group font:font];
            if (!vertical)
                continue;
            glyphIDs = @[vertical];
        }
        NSAttributedString *replacement = GACreateGlyphDisplayString(
            glyphIDs, base, font, attributes,
            ^NSString *(CGGlyph glyph) {
                return [self replacementBaseForOriginal:base glyph:glyph font:font];
            });
        if (replacement)
            GAReplaceSeedDisplayRange(display, sourceIndices, group.textRange, replacement);
    }
    return display;
}

/// Retry a foreign-font cluster with its base text before omitting foreign glyphs.
/// Keep controls in clusters the selected font has already laid out successfully.
static NSIndexSet *GAForeignCharactersToOmit(NSAttributedString *display, NSIndexSet *foreign,
                                             NSArray<NSNumber *> *sourceIndices, BOOL *retryControls) {
    NSMutableIndexSet *controls = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *characters = [NSMutableIndexSet indexSet];
    NSString *text = display.string;
    [foreign enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
            if (sourceIndices[i].unsignedIntegerValue == NSNotFound) continue;
            unichar c = [text characterAtIndex:i];
            NSGlyphInfo *glyphInfo = [display attribute:NSGlyphInfoAttributeName atIndex:i effectiveRange:NULL];
            if ((c == 0xFE0E || c == 0xFE0F || c == 0x200D) && !glyphInfo) {
                [controls addIndex:i];
            }
            if (!glyphInfo && GAIsTextLayoutControl(c)) continue;
            NSRange removal = NSMakeRange(i, 1);
            if (glyphInfo) {
                // The display copy maps every character of one fixed-GID replacement
                // to the same source index, including multi-glyph replacements.
                NSNumber *source = sourceIndices[i];
                NSUInteger start = i, end = i + 1;
                while (start && [sourceIndices[start - 1] isEqual:source]) start--;
                while (end < text.length && [sourceIndices[end] isEqual:source]) end++;
                removal = NSMakeRange(start, end - start);
                i = end - 1;
            } else if (CFStringIsSurrogateHighCharacter(c) && i + 1 < text.length &&
                       CFStringIsSurrogateLowCharacter([text characterAtIndex:i + 1])) {
                removal.length++;
            } else if (CFStringIsSurrogateLowCharacter(c) && i > 0 &&
                       CFStringIsSurrogateHighCharacter([text characterAtIndex:i - 1])) {
                removal = NSMakeRange(i - 1, 2);
            }
            [characters addIndexesInRange:removal];
        }
    }];
    *retryControls = controls.count != 0;
    return *retryControls ? controls : characters;
}

- (void)updateFirstBaselineOffsetForFont:(NSFont *)font {
    GAFirstBaselineMetrics metrics = self.naturalBaselineMetrics;
    if (!self.hasNaturalFirstBaseline || self.baselineMetricsFont != font)
        metrics = GAReadFirstBaselineMetrics((__bridge CTFontRef)font, self.vertical);
    GAFirstBaselineMetrics previous = self.naturalBaselineMetrics;
    if (metrics.ascent != previous.ascent || metrics.descent != previous.descent ||
        metrics.verticalAscent != previous.verticalAscent)
        self.hasNaturalFirstBaseline = NO;
    if (self.hasNaturalFirstBaseline && self.lineHeightMultiple == 1.0) {
        self.baselineMetricsFont = font;
        return;
    }
    CGFloat baseline = 0;
    NSTextLineFragment *line = GAFirstLineBaseline(self.textView.textLayoutManager, &baseline);
    if (!line) return;
    if (!self.hasNaturalFirstBaseline) {
        if (self.lineHeightMultiple == 1.0) {
            self.naturalFirstBaseline = baseline;
        } else {
            if (!line.characterRange.length) return;
            NSMutableAttributedString *text =
                [[line.attributedString attributedSubstringFromRange:line.characterRange] mutableCopy];
            NSMutableParagraphStyle *paragraph =
                [[text attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] mutableCopy];
            paragraph.lineHeightMultiple = 1.0;
            [text addAttribute:NSParagraphStyleAttributeName value:paragraph
                         range:NSMakeRange(0, text.length)];
            GAMultiTextView *reference = GACreateMultiTextView();
            reference.frame = self.textView.frame;
            reference.textContainerInset = self.textView.textContainerInset;
            [reference setLayoutOrientation:self.textView.layoutOrientation];
            reference.textContainer.containerSize = self.textView.textContainer.containerSize;
            reference.textStorage.attributedString = text;
            [reference.textLayoutManager ensureLayoutForRange:reference.textLayoutManager.documentRange];
            CGFloat naturalBaseline = 0;
            if (!GAFirstLineBaseline(reference.textLayoutManager, &naturalBaseline)) return;
            self.naturalFirstBaseline = naturalBaseline;
        }
        self.naturalBaselineMetrics = metrics;
        self.hasNaturalFirstBaseline = YES;
    }
    self.baselineMetricsFont = font;
    self.textView.firstBaselineOffset = baseline - self.naturalFirstBaseline;
}

- (void)rebuildLayout {
    self.layoutPending = YES;
    if (!self.layoutActive) return;
    self.layoutPending = NO;
    self.glyphHits = @[];
    self.pageContentSize = NSZeroSize;
    self.textView.firstBaselineOffset = 0;
    NSRect area = [self pageArea];
    NSFont *font = nil;
    NSSize page = NSZeroSize;
    if (self.document != nil && self.text.length > 0 &&
        self.viewportSize.width >= 1 && self.viewportSize.height >= 1) {
        page = area.size;
        if (!self.displayFont)
            self.displayFont = (__bridge_transfer NSFont *)GACopyFontWithFeatureSettings(
                self.document.fontBox.font, GAMultiBaseFontSize * self.textScale,
                self.featureSettings);
        font = self.displayFont;
    }
    if (font == nil || page.width < 1 || page.height < 1) {
        self.textView.hidden = YES;
        [self setNeedsDisplay:YES];
        if (self.onContentSizeChanged) {
            self.onContentSizeChanged();
        }
        return;
    }

    CGFloat lineLength = self.vertical ? page.height : page.width;
    [self updateTextContainerInset];
    [self.textView setLayoutOrientation:self.vertical
        ? NSTextLayoutOrientationVertical
        : NSTextLayoutOrientationHorizontal];
    self.textView.textContainer.containerSize = NSMakeSize(lineLength, 0);
    NSMutableArray *atomic = [NSMutableArray array];
    for (GACharacterGroup *group in self.groups)
        if (group.seeded)
            [atomic addObject:[NSValue valueWithRange:group.textRange]];

    NSMutableArray<NSNumber *> *sourceIndices = [NSMutableArray arrayWithCapacity:self.text.length];
    NSMutableAttributedString *display = [self displayAttributedStringForFont:font sourceIndices:sourceIndices];
    NSString *fontName = CFBridgingRelease(CTFontCopyPostScriptName((__bridge CTFontRef)font));
    NSTextLayoutManager *layout = self.textView.textLayoutManager;
    while (YES) {
        self.textView.textStorage.attributedString = display;
        [layout ensureLayoutForRange:layout.documentRange];
        NSMutableIndexSet *foreign = [NSMutableIndexSet indexSet];
        NSArray *hits = GAReadDisplayGlyphRuns(layout,
            sourceIndices, atomic, self.text, fontName, foreign);
        BOOL retryControls = NO;
        NSIndexSet *omit = foreign.count
            ? GAForeignCharactersToOmit(display, foreign, sourceIndices, &retryControls) : nil;
        if (!omit.count) {
            self.glyphHits = hits;
            break;
        }
        NSTextAttachment *attachment = retryControls ? nil : GAOmittedGlyphAttachment();
        [omit enumerateRangesWithOptions:NSEnumerationReverse usingBlock:^(NSRange range, BOOL *stop) {
            (void)stop;
            [sourceIndices removeObjectsInRange:range];
            if (retryControls) {
                [display deleteCharactersInRange:range];
            } else {
                NSDictionary *attributes = @{
                    NSAttachmentAttributeName: attachment,
                    NSFontAttributeName: font,
                    NSParagraphStyleAttributeName:
                        [display attribute:NSParagraphStyleAttributeName atIndex:range.location effectiveRange:NULL]
                            ?: NSParagraphStyle.defaultParagraphStyle,
                };
                NSAttributedString *boundary = [[NSAttributedString alloc] initWithString:@"\uFFFC"
                                                                              attributes:attributes];
                [display replaceCharactersInRange:range withAttributedString:boundary];
                [sourceIndices insertObject:@(NSNotFound) atIndex:range.location];
            }
        }];
    }
    self.displaySourceIndices = sourceIndices;

    [self updateFirstBaselineOffsetForFont:font];
    NSRect usage = self.textView.textLayoutManager.usageBoundsForTextContainer;
    CGFloat extent = MAX(1.0, ceil(usage.size.height - self.textView.firstBaselineOffset));
    CGFloat pageWidth = self.vertical ? extent : page.width;
    CGFloat pageHeight = self.vertical ? page.height : extent;
    self.pageContentSize = NSMakeSize(pageWidth, pageHeight);
    self.textView.hidden = NO;
    [self.textView setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
    if (self.onContentSizeChanged) {
        self.onContentSizeChanged();
    }
    [self positionTextView];
}

- (void)positionTextView {
    if (self.textView.hidden || self.pageContentSize.width <= 0.5) {
        return;
    }
    NSRect page = [self pageRect];
    NSPoint inset = [self pageArea].origin;
    if (self.vertical) {
        // Keep vertical clipping on the page; the first-baseline offset is
        // applied separately in the container's rotated coordinates.
        [self.textView setFrame:page];
    } else {
        // Unrotated bounds: expand the frame by the side inset so ink can
        // overhang the page without moving the text container.
        [self.textView setFrame:NSMakeRect(NSMinX(page) - inset.x,
                                           NSMinY(page) - inset.y,
                                           NSWidth(page) + 2 * inset.x,
                                           NSHeight(page) + 2 * inset.y)];
    }
}

#pragma mark - Geometry

- (NSRect)pageArea {
    NSRect viewport = NSMakeRect(0, 0, self.viewportSize.width, self.viewportSize.height);
    return GAInsetRectByFraction(viewport, self.sideInsetFraction);
}

- (CGFloat)pageVerticalMargin {
    CGFloat centeredMargin =
        (self.viewportSize.height - self.pageContentSize.height) * 0.5;
    return MAX([self pageArea].origin.y, centeredMargin);
}

- (NSSize)documentSize {
    NSSize viewport = self.viewportSize;
    NSPoint inset = [self pageArea].origin;
    NSSize page = self.pageContentSize;
    CGFloat width = self.vertical ? MAX(viewport.width, page.width + 2 * inset.x) : viewport.width;
    CGFloat height = self.vertical ? viewport.height : MAX(viewport.height, page.height + 2 * inset.y);
    if (self.toolbarTopInset > 0) {
        CGFloat margin = [self pageVerticalMargin];
        height = MAX(viewport.height - self.toolbarTopInset,
                     page.height + margin + MAX(0, margin - self.toolbarTopInset));
    }
    return NSMakeSize(width, height);
}

- (NSRect)pageRect {
    NSSize viewport = self.viewportSize;
    NSPoint inset = [self pageArea].origin;
    NSSize page = self.pageContentSize;
    if (page.width <= 0 || page.height <= 0) {
        return NSZeroRect;
    }
    CGFloat y = inset.y;
    if (self.toolbarTopInset > 0) {
        CGFloat topGap = MAX(0, [self pageVerticalMargin] - self.toolbarTopInset);
        y = NSHeight(self.bounds) - page.height - topGap;
    } else if (!self.vertical) {
        y = page.height <= viewport.height ? (NSHeight(self.bounds) - page.height) * 0.5
                                          : NSHeight(self.bounds) - inset.y - page.height;
    }
    if (self.vertical) {
        CGFloat x = page.width <= viewport.width
            ? (NSWidth(self.bounds) - page.width) * 0.5
            : NSWidth(self.bounds) - inset.x - page.width;
        return NSMakeRect(x, y, page.width, page.height);
    }
    return NSMakeRect(inset.x, y, page.width, page.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    [[self.previewColors colorForRole:GAPreviewColorBackground] setFill];
    NSRectFill(self.bounds);
    if (self.pageContentSize.width <= 0 || self.pageContentSize.height <= 0) {
        return;
    }
    if (self.showsMetrics) {
        GADrawPage([self pageRect], self.effectiveAppearance, self.previewColors);
    }
}

#pragma mark - Hit testing

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self selectGroupAtPoint:point];
    [self.window performWindowDragWithEvent:event];
}

- (void)selectGroupAtPoint:(NSPoint)point {
    if (self.textView.hidden) {
        return;
    }
    NSPoint local = [self.textView convertPoint:point fromView:self];
    NSPoint containerOrigin = self.textView.textContainerOrigin;
    local.x -= containerOrigin.x;
    local.y -= containerOrigin.y;
    NSTextLayoutManager *layoutManager = self.textView.textLayoutManager;
    NSTextContentManager *contentManager = layoutManager.textContentManager;
    id<NSTextLocation> documentStart = contentManager.documentRange.location;
    __block NSInteger hitIndex = NSNotFound;
    [layoutManager enumerateTextLayoutFragmentsFromLocation:nil
                                                    options:0
                                                usingBlock:^BOOL(NSTextLayoutFragment *fragment) {
        NSInteger fragmentStart =
            [contentManager offsetFromLocation:documentStart
                                    toLocation:fragment.rangeInElement.location];
        for (NSTextLineFragment *line in fragment.textLineFragments) {
            CGRect typographic = line.typographicBounds;
            CGPoint linePoint = CGPointMake(
                local.x - NSMinX(fragment.layoutFragmentFrame) - NSMinX(typographic),
                local.y - NSMinY(fragment.layoutFragmentFrame) - NSMinY(typographic));
            CGRect lineBounds = CGRectMake(0, 0, typographic.size.width,
                                           typographic.size.height);
            if (fragmentStart == 0 && line == fragment.textLineFragments.firstObject) {
                // Tight leading places part of the first glyph above its native line box.
                CGFloat top = MIN(0.0, self.textView.firstBaselineOffset);
                lineBounds.origin.y = top;
                lineBounds.size.height -= top;
            }
            if (!NSPointInRect(linePoint, lineBounds)) {
                continue;
            }
            NSInteger relative = [line characterIndexForPoint:linePoint];
            if (relative < 0) {
                continue;
            }
            if (line.characterRange.length)
                relative = MIN(relative, (NSInteger)NSMaxRange(line.characterRange) - 1);
            hitIndex = fragmentStart + relative;
            return NO;
        }
        return YES;
    }];
    if (hitIndex == NSNotFound || hitIndex < 0 || hitIndex >= (NSInteger)self.displaySourceIndices.count) {
        return;
    }
    NSUInteger sourceIndex = self.displaySourceIndices[(NSUInteger)hitIndex].unsignedIntegerValue;
    if (sourceIndex == NSNotFound) return;
    for (GAGlyphLayoutRun *hit in self.glyphHits)
        if (NSLocationInRange(sourceIndex, hit.range)) {
            if (self.onGlyphSelected)
                self.onGlyphSelected(hit.glyphIDs, hit.range, hit.leadingGlyphIDs, hit.leadingRange);
            break;
        }
}

@end
