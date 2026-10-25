#import "GASidebarViewController.h"
#import "GASidebarInput.h"
#import "GAGlyphViews.h"
#import "GAUnicode.h"

@interface GASidebarViewController (CommandArrowNavigation)
- (void)selectCurrentGroupBase;
- (void)selectNextGroupBase;
- (void)activateSelectedVariantWithModifiers:(NSEventModifierFlags)modifiers;
- (void)copySelectedGlyphEncoding;
- (BOOL)selectedGlyphHasEncoding;
@end

@interface GASidebarTableView : NSTableView
@property (nonatomic, weak) GASidebarViewController *sidebarController;
@end

@implementation GASidebarTableView

- (void)keyDown:(NSEvent *)event {
    // Return works with no modifier or Shift only.
    BOOL canActivate =
        GAModifiersAre(event.modifierFlags, 0) ||
        GAModifiersAre(event.modifierFlags, NSEventModifierFlagShift);
    BOOL commandOnly =
        GAModifiersAre(event.modifierFlags, NSEventModifierFlagCommand);
    if (canActivate && (event.keyCode == 36 || event.keyCode == 76)) {
        [self.sidebarController
            activateSelectedVariantWithModifiers:event.modifierFlags];
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
@property (nonatomic) NSRange selectedVariantTextRange;
@property (nonatomic) BOOL suppressSelectionCallback;
@property (nonatomic) CGFloat lastTableWidth;
@property (nonatomic, copy, nullable) NSString *pendingSelectionGlyphKey;
@property (nonatomic) NSRange pendingSelectionTextRange;
@property (nonatomic) GAPendingSelectionScroll pendingSelectionScroll;
@property (nonatomic, copy, nullable) NSString *lastNotifiedGlyphKey;
@property (nonatomic) NSRange lastNotifiedRange;
@property (nonatomic, strong, nullable) NSLayoutConstraint *searchTopConstraint;
@property (nonatomic) BOOL suppressTextChangeCallback;
@property (nonatomic, strong, nullable) GASearchFieldEditor *searchFieldEditor;
@end

static const CGFloat GASidebarInactiveGlyphListAlpha = 0.37;

@implementation GASidebarViewController

- (void)loadView {
    // The sidebar item + NSTableView Source List style provide the material.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 760)];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.searchField = [[GASearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = NSLocalizedString(@"Enter text", @"Enter text");
    self.searchField.controlSize = NSControlSizeLarge;
    self.searchField.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightRegular];
    // Custom selection attributes live in the field's attributed string and
    // must survive the field editor's edit cycle.
    self.searchField.allowsEditingTextAttributes = YES;
    self.searchField.delegate = self;
    NSSearchFieldCell *searchCell = (NSSearchFieldCell *)self.searchField.cell;
    // Keep the native search-field bezel, but no magnifier or clear button.
    searchCell.searchButtonCell = nil;
    searchCell.cancelButtonCell = nil;
    self.searchField.accessibilityLabel = NSLocalizedString(@"Enter text", @"Enter text");

    GASidebarTableView *tableView = [[GASidebarTableView alloc] initWithFrame:NSZeroRect];
    tableView.sidebarController = self;
    self.tableView = tableView;
    self.tableView.autoresizingMask = NSViewWidthSizable;
    self.tableView.usesAutomaticRowHeights = NO;
    self.tableView.rowHeight = 44;
    self.tableView.headerView = nil;
    self.tableView.style = NSTableViewStyleSourceList;
    self.tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    self.tableView.intercellSpacing = NSMakeSize(0, 0);
    self.tableView.focusRingType = NSFocusRingTypeNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.target = self;
    self.tableView.doubleAction = @selector(tableDoubleClicked:);

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:column];

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.documentView = self.tableView;
    self.scrollView.contentInsets = NSEdgeInsetsMake(4, 0, 14, 0);
    self.scrollView.accessibilityLabel = NSLocalizedString(@"Text and alternate glyph list", @"Text and alternate glyph list");

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

- (NSFont *)inputFont {
    return self.searchField.font ?: [NSFont systemFontOfSize:13.5
                                                         weight:NSFontWeightRegular];
}

- (NSColor *)inputTextColor {
    return [NSColor controlTextColor];
}

/// Returns only the attributes this app understands: the default font,
/// the app-owned foreground color, and selection runs. Everything else
/// (pasted colors, backgrounds, paragraph styles, links, attachments) is
/// discarded.
- (NSAttributedString *)plainCopyOfAttributedText:(NSAttributedString *)text {
    return GANormalizedSidebarInput(text, [self inputFont], [self inputTextColor]);
}

- (void)prepareFieldEditor {
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    if (editor == nil) {
        return;
    }
    // Allow programmatic attributes (selection runs), but keep user edits and
    // pastes plain so external formatting cannot enter the field.
    BOOL wasSuppressed = self.suppressTextChangeCallback;
    self.suppressTextChangeCallback = YES;
    editor.richText = NO;
    editor.typingAttributes = @{
        NSFontAttributeName: [self inputFont],
        NSForegroundColorAttributeName: [self inputTextColor],
    };
    self.suppressTextChangeCallback = wasSuppressed;

    NSTextStorage *storage = editor.textStorage;
    if (storage.length == 0) {
        return;
    }
    NSRange all = NSMakeRange(0, storage.length);
    __block BOOL needsNormalization = NO;
    [storage enumerateAttributesInRange:all
                                options:0
                             usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                          NSRange range, BOOL *stop) {
        (void)range;
        // A line-break marker owns its font and secondary colour. Do not treat
        // that colour as pasted formatting.
        if (attrs[GALineBreakAttributeName] != nil) {
            return;
        }
        for (NSAttributedStringKey key in attrs) {
            if ([key isEqualToString:GAGlyphSelectionAttributeName]) {
                continue;
            }
            if ([key isEqualToString:NSFontAttributeName] &&
                [attrs[key] isEqual:[self inputFont]]) {
                continue;
            }
            if ([key isEqualToString:NSForegroundColorAttributeName] &&
                [attrs[key] isEqual:[self inputTextColor]]) {
                continue;
            }
            needsNormalization = YES;
            *stop = YES;
            return;
        }
    }];
    if (!needsNormalization) {
        return;
    }

    NSRange selection = editor.selectedRange;
    self.suppressTextChangeCallback = YES;
    [storage setAttributedString:GANormalizedSidebarInput(storage, [self inputFont],
                                                           [self inputTextColor])];
    if (selection.location != NSNotFound) {
        NSUInteger location = MIN(selection.location, storage.length);
        NSUInteger length = MIN(selection.length, storage.length - location);
        editor.selectedRange = NSMakeRange(location, length);
    }
    self.suppressTextChangeCallback = NO;
}

- (NSAttributedString *)attributedText {
    NSAttributedString *text = nil;
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    if (editor != nil) {
        text = editor.textStorage;
    }
    if (text == nil) {
        text = self.searchField.attributedStringValue;
    }
    return GAModelTextFromFieldText([self plainCopyOfAttributedText:text]);
}

- (NSString *)text {
    return self.attributedText.string;
}

- (NSRange)inputSelectionRange {
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    return editor != nil ? editor.selectedRange : NSMakeRange(NSNotFound, 0);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *fieldText = GAFieldTextFromModelText(attributedText);
    NSAttributedString *normalized = [self plainCopyOfAttributedText:fieldText];
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    NSRange selection = editor != nil ? editor.selectedRange : NSMakeRange(NSNotFound, 0);
    self.suppressTextChangeCallback = YES;
    self.searchField.attributedStringValue = normalized;
    if (editor != nil && selection.location != NSNotFound) {
        NSUInteger location = MIN(selection.location, normalized.length);
        NSUInteger length = MIN(selection.length, normalized.length - location);
        editor.selectedRange = NSMakeRange(location, length);
    }
    self.suppressTextChangeCallback = NO;
    if (editor != nil) {
        [self prepareFieldEditor];
    }
}

- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange {
    [self selectGlyphKeyAfterNextReload:glyphKey
                              textRange:textRange
                                 scroll:GAPendingSelectionScrollGroup];
}

- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange
                               scroll:(GAPendingSelectionScroll)scroll {
    self.pendingSelectionGlyphKey = [glyphKey copy];
    self.pendingSelectionTextRange = textRange;
    self.pendingSelectionScroll = scroll;
}

- (NSString *)selectedGlyphSourceText {
    GARowItem *row = [self selectedVariantRow];
    NSRange range = row.variant.sourceTextRange;
    if (row.variant.isLigature && range.location != NSNotFound && NSMaxRange(range) <= self.text.length) return [self.text substringWithRange:range];
    return row.group.text ?: @"";
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

- (void)activateRowAtIndex:(NSInteger)row
                 modifiers:(NSEventModifierFlags)modifiers {
    if (row < 0 || row >= (NSInteger)self.rows.count) return;
    GARowItem *item = self.rows[(NSUInteger)row];
    if (item.variant == nil || item.group == nil) return;
    if (GAModifiersAre(modifiers, NSEventModifierFlagShift)) {
        if (self.onGlyphShiftActivated) {
            self.onGlyphShiftActivated(item.group, item.variant);
        }
        return;
    }
    if (self.onGlyphActivated) {
        self.onGlyphActivated(item.group, item.variant);
    }
}

- (void)activateSelectedVariantWithModifiers:(NSEventModifierFlags)modifiers {
    [self activateRowAtIndex:self.tableView.selectedRow modifiers:modifiers];
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
    [self activateRowAtIndex:self.tableView.clickedRow
                   modifiers:NSApp.currentEvent.modifierFlags];
}

- (NSRange)appendInputString:(NSString *)string
                   selection:(GAGlyphSelection *)selection {
    if (string.length == 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSMutableAttributedString *text = [self.attributedText mutableCopy];
    NSRange range = NSMakeRange(text.length, string.length);
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:string]];
    if (selection != nil) {
        [text addAttribute:GAGlyphSelectionAttributeName value:selection range:range];
    }
    [self setAttributedText:text];
    return range;
}

- (void)focusInput {
    if (self.view.window == nil) {
        return;
    }
    [self.view.window makeFirstResponder:self.searchField];
    [self prepareFieldEditor];
}

/// The window asks for a field editor when a control starts editing. Only the
/// search field gets the custom editor; other controls keep the default one.
- (NSTextView *)fieldEditorForControl:(id)control {
    if (control != self.searchField) {
        return nil;
    }
    if (self.searchFieldEditor == nil) {
        GASearchFieldEditor *editor = [[GASearchFieldEditor alloc] initWithFrame:NSZeroRect];
        editor.fieldEditor = YES;
        self.searchFieldEditor = editor;
    }
    return self.searchFieldEditor;
}

- (void)setGlyphListDimmed:(BOOL)dimmed {
    self.tableView.alphaValue = dimmed ? GASidebarInactiveGlyphListAlpha : 1.0;
}

- (void)controlTextDidBeginEditing:(NSNotification *)obj {
    if (obj.object != self.searchField) {
        return;
    }
    [self prepareFieldEditor];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object != self.searchField || self.suppressTextChangeCallback) {
        return;
    }
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    if (editor != nil && editor.hasMarkedText) {
        return;
    }
    [self prepareFieldEditor];
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
    if (commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [textView insertText:@"\n" replacementRange:textView.selectedRange];
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
            [self scrollGroupContainingRow:index];
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

- (BOOL)group:(GACharacterGroup *)group containsGlyphKey:(NSString *)glyphKey {
    for (GAGlyphVariant *variant in group.variants) {
        if ([variant.glyphKey isEqualToString:glyphKey]) {
            return YES;
        }
    }
    return NO;
}

/// Finds the group that owns a restored selection. The text range is the
/// post-replacement range, so it matches exactly. The glyph key is part of
/// the match.
- (GACharacterGroup *)groupForGlyphKey:(NSString *)glyphKey
                             textRange:(NSRange)textRange {
    if (textRange.length == 0) {
        return nil;
    }
    for (GACharacterGroup *group in self.groups) {
        if (NSEqualRanges(group.textRange, textRange) &&
            [self group:group containsGlyphKey:glyphKey]) {
            return group;
        }
    }
    return nil;
}

- (NSInteger)rowForGlyphKey:(NSString *)glyphKey inGroup:(GACharacterGroup *)group {
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
        GARowItem *item = self.rows[index];
        if (item.group == group && [item.variant.glyphKey isEqualToString:glyphKey]) {
            return index;
        }
    }
    return NSNotFound;
}

static NSArray<GARowItem *> *GARowsForGroups(NSArray<GACharacterGroup *> *groups) {
    NSMutableArray<GARowItem *> *rows = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            GARowItem *variantRow = [[GARowItem alloc] init];
            variantRow.group = group;
            variantRow.variant = variant;
            [rows addObject:variantRow];
        }
    }
    return rows;
}

/// Scrolls so the selected row's whole character group is visible when it
/// fits; otherwise only the selected row is brought into view.
- (GACharacterGroup *)groupForTextRange:(NSRange)textRange {
    if (textRange.length == 0) {
        return nil;
    }
    for (GACharacterGroup *group in self.groups) {
        if (NSEqualRanges(group.textRange, textRange)) {
            return group;
        }
    }
    return nil;
}

/// Resolves the pending selection by text range first: the appended character
/// group's base row is the fallback when the clicked all-glyph GID is not one
/// of the shaped variants.
- (NSInteger)rowForPendingSelection {
    if (self.pendingSelectionGlyphKey.length == 0) {
        return NSNotFound;
    }
    GACharacterGroup *group = [self groupForTextRange:self.pendingSelectionTextRange];
    if (group == nil) {
        for (GACharacterGroup *candidate in self.groups)
            if (self.pendingSelectionTextRange.location >= candidate.textRange.location &&
                NSMaxRange(self.pendingSelectionTextRange) <= NSMaxRange(candidate.textRange)) {
                group = candidate;
                break;
            }
    }
    if (group == nil)
        return NSNotFound;
    NSInteger row = [self rowForGlyphKey:self.pendingSelectionGlyphKey inGroup:group];
    if (row != NSNotFound) {
        return row;
    }
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
        GARowItem *item = self.rows[(NSUInteger)index];
        if (item.group == group && item.variant.isBase) {
            return index;
        }
    }
    return NSNotFound;
}

- (void)scrollClipViewToY:(CGFloat)y {
    NSClipView *clipView = self.scrollView.contentView;
    NSRect bounds = clipView.bounds;
    bounds.origin.y = y;
    [clipView scrollToPoint:[clipView constrainBoundsRect:bounds].origin];
    [self.scrollView reflectScrolledClipView:clipView];
}

- (void)scrollSelectedRowToTopIfNeeded:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return;
    }
    [self.tableView layoutSubtreeIfNeeded];
    NSRect rowRect = [self.tableView rectOfRow:row];
    if (NSIntersectsRect(rowRect, self.tableView.visibleRect)) {
        return;
    }
    [self scrollClipViewToY:NSMinY(rowRect)];
}

/// Resolves a pending selection against the current rows. Returns YES when it
/// consumed the pending request; the caller just returns. Returns NO when there
/// is no pending or the target group is not present yet.
- (BOOL)resolvePendingSelectionIfPossible {
    if (self.pendingSelectionGlyphKey.length == 0) {
        return NO;
    }
    NSInteger row = [self rowForPendingSelection];
    if (row == NSNotFound) {
        return NO;
    }
    [self.tableView rectOfRow:row];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                byExtendingSelection:NO];
    if (self.pendingSelectionScroll == GAPendingSelectionScrollSelectedToTopIfNeeded) {
        [self scrollSelectedRowToTopIfNeeded:row];
    } else {
        [self scrollGroupContainingRow:row];
    }
    self.selectedVariant = self.rows[(NSUInteger)row].variant;
    self.selectedVariantTextRange = self.rows[(NSUInteger)row].group.textRange;
    self.pendingSelectionGlyphKey = nil;
    self.pendingSelectionTextRange = NSMakeRange(NSNotFound, 0);
    self.pendingSelectionScroll = GAPendingSelectionScrollGroup;
    self.suppressSelectionCallback = NO;
    [self notifySelection];
    return YES;
}

- (void)scrollGroupContainingRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return;
    }
    GACharacterGroup *group = self.rows[(NSUInteger)row].group;
    NSInteger first = row;
    NSInteger last = row;
    if (group != nil) {
        first = NSNotFound;
        last = NSNotFound;
        for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
            if (self.rows[(NSUInteger)index].group == group) {
                if (first == NSNotFound) {
                    first = index;
                }
                last = index;
            }
        }
    }
    if (first == NSNotFound || last == NSNotFound) {
        [self.tableView scrollRowToVisible:row];
        return;
    }
    [self.tableView layoutSubtreeIfNeeded];
    [self.tableView rectOfRow:first];
    [self.tableView rectOfRow:last];
    NSRect firstRect = [self.tableView rectOfRow:first];
    NSRect lastRect = [self.tableView rectOfRow:last];
    NSRect visibleRect = self.tableView.visibleRect;
    CGFloat groupHeight = NSMaxY(lastRect) - NSMinY(firstRect);
    if (groupHeight > NSHeight(visibleRect)) {
        // Group is taller than the visible area: always align its top.
        // scrollRowToVisible:first only makes the row visible; if it is already
        // visible it does nothing, and a selection below may sit at the bottom.
        // Move the clip view to the group's top explicitly.
        [self scrollClipViewToY:NSMinY(firstRect)];
    } else if (NSMinY(firstRect) < NSMinY(visibleRect)) {
        // Group top is above the visible area: align the top.
        [self.tableView scrollRowToVisible:first];
    } else if (NSMaxY(lastRect) > NSMaxY(visibleRect)) {
        // Group bottom is below the visible area: align the bottom.
        [self.tableView scrollRowToVisible:last];
    }
    // Otherwise both edges are visible: do nothing.
}

- (BOOL)updateGroupsWithSameRows:(NSArray<GACharacterGroup *> *)groups {
    if (self.pendingSelectionGlyphKey != nil) return NO;
    NSArray<GARowItem *> *rows = GARowsForGroups(groups);
    if (rows.count != self.rows.count) return NO;
    for (NSUInteger i = 0; i < rows.count; i++) {
        GARowItem *old = self.rows[i], *updated = rows[i];
        if (!NSEqualRanges(old.group.textRange, updated.group.textRange) ||
            ![old.variant.glyphKey isEqualToString:updated.variant.glyphKey] ||
            ![old.variant.featureSources isEqualToArray:updated.variant.featureSources] ||
            ![old.variant.unicodeScalars isEqualToArray:updated.variant.unicodeScalars] ||
            ![old.variant.glyphName isEqualToString:updated.variant.glyphName]) return NO;
    }
    _groups = [groups copy];
    self.rows = rows;
    NSInteger selected = self.tableView.selectedRow;
    if (selected >= 0 && selected < (NSInteger)rows.count) {
        self.selectedVariant = rows[(NSUInteger)selected].variant;
        self.selectedVariantTextRange = rows[(NSUInteger)selected].group.textRange;
    }
    NSRange visible = [self.tableView rowsInRect:self.tableView.visibleRect];
    if (visible.location != NSNotFound) {
        for (NSUInteger i = visible.location; i < MIN(rows.count, NSMaxRange(visible)); i++) {
            GAVariantCellView *cell = [self.tableView viewAtColumn:0 row:(NSInteger)i makeIfNecessary:NO];
            [cell configureWithVariant:rows[i].variant];
        }
    }
    return YES;
}

- (BOOL)selectGlyphIDs:(NSArray<NSNumber *> *)glyphIDs textRange:(NSRange)range {
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        GARowItem *row = self.rows[index];
        if (!NSEqualRanges(row.group.textRange, range) || ![row.variant.glyphIDs isEqual:glyphIDs])
            continue;
        self.suppressSelectionCallback = YES;
        self.pendingSelectionGlyphKey = nil;
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                    byExtendingSelection:NO];
        self.selectedVariant = row.variant;
        self.selectedVariantTextRange = range;
        [self scrollGroupContainingRow:index];
        self.suppressSelectionCallback = NO;
        [self notifySelection];
        return YES;
    }
    return NO;
}

- (void)setGroups:(NSArray<GACharacterGroup *> *)groups {
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0;
    @try {
        NSDictionary *scrollAnchor = [self captureScrollAnchor];
        NSString *oldGlyphKey = nil;
        NSRange oldGroupRange = self.selectedVariantTextRange;
        if (self.selectedVariant != nil) {
            oldGlyphKey = self.selectedVariant.glyphKey;
        } else {
            oldGroupRange = NSMakeRange(NSNotFound, 0);
        }

        _groups = [groups copy];
        self.rows = GARowsForGroups(groups);

        self.suppressSelectionCallback = YES;
        [self reloadTableGeometry];

        BOOL hasPending = self.pendingSelectionGlyphKey.length > 0;
        if (hasPending) {
            if ([self resolvePendingSelectionIfPossible]) {
                return;
            }
            // The appended character group is not in this snapshot yet (or has no
            // rows). Wait; do not restore the old selection or jump to the first.
            self.selectedVariant = nil;
            self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
            [self restoreScrollAnchor:scrollAnchor];
            self.suppressSelectionCallback = NO;
            [self notifySelection];
            return;
        }

        NSInteger rowToSelect = NSNotFound;
        if (oldGlyphKey.length > 0) {
            GACharacterGroup *oldGroup = [self groupForGlyphKey:oldGlyphKey
                                                      textRange:oldGroupRange];
            if (oldGroup != nil) {
                rowToSelect = [self rowForGlyphKey:oldGlyphKey inGroup:oldGroup];
            }
        }
        // The selected text may have been deleted; fall back to the first base row.
        if (rowToSelect == NSNotFound) {
            for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
                GARowItem *item = self.rows[index];
                if (item.variant.isBase) {
                    rowToSelect = index;
                    break;
                }
            }
        }

        if (rowToSelect != NSNotFound) {
            if (rowToSelect != self.tableView.selectedRow) {
                [self.tableView
                        selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)rowToSelect]
                    byExtendingSelection:NO];
            }
            self.selectedVariant = [self.rows[rowToSelect] variant];
            self.selectedVariantTextRange = self.rows[rowToSelect].group.textRange;
        } else {
            self.selectedVariant = nil;
            self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
        }
        self.suppressSelectionCallback = NO;
        [self notifySelection];
        [self restoreScrollAnchor:scrollAnchor];
    } @finally {
        [NSAnimationContext endGrouping];
    }
}

- (void)reloadTableGeometry {
    [self.tableView reloadData];
    if (self.rows.count) {
        [NSAnimationContext beginGrouping];
        NSAnimationContext.currentContext.duration = 0;
        NSIndexSet *allRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.rows.count)];
        [self.tableView noteHeightOfRowsWithIndexesChanged:allRows];
        [NSAnimationContext endGrouping];
        // rectOfRow: realizes the final row before a scroll position is clamped.
        [self.tableView rectOfRow:(NSInteger)self.rows.count - 1];
    }
    [self.tableView tile];
}

// Preserve the visible row, not just a pixel offset that becomes stale when
// candidates above it change height or the native scroller changes width.
- (NSDictionary *)captureScrollAnchor {
    NSPoint origin = self.scrollView.contentView.bounds.origin;
    NSRange visible = [self.tableView rowsInRect:self.tableView.visibleRect];
    NSMutableDictionary *anchor = [@{@"origin" : [NSValue valueWithPoint:origin]} mutableCopy];
    if (visible.length && visible.location < self.rows.count) {
        GARowItem *row = self.rows[visible.location];
        anchor[@"key"] = row.variant.glyphKey;
        anchor[@"range"] = [NSValue valueWithRange:row.group.textRange];
        anchor[@"offset"] = @(origin.y - NSMinY([self.tableView rectOfRow:visible.location]));
    }
    return anchor;
}

- (void)restoreScrollAnchor:(NSDictionary *)anchor {
    NSPoint origin = [anchor[@"origin"] pointValue];
    if (anchor[@"key"]) {
        GACharacterGroup *group = [self groupForTextRange:[anchor[@"range"] rangeValue]];
        NSInteger row = [self rowForGlyphKey:anchor[@"key"] inGroup:group];
        if (row == NSNotFound && group.variants.count)
            row = [self rowForGlyphKey:group.variants.firstObject.glyphKey inGroup:group];
        if (row != NSNotFound) {
            NSRect rect = [self.tableView rectOfRow:row];
            origin.y = NSMinY(rect) + MIN([anchor[@"offset"] doubleValue], NSHeight(rect) - 1);
        }
    }
    [self restoreScrollOrigin:origin];
}

- (void)restoreScrollOrigin:(NSPoint)origin {
    NSClipView *clip = self.scrollView.contentView;
    NSRect bounds = clip.bounds;
    bounds.origin = origin;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)reloadRowsPreservingSelection {
    NSDictionary *anchor = [self captureScrollAnchor];
    NSInteger selectedRow = self.tableView.selectedRow;
    self.suppressSelectionCallback = YES;
    [self reloadTableGeometry];
    if (selectedRow >= 0 && selectedRow < (NSInteger)self.rows.count) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedRow]
                    byExtendingSelection:NO];
    }
    [self restoreScrollAnchor:anchor];
    self.suppressSelectionCallback = NO;
}

- (void)notifySelection {
    if (self.onSelectionChanged == nil) {
        return;
    }
    NSString *key = self.selectedVariant.glyphKey;
    NSRange range = self.selectedVariantTextRange;
    BOOL same = (key == nil && self.lastNotifiedGlyphKey == nil) ||
                ([key isEqualToString:self.lastNotifiedGlyphKey] &&
                 NSEqualRanges(range, self.lastNotifiedRange));
    if (same) {
        return;
    }
    self.lastNotifiedGlyphKey = [key copy];
    self.lastNotifiedRange = range;
    self.onSelectionChanged(self.selectedVariant);
}

#pragma mark - Table data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return 0;
    }
    return [GAVariantCellView rowHeightForVariant:self.rows[row].variant];
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
        self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
        [self notifySelection];
        return;
    }
    // A manual click overrides any pending auto-selection from an append or
    // activation; streamed snapshots must not snap the user back.
    self.pendingSelectionGlyphKey = nil;
    self.pendingSelectionTextRange = NSMakeRange(NSNotFound, 0);
    self.pendingSelectionScroll = GAPendingSelectionScrollGroup;
    self.selectedVariant = self.rows[row].variant;
    self.selectedVariantTextRange = self.rows[row].group.textRange;
    [self notifySelection];
}

@end
