#import "GAGlyphViews.h"
#import "GAFontEngine.h"
#import "GAUnicode.h"

static const CGFloat GAVariantNameHeight = 16.0;
static const CGFloat GAVariantVerticalPadding = 5.0;
static const CGFloat GAGlyphSide = 34.0;
// Source-list rows add 6 pt of system content inset, so 4 pt here yields a
// 10 pt visible inset from the sidebar edge.
static const CGFloat GAVariantHorizontalInset = 4.0;
static const CGFloat GACodeLineHeight = 13.0;

#pragma mark - Glyph view

/// Draws only the glyph itself. Native table rows provide selection and
/// background; this view deliberately does not draw chrome.
@interface GAGlyphView : NSView
@property (nonatomic, strong, nullable) GAGlyphVariant *variant;
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle;
@end

@implementation GAGlyphView {
    NSBackgroundStyle _backgroundStyle;
    GAGlyphPage _glyphPage;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:GAGlyphSide],
            [self.heightAnchor constraintEqualToConstant:GAGlyphSide],
        ]];
    }
    return self;
}

- (void)setVariant:(GAGlyphVariant *)variant {
    _variant = variant;
    if (variant != nil) {
        _glyphPage = [GAFontDocument pageForVariant:variant
                                 usesVerticalMetrics:NO];
    }
    [self setNeedsDisplay:YES];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    _backgroundStyle = backgroundStyle;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.variant == nil) {
        return;
    }
    NSColor *color = _backgroundStyle == NSBackgroundStyleEmphasized
        ? [NSColor alternateSelectedControlTextColor]
        : [NSColor labelColor];

    GAGlyphVariant *variant = self.variant;
    NSUInteger count = variant.glyphIDs.count;
    if (count == 0 || CGRectIsEmpty(_glyphPage.ink)) {
        return;
    }

    CGFloat side = MAX(1.0, MIN(NSWidth(self.bounds), NSHeight(self.bounds)) - 2.0);
    // The glyph size stays real relative to the em; the page metric only
    // decides where the advance box and baseline sit inside the icon.
    CGFloat scale = side / GAFontShapingSize;
    CGFloat unitScale = side / MAX(1.0, CTFontGetUnitsPerEm(variant.fontBox.font));
    CGFloat pageWidth = _glyphPage.size.width * unitScale;
    CGFloat pageHeight = _glyphPage.size.height * unitScale;
    CGFloat originX = NSMidX(self.bounds) - pageWidth * 0.5;
    CGFloat originY = NSMidY(self.bounds) - pageHeight * 0.5 +
        _glyphPage.baseline * unitScale;

    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    // Work around right-edge clipping in PingFang UI SC variable-font previews.
    // Fill before every glyph draw: a one-time fill did not prevent later clipping.
    // Transparent Source Over preserves the native row background.
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGContextSetFillColorWithColor(context, NSColor.clearColor.CGColor);
    CGContextFillRect(context, dirtyRect);
    CGContextRestoreGState(context);

    CGContextSaveGState(context);
    CGContextTranslateCTM(context, originX, originY);
    CGContextScaleCTM(context, scale, scale);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetFillColorWithColor(context, color.CGColor);
    GADrawGlyphVariant(variant, context);
    CGContextRestoreGState(context);
}

@end

#pragma mark - Unicode badges

static const CGFloat GABadgeHeight = 16.0;
static const CGFloat GABadgeGap = 3.0;
static const CGFloat GABadgeHorizontalPadding = 4.0;

@interface GAUnicodeBadgeView : NSView
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic) NSBackgroundStyle backgroundStyle;
- (instancetype)initWithText:(NSString *)text toolTip:(NSString *)toolTip;
+ (CGFloat)widthForText:(NSString *)text;
@end

@implementation GAUnicodeBadgeView

- (instancetype)initWithText:(NSString *)text toolTip:(NSString *)toolTip {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _text = [text copy];
        self.toolTip = toolTip.length > 0 ? toolTip : text;
        _backgroundStyle = NSBackgroundStyleRaised;
    }
    return self;
}

+ (CGFloat)widthForText:(NSString *)text {
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
                                                              weight:NSFontWeightRegular],
    };
    return ceil([text sizeWithAttributes:attributes].width) +
           GABadgeHorizontalPadding * 2;
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    _backgroundStyle = backgroundStyle;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL emphasized = self.backgroundStyle == NSBackgroundStyleEmphasized;
    NSColor *background = emphasized
        ? [[NSColor alternateSelectedControlTextColor] colorWithAlphaComponent:0.16]
        : [[NSColor labelColor] colorWithAlphaComponent:0.07];
    NSColor *foreground = emphasized
        ? [NSColor alternateSelectedControlTextColor]
        : [NSColor secondaryLabelColor];

    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                        xRadius:4
                                                        yRadius:4];
    [background setFill];
    [path fill];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByClipping;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
                                                              weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: foreground,
        NSParagraphStyleAttributeName: paragraph,
    };
    NSSize textSize = [self.text sizeWithAttributes:attributes];
    NSRect textRect = NSMakeRect(0,
                                 floor((NSHeight(self.bounds) - textSize.height) / 2.0),
                                 NSWidth(self.bounds),
                                 textSize.height);
    [self.text drawInRect:textRect withAttributes:attributes];
}

@end

/// A vertical column of Unicode code badges. Each badge has its own
/// tooltip with that scalar's Unicode name.
@interface GAUnicodeCodesView : NSView
@property (nonatomic, copy, nonnull) NSArray<NSNumber *> *unicodeScalars;
+ (CGFloat)heightForScalars:(NSArray<NSNumber *> * _Nonnull)scalars;
+ (CGFloat)widthForScalars:(NSArray<NSNumber *> * _Nonnull)scalars;
@property (nonatomic, strong) NSMutableArray<GAUnicodeBadgeView *> *labels;
@property (nonatomic) NSBackgroundStyle backgroundStyle;
@end

@implementation GAUnicodeCodesView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _labels = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

+ (NSString *)codeTextForScalar:(uint32_t)scalar {
    return [NSString stringWithFormat:@"%04X", scalar];
}

- (void)setUnicodeScalars:(NSArray<NSNumber *> *)unicodeScalars {
    _unicodeScalars = [unicodeScalars copy] ?: @[];

    for (GAUnicodeBadgeView *badge in self.labels) {
        [badge removeFromSuperview];
    }
    [self.labels removeAllObjects];

    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (NSNumber *scalarNumber in _unicodeScalars) {
        uint32_t scalar = scalarNumber.unsignedIntValue;
        NSString *text = [self.class codeTextForScalar:scalar];
        [codes addObject:text];
        NSString *name = GAUnicodeNameForScalar(scalar);
        GAUnicodeBadgeView *badge = [[GAUnicodeBadgeView alloc]
            initWithText:text toolTip:name];
        badge.backgroundStyle = self.backgroundStyle;
        [self addSubview:badge];
        [self.labels addObject:badge];
    }
    self.accessibilityLabel = [codes componentsJoinedByString:@", "];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    _backgroundStyle = backgroundStyle;
    for (GAUnicodeBadgeView *badge in self.labels) {
        badge.backgroundStyle = backgroundStyle;
    }
}

- (void)layout {
    [super layout];
    CGFloat y = 0;
    CGFloat width = MAX(1.0, self.bounds.size.width);
    for (GAUnicodeBadgeView *badge in self.labels) {
        CGFloat badgeWidth = [GAUnicodeBadgeView widthForText:badge.text];
        badge.frame = NSMakeRect(width - badgeWidth, y, badgeWidth, GABadgeHeight);
        y += GABadgeHeight + GABadgeGap;
    }
}

+ (CGFloat)heightForScalars:(NSArray<NSNumber *> *)scalars {
    if (scalars.count == 0) {
        return 0;
    }
    return scalars.count * GABadgeHeight + (scalars.count - 1) * GABadgeGap;
}

+ (CGFloat)widthForScalars:(NSArray<NSNumber *> *)scalars {
    CGFloat width = 0;
    for (NSNumber *scalarNumber in scalars) {
        NSString *text = [self codeTextForScalar:scalarNumber.unsignedIntValue];
        width = MAX(width, [GAUnicodeBadgeView widthForText:text]);
    }
    return width;
}

@end

#pragma mark - Variant row

@interface GAVariantCellView ()
@property (nonatomic, strong) GAGlyphView *glyphView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) GAUnicodeCodesView *codesView;
@property (nonatomic, strong) NSLayoutConstraint *nameTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sourceTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sourceHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *codesWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *codesHeightConstraint;
- (void)applyBackgroundStyle:(NSBackgroundStyle)backgroundStyle;
@end

@implementation GAVariantCellView

+ (CGFloat)sourceHeightForVariant:(GAGlyphVariant *)variant {
    return variant.featureSources.count > 0 ? GACodeLineHeight : 0;
}

+ (CGFloat)nameBlockHeightForVariant:(GAGlyphVariant *)variant {
    CGFloat nameHeight = GAVariantNameHeight;
    if (variant.featureSources.count > 0) {
        nameHeight += 1.0 + [self sourceHeightForVariant:variant];
    }
    return nameHeight;
}

+ (CGFloat)rowHeightForVariant:(GAGlyphVariant *)variant {
    CGFloat nameHeight = [self nameBlockHeightForVariant:variant];
    CGFloat codeHeight = [GAUnicodeCodesView heightForScalars:variant.unicodeScalars];
    CGFloat contentHeight = MAX(nameHeight, codeHeight);
    return MAX(44.0, contentHeight + GAVariantVerticalPadding * 2);
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _glyphView = [[GAGlyphView alloc] initWithFrame:NSZeroRect];

        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.textColor = [NSColor labelColor];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.maximumNumberOfLines = 1;

        _sourceLabel = [NSTextField labelWithString:@""];
        _sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _sourceLabel.font = [NSFont monospacedDigitSystemFontOfSize:10
                                                            weight:NSFontWeightRegular];
        _sourceLabel.textColor = [NSColor secondaryLabelColor];
        _sourceLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _sourceLabel.maximumNumberOfLines = 1;

        _codesView = [[GAUnicodeCodesView alloc] initWithFrame:NSZeroRect];

        [self addSubview:_glyphView];
        [self addSubview:_nameLabel];
        [self addSubview:_sourceLabel];
        [self addSubview:_codesView];

        _nameTopConstraint = [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor
                                                                   constant:5];
        _sourceTopConstraint = [_sourceLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor
                                                                       constant:1];
        _sourceHeightConstraint = [_sourceLabel.heightAnchor constraintEqualToConstant:0];
        _codesWidthConstraint = [_codesView.widthAnchor constraintEqualToConstant:0];
        _codesHeightConstraint = [_codesView.heightAnchor constraintEqualToConstant:0];

        [NSLayoutConstraint activateConstraints:@[
            [_glyphView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                      constant:GAVariantHorizontalInset],
            [_glyphView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_glyphView.trailingAnchor
                                                      constant:8],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_codesView.leadingAnchor
                                                                 constant:-8],
            _nameTopConstraint,

            [_sourceLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_sourceLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_codesView.leadingAnchor
                                                                   constant:-8],
            _sourceTopConstraint,
            _sourceHeightConstraint,

            [_codesView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                       constant:-GAVariantHorizontalInset],
            [_codesView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            _codesWidthConstraint,
            _codesHeightConstraint,
        ]];
    }
    return self;
}

- (void)configureWithVariant:(GAGlyphVariant *)variant {
    self.glyphView.variant = variant;

    NSString *name = variant.glyphName;
    if (name.length == 0) {
        NSMutableArray<NSString *> *gids = [NSMutableArray arrayWithCapacity:variant.glyphIDs.count];
        for (NSNumber *glyph in variant.glyphIDs) {
            [gids addObject:[NSString stringWithFormat:@"GID %@", glyph]];
        }
        name = gids.count > 0 ? [gids componentsJoinedByString:@" + "] : @"GID ?";
    }
    self.nameLabel.stringValue = name;
    self.nameLabel.font = [NSFont systemFontOfSize:12.5
                                           weight:variant.isBase
                                               ? NSFontWeightBold
                                               : NSFontWeightRegular];
    self.nameLabel.toolTip = name;

    NSArray<NSString *> *sources = variant.featureSources;
    NSString *sourceText = [sources componentsJoinedByString:@", "];
    self.sourceLabel.stringValue = sourceText;
    self.sourceLabel.toolTip = sources.count > 0 ? sourceText : nil;
    self.sourceLabel.hidden = sources.count == 0;
    self.sourceTopConstraint.active = sources.count > 0;
    self.sourceHeightConstraint.constant = [self.class sourceHeightForVariant:variant];

    CGFloat codeHeight = [GAUnicodeCodesView heightForScalars:variant.unicodeScalars];
    CGFloat codeWidth = [GAUnicodeCodesView widthForScalars:variant.unicodeScalars];
    self.codesView.unicodeScalars = variant.unicodeScalars;
    self.codesHeightConstraint.constant = codeHeight;
    self.codesWidthConstraint.constant = codeWidth;
    self.codesView.hidden = codeHeight <= 0;

    CGFloat rowHeight = [self.class rowHeightForVariant:variant];
    CGFloat contentHeight = [self.class nameBlockHeightForVariant:variant];
    self.nameTopConstraint.constant = (rowHeight - contentHeight) * 0.5;

    [self applyBackgroundStyle:self.backgroundStyle];

    NSMutableArray<NSString *> *descriptionParts = [NSMutableArray arrayWithObject:name];
    if (sources.count > 0) {
        [descriptionParts addObject:sourceText];
    }
    if (variant.unicodeScalars.count > 0) {
        [descriptionParts addObject:self.codesView.accessibilityLabel];
    }
    self.accessibilityLabel = [descriptionParts componentsJoinedByString:@", "];
}

- (void)applyBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [self.glyphView setBackgroundStyle:backgroundStyle];
    [self.sourceLabel setTextColor:backgroundStyle == NSBackgroundStyleEmphasized
        ? [NSColor alternateSelectedControlTextColor]
        : [NSColor secondaryLabelColor]];
    [self.codesView setBackgroundStyle:backgroundStyle];
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    [self applyBackgroundStyle:backgroundStyle];
}

@end
