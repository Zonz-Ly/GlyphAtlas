#import "GABoundingBoxView.h"

@interface GABoundingBoxView ()
@property (nonatomic) CGFloat magnificationStartPage;
@end

const CGFloat GAGlyphZoomStep = 1.12;
const CGFloat GAGlyphZoomStep10 =
    (GAGlyphZoomStep * GAGlyphZoomStep) *
    (GAGlyphZoomStep * GAGlyphZoomStep) *
    (GAGlyphZoomStep * GAGlyphZoomStep) *
    (GAGlyphZoomStep * GAGlyphZoomStep) *
    (GAGlyphZoomStep * GAGlyphZoomStep);
/// The default page is two zoom-outs from a full page. The maximum inset is
/// the page after twenty more zoom-outs: `0.5 * (1 - 1 / 1.12^22)`.
const CGFloat GABoundingBoxMaxInsetFraction =
    0.5 * (1.0 - 1.0 /
        (GAGlyphZoomStep10 * GAGlyphZoomStep10 *
         GAGlyphZoomStep * GAGlyphZoomStep));
/// Two 1.12× zoom-outs from a bounding box that fills the viewport.
const CGFloat GABoundingBoxDefaultSideInsetFraction =
    0.5 * (1.0 - 1.0 / (GAGlyphZoomStep * GAGlyphZoomStep));
static const CGFloat GABoundingBoxBoundaryMargin = 1.0;
static const CGFloat GABoundingBoxScaleEpsilon = 0.999999;

/// Largest scale at which a page and its ink can share one translation while
/// the page stays in the content inset and the ink stays in the main view.
/// The constraints are linear, so no search is needed.
static CGFloat GAMaxScaleForAxis(CGFloat pageSize,
                                 CGFloat pageMin,
                                 CGFloat pageMax,
                                 CGFloat inkOffset,
                                 CGFloat inkSize,
                                 CGFloat limitMin,
                                 CGFloat limitMax) {
    if (pageSize <= 0) {
        return 0;
    }
    CGFloat maxScale = (pageMax - pageMin) / pageSize;
    if (inkSize > 0) {
        maxScale = MIN(maxScale, (limitMax - limitMin) / inkSize);
    }
    // The ink's far edge and the page's far edge must both fit after the
    // shared translation. Each condition is linear in the scale.
    CGFloat inkLimit = limitMax - pageMin;
    CGFloat inkCoefficient = inkOffset + inkSize;
    if (inkLimit < 0) {
        return 0;
    }
    if (inkCoefficient > 0) {
        maxScale = MIN(maxScale, inkLimit / inkCoefficient);
    }
    CGFloat pageLimit = pageMax - limitMin;
    CGFloat pageCoefficient = pageSize - inkOffset;
    if (pageLimit < 0) {
        return 0;
    }
    if (pageCoefficient > 0) {
        maxScale = MIN(maxScale, pageLimit / pageCoefficient);
    }
    return MAX(0, maxScale);
}

CGFloat GAClampSideInsetFraction(CGFloat fraction) {
    return MIN(GABoundingBoxMaxInsetFraction, MAX(0.0, fraction));
}

CGFloat GABoundingBoxPageFractionForMagnification(CGFloat startPage, CGFloat magnification) {
    CGFloat minimum = 1.0 - 2.0 * GABoundingBoxMaxInsetFraction;
    return MIN(1.0, MAX(minimum, startPage * (1.0 + magnification)));
}

NSRect GAInsetRectByFraction(NSRect rect, CGFloat fraction) {
    CGFloat insetX = NSWidth(rect) * fraction;
    CGFloat insetY = NSHeight(rect) * fraction;
    return NSInsetRect(rect, insetX, insetY);
}

// Ask the clip view for its actual limits, including any content insets.
// The views use custom content sizing rather than NSScrollView magnification.
static NSRect GAScrollPositionLimits(NSScrollView *scrollView) {
    NSClipView *clip = scrollView.contentView;
    NSRect document = scrollView.documentView.frame;
    NSRect proposed = clip.bounds;
    proposed.origin = NSMakePoint(NSMinX(document) - NSWidth(proposed),
                                  NSMinY(document) - NSHeight(proposed));
    NSPoint minimum = [clip constrainBoundsRect:proposed].origin;
    proposed.origin = NSMakePoint(NSMaxX(document), NSMaxY(document));
    NSPoint maximum = [clip constrainBoundsRect:proposed].origin;
    return NSMakeRect(minimum.x, minimum.y, MAX(0, maximum.x - minimum.x),
                       MAX(0, maximum.y - minimum.y));
}

static NSPoint GACaptureScrollPosition(NSScrollView *scrollView) {
    NSRect bounds = scrollView.contentView.bounds;
    if (scrollView.documentView == nil || NSWidth(bounds) <= 0 || NSHeight(bounds) <= 0)
        return NSMakePoint(0.5, 0.5);
    NSRect limits = GAScrollPositionLimits(scrollView);
    return NSMakePoint(NSWidth(limits) > 0.5
                           ? MIN(1, MAX(0, (NSMinX(bounds) - NSMinX(limits)) / NSWidth(limits))) : 0.5,
                       NSHeight(limits) > 0.5
                           ? MIN(1, MAX(0, (NSMinY(bounds) - NSMinY(limits)) / NSHeight(limits))) : 0.5);
}

static void GARestoreScrollPosition(NSScrollView *scrollView, NSPoint position) {
    if (scrollView.documentView == nil) return;
    [scrollView layoutSubtreeIfNeeded];
    NSClipView *clip = scrollView.contentView;
    if (NSWidth(clip.bounds) <= 0 || NSHeight(clip.bounds) <= 0) return;
    NSRect limits = GAScrollPositionLimits(scrollView);
    NSRect proposed = clip.bounds;
    proposed.origin = NSMakePoint(NSMinX(limits) + MIN(1, MAX(0, position.x)) * NSWidth(limits),
                                  NSMinY(limits) + MIN(1, MAX(0, position.y)) * NSHeight(limits));
    [clip scrollToPoint:[clip constrainBoundsRect:proposed].origin];
    [scrollView reflectScrolledClipView:clip];
}

void GAPreserveScrollPosition(NSScrollView *scrollView, void (^changes)(void)) {
    NSPoint position = GACaptureScrollPosition(scrollView);
    changes();
    GARestoreScrollPosition(scrollView, position);
}

static BOOL GAAppearanceIsDark(NSAppearance *appearance) {
    NSString *match = [appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

void GADrawPage(NSRect page, NSAppearance *appearance) {
    BOOL darkAppearance = GAAppearanceIsDark(appearance);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [[NSColor blackColor]
        colorWithAlphaComponent:darkAppearance ? 0.58 : 0.18];
    shadow.shadowBlurRadius = 22;
    shadow.shadowOffset = NSMakeSize(0, -8);
    [shadow set];
    [GABoundingBoxBackgroundColor() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:page xRadius:2 yRadius:2] fill];
    [NSGraphicsContext restoreGraphicsState];
}

NSColor *GABoundingBoxBackgroundColor(void) {
    return [NSColor colorWithName:@"GABoundingBoxBackground"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return GAAppearanceIsDark(appearance)
            ? [NSColor colorWithSRGBRed:(60.0 / 255.0)
                                   green:(60.0 / 255.0)
                                    blue:(60.0 / 255.0)
                                   alpha:1.0]
            : [NSColor whiteColor];
    }];
}

NSColor *GAGlyphForegroundColor(void) {
    return [NSColor colorWithName:@"GAGlyphForeground"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        CGFloat component = GAAppearanceIsDark(appearance)
            ? (0xEE / 255.0) : (0x22 / 255.0);
        return [NSColor colorWithSRGBRed:component
                                   green:component
                                    blue:component
                                   alpha:1.0];
    }];
}

@implementation GABoundingBoxView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        self.accessibilityLabel = NSLocalizedString(@"Bounding Box", @"Bounding Box");

        _sideInsetFraction = GABoundingBoxDefaultSideInsetFraction;
        _showsMetrics = YES;
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

- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}

- (void)setVariant:(GAGlyphVariant *)variant {
    _variant = variant;
    [self setNeedsDisplay:YES];
}

- (void)setSideInsetFraction:(CGFloat)sideInsetFraction {
    CGFloat clamped = GAClampSideInsetFraction(sideInsetFraction);
    if (fabs(clamped - _sideInsetFraction) < 1e-9) {
        return;
    }
    GAPreserveScrollPosition(self.enclosingScrollView, ^{
        self->_sideInsetFraction = clamped;
        [self setNeedsDisplay:YES];
        if (self.onSideInsetFractionChanged) {
            self.onSideInsetFractionChanged(clamped);
        }
    });
}

- (void)setShowsMetrics:(BOOL)showsMetrics {
    _showsMetrics = showsMetrics;
    [self setNeedsDisplay:YES];
}

- (void)handleMagnification:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        self.magnificationStartPage = 1.0 - 2.0 * self.sideInsetFraction;
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        // 1:1 with the gesture, like system zooming views.
        CGFloat page = GABoundingBoxPageFractionForMagnification(
            self.magnificationStartPage, recognizer.magnification);
        self.sideInsetFraction = (1.0 - page) * 0.5;
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [GABoundingBoxBackgroundColor() setFill];
    NSRectFill(self.bounds);

    GAGlyphVariant *variant = self.variant;
    if (variant == nil) {
        return;
    }

    CTFontRef font = variant.fontBox.font;
    CGFloat shapeToUnits = CTFontGetUnitsPerEm(font) / GAFontShapingSize;

    GAGlyphPage glyphPage = [GAFontDocument pageForVariant:variant
                                       usesVerticalMetrics:YES];
    CGRect ink = glyphPage.ink;
    BOOL hasInk = !CGRectIsEmpty(ink);
    CGFloat widthUnits = glyphPage.size.width;
    CGFloat heightUnits = glyphPage.size.height;
    CGFloat baselineUnits = glyphPage.baseline;

    NSRect contentRect = GAInsetRectByFraction(self.bounds, self.sideInsetFraction);
    if (NSIsEmptyRect(contentRect)) {
        contentRect = NSInsetRect(self.bounds, 80.0, 80.0);
    }
    CGFloat availableWidth = MAX(1.0, NSWidth(contentRect));
    CGFloat availableHeight = MAX(1.0, NSHeight(contentRect));

    CGFloat scale = MIN(availableWidth / MAX(widthUnits, 0.001),
                        availableHeight / MAX(heightUnits, 0.001));
    if (!isfinite(scale) || scale <= 0) {
        return;
    }

    NSRect glyphLimit = self.bounds;
    NSView *contentView = self.window.contentView;
    if (contentView != nil) {
        NSRect windowRect = [self convertRect:contentView.bounds
                                      fromView:contentView];
        NSRect intersection = NSIntersectionRect(self.bounds, windowRect);
        if (!NSIsEmptyRect(intersection)) {
            glyphLimit = intersection;
        }
    }
    glyphLimit = NSInsetRect(glyphLimit, GABoundingBoxBoundaryMargin,
                             GABoundingBoxBoundaryMargin);

    BOOL (^translationForScale)(CGFloat, CGFloat *, CGFloat *) =
        ^BOOL(CGFloat candidateScale, CGFloat *outX, CGFloat *outY) {
        CGFloat candidatePageWidth = widthUnits * candidateScale;
        CGFloat candidatePageHeight = heightUnits * candidateScale;
        CGFloat candidatePageX = NSMidX(contentRect) - candidatePageWidth * 0.5;
        CGFloat candidatePageY = NSMidY(contentRect) - candidatePageHeight * 0.5;
        NSRect candidatePage = NSMakeRect(candidatePageX, candidatePageY,
                                          candidatePageWidth, candidatePageHeight);

        // The page stays inside the current content inset; the ink may use the
        // full main view, so the two constraints produce a shared shift range.
        CGFloat minX = NSMinX(contentRect) - NSMinX(candidatePage);
        CGFloat maxX = NSMaxX(contentRect) - NSMaxX(candidatePage);
        CGFloat minY = NSMinY(contentRect) - NSMinY(candidatePage);
        CGFloat maxY = NSMaxY(contentRect) - NSMaxY(candidatePage);

        if (hasInk) {
            NSRect candidateInk = NSMakeRect(
                candidatePageX + CGRectGetMinX(ink) * candidateScale,
                candidatePageY + baselineUnits * candidateScale +
                    CGRectGetMinY(ink) * candidateScale,
                CGRectGetWidth(ink) * candidateScale,
                CGRectGetHeight(ink) * candidateScale);
            minX = MAX(minX, NSMinX(glyphLimit) - NSMinX(candidateInk));
            maxX = MIN(maxX, NSMaxX(glyphLimit) - NSMaxX(candidateInk));
            minY = MAX(minY, NSMinY(glyphLimit) - NSMinY(candidateInk));
            maxY = MIN(maxY, NSMaxY(glyphLimit) - NSMaxY(candidateInk));
        }

        if (minX > maxX || minY > maxY) {
            return NO;
        }
        CGFloat shiftX = 0;
        if (shiftX < minX) {
            shiftX = minX;
        } else if (shiftX > maxX) {
            shiftX = maxX;
        }
        CGFloat shiftY = 0;
        if (shiftY < minY) {
            shiftY = minY;
        } else if (shiftY > maxY) {
            shiftY = maxY;
        }
        *outX = shiftX;
        *outY = shiftY;
        return YES;
    };

    if (hasInk) {
        CGFloat constrainedScale = MIN(scale, GAMaxScaleForAxis(
            widthUnits, NSMinX(contentRect), NSMaxX(contentRect),
            CGRectGetMinX(ink),
            CGRectGetWidth(ink),
            NSMinX(glyphLimit), NSMaxX(glyphLimit)));
        constrainedScale = MIN(constrainedScale, GAMaxScaleForAxis(
            heightUnits, NSMinY(contentRect), NSMaxY(contentRect),
            baselineUnits + CGRectGetMinY(ink),
            CGRectGetHeight(ink),
            NSMinY(glyphLimit), NSMaxY(glyphLimit)));
        if (constrainedScale <= 0) {
            return;
        }
        // Numerical slack only; the visible 1pt margin is the glyph limit inset.
        scale = constrainedScale * GABoundingBoxScaleEpsilon;
    }

    CGFloat shiftX;
    CGFloat shiftY;
    if (!translationForScale(scale, &shiftX, &shiftY)) {
        return;
    }

    CGFloat pageWidth = widthUnits * scale;
    CGFloat pageHeight = heightUnits * scale;
    CGFloat pageX = NSMidX(contentRect) - pageWidth * 0.5 + shiftX;
    CGFloat pageY = NSMidY(contentRect) - pageHeight * 0.5 + shiftY;
    NSRect page = NSMakeRect(pageX, pageY, pageWidth, pageHeight);
    CGFloat glyphScale = scale * shapeToUnits;

    if (self.showsMetrics) {
        GADrawPage(page, self.effectiveAppearance);
    }

    NSUInteger count = variant.glyphIDs.count;
    if (count == 0) {
        return;
    }

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    // The page keeps its metric size; the baseline comes from the font metrics.
    CGContextTranslateCTM(context, pageX, pageY + baselineUnits * scale);
    CGContextScaleCTM(context, glyphScale, glyphScale);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetFillColorWithColor(context, GAGlyphForegroundColor().CGColor);
    GADrawGlyphVariant(variant, context);
    CGContextRestoreGState(context);
}

@end
