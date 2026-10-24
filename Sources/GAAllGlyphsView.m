#import "GAAllGlyphsView.h"
#import "GAGlyphCanvasView.h"

static const CGFloat GAAllGlyphsMargin = 14.0;
static const CGFloat GAAllGlyphsGap = 8.0;
static const CGFloat GAAllGlyphsBaseCell = 44.0;
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
/// Extra space above the first row so it clears the window titlebar.
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
        _entries = @[];
        _cellScale = 1.0;
        _columns = 1;
        _highlightIndex = NSNotFound;
        _pageMetrics = [NSMutableData dataWithLength:0];
        _pageMetricsValid = [NSMutableData dataWithLength:0];
    }
    return self;
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

- (CGFloat)minimumHeight {
    if (self.enclosingScrollView == nil) {
        return 0;
    }
    return self.enclosingScrollView.contentSize.height;
}

- (void)updateLayoutForWidth:(CGFloat)width {
    if (width < 1) {
        return;
    }
    CGFloat cell = self.cellSide;
    CGFloat usable = MAX(cell, width - 2 * GAAllGlyphsMargin);
    self.columns = MAX(1, (NSUInteger)floor((usable + GAAllGlyphsGap) /
                                           (cell + GAAllGlyphsGap)));
    NSUInteger rows = self.entries.count == 0
        ? 0
        : (self.entries.count + self.columns - 1) / self.columns;
    CGFloat height = self.topInset + 2 * GAAllGlyphsMargin + rows * cell +
        MAX(0, (NSInteger)rows - 1) * GAAllGlyphsGap;
    CGFloat minimum = [self minimumHeight];
    CGFloat target = MAX(height, minimum >= 1 ? minimum : 0);
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
    return MAX(GAAllGlyphsMargin, (NSWidth(self.bounds) - used) * 0.5);
}

- (NSRect)rectForIndex:(NSUInteger)index {
    CGFloat cell = self.cellSide;
    CGFloat stride = cell + GAAllGlyphsGap;
    return NSMakeRect([self contentLeft] + (index % self.columns) * stride,
                      self.topInset + GAAllGlyphsMargin + (index / self.columns) * stride,
                      cell, cell);
}

- (NSInteger)indexAtPoint:(NSPoint)point {
    CGFloat cell = self.cellSide;
    CGFloat stride = cell + GAAllGlyphsGap;
    CGFloat x = point.x - [self contentLeft];
    CGFloat y = point.y - self.topInset - GAAllGlyphsMargin;
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
    NSUInteger index = NSNotFound;
    for (NSUInteger candidate = 0; candidate < self.entries.count; candidate++) {
        if ([self.entries[candidate].glyphID isEqualToNumber:glyphID]) {
            index = candidate;
            break;
        }
    }
    if (index == NSNotFound) {
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
        // The old cell was only invalidated while it was the active highlight.
        // Repaint it now so its last faded pixels do not stay on screen.
        [self setNeedsDisplayInRect:[self rectForIndex:previous]];
    }
    NSRect rect = [self rectForIndex:index];
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
    NSRect rect = [self rectForIndex:self.highlightIndex];
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
        self.highlightAppendStyle = NO;
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
    [GACanvasBackgroundColor() setFill];
    NSRectFill(self.bounds);
    if (self.entries.count == 0 || self.fontBox == nil) {
        return;
    }
    CTFontRef font = self.fontBox.font;
    CGFloat cell = self.cellSide;
    CGFloat upem = CTFontGetUnitsPerEm(font);
    CGFloat unitScale = cell * 0.85 / upem;
    CGFloat glyphScale = cell * 0.85 / GAFontShapingSize;
    GAGlyphPage *pageMetrics = self.pageMetrics.mutableBytes;
    uint8_t *pageMetricsValid = self.pageMetricsValid.mutableBytes;
    NSRect visible = self.visibleRect;
    CGFloat stride = cell + GAAllGlyphsGap;
    CGFloat contentTop = self.topInset + GAAllGlyphsMargin;
    NSUInteger firstRow = NSMinY(visible) <= contentTop
        ? 0 : (NSUInteger)MAX(0.0, floor((NSMinY(visible) - contentTop) / stride));
    NSUInteger lastRow = (NSUInteger)MAX(0.0, floor((NSMaxY(visible) - contentTop) / stride));
    NSUInteger firstIndex = MIN(self.entries.count, firstRow * self.columns);
    NSUInteger lastIndex = MIN(self.entries.count, (lastRow + 1) * self.columns);
    NSColor *glyphColor = GAGlyphForegroundColor();
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetFillColorWithColor(context, glyphColor.CGColor);

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
        if (!pageMetricsValid[index]) {
            // Reuse the single-glyph page metric for one GID. It is cached per
            // entry because the table reads are not free.
            GAGlyphVariant *probe = [[GAGlyphVariant alloc] init];
            probe.fontBox = self.fontBox;
            probe.glyphIDs = @[entry.glyphID];
            pageMetrics[index] = [GAFontDocument pageForVariant:probe];
            pageMetricsValid[index] = 1;
        }
        GAGlyphPage page = pageMetrics[index];
        if (CGRectIsEmpty(page.ink)) {
            continue;
        }
        CGGlyph glyph = (CGGlyph)entry.glyphID.unsignedShortValue;
        NSRect cellRect = [self rectForIndex:index];
        // Centre the definition page (advance width × page height), not the
        // ink. The baseline then follows the same metrics as the single-glyph
        // canvas.
        CGFloat pageWidth = page.size.width * unitScale;
        CGFloat pageHeight = page.size.height * unitScale;
        CGFloat pageX = NSMidX(cellRect) - pageWidth * 0.5;
        CGFloat pageY = NSMidY(cellRect) - pageHeight * 0.5;
        CGFloat baselineY = pageY + (page.size.height - page.baseline) * unitScale;
        CGPoint origin = CGPointMake(pageX, baselineY);
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
        _scrollView.backgroundColor = GACanvasBackgroundColor();
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
    _document = document;
    self.grid.entries = document != nil ? [document allGlyphEntries] : @[];
    self.grid.fontBox = document.fontBox;
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
    [self.grid scrollPoint:NSZeroPoint];
    [self.grid setNeedsDisplay:YES];
}

- (void)layout {
    [super layout];
    // Push the grid down by exactly the part of the title bar that would
    // otherwise cover the first row: the top margin already covers the rest.
    self.grid.topInset = MAX(0, self.safeAreaInsets.top - GAAllGlyphsMargin);
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
}

- (void)revealGlyphID:(NSNumber *)glyphID quick:(BOOL)quick {
    [self.grid revealGlyph:glyphID quick:quick];
}

- (void)handleMagnification:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.magnificationStartScale = self.cellScale;
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        self.cellScale = GAAllGlyphsClampScale(
            self.magnificationStartScale * (1.0 + recognizer.magnification));
    }
}

- (void)setCellScale:(CGFloat)cellScale {
    _cellScale = cellScale;
    self.grid.cellScale = cellScale;
    [self.grid updateLayoutForWidth:NSWidth(self.bounds)];
}

- (void)zoomIn {
    self.cellScale = GAAllGlyphsClampScale(self.cellScale * GAGlyphZoomStep);
}

- (void)zoomOut {
    self.cellScale = GAAllGlyphsClampScale(self.cellScale / GAGlyphZoomStep);
}

- (void)resetZoom {
    self.cellScale = 1.0;
}

@end
