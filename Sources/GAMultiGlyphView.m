#import "GAMultiGlyphView.h"
#import "GABoundingBoxView.h"
#import "GAUnicode.h"
#import <CoreText/CoreText.h>
#import <CoreText/SFNTLayoutTypes.h>
#import <math.h>

static const CGFloat GAMultiBaseFontSize = 51.0;
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
@end

@implementation GAMultiTextView

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

/// Native AAT display settings only; candidate discovery is independent.
/// Contextual Alternates controls the three contextual/swash alternate selectors;
/// Ligatures controls the eleven ligature selectors. Disabled groups send
/// Off selectors; enabled groups omit settings and preserve the font defaults.
static
CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
                                BOOL ligatures) CF_RETURNS_RETAINED;

/// Builds fixed-GID display text for explicit selections and vertical quotes.
/// Each component keeps its override; the user's source text is untouched.
static NSAttributedString *_Nullable GACreateGlyphDisplayString(
    NSArray<NSNumber *> *glyphIDs, NSString *baseString, NSFont *font,
    NSDictionary<NSAttributedStringKey, id> *attributes,
    NSString *_Nullable (^baseForGlyph)(CGGlyph glyph));
/// Replaces a source range in a display copy and updates its UTF-16 hit map.
static void
GAReplaceSeedDisplayRange(NSMutableAttributedString *display,
                          NSMutableArray<NSNumber *> *sourceIndices,
                          NSRange sourceRange, NSAttributedString *replacement);

/// Native TextKit GIDs for one source span, distinct from sidebar candidates.
@interface GAGlyphLayoutRun : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@end

@interface NSTextLayoutManager (GAGlyphReadback)
@property(nonatomic) BOOL requiresCTLineRef;
@end

/// Reads native GIDs and maps display clusters back to source UTF-16 ranges.
/// Composed characters and explicit selection ranges remain atomic.
static NSArray<GAGlyphLayoutRun *> *
GAReadDisplayGlyphRuns(NSTextLayoutManager *layout, NSArray<NSNumber *> *sourceIndices,
                       NSArray<NSValue *> *atomicRanges, NSString *sourceText);
NS_ASSUME_NONNULL_END

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

static CTFontRef GACopyTextDisplayFont(CTFontRef font, CGFloat size, BOOL contextualAlternates,
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

static NSArray<GAGlyphLayoutRun *> *GAReadDisplayGlyphRuns(
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

#pragma mark - View

@interface GAMultiGlyphView ()
@property (nonatomic, strong) GAMultiTextView *textView;
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, copy) NSArray<NSNumber *> *displaySourceIndices;
@property (nonatomic, copy, readonly) NSArray<GACharacterGroup *> *groups;
@property(nonatomic, copy) NSArray<GAGlyphLayoutRun *> *glyphHits;
@property (nonatomic) NSSize pageContentSize;
@property (nonatomic) CGFloat textScale;
@property (nonatomic) CGFloat magnificationStartTextScale;
/// The page in the view's own coordinates, including the current page inset.
- (NSRect)pageRect;
@end

@implementation GAMultiGlyphView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _sideInsetFraction = GABoundingBoxDefaultSideInsetFraction;
        _showsMetrics = YES;
        _textScale = 1.0;
        _usesContextualAlternates = YES;
        _usesLigatures = YES;

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

- (void)setDocument:(GAFontDocument *)document {
    _document = document;
    [self rebuildLayout];
}

- (void)setText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups {
    _text = [text copy] ?: @"";
    _groups = [groups copy] ?: @[];
    [self rebuildLayout];
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

- (void)setTextScale:(CGFloat)textScale {
    CGFloat clamped = GAMultiClampTextScale(textScale);
    if (fabs(clamped - _textScale) < 1e-9) return;
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        self->_textScale = clamped;
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

- (void)setUsesContextualAlternates:(BOOL)enabled {
    if (_usesContextualAlternates == enabled)
        return;
    _usesContextualAlternates = enabled;
    [self rebuildLayout];
}

- (void)setUsesLigatures:(BOOL)enabled {
    if (_usesLigatures == enabled)
        return;
    _usesLigatures = enabled;
    [self rebuildLayout];
}

- (void)setVertical:(BOOL)vertical {
    if (_vertical == vertical) {
        return;
    }
    _vertical = vertical;
    [self rebuildLayout];
}

- (void)setViewportSize:(NSSize)viewportSize {
    if (NSEqualSizes(_viewportSize, viewportSize)) {
        return;
    }
    _viewportSize = viewportSize;
    [self rebuildLayout];
}

- (void)zoomTextIn {
    self.textScale *= GAGlyphZoomStep;
}

- (void)zoomTextOut {
    self.textScale /= GAGlyphZoomStep;
}

- (void)resetTextZoom {
    self.textScale = 1.0;
}

- (void)handleMagnification:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.magnificationStartTextScale = self.textScale;
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        self.textScale = self.magnificationStartTextScale *
                         (1.0 + recognizer.magnification);
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self rebuildLayout];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self positionTextView];
}

#pragma mark - Layout

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

- (NSAttributedString *)displayAttributedStringForFont:(NSFont *)font {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = self.textAlignment;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName :
            GAResolvedColor(GAGlyphForegroundColor(), self.effectiveAppearance),
        NSParagraphStyleAttributeName : paragraph,
    };

    NSMutableAttributedString *display =
        [[NSMutableAttributedString alloc] initWithString:self.text attributes:attributes];
    NSMutableArray<NSNumber *> *sourceIndices = [NSMutableArray arrayWithCapacity:self.text.length];
    for (NSUInteger i = 0; i < self.text.length; i++)
        [sourceIndices addObject:@(i)];
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
            glyphIDs, base, font, attributes, ^NSString *(CGGlyph glyph) {
                return [self replacementBaseForOriginal:base glyph:glyph font:font];
            });
        if (replacement)
            GAReplaceSeedDisplayRange(display, sourceIndices, group.textRange, replacement);
    }
    self.displaySourceIndices = sourceIndices;
    return display;
}

- (void)rebuildLayout {
    self.glyphHits = @[];
    self.pageContentSize = NSZeroSize;
    NSRect area = [self pageArea];
    NSFont *font = nil;
    NSSize page = NSZeroSize;
    if (self.document != nil && self.text.length > 0 &&
        self.viewportSize.width >= 1 && self.viewportSize.height >= 1) {
        page = area.size;
        font = (__bridge_transfer NSFont *)GACopyTextDisplayFont(
            self.document.fontBox.font, GAMultiBaseFontSize * self.textScale,
            self.usesContextualAlternates, self.usesLigatures);
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
    // Horizontal text views have unrotated bounds, so the inset-expanded frame
    // gives ink room to overhang the page. Vertical text views are rotated by
    // -setLayoutOrientation:; textContainerOrigin lives in that rotated space,
    // so the same inset expansion moves the text container off pageRect. Keep
    // vertical at zero inset (vertical ink overhanging the page is clipped).
    NSPoint inset = area.origin;
    self.textView.textContainerInset = self.vertical
        ? NSZeroSize
        : NSMakeSize(inset.x, inset.y);
    [self.textView setLayoutOrientation:self.vertical
        ? NSTextLayoutOrientationVertical
        : NSTextLayoutOrientationHorizontal];
    self.textView.textContainer.containerSize = NSMakeSize(lineLength, 0);
    self.textView.textStorage.attributedString = [self displayAttributedStringForFont:font];
    [self.textView.textLayoutManager
        ensureLayoutForBounds:NSMakeRect(0, 0, lineLength, 1000000.0)];

    NSMutableArray *atomic = [NSMutableArray array];
    for (GACharacterGroup *group in self.groups)
        if (group.seeded)
            [atomic addObject:[NSValue valueWithRange:group.textRange]];
    self.glyphHits = GAReadDisplayGlyphRuns(self.textView.textLayoutManager,
                                           self.displaySourceIndices, atomic, self.text);

    NSRect usage = self.textView.textLayoutManager.usageBoundsForTextContainer;
    CGFloat pageWidth = self.vertical ? MAX(1.0, ceil(usage.size.height)) : page.width;
    CGFloat pageHeight = self.vertical ? page.height
                                       : MAX(1.0, ceil(usage.size.height));
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
        // Rotated bounds: keep the frame on the page so the text container's
        // rotated origin still lands on pageRect.
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

- (NSSize)documentSize {
    NSSize viewport = self.viewportSize;
    NSPoint inset = [self pageArea].origin;
    NSSize page = self.pageContentSize;
    if (self.vertical) {
        return NSMakeSize(MAX(viewport.width, page.width + 2 * inset.x), viewport.height);
    }
    return NSMakeSize(viewport.width, MAX(viewport.height, page.height + 2 * inset.y));
}

- (NSRect)pageRect {
    NSSize viewport = self.viewportSize;
    NSPoint inset = [self pageArea].origin;
    NSSize page = self.pageContentSize;
    if (page.width <= 0 || page.height <= 0) {
        return NSZeroRect;
    }
    if (self.vertical) {
        CGFloat x = page.width <= viewport.width
            ? (NSWidth(self.bounds) - page.width) * 0.5
            : NSWidth(self.bounds) - inset.x - page.width;
        return NSMakeRect(x, inset.y, page.width, page.height);
    }
    CGFloat y = page.height <= viewport.height
        ? (NSHeight(self.bounds) - page.height) * 0.5
        : NSHeight(self.bounds) - inset.y - page.height;
    return NSMakeRect(inset.x, y, page.width, page.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    [GABoundingBoxBackgroundColor() setFill];
    NSRectFill(self.bounds);
    if (self.pageContentSize.width <= 0 || self.pageContentSize.height <= 0) {
        return;
    }
    if (self.showsMetrics) {
        GADrawPage([self pageRect], self.effectiveAppearance);
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
    for (GAGlyphLayoutRun *hit in self.glyphHits)
        if (NSLocationInRange(sourceIndex, hit.range)) {
            if (self.onGlyphSelected)
                self.onGlyphSelected(hit.glyphIDs, hit.range);
            break;
        }
}

@end
