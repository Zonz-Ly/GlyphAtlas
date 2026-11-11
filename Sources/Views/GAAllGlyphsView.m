#import "GAAllGlyphsView.h"
#import "GABoundingBoxView.h"

static const CGFloat GAAllGlyphsSideMargin = 16.0;
static const CGFloat GAAllGlyphsVerticalMargin = 18.0;
static const CGFloat GAAllGlyphsHorizontalGap = 6.0;
static const CGFloat GAAllGlyphsVerticalGap = 8.0;
static const CGFloat GAAllGlyphsBaseCell = 44.0;
static const CGFloat GAAllGlyphsGlyphRatio = 0.85;
static const CGFloat GAAllGlyphsInkOutset = 2.0;

/// Drawing-space ink bounds, including the antialiased fringe.
static NSRect GAAllGlyphsInkRect(GAGlyphPage page, CGPoint origin, CGFloat unitScale) {
    NSRect ink = NSMakeRect(origin.x + CGRectGetMinX(page.ink) * unitScale,
                           origin.y - CGRectGetMaxY(page.ink) * unitScale,
                           CGRectGetWidth(page.ink) * unitScale,
                           CGRectGetHeight(page.ink) * unitScale);
    return NSInsetRect(ink, -GAAllGlyphsInkOutset, -GAAllGlyphsInkOutset);
}

/// Ten zoom-outs and ten zoom-ins from the default cell: `1 / 1.12^10` to
/// `1.12^10`.
static CGFloat GAAllGlyphsClampScale(CGFloat scale) {
    return MIN(GAGlyphZoomStep10, MAX(1.0 / GAGlyphZoomStep10, scale));
}
static const NSTimeInterval GAHighlightBlinkOn = 0.1;
static const NSTimeInterval GAHighlightBlinkOff = 0.1;
static const NSTimeInterval GAHighlightHold = 1.0;
static const NSTimeInterval GAHighlightFade = 0.7;
static const NSTimeInterval GAHighlightAppendOn = 0.2;
static const NSTimeInterval GAHighlightAppendFade = 0.8;
static const NSTimeInterval GAHighlightTick = 1.0 / 30.0;

@interface GAAllGlyphsGrid : NSView
@property(nonatomic, strong) GAPreviewColors *previewColors;
@property (nonatomic, copy) NSArray<GAAllGlyphEntry *> *entries;
@property (nonatomic, strong, nullable) GAFontBox *fontBox;
/// Lazily computed GAGlyphPage per entry, and one validity byte per entry.
@property (nonatomic, strong) NSMutableData *pageMetrics;
@property (nonatomic, strong) NSMutableData *pageMetricsValid;
@property (nonatomic) CGFloat cellScale;
@property (nonatomic) NSUInteger columns;
/// Top spacing before the first row.
@property (nonatomic) CGFloat topInset;
@property (nonatomic) NSUInteger highlightIndex;
@property (nonatomic) CGFloat highlightAlpha;
@property (nonatomic) NSTimeInterval highlightElapsed;
@property (nonatomic) BOOL highlightAppendStyle;
@property (nonatomic, strong, nullable) NSTimer *highlightTimer;
@property (nonatomic, copy, nullable) void (^onDoubleClick)(GAAllGlyphEntry *entry);
- (void)updateLayoutForWidth:(CGFloat)width;
- (void)revealGlyph:(NSNumber *)glyphID quick:(BOOL)quick;
@end

@implementation GAAllGlyphsGrid

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _previewColors = [GAPreviewColors new];
        _columns = 1;
        _topInset = GAAllGlyphsVerticalMargin;
        _highlightIndex = NSNotFound;
    }
    return self;
}

- (void)dealloc {
    [_highlightTimer invalidate];
}

- (void)setEntries:(NSArray<GAAllGlyphEntry *> *)entries {
    [self.highlightTimer invalidate];
    self.highlightTimer = nil;
    self.highlightIndex = NSNotFound;
    if (_entries != entries) {
        _entries = [entries copy];
        _pageMetrics = [NSMutableData dataWithLength:_entries.count * sizeof(GAGlyphPage)];
        _pageMetricsValid = [NSMutableData dataWithLength:_entries.count];
    }
    [self setNeedsDisplay:YES];
}

- (void)setFontBox:(GAFontBox *)fontBox {
    _fontBox = fontBox;
    // The page metrics depend on the font, not just on the glyph ID.
    if (_pageMetricsValid.length > 0) {
        [_pageMetricsValid resetBytesInRange:NSMakeRange(0, _pageMetricsValid.length)];
    }
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (CGFloat)cellSide {
    return GAAllGlyphsBaseCell * self.cellScale;
}

- (void)updateLayoutForWidth:(CGFloat)width {
    if (width < 1) {
        return;
    }
    CGFloat cell = self.cellSide;
    CGFloat usable = MAX(cell, width - 2 * GAAllGlyphsSideMargin);
    self.columns = MAX(1, (NSUInteger)floor((usable + GAAllGlyphsHorizontalGap) /
                                           (cell + GAAllGlyphsHorizontalGap)));
    NSUInteger rows = self.entries.count == 0
        ? 0
        : (self.entries.count + self.columns - 1) / self.columns;
    CGFloat height = self.topInset + GAAllGlyphsVerticalMargin + rows * cell +
        MAX(0, (NSInteger)rows - 1) * GAAllGlyphsVerticalGap;
    NSScrollView *scrollView = self.enclosingScrollView;
    NSEdgeInsets insets = scrollView.contentInsets;
    CGFloat minimum = scrollView.contentSize.height - insets.top - insets.bottom;
    CGFloat target = MAX(height, minimum);
    NSSize current = self.frame.size;
    if (fabs(current.width - width) > 0.5 || fabs(current.height - target) > 0.5) {
        self.frame = NSMakeRect(0, 0, width, target);
    }
    [self setNeedsDisplay:YES];
}

- (CGFloat)horizontalExtraSpacing {
    // Preserve the base margins and gaps; each outer edge gets two extra shares.
    CGFloat used = 2 * GAAllGlyphsSideMargin + self.columns * self.cellSide +
        (self.columns - 1) * GAAllGlyphsHorizontalGap;
    return MAX(0, (NSWidth(self.bounds) - used) / (self.columns + 3));
}

- (NSRect)rectForIndex:(NSUInteger)index {
    CGFloat cell = self.cellSide;
    CGFloat extra = self.horizontalExtraSpacing;
    return NSMakeRect(GAAllGlyphsSideMargin + 2 * extra +
                          (index % self.columns) * (cell + GAAllGlyphsHorizontalGap + extra),
                      self.topInset + (index / self.columns) * (cell + GAAllGlyphsVerticalGap),
                      cell, cell);
}

- (GAGlyphPage)pageForIndex:(NSUInteger)index {
    GAGlyphPage *pages = self.pageMetrics.mutableBytes;
    uint8_t *valid = self.pageMetricsValid.mutableBytes;
    if (!valid[index]) {
        // Advance width × (ascent + descent); cached per entry.
        GAGlyphVariant *probe = [[GAGlyphVariant alloc] init];
        probe.fontBox = self.fontBox;
        probe.glyphIDs = @[self.entries[index].glyphID];
        pages[index] = [GAFontDocument pageForVariant:probe usesVerticalMetrics:NO];
        valid[index] = 1;
    }
    return pages[index];
}

- (CGPoint)glyphOriginForIndex:(NSUInteger)index
                         page:(GAGlyphPage)page
                    unitScale:(CGFloat)unitScale {
    NSRect cell = [self rectForIndex:index];
    // Centre the advance-by-line-height page, preserving its horizontal baseline.
    CGFloat pageX = NSMidX(cell) - page.size.width * unitScale * 0.5;
    CGFloat pageY = NSMidY(cell) - page.size.height * unitScale * 0.5;
    return CGPointMake(pageX, pageY + (page.size.height - page.baseline) * unitScale);
}

- (NSRect)redrawRectForIndex:(NSUInteger)index {
    if (index >= self.entries.count || self.fontBox == nil) {
        return NSZeroRect;
    }
    GAGlyphPage page = [self pageForIndex:index];
    if (CGRectIsNull(page.ink) || CGRectIsEmpty(page.ink)) {
        return NSZeroRect;
    }
    CGFloat unitScale = self.cellSide * GAAllGlyphsGlyphRatio / CTFontGetUnitsPerEm(self.fontBox.font);
    CGPoint origin = [self glyphOriginForIndex:index page:page unitScale:unitScale];
    // Match the drawing transform, including the flipped Y axis. Only the
    // actual ink and its antialiased fringe need repainting, not the cell.
    return GAAllGlyphsInkRect(page, origin, unitScale);
}

- (NSInteger)indexAtPoint:(NSPoint)point {
    CGFloat cell = self.cellSide;
    CGFloat extra = self.horizontalExtraSpacing;
    CGFloat horizontalStride = cell + GAAllGlyphsHorizontalGap + extra;
    CGFloat verticalStride = cell + GAAllGlyphsVerticalGap;
    CGFloat x = point.x - GAAllGlyphsSideMargin - 2 * extra;
    CGFloat y = point.y - self.topInset;
    if (x < 0 || y < 0) {
        return -1;
    }
    NSUInteger column = (NSUInteger)floor(x / horizontalStride);
    NSUInteger row = (NSUInteger)floor(y / verticalStride);
    if (column >= self.columns) {
        return -1;
    }
    // The gap between cells is dead space, not part of the neighbouring cell.
    if (x - column * horizontalStride > cell || y - row * verticalStride > cell) {
        return -1;
    }
    NSUInteger index = row * self.columns + column;
    return index < self.entries.count ? (NSInteger)index : -1;
}

- (void)revealGlyph:(NSNumber *)glyphID quick:(BOOL)quick {
    const NSUInteger target = glyphID.unsignedIntegerValue;
    NSArray<GAAllGlyphEntry *> *entries = self.entries;
    NSUInteger index = target;
    // The complete inventory is contiguous. Filtered inventories remain sorted.
    if (index >= entries.count || entries[index].glyphID.unsignedIntegerValue != target) {
        NSUInteger low = 0, high = entries.count;
        while (low < high) {
            NSUInteger mid = low + (high - low) / 2;
            if (entries[mid].glyphID.unsignedIntegerValue < target)
                low = mid + 1;
            else
                high = mid;
        }
        if (low == entries.count || entries[low].glyphID.unsignedIntegerValue != target)
            return;
        index = low;
    }
    NSRect row = [self rectForIndex:index];
    if (NSIntersectsRect(row, [self unobscuredVisibleRect])) {
        [self scrollRectToVisible:NSInsetRect(row, -4, -4)];
    } else {
        [self centerRow:row];
    }
    [self flashIndex:index quick:quick];
}

- (NSRect)unobscuredVisibleRect {
    NSClipView *clip = self.enclosingScrollView.contentView;
    if (!clip) return self.visibleRect;
    NSRect viewport = [self convertRect:clip.bounds fromView:clip];
    NSEdgeInsets insets = clip.contentInsets;
    viewport.origin.y += insets.top;
    viewport.size.height = MAX(0, NSHeight(viewport) - insets.top - insets.bottom);
    return NSIntersectionRect(self.visibleRect, viewport);
}

/// A row that is completely outside the viewport is centred vertically, so a
/// sidebar jump does not stop against the top or bottom edge. Rows already in
/// view keep the minimal scroll; the centre is clamped at the document ends.
- (void)centerRow:(NSRect)row {
    NSScrollView *scrollView = self.enclosingScrollView;
    if (scrollView == nil) {
        [self scrollRectToVisible:NSInsetRect(row, -4, -4)];
        return;
    }
    NSClipView *clipView = scrollView.contentView;
    NSRect viewport = clipView.bounds;
    viewport.origin.y += NSMidY(row) - NSMidY([self unobscuredVisibleRect]);
    [clipView scrollToPoint:[clipView constrainBoundsRect:viewport].origin];
    [scrollView reflectScrolledClipView:clipView];
}

/// Locate animation: blink, hold, then fade. Append animation: one 0.2 s
/// highlight followed by a 0.8 s fade. A timer keeps both phases independent
/// of layer geometry.
- (void)flashIndex:(NSUInteger)index quick:(BOOL)quick {
    NSUInteger previous = self.highlightIndex;
    [self.highlightTimer invalidate];
    self.highlightIndex = index;
    self.highlightAlpha = 1.0;
    self.highlightElapsed = 0;
    self.highlightAppendStyle = quick;
    if (previous != NSNotFound && previous != index) {
        // Clear the previous glyph's full ink, including any cell overhang.
        [self setNeedsDisplayInRect:[self redrawRectForIndex:previous]];
    }
    NSRect rect = [self redrawRectForIndex:index];
    [self setNeedsDisplayInRect:rect];
    __weak typeof(self) weakSelf = self;
    self.highlightTimer = [NSTimer timerWithTimeInterval:GAHighlightTick
                                                repeats:YES
                                                  block:^(NSTimer *timer) {
        [weakSelf stepHighlight:timer];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.highlightTimer forMode:NSRunLoopCommonModes];
}

- (void)stepHighlight:(NSTimer *)timer {
    NSRect rect = [self redrawRectForIndex:self.highlightIndex];
    self.highlightElapsed += GAHighlightTick;
    const BOOL appendStyle = self.highlightAppendStyle;
    const NSTimeInterval on = appendStyle ? GAHighlightAppendOn : GAHighlightBlinkOn;
    const NSTimeInterval off = appendStyle ? 0.0 : GAHighlightBlinkOff;
    const NSTimeInterval hold = appendStyle ? 0.0 : GAHighlightHold;
    const NSTimeInterval fade = appendStyle ? GAHighlightAppendFade : GAHighlightFade;
    const NSTimeInterval secondPhase = on + off;
    const NSTimeInterval fadeStart = secondPhase + hold;
    const NSTimeInterval end = fadeStart + fade;
    if (self.highlightElapsed < on) {
        self.highlightAlpha = 1.0;
    } else if (self.highlightElapsed < secondPhase) {
        self.highlightAlpha = 0.0;
    } else if (self.highlightElapsed < fadeStart) {
        self.highlightAlpha = 1.0;
    } else {
        self.highlightAlpha = MAX(0.0, 1.0 -
            (self.highlightElapsed - fadeStart) / fade);
    }
    if (self.highlightElapsed >= end) {
        self.highlightAlpha = 0;
        self.highlightIndex = NSNotFound;
        [timer invalidate];
        self.highlightTimer = nil;
    }
    [self setNeedsDisplayInRect:rect];
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2 && self.onDoubleClick != nil) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSInteger index = [self indexAtPoint:point];
        if (index >= 0) self.onDoubleClick(self.entries[(NSUInteger)index]);
    }
    [self.window performWindowDragWithEvent:event];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[self.previewColors colorForRole:GAPreviewColorBackground] setFill];
    NSRectFill(self.bounds);
    if (self.entries.count == 0 || self.fontBox == nil) {
        return;
    }
    CTFontRef font = self.fontBox.font;
    CGFloat cell = self.cellSide;
    CGFloat upem = CTFontGetUnitsPerEm(font);
    CGFloat unitScale = cell * GAAllGlyphsGlyphRatio / upem;
    CGFloat glyphScale = cell * GAAllGlyphsGlyphRatio / GAFontShapingSize;
    NSRect drawingRect = NSIntersectionRect(dirtyRect, self.bounds);
    CGFloat stride = cell + GAAllGlyphsVerticalGap;
    CGFloat contentTop = self.topInset;
    // A glyph can paint beyond its row. Include every row whose font bounds
    // can reach the dirty area, including the antialiased fringe.
    GAGlyphPage referencePage = [self pageForIndex:0];
    CGPoint referenceOrigin = [self glyphOriginForIndex:0 page:referencePage unitScale:unitScale];
    CGRect fontBounds = CTFontGetBoundingBox(font);
    CGFloat inkTop = referenceOrigin.y - contentTop - CGRectGetMaxY(fontBounds) * glyphScale - GAAllGlyphsInkOutset;
    CGFloat inkBottom = referenceOrigin.y - contentTop - CGRectGetMinY(fontBounds) * glyphScale + GAAllGlyphsInkOutset;
    NSUInteger firstRow = (NSUInteger)MAX(0.0,
        floor((NSMinY(drawingRect) - contentTop - inkBottom) / stride));
    NSUInteger lastRow = (NSUInteger)MAX(0.0,
        floor((NSMaxY(drawingRect) - contentTop - inkTop) / stride));
    NSUInteger firstIndex = MIN(self.entries.count, firstRow * self.columns);
    NSUInteger lastIndex = MIN(self.entries.count, (lastRow + 1) * self.columns);
    NSColor *glyphColor = [self.previewColors colorForRole:GAPreviewColorGlyph];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;

    for (NSUInteger index = firstIndex; index < lastIndex; index++) {
        GAGlyphPage page = [self pageForIndex:index];
        if (CGRectIsEmpty(page.ink)) {
            continue;
        }
        CGPoint origin = [self glyphOriginForIndex:index page:page unitScale:unitScale];
        if (!NSIntersectsRect(GAAllGlyphsInkRect(page, origin, unitScale), drawingRect)) {
            continue;
        }
        BOOL highlighted = index == self.highlightIndex && self.highlightAlpha > 0;
        if (highlighted) {
            // Tint the glyph itself; the fade blends it back to the glyph colour.
            NSColor *blend = [glyphColor blendedColorWithFraction:self.highlightAlpha
                                                          ofColor:[NSColor controlAccentColor]]
                ?: [NSColor controlAccentColor];
            CGContextSetFillColorWithColor(context, blend.CGColor);
        } else {
            CGContextSetFillColorWithColor(context, glyphColor.CGColor);
        }
        GAAllGlyphEntry *entry = self.entries[index];
        CGGlyph glyph = (CGGlyph)entry.glyphID.unsignedShortValue;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, origin.x, origin.y);
        CGContextScaleCTM(context, glyphScale, -glyphScale);
        CTFontDrawGlyphs(font, &glyph, &(CGPoint){0, 0}, 1, context);
        CGContextRestoreGState(context);
    }
}

@end

@interface GAAllGlyphsView ()
@property (nonatomic, strong) GAAllGlyphsGrid *grid;
@property (nonatomic, strong) NSArray<GAAllGlyphEntry *> *inventory;
@property(nonatomic, copy) NSIndexSet *appliedGlyphIDs;
@property(nonatomic, copy) NSIndexSet *pendingGlyphIDs;
@property(nonatomic) BOOL hasPendingGlyphIDs;
@property (nonatomic) CGFloat magnificationStartScale;
@property (nonatomic) BOOL scrollsUnderToolbar;
@end

@implementation GAAllGlyphsView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _cellScale = 1.0;
        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.hasVerticalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        _scrollView.backgroundColor = GABoundingBoxBackgroundColor();
        _scrollView.automaticallyAdjustsContentInsets = NO;
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_scrollView];
        [NSLayoutConstraint activateConstraints:@[
            [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        _grid = [[GAAllGlyphsGrid alloc] initWithFrame:NSMakeRect(0, 0, 800, 800)];
        _grid.cellScale = _cellScale;
        _scrollView.documentView = _grid;
        __weak typeof(self) weakSelf = self;
        _grid.onDoubleClick = ^(GAAllGlyphEntry *entry) {
            if (weakSelf.onGlyphDoubleClick != nil) {
                weakSelf.onGlyphDoubleClick(entry);
            }
        };
        NSMagnificationGestureRecognizer *magnification =
            [[NSMagnificationGestureRecognizer alloc] initWithTarget:self
                                                               action:@selector(handleMagnification:)];
        [_grid addGestureRecognizer:magnification];
    }
    return self;
}

- (void)setMenu:(NSMenu *)menu {
    [super setMenu:menu];
    self.grid.menu = menu;
}

- (void)applyPreviewColors:(GAPreviewColors *)colors {
    self.grid.previewColors = colors;
    self.scrollView.backgroundColor = [colors colorForRole:GAPreviewColorBackground];
    [self.grid setNeedsDisplay:YES];
}

- (void)setDocument:(GAFontDocument *)document {
    _document = document;
    // Until this view is first shown, no full GID inventory is needed.
    // Once prepared, retain the existing updates and scroll/highlight behavior.
    if (self.hidden && !self.inventory) return;
    [self updateInventory];
}

- (void)updateInventory {
    NSArray<GAAllGlyphEntry *> *inventory = self.document.allGlyphEntries;
    self.grid.fontBox = self.document.fontBox;
    if (self.inventory != inventory) {
        self.inventory = inventory;
        [self applyVisibleGlyphIDs:nil];
    }
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden && !self.inventory) {
        [self updateInventory];
        if (self.hasPendingGlyphIDs) [self applyVisibleGlyphIDs:self.pendingGlyphIDs];
        self.pendingGlyphIDs = nil;
        self.hasPendingGlyphIDs = NO;
    }
    [super setHidden:hidden];
}

- (void)setVisibleGlyphIDs:(NSIndexSet *)glyphIDs {
    if (self.hidden && !self.inventory) {
        self.pendingGlyphIDs = glyphIDs;
        self.hasPendingGlyphIDs = YES;
        return;
    }
    [self applyVisibleGlyphIDs:glyphIDs];
}

- (void)applyVisibleGlyphIDs:(NSIndexSet *)glyphIDs {
    NSArray<GAAllGlyphEntry *> *inventory = self.inventory ?: @[];
    NSArray<GAAllGlyphEntry *> *entries = inventory;
    if (glyphIDs && self.appliedGlyphIDs && [glyphIDs isEqualToIndexSet:self.appliedGlyphIDs]) {
        // An inventory change clears the filter. Font changes invalidate page
        // metrics separately, even when the filtered entries stay the same.
        entries = self.grid.entries;
    } else if (glyphIDs) {
        NSMutableArray<GAAllGlyphEntry *> *filtered = [NSMutableArray arrayWithCapacity:glyphIDs.count];
        [glyphIDs enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
            if (index >= inventory.count) {
                *stop = YES;
                return;
            }
            [filtered addObject:inventory[index]];
        }];
        entries = filtered;
    }
    self.appliedGlyphIDs = glyphIDs;
    self.grid.entries = entries;
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
}

- (void)setFrameSize:(NSSize)newSize {
    if (self.scrollView == nil || NSEqualSizes(self.frame.size, newSize)) {
        [super setFrameSize:newSize];
        return;
    }
    // Capture before the clip view changes size, and restore after grid reflow.
    GAPreserveScrollPosition(self.scrollView, ^{
        [super setFrameSize:newSize];
        self.needsLayout = YES;
        [self layoutSubtreeIfNeeded];
    });
}

- (void)setScrollsUnderToolbar:(BOOL)enabled {
    GAPreserveScrollPosition(self.scrollView, ^{
        self->_scrollsUnderToolbar = enabled;
        self.needsLayout = YES;
        [self layoutSubtreeIfNeeded];
    });
}

- (void)layout {
    BOOL usesToolbarClearance = self.scrollsUnderToolbar ||
        (self.window.styleMask & NSWindowStyleMaskFullScreen);
    if (self.scrollView.automaticallyAdjustsContentInsets != usesToolbarClearance) {
        self.scrollView.automaticallyAdjustsContentInsets = usesToolbarClearance;
        if (!usesToolbarClearance) self.scrollView.contentInsets = NSEdgeInsetsZero;
        [self.scrollView tile];
    }
    [super layout];
    self.grid.topInset = usesToolbarClearance ? 0 : GAAllGlyphsVerticalMargin;
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
}

- (void)revealGlyphID:(NSNumber *)glyphID quick:(BOOL)quick {
    [self.grid revealGlyph:glyphID quick:quick];
}

- (BOOL)containsGlyphAtWindowPoint:(NSPoint)point {
    point = [self.grid convertPoint:point fromView:nil];
    return NSMouseInRect(point, [self.grid unobscuredVisibleRect], self.grid.isFlipped) &&
           [self.grid indexAtPoint:point] >= 0;
}

- (void)handleMagnification:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.magnificationStartScale = self.cellScale;
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        self.cellScale = self.magnificationStartScale * (1.0 + recognizer.magnification);
    }
}

- (void)setCellScale:(CGFloat)cellScale {
    CGFloat clamped = GAAllGlyphsClampScale(cellScale);
    if (fabs(clamped - _cellScale) < 1e-9) return;
    [self layoutSubtreeIfNeeded];
    GAPreserveScrollPosition(self.scrollView, ^{
        self->_cellScale = clamped;
        self.grid.cellScale = clamped;
        [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
    });
}

- (void)zoomIn {
    self.cellScale = self.cellScale * GAGlyphZoomStep;
}

- (void)zoomOut {
    self.cellScale = self.cellScale / GAGlyphZoomStep;
}

- (void)resetZoom {
    self.cellScale = 1.0;
}

@end
