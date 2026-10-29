#import "GAAllGlyphsView.h"
#import "GABoundingBoxView.h"

static const CGFloat GAAllGlyphsSideMargin = 14.0;
static const CGFloat GAAllGlyphsVerticalMargin = 18.0;
static const CGFloat GAAllGlyphsGap = 8.0;
static const CGFloat GAAllGlyphsBaseCell = 44.0;
static const CGFloat GAAllGlyphsGlyphRatio = 0.85;
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
@property (nonatomic, copy) NSArray<GAAllGlyphEntry *> *entries;
@property (nonatomic, strong, nullable) GAFontBox *fontBox;
/// Lazily computed GAGlyphPage per entry, and one validity byte per entry.
@property (nonatomic, strong) NSMutableData *pageMetrics;
@property (nonatomic, strong) NSMutableData *pageMetricsValid;
@property (nonatomic) CGFloat cellScale;
@property (nonatomic) NSUInteger columns;
/// Top spacing before the first row; full screen uses titlebar clearance.
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

@synthesize entries = _entries;
@synthesize fontBox = _fontBox;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
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
    _entries = [entries copy];
    _pageMetrics = [NSMutableData dataWithLength:_entries.count * sizeof(GAGlyphPage)];
    _pageMetricsValid = [NSMutableData dataWithLength:_entries.count];
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
    self.columns = MAX(1, (NSUInteger)floor((usable + GAAllGlyphsGap) /
                                           (cell + GAAllGlyphsGap)));
    NSUInteger rows = self.entries.count == 0
        ? 0
        : (self.entries.count + self.columns - 1) / self.columns;
    CGFloat height = self.topInset + GAAllGlyphsVerticalMargin + rows * cell +
        MAX(0, (NSInteger)rows - 1) * GAAllGlyphsGap;
    NSScrollView *scrollView = self.enclosingScrollView;
    CGFloat minimum = scrollView != nil ? scrollView.contentSize.height : 0;
    CGFloat target = MAX(height, minimum);
    NSSize current = self.frame.size;
    if (fabs(current.width - width) > 0.5 || fabs(current.height - target) > 0.5) {
        self.frame = NSMakeRect(0, 0, width, target);
        [self setNeedsDisplay:YES];
    }
}

- (CGFloat)contentLeft {
    CGFloat cell = self.cellSide;
    CGFloat used = self.columns * cell +
        MAX(0, (NSInteger)self.columns - 1) * GAAllGlyphsGap;
    return MAX(GAAllGlyphsSideMargin, (NSWidth(self.bounds) - used) * 0.5);
}

- (NSRect)rectForIndex:(NSUInteger)index {
    CGFloat cell = self.cellSide;
    CGFloat stride = cell + GAAllGlyphsGap;
    return NSMakeRect([self contentLeft] + (index % self.columns) * stride,
                      self.topInset + (index / self.columns) * stride,
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
    NSRect ink = NSMakeRect(origin.x + CGRectGetMinX(page.ink) * unitScale,
                             origin.y - CGRectGetMaxY(page.ink) * unitScale,
                             CGRectGetWidth(page.ink) * unitScale,
                             CGRectGetHeight(page.ink) * unitScale);
    return NSInsetRect(ink, -2.0, -2.0);
}

- (NSInteger)indexAtPoint:(NSPoint)point {
    CGFloat cell = self.cellSide;
    CGFloat stride = cell + GAAllGlyphsGap;
    CGFloat x = point.x - [self contentLeft];
    CGFloat y = point.y - self.topInset;
    if (x < 0 || y < 0) {
        return -1;
    }
    NSUInteger column = (NSUInteger)floor(x / stride);
    NSUInteger row = (NSUInteger)floor(y / stride);
    if (column >= self.columns) {
        return -1;
    }
    // The gap between cells is dead space, not part of the neighbouring cell.
    if (x - column * stride > cell || y - row * stride > cell) {
        return -1;
    }
    NSUInteger index = row * self.columns + column;
    return index < self.entries.count ? (NSInteger)index : -1;
}

- (void)revealGlyph:(NSNumber *)glyphID quick:(BOOL)quick {
    // The complete inventory is in GID order, so each GID is its entry index.
    NSUInteger index = glyphID.unsignedIntegerValue;
    if (index >= self.entries.count) {
        return;
    }
    NSRect row = [self rectForIndex:index];
    if (NSIntersectsRect(row, self.visibleRect)) {
        [self scrollRectToVisible:NSInsetRect(row, -4, -4)];
    } else {
        [self centerRow:row];
    }
    [self flashIndex:index quick:quick];
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
    CGFloat y = NSMidY(row) - NSHeight(viewport) * 0.5;
    CGFloat maximum = MAX(0, NSHeight(self.bounds) - NSHeight(viewport));
    y = MIN(MAX(0, y), maximum);
    [clipView scrollToPoint:NSMakePoint(NSMinX(viewport), y)];
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
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = [self indexAtPoint:point];
    if (index >= 0 && event.clickCount == 2 && self.onDoubleClick != nil) {
        self.onDoubleClick(self.entries[(NSUInteger)index]);
    }
    [self.window performWindowDragWithEvent:event];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [GABoundingBoxBackgroundColor() setFill];
    NSRectFill(self.bounds);
    if (self.entries.count == 0 || self.fontBox == nil) {
        return;
    }
    CTFontRef font = self.fontBox.font;
    CGFloat cell = self.cellSide;
    CGFloat upem = CTFontGetUnitsPerEm(font);
    CGFloat unitScale = cell * GAAllGlyphsGlyphRatio / upem;
    CGFloat glyphScale = cell * GAAllGlyphsGlyphRatio / GAFontShapingSize;
    NSRect visible = self.visibleRect;
    CGFloat stride = cell + GAAllGlyphsGap;
    CGFloat contentTop = self.topInset;
    NSUInteger firstRow = NSMinY(visible) <= contentTop
        ? 0 : (NSUInteger)MAX(0.0, floor((NSMinY(visible) - contentTop) / stride));
    NSUInteger lastRow = (NSUInteger)MAX(0.0, floor((NSMaxY(visible) - contentTop) / stride));
    NSUInteger firstIndex = MIN(self.entries.count, firstRow * self.columns);
    NSUInteger lastIndex = MIN(self.entries.count, (lastRow + 1) * self.columns);
    NSColor *glyphColor = GAGlyphForegroundColor();
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;

    for (NSUInteger index = firstIndex; index < lastIndex; index++) {
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
        GAGlyphPage page = [self pageForIndex:index];
        if (CGRectIsEmpty(page.ink)) {
            continue;
        }
        CGGlyph glyph = (CGGlyph)entry.glyphID.unsignedShortValue;
        CGPoint origin = [self glyphOriginForIndex:index page:page unitScale:unitScale];
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, origin.x, origin.y);
        CGContextScaleCTM(context, glyphScale, -glyphScale);
        CTFontDrawGlyphs(font, &glyph, &(CGPoint){0, 0}, 1, context);
        CGContextRestoreGState(context);
    }
}

@end

@interface GAAllGlyphsView ()
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) GAAllGlyphsGrid *grid;
@property (nonatomic) CGFloat cellScale;
@property (nonatomic) CGFloat magnificationStartScale;
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

- (void)setDocument:(GAFontDocument *)document {
    // Each window owns one resource. Its inventory is installed once; axis
    // changes only invalidate font-dependent metrics and drawing.
    if (_document == nil && document != nil) {
        self.grid.entries = [document allGlyphEntries];
        [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
    }
    _document = document;
    self.grid.fontBox = document.fontBox;
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

- (void)layout {
    [super layout];
    // Full screen uses the titlebar clearance directly instead of the margin.
    self.grid.topInset = (self.window.styleMask & NSWindowStyleMaskFullScreen)
        ? self.safeAreaInsets.top : GAAllGlyphsVerticalMargin;
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
}

- (void)revealGlyphID:(NSNumber *)glyphID quick:(BOOL)quick {
    [self.grid revealGlyph:glyphID quick:quick];
}

- (BOOL)containsGlyphAtWindowPoint:(NSPoint)point {
    point = [self.grid convertPoint:point fromView:nil];
    return NSMouseInRect(point, self.grid.visibleRect, self.grid.isFlipped) &&
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
