#import "GASidebarViewController.h"
#import "GAGlyphViews.h"
#import "GAUnicode.h"

@class GASidebarViewController;

@interface GASidebarViewController (CommandArrowNavigation)
- (void)selectCurrentGroupBase;
- (void)selectNextGroupBase;
- (void)activateSelectedVariant;
- (void)copySelectedGlyphEncoding;
- (BOOL)selectedGlyphHasEncoding;
@end

@interface GASidebarTableView : NSTableView
@property (nonatomic, weak) GASidebarViewController *sidebarController;
@end

@implementation GASidebarTableView

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags &
        NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL commandOnly = (flags & NSEventModifierFlagCommand) &&
        !(flags & (NSEventModifierFlagShift |
                   NSEventModifierFlagOption |
                   NSEventModifierFlagControl));
    BOOL noModifiers = (flags & (NSEventModifierFlagCommand |
                                 NSEventModifierFlagShift |
                                 NSEventModifierFlagOption |
                                 NSEventModifierFlagControl)) == 0;
    if (noModifiers && (event.keyCode == 36 || event.keyCode == 76)) {
        [self.sidebarController activateSelectedVariant];
        return;
    }
    if (commandOnly &&
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"c"]) {
        [self.sidebarController copySelectedGlyphEncoding];
        return;
    }
    if (commandOnly && event.keyCode == 126) { // Command-Up
        [self.sidebarController selectCurrentGroupBase];
        return;
    }
    if (commandOnly && event.keyCode == 125) { // Command-Down
        [self.sidebarController selectNextGroupBase];
        return;
    }
    [super keyDown:event];
}

- (void)copy:(id)sender {
    [self.sidebarController copySelectedGlyphEncoding];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if (item.action == @selector(copy:)) {
        return [self.sidebarController selectedGlyphHasEncoding];
    }
    return [super validateUserInterfaceItem:item];
}

@end

@interface GASidebarViewController () <NSSearchFieldDelegate,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate>
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSArray<GACharacterGroup *> *groups;
@property (nonatomic, strong) NSArray<GARowItem *> *rows;
@property (nonatomic, strong, nullable) GAGlyphVariant *selectedVariant;
@property (nonatomic) BOOL suppressSelectionCallback;
@property (nonatomic) CGFloat lastTableWidth;
@property (nonatomic, copy, nullable) NSString *pendingSelectionGlyphKey;
@property (nonatomic, strong, nullable) NSLayoutConstraint *searchTopConstraint;
@end

static const CGFloat GASidebarInactiveGlyphListAlpha = 0.37;

@implementation GASidebarViewController

- (void)loadView {
    // The sidebar item + NSTableView Source List style provide the material.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 760)];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Enter text";
    self.searchField.controlSize = NSControlSizeLarge;
    self.searchField.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightRegular];
    self.searchField.delegate = self;
    NSSearchFieldCell *searchCell = (NSSearchFieldCell *)self.searchField.cell;
    // Keep the native search-field bezel, but no magnifier or clear button.
    searchCell.searchButtonCell = nil;
    searchCell.cancelButtonCell = nil;
    self.searchField.accessibilityLabel = @"Enter text";

    GASidebarTableView *tableView = [[GASidebarTableView alloc] initWithFrame:NSZeroRect];
    tableView.sidebarController = self;
    self.tableView = tableView;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.headerView = nil;
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    self.tableView.intercellSpacing = NSMakeSize(0, 0);
    self.tableView.allowsEmptySelection = YES;
    self.tableView.focusRingType = NSFocusRingTypeNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(tableDoubleClicked:);

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];
    self.tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.documentView = self.tableView;
    self.scrollView.contentInsets = NSEdgeInsetsMake(4, 0, 14, 0);
    self.scrollView.accessibilityLabel = @"Text and alternate glyph list";

    [self.view addSubview:self.searchField];
    [self.view addSubview:self.scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                                        constant:9],
        [self.searchField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                         constant:-9],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor
                                                   constant:9],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (self.searchTopConstraint != nil) {
        self.searchTopConstraint.active = NO;
        self.searchTopConstraint = nil;
    }
    if (self.view.window != nil) {
        NSLayoutGuide *guide = (NSLayoutGuide *)self.view.window.contentLayoutGuide;
        if (guide != nil) {
            self.searchTopConstraint = [self.searchField.topAnchor
                constraintEqualToAnchor:guide.topAnchor
                             constant:-1];
            self.searchTopConstraint.active = YES;
        }
    }
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self.tableView sizeLastColumnToFit];
    CGFloat width = self.tableView.bounds.size.width;
    if (self.lastTableWidth > 0 && fabs(width - self.lastTableWidth) > 0.5) {
        self.lastTableWidth = width;
        [self reloadRowsPreservingSelection];
    } else if (self.lastTableWidth <= 0) {
        self.lastTableWidth = width;
    }
}

- (NSString *)text {
    return self.searchField.stringValue;
}

- (void)setText:(NSString *)text {
    self.searchField.stringValue = text ?: @"";
}

- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey {
    self.pendingSelectionGlyphKey = [glyphKey copy];
}

- (GARowItem *)selectedVariantRow {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) return nil;
    GARowItem *item = self.rows[(NSUInteger)row];
    if (item.variant == nil || item.group == nil) {
        return nil;
    }
    return item;
}

- (void)activateRowAtIndex:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) return;
    GARowItem *item = self.rows[(NSUInteger)row];
    if (item.variant != nil && item.group != nil && self.onGlyphActivated) {
        self.onGlyphActivated(item.group, item.variant);
    }
}

- (void)activateSelectedVariant {
    [self activateRowAtIndex:self.tableView.selectedRow];
}

- (BOOL)selectedGlyphHasEncoding {
    GARowItem *item = [self selectedVariantRow];
    return item != nil && item.variant.unicodeScalars.count > 0;
}

- (void)copySelectedGlyphEncoding {
    GARowItem *item = [self selectedVariantRow];
    if (item == nil || item.variant.unicodeScalars.count == 0) {
        NSBeep();
        return;
    }
    NSString *string = GAStringFromUnicodeScalars(item.variant.unicodeScalars);
    if (string.length == 0) {
        NSBeep();
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:string forType:NSPasteboardTypeString];
}

- (void)tableDoubleClicked:(id)sender {
    [self activateRowAtIndex:self.tableView.clickedRow];
}

- (void)focusInput {
    if (self.view.window == nil) {
        return;
    }
    [self.view.window makeFirstResponder:self.searchField];
}

- (void)setGlyphListDimmed:(BOOL)dimmed {
    self.tableView.alphaValue = dimmed ? GASidebarInactiveGlyphListAlpha : 1.0;
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object != self.searchField) {
        return;
    }
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    if (editor != nil && editor.hasMarkedText) {
        return;
    }
    if (self.onTextChanged) {
        self.onTextChanged();
    }
}

- (BOOL)control:(NSControl *)control
    textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(cancelOperation:)) {
        [self.tableView.window makeFirstResponder:self.tableView];
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        [self.tableView.window makeFirstResponder:self.tableView];
        return YES;
    }
    return NO;
}

- (void)selectBaseRowForGroupAtIndex:(NSUInteger)groupIndex {
    if (groupIndex >= self.groups.count) return;
    GACharacterGroup *group = self.groups[groupIndex];
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
        GARowItem *item = self.rows[(NSUInteger)index];
        if (item.group == group && item.variant.isBase) {
            [self.tableView selectRowIndexes:
                [NSIndexSet indexSetWithIndex:(NSUInteger)index]
                        byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:index];
            return;
        }
    }
}

- (void)selectCurrentGroupBase {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        [self selectBaseRowForGroupAtIndex:0];
        return;
    }
    GARowItem *item = self.rows[(NSUInteger)row];
    if (item.group == nil) {
        return;
    }
    NSUInteger groupIndex = [self.groups indexOfObjectIdenticalTo:item.group];
    if (groupIndex == NSNotFound) return;
    if (item.variant.isBase) {
        // Already on the base glyph: move to the previous group's base.
        if (groupIndex > 0) {
            [self selectBaseRowForGroupAtIndex:groupIndex - 1];
        }
    } else {
        [self selectBaseRowForGroupAtIndex:groupIndex];
    }
}

- (void)selectNextGroupBase {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        [self selectBaseRowForGroupAtIndex:0];
        return;
    }
    GARowItem *item = self.rows[(NSUInteger)row];
    if (item.group == nil) {
        return;
    }
    NSUInteger groupIndex = [self.groups indexOfObjectIdenticalTo:item.group];
    if (groupIndex != NSNotFound && groupIndex + 1 < self.groups.count) {
        [self selectBaseRowForGroupAtIndex:groupIndex + 1];
    }
}

#pragma mark - Updating groups

- (void)setGroups:(NSArray<GACharacterGroup *> *)groups {
    NSString *oldGroupText = nil;
    NSString *oldGlyphKey = nil;
    if (self.selectedVariant != nil) {
        oldGlyphKey = self.selectedVariant.glyphKey;
        for (GACharacterGroup *group in self.groups) {
            if ([group.variants containsObject:self.selectedVariant]) {
                oldGroupText = group.text;
                break;
            }
        }
    }

    _groups = [groups copy];

    NSMutableArray<GARowItem *> *rows = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            GARowItem *variantRow = [[GARowItem alloc] init];
            variantRow.group = group;
            variantRow.variant = variant;
            [rows addObject:variantRow];
        }
    }
    self.rows = rows;

    self.suppressSelectionCallback = YES;
    [self.tableView reloadData];

    NSInteger rowToSelect = -1;
    if (self.pendingSelectionGlyphKey.length > 0) {
        for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
            GARowItem *item = self.rows[index];
            if ([item.variant.glyphKey isEqualToString:self.pendingSelectionGlyphKey]) {
                rowToSelect = index;
                break;
            }
        }
        self.pendingSelectionGlyphKey = nil;
    }
    if (rowToSelect < 0 && oldGlyphKey.length > 0) {
        for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
            GARowItem *item = self.rows[index];
            if ([item.variant.glyphKey isEqualToString:oldGlyphKey] &&
                (oldGroupText == nil || [item.group.text isEqualToString:oldGroupText])) {
                rowToSelect = index;
                break;
            }
        }
    }
    if (rowToSelect < 0) {
        for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
            GARowItem *item = self.rows[index];
            if (item.variant.isBase) {
                rowToSelect = index;
                break;
            }
        }
    }

    if (rowToSelect >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)rowToSelect]
                    byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:rowToSelect];
        self.selectedVariant = [self.rows[rowToSelect] variant];
    } else {
        self.selectedVariant = nil;
    }
    self.suppressSelectionCallback = NO;
    [self notifySelection];

}

- (void)reloadRowsPreservingSelection {
    NSInteger selectedRow = self.tableView.selectedRow;
    self.suppressSelectionCallback = YES;
    [self.tableView reloadData];
    if (selectedRow >= 0 && selectedRow < (NSInteger)self.rows.count) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedRow]
                    byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:selectedRow];
    }
    self.suppressSelectionCallback = NO;
}

- (void)notifySelection {
    if (self.onSelectionChanged) {
        self.onSelectionChanged(self.selectedVariant);
    }
}

- (CGFloat)variantRowHeightForVariant:(GAGlyphVariant *)variant {
    return [GAVariantCellView rowHeightForVariant:variant];
}

#pragma mark - Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return 0;
    }
    return [self variantRowHeightForVariant:self.rows[row].variant];
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return nil;
    }
    GARowItem *item = self.rows[row];
    GAVariantCellView *cell =
        [tableView makeViewWithIdentifier:@"VariantCell" owner:self];
    if (cell == nil) {
        cell = [[GAVariantCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"VariantCell";
    }
    [cell configureWithVariant:item.variant];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.suppressSelectionCallback) {
        return;
    }
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        self.selectedVariant = nil;
        [self notifySelection];
        return;
    }
    self.selectedVariant = self.rows[row].variant;
    [self notifySelection];
}

@end
