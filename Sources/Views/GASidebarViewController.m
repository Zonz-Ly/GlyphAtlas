#import "GASidebarViewController.h"
#import "Input/GASidebarInput.h"
#import "GAGlyphViews.h"
#import "Font/GAUnicode.h"
#import "GAViewMode.h"

@interface GARowItem : NSObject
@property (nonatomic, strong, nonnull) GACharacterGroup *group;
@property (nonatomic, strong, nonnull) GAGlyphVariant *variant;
@end

@implementation GARowItem
@end

static NSArray<GARowItem *> *GARowsForGroups(NSArray<GACharacterGroup *> *groups,
                                            GAGlyphResolution *temporary) {
    NSMutableArray<GARowItem *> *rows = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            GARowItem *variantRow = [[GARowItem alloc] init];
            variantRow.group = group;
            variantRow.variant = variant;
            [rows addObject:variantRow];
            if (variant == temporary.parent) {
                GARowItem *temporaryRow = [[GARowItem alloc] init];
                temporaryRow.group = group;
                temporaryRow.variant = temporary.variant;
                [rows addObject:temporaryRow];
            }
        }
    }
    return rows;
}

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
        [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"c"] &&
        ![self.sidebarController selectedGlyphHasEncoding]) {
        NSBeep();
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
@property (nonatomic, strong, nullable) GAGlyphResolution *temporaryResolution;
@property (nonatomic, copy, nullable) NSString *displayedText;
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
/// Rebinds the same visual row sequence, including shifted source ranges,
/// without reloading the table, changing the selected row or scrolling.
/// Returns NO if the inventory changed or a normal activation is pending.
- (BOOL)updateGroupsWithSameRows:(NSArray<GACharacterGroup *> *)groups
                           rows:(NSArray<GARowItem *> *)rows;
- (void)clearTemporaryGlyph;
- (BOOL)selectVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group
    temporaryResolution:(nullable GAGlyphResolution *)temporary;
@end

// Map unchanged source spans across the edit between two published texts.
// Intersecting spans were replaced/deleted and must not bind to another character.
typedef struct {
    NSRange changed;
    NSInteger shift;
} GASourceEdit;

static GASourceEdit GASourceEditBetween(NSString *before, NSString *after) {
    if (before == nil || after == nil || [before isEqualToString:after])
        return (GASourceEdit){ NSMakeRange(NSNotFound, 0), 0 };
    NSUInteger prefix = 0, suffix = 0;
    NSUInteger common = MIN(before.length, after.length);
    while (prefix < common && [before characterAtIndex:prefix] == [after characterAtIndex:prefix])
        prefix++;
    while (suffix < common - prefix &&
           [before characterAtIndex:before.length - suffix - 1] ==
               [after characterAtIndex:after.length - suffix - 1])
        suffix++;
    return (GASourceEdit){ NSMakeRange(prefix, before.length - prefix - suffix),
                          (NSInteger)after.length - (NSInteger)before.length };
}

static NSRange GARemapSourceRange(NSRange range, GASourceEdit edit) {
    if (range.location == NSNotFound || edit.changed.location == NSNotFound ||
        NSMaxRange(range) <= edit.changed.location)
        return range;
    if (range.location >= NSMaxRange(edit.changed))
        return NSMakeRange((NSUInteger)((NSInteger)range.location + edit.shift), range.length);
    return NSMakeRange(NSNotFound, 0);
}

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
    if (GAUsesMacOS26Layout()) {
        self.scrollView.drawsBackground = NO;
        self.tableView.backgroundColor = NSColor.clearColor;
    }
    self.scrollView.accessibilityLabel = NSLocalizedString(@"Text and alternate glyph list", @"Text and alternate glyph list");

    [self.view addSubview:self.searchField];
    [self.view addSubview:self.scrollView];

    BOOL tahoeLayout = GAUsesMacOS26Layout();
    NSLayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.leadingAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.leadingAnchor : self.view.leadingAnchor
                                                        constant:tahoeLayout ? 12 : 9],
        [self.searchField.trailingAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.trailingAnchor : self.view.trailingAnchor
                                                         constant:tahoeLayout ? -12 : -9],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor
                                                   constant:9],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.bottomAnchor : self.view.bottomAnchor
                                                    constant:tahoeLayout ? -8 : 0],
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
            CGFloat topOffset = GAUsesMacOS26Layout() ? -8 : -1;
            if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
                topOffset = 0;
            self.searchTopConstraint = [self.searchField.topAnchor
                constraintEqualToAnchor:guide.topAnchor
                             constant:topOffset];
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
/// the app-owned foreground color, selection runs, and line-break markers. Everything else
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
    NSFont *font = [self inputFont];
    NSColor *color = [self inputTextColor];
    // Allow programmatic attributes (selection runs), but keep user edits and
    // pastes plain so external formatting cannot enter the field.
    BOOL wasSuppressed = self.suppressTextChangeCallback;
    self.suppressTextChangeCallback = YES;
    editor.richText = NO;
    editor.usesFontPanel = NO;
    editor.typingAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
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
                [attrs[key] isEqual:font]) {
                continue;
            }
            if ([key isEqualToString:NSForegroundColorAttributeName] &&
                [attrs[key] isEqual:color]) {
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
    [storage setAttributedString:GANormalizedSidebarInput(storage, font, color)];
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

- (BOOL)isInputFocused {
    NSText *editor = self.searchField.currentEditor;
    return editor != nil && self.searchField.window.firstResponder == editor;
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

- (void)replaceInputText:(NSString *)text {
    if (![self.searchField.window makeFirstResponder:self.searchField]) return;
    [self prepareFieldEditor];
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    [editor insertText:text replacementRange:NSMakeRange(0, editor.string.length)];
}

- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange
                               scroll:(GAPendingSelectionScroll)scroll {
    self.pendingSelectionGlyphKey = glyphKey;
    self.pendingSelectionTextRange = textRange;
    self.pendingSelectionScroll = scroll;
}

- (NSString *)selectedGlyphSourceText {
    GARowItem *row = [self selectedVariantRow];
    NSRange range = row.variant.sourceTextRange;
    if (row.variant.isLigature && range.location != NSNotFound) {
        NSString *text = self.text;
        if (NSMaxRange(range) <= text.length) return [text substringWithRange:range];
    }
    return row.group.text ?: @"";
}

- (GARowItem *)selectedVariantRow {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) return nil;
    return self.rows[(NSUInteger)row];
}

/// Keep the selected variant and its source range as one state update.
- (void)rememberSelectedRow:(NSInteger)row {
    if (row >= 0 && row < (NSInteger)self.rows.count) {
        self.selectedVariant = self.rows[(NSUInteger)row].variant;
        self.selectedVariantTextRange = self.rows[(NSUInteger)row].group.textRange;
    } else {
        self.selectedVariant = nil;
        self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
    }
}

- (void)activateRowAtIndex:(NSInteger)row
                 modifiers:(NSEventModifierFlags)modifiers {
    if (row < 0 || row >= (NSInteger)self.rows.count) return;
    GARowItem *item = self.rows[(NSUInteger)row];
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
    return item.variant.unicodeScalars.count > 0;
}

- (void)copySelectedGlyphEncoding {
    GARowItem *item = [self selectedVariantRow];
    if (item.variant.unicodeScalars.count == 0) {
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

- (void)focusGlyphList {
    [self.tableView.window makeFirstResponder:self.tableView];
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
    if (commandSelector == @selector(cancelOperation:) ||
        commandSelector == @selector(insertNewline:)) {
        [self focusGlyphList];
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
    NSUInteger groupIndex = [self.groups indexOfObjectIdenticalTo:item.group];
    if (groupIndex != NSNotFound && groupIndex + 1 < self.groups.count) {
        [self selectBaseRowForGroupAtIndex:groupIndex + 1];
    }
}

#pragma mark - Updating groups

/// Restores the first row matching both the source range and glyph key.
- (NSInteger)rowForGlyphKey:(NSString *)glyphKey textRange:(NSRange)textRange {
    if (textRange.length == 0) {
        return NSNotFound;
    }
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
        GARowItem *item = self.rows[(NSUInteger)index];
        if (NSEqualRanges(item.group.textRange, textRange) &&
            [item.variant.glyphKey isEqualToString:glyphKey]) {
            return index;
        }
    }
    return NSNotFound;
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

/// Finds the group at an exact source range.
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

- (void)scrollTableToY:(CGFloat)y {
    NSClipView *clipView = self.scrollView.contentView;
    NSRect bounds = clipView.bounds;
    bounds.origin.y += y - NSMinY(clipView.documentVisibleRect);
    [clipView scrollToPoint:[clipView constrainBoundsRect:bounds].origin];
    [self.scrollView reflectScrolledClipView:clipView];
}

- (void)scrollSelectedRowToTopIfNeeded:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return;
    }
    [self.tableView layoutSubtreeIfNeeded];
    NSRect rowRect = [self.tableView rectOfRow:row];
    if (NSIntersectsRect(rowRect, self.scrollView.contentView.documentVisibleRect)) {
        return;
    }
    [self scrollTableToY:NSMinY(rowRect)];
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
    [self rememberSelectedRow:row];
    self.pendingSelectionGlyphKey = nil;
    self.suppressSelectionCallback = NO;
    [self notifySelection];
    return YES;
}

- (void)scrollGroupContainingRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return;
    }
    // Decide before centering: a visible selection never needs navigation.
    if (self.isViewLoaded) [self.view.window.contentView layoutSubtreeIfNeeded];
    [self.tableView layoutSubtreeIfNeeded];
    NSRect selectedRect = [self.tableView rectOfRow:row];
    NSRect visibleRect = self.scrollView.contentView.documentVisibleRect;
    if (NSMinY(selectedRect) >= NSMinY(visibleRect) &&
        NSMaxY(selectedRect) <= NSMaxY(visibleRect)) return;

    GACharacterGroup *group = self.rows[(NSUInteger)row].group;
    NSInteger first = row;
    NSInteger last = row;
    for (NSInteger index = 0; index < (NSInteger)self.rows.count; index++) {
        if (self.rows[(NSUInteger)index].group == group) {
            first = MIN(first, index);
            last = index;
        }
    }
    [self.tableView rectOfRow:first];
    [self.tableView rectOfRow:last];
    NSRect firstRect = [self.tableView rectOfRow:first];
    NSRect lastRect = [self.tableView rectOfRow:last];
    visibleRect = self.scrollView.contentView.documentVisibleRect;
    CGFloat groupCenter = (NSMinY(firstRect) + NSMaxY(lastRect)) * 0.5;
    [self scrollTableToY:groupCenter - NSHeight(visibleRect) * 0.5];
    // Only the selected row decides the minimal correction after centering.
    selectedRect = [self.tableView rectOfRow:row];
    visibleRect = self.scrollView.contentView.documentVisibleRect;
    if (NSMinY(selectedRect) < NSMinY(visibleRect))
        [self scrollTableToY:NSMinY(selectedRect)];
    else if (NSMaxY(selectedRect) > NSMaxY(visibleRect))
        [self scrollTableToY:NSMaxY(selectedRect) - NSHeight(visibleRect)];
}

- (BOOL)updateGroupsWithSameRows:(NSArray<GACharacterGroup *> *)groups
                           rows:(NSArray<GARowItem *> *)rows {
    if (self.pendingSelectionGlyphKey != nil) return NO;
    if (rows.count != self.rows.count) return NO;
    for (NSUInteger i = 0; i < rows.count; i++) {
        GARowItem *old = self.rows[i], *updated = rows[i];
        BOOL oldGroupStarts = i == 0 || self.rows[i - 1].group != old.group;
        BOOL newGroupStarts = i == 0 || rows[i - 1].group != updated.group;
        // Absolute source locations move after edits. They are rebound below,
        // not a reason to reload an otherwise identical visual row sequence.
        if (oldGroupStarts != newGroupStarts ||
            old.group.textRange.length != updated.group.textRange.length ||
            ![old.group.text isEqualToString:updated.group.text] ||
            old.group.seeded != updated.group.seeded ||
            old.group.insertedLigature != updated.group.insertedLigature ||
            old.variant.isBase != updated.variant.isBase ||
            old.variant.isLigature != updated.variant.isLigature ||
            old.variant.isTemporary != updated.variant.isTemporary ||
            ![old.variant.glyphKey isEqualToString:updated.variant.glyphKey] ||
            ![old.variant.featureSources isEqualToArray:updated.variant.featureSources] ||
            ![old.variant.unicodeScalars isEqualToArray:updated.variant.unicodeScalars] ||
            ![old.variant.glyphName isEqualToString:updated.variant.glyphName]) return NO;
    }
    _groups = [groups copy];
    self.rows = rows;
    NSInteger selected = self.tableView.selectedRow;
    if (selected >= 0 && selected < (NSInteger)rows.count) {
        [self rememberSelectedRow:selected];
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
    for (GARowItem *row in self.rows) {
        if (!NSEqualRanges(row.group.textRange, range) || ![row.variant.glyphIDs isEqual:glyphIDs])
            continue;
        return [self selectVariant:row.variant inGroup:row.group
            temporaryResolution:row.variant.isTemporary ? self.temporaryResolution : nil];
    }
    return NO;
}

- (BOOL)selectVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group
    temporaryResolution:(GAGlyphResolution *)temporary {
    BOOL replacesRows = self.temporaryResolution != temporary;
    NSArray<GARowItem *> *rows = replacesRows ? GARowsForGroups(self.groups, temporary) : self.rows;
    for (NSUInteger index = 0; index < rows.count; index++) {
        GARowItem *row = rows[index];
        if (row.group != group || row.variant != variant) continue;
        NSDictionary *anchor = replacesRows ? [self captureScrollAnchor] : nil;
        self.suppressSelectionCallback = YES;
        self.pendingSelectionGlyphKey = nil;
        // Publish only the final row set. Removing an old temporary item must
        // not select/notify its parent or navigate before the target is ready.
        if (replacesRows) {
            self.temporaryResolution = temporary;
            self.rows = rows;
            [self reloadTableGeometry];
            [self restoreScrollAnchor:anchor];
        }
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                    byExtendingSelection:NO];
        [self rememberSelectedRow:(NSInteger)index];
        [self scrollGroupContainingRow:index];
        self.suppressSelectionCallback = NO;
        [self notifySelection];
        return YES;
    }
    return NO;
}

- (void)clearTemporaryGlyph {
    if (!self.temporaryResolution) return;
    NSDictionary *anchor = [self captureScrollAnchor];
    GAGlyphVariant *selected = self.selectedVariant;
    self.temporaryResolution = nil;
    self.rows = GARowsForGroups(self.groups, nil);
    self.suppressSelectionCallback = YES;
    [self reloadTableGeometry];
    [self.tableView deselectAll:nil];
    for (NSUInteger i = 0; i < self.rows.count; i++)
        if (self.rows[i].variant == selected) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            break;
        }
    [self restoreScrollAnchor:anchor];
    self.suppressSelectionCallback = NO;
}

- (void)showGlyphResolution:(GAGlyphResolution *)resolution {
    for (GARowItem *parent in self.rows) {
        if (parent.variant != resolution.parent) continue;
        [self selectVariant:resolution.variant inGroup:parent.group temporaryResolution:resolution];
        return;
    }
}

- (void)selectBaseForTextRange:(NSRange)range {
    GACharacterGroup *group = [self groupForTextRange:range];
    if (!group)
        for (GACharacterGroup *candidate in self.groups)
            if (NSIntersectionRange(candidate.textRange, range).length) {
                group = candidate;
                break;
            }
    for (GARowItem *row in self.rows)
        if (row.variant.isBase && (!group || row.group == group)) {
            [self selectGlyphIDs:row.variant.glyphIDs textRange:row.group.textRange];
            return;
        }
}

- (GAGlyphResolution *)rebindTemporaryForGroups:(NSArray<GACharacterGroup *> *)groups
                                    sourceText:(NSString *)text
                                      document:(GAFontDocument *)document {
    GAGlyphResolution *temporary = self.temporaryResolution;
    if (!temporary || self.selectedVariant != temporary.variant || self.pendingSelectionGlyphKey)
        return nil;
    GARowItem *oldParent = nil;
    for (GARowItem *row in self.rows)
        if (row.variant == temporary.parent) {
            oldParent = row;
            break;
        }
    if (!oldParent) return nil;
    NSRange range = GARemapSourceRange(oldParent.group.textRange,
        GASourceEditBetween(self.displayedText, text));
    if (range.location == NSNotFound) return nil;
    for (GACharacterGroup *group in groups) {
        if (!NSEqualRanges(group.textRange, range) ||
            ![group.text isEqualToString:oldParent.group.text] ||
            group.seeded != oldParent.group.seeded ||
            group.insertedLigature != oldParent.group.insertedLigature)
            continue;
        GAGlyphVariant *parent = nil;
        for (GAGlyphVariant *variant in group.variants) {
            // A newly persistent result takes over without a duplicate row.
            if ([variant.glyphIDs isEqual:temporary.variant.glyphIDs]) return nil;
            if ([variant.glyphIDs isEqual:temporary.parent.glyphIDs]) parent = variant;
        }
        if (!parent) return nil;
        GAGlyphResolution *rebound = [[GAGlyphResolution alloc] init];
        rebound.parent = parent;
        rebound.variant = [document rebindVariant:temporary.variant content:group.text];
        rebound.variant.sourceTextRange = range;
        return rebound;
    }
    return nil;
}

- (void)updateGroups:(NSArray<GACharacterGroup *> *)groups
           sourceText:(NSString *)text
         fontDocument:(GAFontDocument *)document {
    self.temporaryResolution = [self rebindTemporaryForGroups:groups sourceText:text document:document];
    NSArray<GARowItem *> *rows = GARowsForGroups(groups, self.temporaryResolution);
    if ([self updateGroupsWithSameRows:groups rows:rows]) {
        self.displayedText = text;
        return;
    }
    [self setGroups:groups sourceText:text rows:rows];
}

- (void)setGroups:(NSArray<GACharacterGroup *> *)groups {
    self.temporaryResolution = nil;
    [self setGroups:groups sourceText:nil rows:GARowsForGroups(groups, nil)];
}

- (void)setGroups:(NSArray<GACharacterGroup *> *)groups sourceText:(NSString *)text
             rows:(NSArray<GARowItem *> *)rows {
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0;
    @try {
        NSDictionary *scrollAnchor = [self captureScrollAnchor];
        NSString *oldGlyphKey = nil;
        NSRange oldGroupRange = GARemapSourceRange(self.selectedVariantTextRange,
            GASourceEditBetween(self.displayedText, text));
        if (self.selectedVariant != nil) {
            oldGlyphKey = self.selectedVariant.glyphKey;
        } else {
            oldGroupRange = NSMakeRange(NSNotFound, 0);
        }

        _groups = [groups copy];
        self.displayedText = text;
        self.rows = rows;

        self.suppressSelectionCallback = YES;
        [self reloadTableGeometry];

        BOOL hasPending = self.pendingSelectionGlyphKey.length > 0;
        if (hasPending) {
            if ([self resolvePendingSelectionIfPossible]) {
                return;
            }
            // The appended character group is not in this snapshot yet (or has no
            // rows). Wait; do not restore the old selection or jump to the first.
            [self rememberSelectedRow:NSNotFound];
            [self restoreScrollAnchor:scrollAnchor];
            self.suppressSelectionCallback = NO;
            [self notifySelection];
            return;
        }

        NSInteger rowToSelect = NSNotFound;
        if (oldGlyphKey.length > 0) {
            rowToSelect = [self rowForGlyphKey:oldGlyphKey textRange:oldGroupRange];
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
        }
        [self rememberSelectedRow:rowToSelect];
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
    NSMutableArray *rows = [NSMutableArray array];
    if (visible.location != NSNotFound) {
        for (NSUInteger i = visible.location; i < MIN(self.rows.count, NSMaxRange(visible)); i++) {
            GARowItem *row = self.rows[i];
            [rows addObject:@{
                @"key" : row.variant.glyphKey,
                @"range" : [NSValue valueWithRange:row.group.textRange],
                @"text" : row.group.text,
                @"ligature" : @(row.group.insertedLigature),
                @"offset" : @(NSMinY(self.scrollView.contentView.documentVisibleRect) -
                               NSMinY([self.tableView rectOfRow:(NSInteger)i]))
            }];
        }
    }
    NSMutableDictionary *anchor = [@{@"origin" : [NSValue valueWithPoint:origin],
                                     @"rows" : rows} mutableCopy];
    if (self.displayedText != nil) anchor[@"text"] = self.displayedText;
    return anchor;
}

- (void)restoreScrollAnchor:(NSDictionary *)anchor {
    NSPoint origin = [anchor[@"origin"] pointValue];
    GASourceEdit edit = GASourceEditBetween(anchor[@"text"], self.displayedText);
    for (NSDictionary *visible in anchor[@"rows"]) {
        NSRange range = GARemapSourceRange([visible[@"range"] rangeValue], edit);
        GACharacterGroup *group = nil;
        for (GACharacterGroup *candidate in self.groups)
            if (NSEqualRanges(candidate.textRange, range) &&
                [candidate.text isEqualToString:visible[@"text"]] &&
                candidate.insertedLigature == [visible[@"ligature"] boolValue]) {
                group = candidate;
                break;
            }
        if (group == nil) continue;
        NSInteger row = [self rowForGlyphKey:visible[@"key"] inGroup:group];
        if (row == NSNotFound && group.variants.count)
            row = [self rowForGlyphKey:group.variants.firstObject.glyphKey inGroup:group];
        if (row == NSNotFound) continue;
        NSRect rect = [self.tableView rectOfRow:row];
        CGFloat target = NSMinY(rect) + MIN([visible[@"offset"] doubleValue], NSHeight(rect) - 1);
        origin.y += target - NSMinY(self.scrollView.contentView.documentVisibleRect);
        break;
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
    self.lastNotifiedGlyphKey = key;
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
        [self rememberSelectedRow:NSNotFound];
        [self clearTemporaryGlyph];
        [self notifySelection];
        return;
    }
    // A manual click overrides any pending auto-selection from an append or
    // activation; later list snapshots must not snap the user back.
    self.pendingSelectionGlyphKey = nil;
    [self rememberSelectedRow:row];
    if (!self.selectedVariant.isTemporary) [self clearTemporaryGlyph];
    [self notifySelection];
}

@end
