#import "GAVariationViewController.h"
#import "GAFontResource.h"
#import "GAInputFocus.h"
#import <math.h>

@interface GAVariationBackgroundView : NSView
@end
@implementation GAVariationBackgroundView
- (BOOL)acceptsFirstResponder { return YES; }
@end

@interface GAVariationContentView : GAVariationBackgroundView
@end
@implementation GAVariationContentView
- (BOOL)isFlipped { return YES; }
@end

@interface GAVariationViewController () <NSTextFieldDelegate>
@property (nonatomic, strong, readonly) GAFontResource *resource;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@property (nonatomic, strong) NSPopUpButton *instancePopup;
@property (nonatomic, strong, readonly) NSMutableArray<NSSlider *> *sliders;
@property (nonatomic, strong, readonly) NSMutableArray<NSTextField *> *valueFields;
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
    CGFloat height = 100 + MIN(contentHeight, axisHeight * 5);
    GAVariationBackgroundView *background = [[GAVariationBackgroundView alloc]
        initWithFrame:NSMakeRect(0, 0, width, height)];
    self.view = background;
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
        // Use NSMenu directly: NSPopUpButton replaces items with duplicate titles.
        [self.instancePopup.menu addItemWithTitle:instance.name action:nil keyEquivalent:@""];
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
        NSSlider *slider = [NSSlider sliderWithValue:minimum minValue:minimum maxValue:maximum target:self action:@selector(changeAxisValue:)];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        slider.tag = (NSInteger)i;
        slider.continuous = YES;
        slider.enabled = maximum > minimum;
        slider.accessibilityLabel = name;
        [row addSubview:slider];
        [self.sliders addObject:slider];
        NSTextField *value = [[GAInputTextField alloc] initWithFrame:NSZeroRect];
        value.translatesAutoresizingMaskIntoConstraints = NO;
        value.tag = (NSInteger)i;
        value.target = self;
        value.action = @selector(changeAxisValue:);
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
            [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
            [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [label.firstBaselineAnchor constraintEqualToAnchor:value.firstBaselineAnchor],
            [value.leadingAnchor constraintGreaterThanOrEqualToSystemSpacingAfterAnchor:label.trailingAnchor multiplier:1],
            [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [value.topAnchor constraintEqualToAnchor:row.topAnchor],
            [value.widthAnchor constraintEqualToConstant:75],
            [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [slider.topAnchor constraintEqualToAnchor:value.bottomAnchor constant:4],
            [slider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        ]];
        if (i == 0) {
            [row.topAnchor constraintEqualToAnchor:content.topAnchor constant:12].active = YES;
        } else {
            [row.topAnchor constraintEqualToAnchor:rows[i - 1].bottomAnchor constant:4].active = YES;
        }
        if (i + 1 == self.resource.axes.count) {
            [row.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18].active = YES;
        }
    }
    NSLayoutGuide *margins = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.instancePopup.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.instancePopup.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.instancePopup.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20],
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
    // Fit the initial viewport, then let it adapt to the native window's content size.
    viewportHeight.active = NO;
    [self updateControls];
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

- (void)prepareWindowFocus {
    self.view.window.initialFirstResponder = self.view;
    [self focusWindow];
}

- (void)focusWindow {
    [self.view.window makeFirstResponder:nil];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(insertNewline:) || command == @selector(cancelOperation:)) {
        // Only request focus loss; leave validation and end editing to AppKit.
        [self focusWindow];
        return YES;
    }
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
    [self changeAxisAtIndex:(NSUInteger)field.tag value:number.doubleValue + (up ? step : -step)];
    textView.string = [formatter stringForObjectValue:field.objectValue] ?: field.stringValue;
    textView.selectedRange = NSMakeRange(0, textView.string.length);
    return YES;
}

- (void)publishCoordinates:(NSDictionary *)coordinates {
    if ([self.coordinates isEqualToDictionary:coordinates]) return;
    self.coordinates = coordinates;
    [self updateControls];
    if (self.onCoordinatesChanged) self.onCoordinatesChanged(coordinates);
}

- (void)selectInstance:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem - 1;
    if (i >= 0 && i < (NSInteger)self.resource.instances.count) {
        [self publishCoordinates:self.resource.instances[(NSUInteger)i].coordinates];
    }
}

- (void)changeAxisAtIndex:(NSUInteger)index value:(double)value {
    if (!isfinite(value)) return;
    NSDictionary *axis = self.resource.axes[index];
    double minimum = [axis[(__bridge NSString *)kCTFontVariationAxisMinimumValueKey] doubleValue];
    double maximum = [axis[(__bridge NSString *)kCTFontVariationAxisMaximumValueKey] doubleValue];
    NSMutableDictionary *coordinates = [self.coordinates mutableCopy];
    coordinates[axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey]] = @(MIN(maximum, MAX(minimum, value)));
    [self publishCoordinates:coordinates];
}

- (void)changeAxisValue:(NSControl *)sender {
    [self changeAxisAtIndex:(NSUInteger)sender.tag value:sender.doubleValue];
}
@end
