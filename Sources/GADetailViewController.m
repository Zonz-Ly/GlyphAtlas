#import "GADetailViewController.h"
#import "GABoundingBoxView.h"
#import "GAAllGlyphsView.h"
#import "GAMultiGlyphView.h"
#import "GAAppDelegate.h"

@interface GADetailContainerView : NSView
@property (nonatomic, copy, nullable) void (^resizeHandler)(void (^changes)(void));
@end

@implementation GADetailContainerView

- (void)setFrameSize:(NSSize)newSize {
    if (self.resizeHandler == nil || NSEqualSizes(self.frame.size, newSize)) {
        [super setFrameSize:newSize];
        return;
    }
    self.resizeHandler(^{
        [super setFrameSize:newSize];
        self.needsLayout = YES;
        [self layoutSubtreeIfNeeded];
    });
}

@end

@interface GADetailViewController ()
@property (nonatomic, strong) GABoundingBoxView *boundingBoxView;
@property (nonatomic, strong) GAAllGlyphsView *allGlyphsView;
@property (nonatomic, strong) GAMultiGlyphView *multiView;
@property (nonatomic, strong) NSScrollView *multiScrollView;
@property (nonatomic) BOOL updatingMultiLayout;
@property (nonatomic) CGFloat boundingBoxInsetFraction;
@end

@implementation GADetailViewController

#pragma mark - View creation

- (void)loadView {
    GADetailContainerView *container =
        [[GADetailContainerView alloc] initWithFrame:NSMakeRect(0, 0, 900, 760)];
    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.boundingBoxView = [[GABoundingBoxView alloc] initWithFrame:NSZeroRect];
    self.boundingBoxView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.boundingBoxView];

    self.allGlyphsView = [[GAAllGlyphsView alloc] initWithFrame:NSZeroRect];
    self.allGlyphsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.allGlyphsView];

    self.multiScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.multiScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.multiScrollView.hasVerticalScroller = YES;
    self.multiScrollView.hasHorizontalScroller = YES;
    self.multiScrollView.autohidesScrollers = YES;
    self.multiScrollView.backgroundColor = GABoundingBoxBackgroundColor();
    self.multiScrollView.automaticallyAdjustsContentInsets = NO;
    [self.view addSubview:self.multiScrollView];

    self.multiView = [[GAMultiGlyphView alloc] initWithFrame:NSMakeRect(0, 0, 900, 760)];
    self.multiScrollView.documentView = self.multiView;

    for (NSView *view in @[self.boundingBoxView, self.allGlyphsView, self.multiScrollView]) {
        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    }

    __weak typeof(self) weakSelf = self;
    GADetailContainerView *container = (GADetailContainerView *)self.view;
    container.resizeHandler = ^(void (^changes)(void)) {
        GADetailViewController *controller = weakSelf;
        NSScrollView *scrollView = controller.viewMode == GAViewModeMultiCharacter
            ? controller.multiScrollView : nil;
        GAPreserveScrollPosition(scrollView, ^{
            changes();
            [controller updateMultiLayout];
        });
    };
    self.allGlyphsView.onGlyphDoubleClick = ^(GAAllGlyphEntry *entry) {
        if (weakSelf.onAllGlyphDoubleClick != nil) {
            weakSelf.onAllGlyphDoubleClick(entry);
        }
    };
    self.multiView.onGlyphSelected = ^(NSArray<NSNumber *> *glyphIDs, NSRange range) {
      if (weakSelf.onGlyphSelected)
          weakSelf.onGlyphSelected(glyphIDs, range);
    };
    self.multiView.onContentSizeChanged = ^{
        [weakSelf updateMultiLayout];
    };
    // Single- and multi-character views share one bounding-box zoom.
    self.boundingBoxView.onSideInsetFractionChanged = ^(CGFloat fraction) {
        weakSelf.multiView.sideInsetFraction = fraction;
    };
    self.multiView.onSideInsetFractionChanged = ^(CGFloat fraction) {
        weakSelf.boundingBoxView.sideInsetFraction = fraction;
    };

    NSMenu *contextMenu = [NSApp.delegate respondsToSelector:@selector(viewMenuForContext)]
        ? [(GAAppDelegate *)NSApp.delegate viewMenuForContext] : nil;
    self.view.menu = contextMenu;
    self.boundingBoxView.menu = contextMenu;
    self.multiView.menu = contextMenu;
    self.allGlyphsView.menu = contextMenu;

    [self updateVisibleView];
}

#pragma mark - Layout

- (void)viewDidLayout {
    [super viewDidLayout];
    [self updateMultiLayout];
}

- (void)updateMultiLayout {
    if (self.updatingMultiLayout || !self.isViewLoaded || self.multiScrollView.hidden) {
        return;
    }
    NSSize viewport = self.multiScrollView.contentSize;
    if (viewport.width < 1 || viewport.height < 1) {
        return;
    }
    self.updatingMultiLayout = YES;
    self.multiView.viewportSize = viewport;
    NSSize size = self.multiView.documentSize;
    if (fabs(NSWidth(self.multiView.frame) - size.width) > 0.5 ||
        fabs(NSHeight(self.multiView.frame) - size.height) > 0.5) {
        self.multiView.frame = NSMakeRect(0, 0, size.width, size.height);
    }
    self.updatingMultiLayout = NO;
}

- (void)setViewMode:(GAViewMode)viewMode {
    _viewMode = viewMode;
    [self updateVisibleView];
}

- (void)updateVisibleView {
    if (!self.isViewLoaded) {
        return;
    }
    self.boundingBoxView.hidden = self.viewMode != GAViewModeSingleGlyph;
    self.allGlyphsView.hidden = self.viewMode != GAViewModeAllGlyphs;
    self.multiScrollView.hidden = self.viewMode != GAViewModeMultiCharacter;
    [self updateMultiLayout];
}

#pragma mark - Shared display state

- (void)setVariant:(GAGlyphVariant *)variant {
    self.boundingBoxView.variant = variant;
}

- (void)setFontDocument:(GAFontDocument *)document {
    self.allGlyphsView.document = document;
    self.multiView.document = document;
}

- (void)setShowsMetrics:(BOOL)showsMetrics {
    self.boundingBoxView.showsMetrics = showsMetrics;
    self.multiView.showsMetrics = showsMetrics;
}

- (CGFloat)boundingBoxInsetFraction {
    return self.boundingBoxView.sideInsetFraction;
}

- (void)setBoundingBoxInsetFraction:(CGFloat)fraction {
    self.boundingBoxView.sideInsetFraction = fraction;
    self.multiView.sideInsetFraction = fraction;
}

#pragma mark - Page zoom

/// The page occupies (1 - 2 * inset) of the viewport. Keyboard zoom scales that
/// fraction instead of the inset so the visual step stays constant.
- (void)scaleBoundingBoxBy:(CGFloat)factor {
    CGFloat page = 1.0 - 2.0 * self.boundingBoxInsetFraction;
    CGFloat minimum = 1.0 - 2.0 * GABoundingBoxMaxInsetFraction;
    page = MIN(1.0, MAX(minimum, page * factor));
    self.boundingBoxInsetFraction = (1.0 - page) * 0.5;
}

- (void)zoomBoundingBoxIn {
    [self scaleBoundingBoxBy:GAGlyphZoomStep];
}

- (void)zoomBoundingBoxOut {
    [self scaleBoundingBoxBy:1.0 / GAGlyphZoomStep];
}

- (void)resetBoundingBoxZoom {
    self.boundingBoxInsetFraction = GABoundingBoxDefaultSideInsetFraction;
}

#pragma mark - All glyphs

- (void)zoomAllGlyphsIn {
    [self.allGlyphsView zoomIn];
}

- (void)zoomAllGlyphsOut {
    [self.allGlyphsView zoomOut];
}

- (void)resetAllGlyphsZoom {
    [self.allGlyphsView resetZoom];
}

- (void)revealAllGlyphID:(NSNumber *)glyphID quick:(BOOL)quick {
    [self.allGlyphsView revealGlyphID:glyphID quick:quick];
}

- (BOOL)containsAllGlyphAtWindowPoint:(NSPoint)point {
    return self.viewMode == GAViewModeAllGlyphs &&
           [self.allGlyphsView containsGlyphAtWindowPoint:point];
}

#pragma mark - Multi-character view

- (void)scrollMultiToPoint:(NSPoint)point {
    NSSize viewport = self.multiScrollView.contentSize;
    NSSize document = self.multiView.frame.size;
    point.x = MIN(MAX(0.0, point.x), MAX(0.0, document.width - viewport.width));
    point.y = MIN(MAX(0.0, point.y), MAX(0.0, document.height - viewport.height));
    [self.multiScrollView.contentView scrollToPoint:point];
    [self.multiScrollView reflectScrolledClipView:self.multiScrollView.contentView];
}

- (void)setMultiText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups {
    NSPoint origin = self.multiScrollView.contentView.bounds.origin;
    [self.multiView setText:text groups:groups];
    [self scrollMultiToPoint:origin];
}

- (void)setTextAlignment:(NSTextAlignment)alignment {
    self.multiView.textAlignment = alignment;
}

- (void)setWritingDirectionVertical:(BOOL)vertical {
    self.multiView.vertical = vertical;
    [self updateMultiLayout];
}

- (void)setUsesContextualAlternates:(BOOL)enabled {
    self.multiView.usesContextualAlternates = enabled;
}

- (void)setUsesLigatures:(BOOL)enabled {
    self.multiView.usesLigatures = enabled;
}

- (void)zoomMultiTextIn {
    [self.multiView zoomTextIn];
}

- (void)zoomMultiTextOut {
    [self.multiView zoomTextOut];
}

- (void)resetMultiTextZoom {
    // Actual Size resets both zooms in this mode: the text scale (pinch and
    // keyboard) and the shared page inset (trackpad). Resetting only the text
    // made the command look dead after a page pinch.
    GAPreserveScrollPosition(self.multiScrollView, ^{
        [self.multiView resetTextZoom];
        self.boundingBoxInsetFraction = GABoundingBoxDefaultSideInsetFraction;
    });
}

@end
