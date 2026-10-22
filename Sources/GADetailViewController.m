#import "GADetailViewController.h"
#import "GAGlyphCanvasView.h"
#import "GAAllGlyphsView.h"
#import "GAMultiGlyphView.h"
#import "GAAppDelegate.h"

@interface GADetailContainerView : NSView
@property (nonatomic, copy, nullable) NSMenu *(^menuProvider)(void);
@end

@implementation GADetailContainerView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    return self.menuProvider != nil ? self.menuProvider() : nil;
}

@end

@interface GADetailViewController ()
@property (nonatomic, strong) GAGlyphCanvasView *canvasView;
@property (nonatomic, strong) GAAllGlyphsView *allGlyphsView;
@property (nonatomic, strong) GAMultiGlyphView *multiView;
@property (nonatomic, strong) NSScrollView *multiScrollView;
@property (nonatomic) BOOL updatingMultiLayout;
@end

@implementation GADetailViewController

- (void)loadView {
    GADetailContainerView *container =
        [[GADetailContainerView alloc] initWithFrame:NSMakeRect(0, 0, 900, 760)];
    __weak typeof(self) weakSelf = self;
    container.menuProvider = ^NSMenu *{
        (void)weakSelf;
        id delegate = NSApp.delegate;
        if ([delegate respondsToSelector:@selector(viewMenuForContext)]) {
            return [delegate viewMenuForContext];
        }
        return nil;
    };
    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.canvasView = [[GAGlyphCanvasView alloc] initWithFrame:NSZeroRect];
    self.canvasView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.canvasView];

    self.allGlyphsView = [[GAAllGlyphsView alloc] initWithFrame:NSZeroRect];
    self.allGlyphsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.allGlyphsView];

    self.multiScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.multiScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.multiScrollView.hasVerticalScroller = YES;
    self.multiScrollView.hasHorizontalScroller = YES;
    self.multiScrollView.autohidesScrollers = YES;
    self.multiScrollView.drawsBackground = YES;
    self.multiScrollView.backgroundColor = GACanvasBackgroundColor();
    self.multiScrollView.automaticallyAdjustsContentInsets = NO;
    self.multiScrollView.borderType = NSNoBorder;
    [self.view addSubview:self.multiScrollView];

    self.multiView = [[GAMultiGlyphView alloc] initWithFrame:NSMakeRect(0, 0, 900, 760)];
    self.multiScrollView.documentView = self.multiView;

    for (NSView *view in @[self.canvasView, self.allGlyphsView, self.multiScrollView]) {
        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    }

    __weak typeof(self) weakSelf = self;
    self.allGlyphsView.onGlyphDoubleClick = ^(GAAllGlyphEntry *entry) {
        if (weakSelf.onAllGlyphDoubleClick != nil) {
            weakSelf.onAllGlyphDoubleClick(entry);
        }
    };
    self.multiView.onGroupSelected = ^(GACharacterGroup *group) {
        if (weakSelf.onGroupSelected != nil) {
            weakSelf.onGroupSelected(group);
        }
    };
    self.multiView.onContentSizeChanged = ^{
        [weakSelf updateMultiLayout];
    };
    self.multiView.onTextScaleChanged = ^{
        [weakSelf centerMultiScrollOnPage];
    };
    // One canvas, one zoom: whichever view is pinched, both keep the value.
    self.canvasView.onSideInsetFractionChanged = ^(CGFloat fraction) {
        weakSelf.multiView.sideInsetFraction = fraction;
    };
    self.multiView.onSideInsetFractionChanged = ^(CGFloat fraction) {
        weakSelf.canvasView.sideInsetFraction = fraction;
        [weakSelf centerMultiScrollOnPage];
    };

    NSMenu *contextMenu = [NSApp.delegate respondsToSelector:@selector(viewMenuForContext)]
        ? [(GAAppDelegate *)NSApp.delegate viewMenuForContext] : nil;
    self.canvasView.menu = contextMenu;
    self.multiView.menu = contextMenu;
    self.allGlyphsView.menu = contextMenu;

    [self updateVisibleView];
}

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
    self.canvasView.hidden = self.viewMode != GAViewModeSingleGlyph;
    self.allGlyphsView.hidden = self.viewMode != GAViewModeAllGlyphs;
    self.multiScrollView.hidden = self.viewMode != GAViewModeMultiCharacter;
    [self updateMultiLayout];
}

- (void)setVariant:(GAGlyphVariant *)variant {
    self.canvasView.variant = variant;
}

- (void)setFontDocument:(GAFontDocument *)document {
    self.allGlyphsView.document = document;
    self.multiView.document = document;
}

- (void)setMultiText:(NSString *)text groups:(NSArray<GACharacterGroup *> *)groups {
    NSPoint origin = self.multiScrollView.contentView.bounds.origin;
    [self.multiView setText:text groups:groups];
    NSSize viewport = self.multiScrollView.contentSize;
    NSSize document = self.multiView.frame.size;
    origin.x = MIN(MAX(0.0, origin.x), MAX(0.0, document.width - viewport.width));
    origin.y = MIN(MAX(0.0, origin.y), MAX(0.0, document.height - viewport.height));
    [self.multiScrollView.contentView scrollToPoint:origin];
    [self.multiScrollView reflectScrolledClipView:self.multiScrollView.contentView];
}

- (void)setShowsMetrics:(BOOL)showsMetrics {
    self.canvasView.showsMetrics = showsMetrics;
    self.multiView.showsMetrics = showsMetrics;
}

- (CGFloat)canvasInsetFraction {
    return self.canvasView.sideInsetFraction;
}

- (void)setCanvasInsetFraction:(CGFloat)fraction {
    self.canvasView.sideInsetFraction = fraction;
    self.multiView.sideInsetFraction = fraction;
}

/// The page occupies (1 - 2 * inset) of the viewport. Keyboard zoom scales that
/// fraction instead of the inset so the visual step stays constant.
- (void)scaleCanvasPageBy:(CGFloat)factor {
    CGFloat page = 1.0 - 2.0 * self.canvasInsetFraction;
    CGFloat minimum = 1.0 - 2.0 * GACanvasMaxInsetFraction;
    page = MIN(1.0, MAX(minimum, page * factor));
    self.canvasInsetFraction = (1.0 - page) * 0.5;
}

- (void)zoomCanvasIn {
    [self scaleCanvasPageBy:GAGlyphZoomStep];
}

- (void)zoomCanvasOut {
    [self scaleCanvasPageBy:1.0 / GAGlyphZoomStep];
}

- (void)resetCanvasZoom {
    self.canvasInsetFraction = GACanvasDefaultSideInsetFraction;
}

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

- (void)setTextAlignment:(NSTextAlignment)alignment {
    self.multiView.textAlignment = alignment;
}

- (void)setWritingDirectionVertical:(BOOL)vertical {
    self.multiView.vertical = vertical;
    [self updateMultiLayout];
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
    [self.multiView resetTextZoom];
    self.canvasInsetFraction = GACanvasDefaultSideInsetFraction;
}

/// Keep the page centre under the viewport centre after a zoom, so the scroll
/// thumbs stay in the middle instead of jumping to an edge.
- (void)centerMultiScrollOnPage {
    if (!self.isViewLoaded || self.multiScrollView.hidden) {
        return;
    }
    NSSize viewport = self.multiScrollView.contentSize;
    NSSize document = self.multiView.frame.size;
    NSRect page = [self.multiView pageRect];
    CGFloat x = NSMidX(page) - viewport.width * 0.5;
    CGFloat y = NSMidY(page) - viewport.height * 0.5;
    x = MIN(MAX(0, x), MAX(0, document.width - viewport.width));
    y = MIN(MAX(0, y), MAX(0, document.height - viewport.height));
    [self.multiScrollView.contentView scrollToPoint:NSMakePoint(x, y)];
    [self.multiScrollView reflectScrolledClipView:self.multiScrollView.contentView];
}

@end
