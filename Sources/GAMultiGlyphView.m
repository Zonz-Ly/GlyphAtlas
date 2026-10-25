#import "GAMultiGlyphView.h"
#import "GAGlyphCanvasView.h"
#import "GAUnicode.h"
#import "GATextDisplay.h"
#import "GATextHitMap.h"
#import <CoreText/CoreText.h>
#import <math.h>

static const CGFloat GAMultiBaseFontSize = 32.0;
/// Ten zoom-outs and twenty zoom-ins: `1 / 1.12^10` to `1.12^20`.
static CGFloat GAMultiClampTextScale(CGFloat scale) {
    CGFloat minimum = 1.0 / GAGlyphZoomStep10;
    CGFloat maximum = GAGlyphZoomStep10 * GAGlyphZoomStep10;
    return MIN(maximum, MAX(minimum, scale));
}

#pragma mark - Display-only text view

/// The text view exists to lay out and draw the text. Clicks and drags belong
/// to the page view so the whole canvas stays draggable and click-to-select
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

#pragma mark - Seed image

static NSColor *GAResolvedColor(NSColor *color, NSAppearance *appearance) {
    __block NSColor *resolved = color;
    [(appearance ?: NSApp.effectiveAppearance) performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    }];
    return resolved;
}

#pragma mark - View

@interface GAMultiGlyphView ()
@property (nonatomic, strong) GAMultiTextView *textView;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSArray<NSNumber *> *displaySourceIndices;
@property(nonatomic, copy) NSArray *displayGlyphSelections;
@property (nonatomic, copy) NSArray<GACharacterGroup *> *groups;
@property(nonatomic, copy, nullable) NSArray<GAGlyphLayoutRun *> *glyphHits;
@property (nonatomic) NSSize pageContentSize;
@property (nonatomic) CGFloat textScale;
@property (nonatomic) CGFloat magnificationStartTextScale;
@end

@implementation GAMultiGlyphView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _text = @"";
        _groups = @[];
        _sideInsetFraction = GACanvasDefaultSideInsetFraction;
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
    _sideInsetFraction = clamped;
    [self rebuildLayout];
    if (self.onSideInsetFractionChanged) {
        self.onSideInsetFractionChanged(clamped);
    }
}

- (void)setShowsMetrics:(BOOL)showsMetrics {
    _showsMetrics = showsMetrics;
    [self setNeedsDisplay:YES];
}

- (void)setTextScale:(CGFloat)textScale {
    _textScale = GAMultiClampTextScale(textScale);
    [self rebuildLayout];
    if (self.onTextScaleChanged) {
        self.onTextScaleChanged();
    }
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

- (NSFont *)fontAtSize:(CGFloat)size {
    GAFontDocument *document = self.document;
    if (document == nil) {
        return nil;
    }
    return (__bridge_transfer NSFont *)GACopyTextDisplayFont(
        document.fontBox.font, size, self.usesContextualAlternates, self.usesLigatures);
}

- (CGFloat)horizontalAdvanceForGlyph:(CGGlyph)glyph font:(NSFont *)font {
    CGSize advance = CGSizeZero;
    CTFontGetAdvancesForGlyphs((__bridge CTFontRef)font,
                               kCTFontOrientationHorizontal,
                               &glyph, &advance, 1);
    return advance.width;
}

- (BOOL)font:(NSFont *)font encodesCharacter:(unichar)character {
    CGGlyph glyph = 0;
    return CTFontGetGlyphsForCharacters((__bridge CTFontRef)font,
                                        &character, &glyph, 1) && glyph != 0;
}

- (BOOL)font:(NSFont *)font glyph:(CGGlyph)glyph encodesCharacter:(unichar)character {
    CGGlyph mapped = 0;
    if (!CTFontGetGlyphsForCharacters((__bridge CTFontRef)font,
                                      &character, &mapped, 1)) {
        return NO;
    }
    return mapped == glyph;
}

- (BOOL)glyphIsFullWidth:(CGGlyph)glyph font:(NSFont *)font {
    CGFloat advance = [self horizontalAdvanceForGlyph:glyph font:font];
    if (advance <= 0.01) {
        return NO;
    }
    if (fabs(advance - font.pointSize) < 0.01) {
        return YES;
    }
    UniChar ideograph = 0x5B57;  // 字
    CGGlyph ideographGlyph = 0;
    if (CTFontGetGlyphsForCharacters((__bridge CTFontRef)font,
                                     &ideograph, &ideographGlyph, 1) &&
        ideographGlyph != 0) {
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
    if (rotated && fullWidth && [self font:font encodesCharacter:0x5B57]) {
        return @"字";
    }
    if (!rotated && !fullWidth && [self font:font encodesCharacter:0x41]) {
        return @"A";
    }
    return nil;
}

- (nullable NSNumber *)verticalQuoteGlyphForGroup:(GACharacterGroup *)group
                                             font:(NSFont *)font {
    if (!self.vertical || group.seeded || group.insertedLigature ||
        group.text.length != 1) {
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
    if (baseGlyph == nil || baseGlyph.unsignedShortValue == 0) {
        return nil;
    }
    NSNumber *vertical = [self.document
        verticalSubstituteForGlyph:(CGGlyph)baseGlyph.unsignedShortValue];
    if (vertical == nil || vertical.unsignedShortValue == 0 ||
        vertical.unsignedShortValue == baseGlyph.unsignedShortValue) {
        return nil;
    }
    // Do not replace a glyph that is already the encoded vertical presentation
    // form for this quote: U+FE41/U+FE43 for ‘/“, U+FE42/U+FE44 for ’/”.
    unichar presentation = opening ? 0xFE41 : 0xFE42;
    unichar whitePresentation = opening ? 0xFE43 : 0xFE44;
    CGGlyph verticalGlyph = (CGGlyph)vertical.unsignedShortValue;
    if ([self font:font glyph:verticalGlyph encodesCharacter:presentation] ||
        [self font:font glyph:verticalGlyph encodesCharacter:whitePresentation]) {
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
        // Native TextKit owns shaping. Explicit glyph selections remain seeds.
        // Optional features live on the font; do not disable the shaping channel.
        NSLigatureAttributeName : @1,
    };

    NSMutableAttributedString *display =
        [[NSMutableAttributedString alloc] initWithString:self.text attributes:attributes];
    NSMutableArray<NSNumber *> *sourceIndices = [NSMutableArray arrayWithCapacity:self.text.length];
    NSMutableArray *pins = [NSMutableArray arrayWithCapacity:self.text.length];
    for (NSUInteger i = 0; i < self.text.length; i++) {
        [sourceIndices addObject:@(i)];
        [pins addObject:NSNull.null];
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
        if (group.seeded && variant.glyphIDs.count > 1) {
            NSString *source = [self.text substringWithRange:group.textRange];
            NSString *base =
                [source substringWithRange:[source rangeOfComposedCharacterSequenceAtIndex:0]];
            NSMutableArray *components = [NSMutableArray array];
            NSAttributedString *sequence = GACreateSeedDisplayString(
                variant.glyphIDs, base, font, attributes, ^NSString *(CGGlyph glyph) {
                  NSString *alias =
                      [self replacementBaseForOriginal:base glyph:glyph font:font] ?: base;
                  GAGlyphSelection *pin = [[GAGlyphSelection alloc] initWithSourceText:alias
                                                                              glyphIDs:@[ @(glyph) ]
                                                                        featureSources:@[]
                                                                              ligature:NO];
                  for (NSUInteger i = 0; i < alias.length; i++)
                      [components addObject:pin];
                  return alias;
                });
            if (sequence) {
                GAReplaceSeedDisplayRange(display, sourceIndices, group.textRange, sequence);
                [pins replaceObjectsInRange:group.textRange withObjectsFromArray:components];
            }
            continue;
        }
        // A seed affects only its own group; other quote groups still use vert.
        NSNumber *displayGlyph = group.seeded ? variant.glyphIDs.firstObject
                                              : [self verticalQuoteGlyphForGroup:group font:font];
        if (displayGlyph == nil) {
            continue;
        }
        CGGlyph glyph = (CGGlyph)displayGlyph.unsignedShortValue;
        NSString *original = [self.text substringWithRange:group.textRange];
        NSString *baseString =
            [self replacementBaseForOriginal:original glyph:glyph font:font] ?: original;
        NSGlyphInfo *info = [NSGlyphInfo glyphInfoWithGlyph:glyph
                                                    forFont:font
                                                 baseString:baseString];
        if (info != nil) {
            NSMutableAttributedString *component =
                [[NSMutableAttributedString alloc] initWithString:baseString attributes:attributes];
            [component addAttribute:NSGlyphInfoAttributeName
                              value:info
                              range:NSMakeRange(0, component.length)];
            GAReplaceSeedDisplayRange(display, sourceIndices, group.textRange, component);
            GAGlyphSelection *pin = [[GAGlyphSelection alloc] initWithSourceText:baseString
                                                                        glyphIDs:@[ @(glyph) ]
                                                                  featureSources:@[]
                                                                        ligature:NO];
            NSMutableArray *components = [NSMutableArray array];
            for (NSUInteger i = 0; i < baseString.length; i++)
                [components addObject:pin];
            [pins replaceObjectsInRange:group.textRange withObjectsFromArray:components];
        }
    }
    self.displaySourceIndices = sourceIndices;
    self.displayGlyphSelections = pins;
    return display;
}

- (void)rebuildLayout {
    self.glyphHits = nil;
    self.pageContentSize = NSZeroSize;
    NSRect area = [self pageArea];
    NSFont *font = nil;
    NSSize page = NSZeroSize;
    if (self.document != nil && self.text.length > 0 &&
        self.viewportSize.width >= 1 && self.viewportSize.height >= 1) {
        page = area.size;
        font = [self fontAtSize:GAMultiBaseFontSize * self.textScale];
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
    [GACanvasBackgroundColor() setFill];
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

- (NSArray<GAGlyphLayoutRun *> *)resolvedGlyphHits {
    if (self.glyphHits)
        return self.glyphHits;
    NSArray *display = GAPredictDisplayGlyphRuns(
        self.textView.textLayoutManager, self.displayGlyphSelections, self.document,
        self.usesContextualAlternates, self.usesLigatures, self.vertical);
    NSMutableArray *atomic = [NSMutableArray array];
    for (GACharacterGroup *group in self.groups)
        if (group.seeded)
            [atomic addObject:[NSValue valueWithRange:group.textRange]];
    self.glyphHits = GAMapGlyphLayoutRuns(display, self.displaySourceIndices, atomic, self.text);
    return self.glyphHits;
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
    // Vertical substitutions are active independently of the optional switches.
    if (!self.vertical && !self.usesContextualAlternates && !self.usesLigatures) {
        for (GACharacterGroup *group in self.groups)
            if (NSLocationInRange(sourceIndex, group.textRange)) {
                NSArray *ids = group.variants.firstObject.glyphIDs;
                if (self.onGlyphSelected)
                    self.onGlyphSelected(ids, group.textRange);
                return;
            }
    }
    for (GAGlyphLayoutRun *hit in [self resolvedGlyphHits])
        if (NSLocationInRange(sourceIndex, hit.range)) {
            if (self.onGlyphSelected)
                self.onGlyphSelected(hit.glyphIDs, hit.range);
            break;
        }
}

@end
