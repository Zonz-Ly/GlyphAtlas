#import "GAVariationViewController.h"
#import <math.h>

static const CGFloat GAVariationTopSpacingReduction = 18;

@interface GAVariationSlider : NSSlider
@property (nonatomic, copy) void (^onTrackingEnded)(void);
@property (nonatomic, readonly) BOOL trackingVariation;
@end
@implementation GAVariationSlider
- (void)mouseDown:(NSEvent *)event {
    _trackingVariation = YES;
    [super mouseDown:event];
    _trackingVariation = NO;
    if (self.onTrackingEnded) self.onTrackingEnded();
}
@end

@interface GAVariationContentView : NSView
@end
@implementation GAVariationContentView
- (BOOL)isFlipped { return YES; }
@end

@interface GAVariationViewController () <NSTextFieldDelegate>
@property (nonatomic) BOOL hasPendingCommit;
@property (nonatomic, strong) GAFontResource *resource;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@property (nonatomic, strong) NSPopUpButton *instancePopup;
@property (nonatomic, strong) NSMutableArray<NSSlider *> *sliders;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *valueFields;
@property (nonatomic, strong) NSLayoutConstraint *titlebarReservation;
@property (nonatomic) CGFloat reservedTitlebarHeight;
@end

@implementation GAVariationViewController
- (instancetype)initWithResource:(GAFontResource *)resource
                    coordinates:(NSDictionary<NSNumber *, NSNumber *> *)coordinates {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _resource = resource;
        _coordinates = [coordinates copy];
        _sliders = [NSMutableArray array];
        _valueFields = [NSMutableArray array];
    }
    return self;
}

- (void)loadView {
    CGFloat width = 320;
    CGFloat axisHeight = 48;
    CGFloat contentHeight = self.resource.axes.count * axisHeight;
    NSRect titlebarFrame = [NSWindow frameRectForContentRect:NSMakeRect(0, 0, width, 100)
                                                  styleMask:NSWindowStyleMaskTitled];
    self.reservedTitlebarHeight = NSHeight(titlebarFrame) - 100;
    CGFloat height = 100 + MIN(contentHeight, axisHeight * 5) + self.reservedTitlebarHeight;
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.instancePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.instancePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.instancePopup.target = self;
    self.instancePopup.action = @selector(selectInstance:);
    self.instancePopup.accessibilityLabel = NSLocalizedString(@"Named Instance", @"Variable font preset menu");
    [self.instancePopup addItemWithTitle:NSLocalizedString(@"Custom", @"Custom variation coordinates")];
    self.instancePopup.itemArray.firstObject.enabled = NO;
    self.instancePopup.autoenablesItems = NO;
    for (GAFontInstance *instance in self.resource.instances) {
        // addItemWithTitle replaces duplicates, but distinct presets may share a name.
        [self.instancePopup.menu addItem:[[NSMenuItem alloc] initWithTitle:instance.name action:nil keyEquivalent:@""]];
    }
    [self.view addSubview:self.instancePopup];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = contentHeight > axisHeight * 5;
    scroll.autohidesScrollers = YES;
    [self.view addSubview:scroll];
    GAVariationContentView *content = [[GAVariationContentView alloc] initWithFrame:NSMakeRect(0, 0, width, contentHeight)];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = content;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
    NSLayoutGuide *axisMargins = content.layoutMarginsGuide;
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.resource.axes.count; i++) {
        NSDictionary *axis = self.resource.axes[i];
        NSString *name = axis[(__bridge NSString *)kCTFontVariationAxisNameKey];
        CGFloat minimum = [axis[(__bridge NSString *)kCTFontVariationAxisMinimumValueKey] doubleValue];
        CGFloat maximum = [axis[(__bridge NSString *)kCTFontVariationAxisMaximumValueKey] doubleValue];
        NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:row];
        [rows addObject:row];
        NSTextField *label = [NSTextField labelWithString:name];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.toolTip = name;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [row addSubview:label];
        GAVariationSlider *slider = [GAVariationSlider sliderWithValue:minimum minValue:minimum maxValue:maximum target:self action:@selector(changeSlider:)];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        slider.tag = (NSInteger)i;
        slider.continuous = YES;
        __weak typeof(self) weakSelf = self;
        slider.onTrackingEnded = ^{ [weakSelf publishCoordinates:weakSelf.coordinates committed:YES]; };
        slider.enabled = maximum > minimum;
        slider.accessibilityLabel = name;
        [row addSubview:slider];
        [self.sliders addObject:slider];
        NSTextField *value = [[NSTextField alloc] initWithFrame:NSZeroRect];
        value.translatesAutoresizingMaskIntoConstraints = NO;
        value.tag = (NSInteger)i;
        value.target = self;
        value.action = @selector(changeValue:);
        value.delegate = self;
        value.cell.sendsActionOnEndEditing = YES;
        value.alignment = NSTextAlignmentRight;
        value.accessibilityLabel = name;
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = NO;
        formatter.maximumFractionDigits = 4;
        formatter.minimum = @(minimum);
        formatter.maximum = @(maximum);
        value.formatter = formatter;
        [row addSubview:value];
        [self.valueFields addObject:value];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:axisMargins.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:axisMargins.trailingAnchor],
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [label.firstBaselineAnchor constraintEqualToAnchor:value.firstBaselineAnchor],
            [value.leadingAnchor constraintGreaterThanOrEqualToSystemSpacingAfterAnchor:label.trailingAnchor multiplier:1],
            [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [value.topAnchor constraintEqualToAnchor:row.topAnchor],
            [value.widthAnchor constraintEqualToConstant:70],
            [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [slider.topAnchor constraintEqualToSystemSpacingBelowAnchor:value.bottomAnchor multiplier:0.25],
            [slider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        ]];
        if (i == 0) {
            [row.topAnchor constraintEqualToAnchor:axisMargins.topAnchor constant:-10].active = YES;
        } else {
            [row.topAnchor constraintEqualToSystemSpacingBelowAnchor:rows[i - 1].bottomAnchor multiplier:0.25].active = YES;
        }
        if (i + 1 == self.resource.axes.count) {
            [row.bottomAnchor constraintEqualToAnchor:axisMargins.bottomAnchor constant:15].active = YES;
        }
    }
    NSLayoutGuide *margins = self.view.layoutMarginsGuide;
    self.titlebarReservation = [self.instancePopup.topAnchor constraintEqualToAnchor:margins.topAnchor
                                                                          constant:self.reservedTitlebarHeight - GAVariationTopSpacingReduction];
    [NSLayoutConstraint activateConstraints:@[
        [self.instancePopup.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.instancePopup.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        self.titlebarReservation,
        [scroll.topAnchor constraintEqualToAnchor:self.instancePopup.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    [self.view layoutSubtreeIfNeeded];
    CGFloat documentHeight = content.fittingSize.height;
    CGFloat visibleHeight = documentHeight;
    if (rows.count > 5) {
        visibleHeight -= NSMaxY(rows.lastObject.frame) - NSMaxY(rows[4].frame);
    }
    NSLayoutConstraint *viewportHeight = [scroll.heightAnchor constraintEqualToConstant:visibleHeight];
    viewportHeight.active = YES;
    [self.view setFrameSize:NSMakeSize(width, self.view.fittingSize.height)];
    // The viewport may lose the title bar's height when AppKit detaches it.
    // Its content is allowed to shrink by exactly that reserved amount.
    viewportHeight.active = NO;
    [self updateControls];
}

- (void)didDetachWithPreviousContentHeight:(CGFloat)height {
    CGFloat consumedHeight = MAX(0, height - NSHeight(self.view.bounds));
    self.titlebarReservation.constant = MAX(0, self.reservedTitlebarHeight - consumedHeight) - GAVariationTopSpacingReduction;
    [self.view layoutSubtreeIfNeeded];
}

- (void)updateControls {
    NSInteger selected = 0;
    for (NSUInteger i = 0; i < self.resource.instances.count; i++) {
        NSDictionary *preset = self.resource.instances[i].coordinates;
        BOOL matches = YES;
        for (NSNumber *identifier in self.resource.defaultCoordinates) {
            if (fabs([preset[identifier] doubleValue] - [self.coordinates[identifier] doubleValue]) > 0.0001) {
                matches = NO;
                break;
            }
        }
        if (matches) { selected = (NSInteger)i + 1; break; }
    }
    [self.instancePopup selectItemAtIndex:selected];
    for (NSUInteger i = 0; i < self.resource.axes.count; i++) {
        NSNumber *identifier = self.resource.axes[i][(__bridge NSString *)kCTFontVariationAxisIdentifierKey];
        self.sliders[i].doubleValue = self.coordinates[identifier].doubleValue;
        self.valueFields[i].objectValue = self.coordinates[identifier];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    BOOL up = command == @selector(moveUp:) || command == @selector(moveUpAndModifySelection:);
    BOOL down = command == @selector(moveDown:) || command == @selector(moveDownAndModifySelection:);
    if (!up && !down) return NO;
    NSTextField *field = (NSTextField *)control;
    NSNumberFormatter *formatter = (NSNumberFormatter *)field.formatter;
    NSNumber *number = [formatter numberFromString:textView.string];
    if (number == nil) return YES;
    // The field editor encodes Shift in the command selector; Command and
    // Option produce different selectors.
    BOOL shift = command == @selector(moveUpAndModifySelection:) ||
        command == @selector(moveDownAndModifySelection:);
    double step = shift ? 10 : 1;
    [self changeAxisAtIndex:(NSUInteger)field.tag value:number.doubleValue + (up ? step : -step) committed:YES];
    textView.string = [formatter stringForObjectValue:field.objectValue] ?: field.stringValue;
    textView.selectedRange = NSMakeRange(0, textView.string.length);
    return YES;
}

- (void)publishCoordinates:(NSDictionary *)coordinates committed:(BOOL)committed {
    if ([self.coordinates isEqualToDictionary:coordinates] && !(committed && self.hasPendingCommit)) return;
    self.hasPendingCommit = !committed;
    self.coordinates = coordinates;
    [self updateControls];
    if (self.onCoordinatesChanged) self.onCoordinatesChanged(coordinates, committed);
}

- (void)selectInstance:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem - 1;
    if (i >= 0 && i < (NSInteger)self.resource.instances.count) {
        [self publishCoordinates:self.resource.instances[(NSUInteger)i].coordinates committed:YES];
    }
}

- (void)changeAxisAtIndex:(NSUInteger)index value:(double)value committed:(BOOL)committed {
    if (!isfinite(value)) return;
    NSDictionary *axis = self.resource.axes[index];
    double minimum = [axis[(__bridge NSString *)kCTFontVariationAxisMinimumValueKey] doubleValue];
    double maximum = [axis[(__bridge NSString *)kCTFontVariationAxisMaximumValueKey] doubleValue];
    NSMutableDictionary *coordinates = [self.coordinates mutableCopy];
    coordinates[axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey]] = @(MIN(maximum, MAX(minimum, value)));
    [self publishCoordinates:coordinates committed:committed];
}

- (void)changeSlider:(NSSlider *)sender {
    BOOL committed = ![(GAVariationSlider *)sender trackingVariation];
    [self changeAxisAtIndex:(NSUInteger)sender.tag value:sender.doubleValue committed:committed];
}

- (void)changeValue:(NSTextField *)sender {
    [self changeAxisAtIndex:(NSUInteger)sender.tag value:sender.doubleValue committed:YES];
}
@end
