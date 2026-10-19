#import "GADetailViewController.h"
#import "GAGlyphCanvasView.h"

@interface GADetailViewController ()
@property (nonatomic, strong) GAGlyphCanvasView *canvasView;
@end

@implementation GADetailViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 760)];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.canvasView = [[GAGlyphCanvasView alloc] initWithFrame:NSZeroRect];
    self.canvasView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.canvasView];

    [NSLayoutConstraint activateConstraints:@[
        [self.canvasView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.canvasView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.canvasView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.canvasView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setVariant:(GAGlyphVariant *)variant {
    self.canvasView.variant = variant;
}

@end
