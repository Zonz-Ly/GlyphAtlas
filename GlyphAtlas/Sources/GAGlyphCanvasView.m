#import "GAGlyphCanvasView.h"

@interface GAGlyphCanvasView ()
@property (nonatomic, strong) NSLayoutGuide *contentGuide;
@end

static const CGFloat GACanvasSideInsetFraction = 0.11;

static NSColor *GACanvasBackgroundColor(void) {
    return [NSColor colorWithName:@"GACanvasBackground"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua]
            ? [NSColor colorWithSRGBRed:(60.0 / 255.0)
                                   green:(60.0 / 255.0)
                                    blue:(60.0 / 255.0)
                                   alpha:1.0]
            : [NSColor whiteColor];
    }];
}

@implementation GAGlyphCanvasView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        self.accessibilityLabel = @"Glyph canvas";

        _contentGuide = [[NSLayoutGuide alloc] init];
        [self addLayoutGuide:_contentGuide];
        [NSLayoutConstraint activateConstraints:@[
            [_contentGuide.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_contentGuide.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_contentGuide.widthAnchor constraintEqualToAnchor:self.widthAnchor
                multiplier:1.0 - 2.0 * GACanvasSideInsetFraction],
            [_contentGuide.heightAnchor constraintEqualToAnchor:self.heightAnchor
                multiplier:1.0 - 2.0 * GACanvasSideInsetFraction],
        ]];
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

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [GACanvasBackgroundColor() setFill];
    NSRectFill(self.bounds);

    GAGlyphVariant *variant = self.variant;
    if (variant == nil) {
        return;
    }

    CTFontRef font = variant.fontBox.font;
    unsigned upem = CTFontGetUnitsPerEm(font);
    if (upem == 0) {
        upem = 1000;
    }

    CGSize advance = [GAFontDocument advanceInFontUnitsForVariant:variant];
    CGFloat widthUnits = advance.width;
    CGFloat heightUnits = advance.height;
    if (widthUnits <= 0 || heightUnits <= 0) {
        CGRect ink = [GAFontDocument inkBoundsForVariant:variant];
        if (widthUnits <= 0) {
            widthUnits = MAX(ink.size.width, upem * 0.01);
        }
        if (heightUnits <= 0) {
            heightUnits = MAX(ink.size.height, (CGFloat)upem);
        }
    }

    NSRect contentRect = self.contentGuide.frame;
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

    CGFloat pageWidth = widthUnits * scale;
    CGFloat pageHeight = heightUnits * scale;
    NSRect page = NSMakeRect(NSMidX(contentRect) - pageWidth * 0.5,
                             NSMidY(contentRect) - pageHeight * 0.5,
                             pageWidth, pageHeight);
    [self drawPageShadowInRect:page];

    NSUInteger count = variant.glyphIDs.count;
    if (count == 0) {
        return;
    }

    CGFloat shapeToUnits = (CGFloat)upem / GAFontShapingSize;
    CGFloat glyphScale = scale * shapeToUnits;

    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    CGPoint *positions = calloc(count, sizeof(CGPoint));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
        CGPoint position = CGPointZero;
        if (index < variant.positions.count) {
            position = variant.positions[index].pointValue;
        }
        positions[index] = position;
    }

    CGFloat baselineUnits;
    if ([GAFontDocument variantHasVerticalMetrics:variant]) {
        CGRect ink = [GAFontDocument inkBoundsForVariant:variant];
        CGFloat inkTopUnits = CGRectIsEmpty(ink) ? 0 : CGRectGetMaxY(ink) * shapeToUnits;
        CGFloat tsb = [GAFontDocument verticalTopSideBearingForVariant:variant];
        baselineUnits = heightUnits - tsb - inkTopUnits;
    } else {
        baselineUnits = CTFontGetDescent(font) * shapeToUnits;
    }

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    // Place the glyph origin baselineUnits above the page bottom.
    // Glyph overhang is intentionally not clipped (bleed).
    CGContextTranslateCTM(context, NSMinX(page),
                          NSMinY(page) + baselineUnits * scale);
    CGContextScaleCTM(context, glyphScale, glyphScale);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetFillColorWithColor(context, [NSColor labelColor].CGColor);
    CTFontDrawGlyphs(font, glyphs, positions, count, context);
    CGContextRestoreGState(context);

    free(glyphs);
    free(positions);
}

- (void)drawPageShadowInRect:(NSRect)page {
    NSString *match = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL darkAppearance = [match isEqualToString:NSAppearanceNameDarkAqua];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [[NSColor blackColor]
        colorWithAlphaComponent:darkAppearance ? 0.58 : 0.18];
    shadow.shadowBlurRadius = 22;
    shadow.shadowOffset = NSMakeSize(0, -8);
    [shadow set];
    [GACanvasBackgroundColor() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:page xRadius:2 yRadius:2] fill];
    [NSGraphicsContext restoreGraphicsState];
}

@end
