#import "GASidebarViewController.h"
#import "Input/GAInput.h"
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
@property (nonatomic, strong) GASearchField *searchField;
@property (nonatomic, strong) GASearchField *sidebarSearchField;
@property (nonatomic, strong) GASearchField *toolbarSearchField;
@property (nonatomic, strong) NSLayoutConstraint *sidebarListTopConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *pinnedSidebarListTopConstraint;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSViewController *inputAccessory;
@property (nonatomic, strong) NSArray<GACharacterGroup *> *groups;
@property (nonatomic, strong) NSArray<GARowItem *> *rows;
@property (nonatomic, strong, nullable) GAGlyphResolution *temporaryResolution;
@property (nonatomic, copy, nullable) NSString *displayedText;
@property (nonatomic, copy, nullable) NSString *trackedFieldText;
@property (nonatomic, strong, nullable) NSMutableData *displayedSourceEdits;
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
@property (nonatomic) BOOL handlingNativeInputEdit;
@property (nonatomic) BOOL inputChangedDuringReplay;
@property (nonatomic, strong) GASearchFieldEditor *searchFieldEditor;
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
static const CGFloat GASidebarInputSpacing = 9;

static void GAApplyInputAttributes(NSTextStorage *storage, NSAttributedString *text) {
    [storage beginEditing];
    [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0
        usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attributes, NSRange range, BOOL *stop) {
            (void)stop;
            [storage setAttributes:attributes range:range];
        }];
    [storage endEditing];
}

@implementation GASidebarViewController

- (void)loadView {
    // The sidebar item + NSTableView Source List style provide the material.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 760)];
}

- (GASearchField *)newInputField {
    GASearchField *field = [[GASearchField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholderString = NSLocalizedString(@"Enter text", @"Enter text");
    field.controlSize = NSControlSizeLarge;
    field.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightRegular];
    // Custom selection attributes live in the field's attributed string and
    // must survive the field editor's edit cycle.
    field.allowsEditingTextAttributes = YES;
    field.delegate = self;
    __weak typeof(self) weakSelf = self;
    field.onFieldEditorFocus = ^{
        [weakSelf prepareFieldEditor];
    };
    NSSearchFieldCell *searchCell = (NSSearchFieldCell *)field.cell;
    // Keep the native search-field bezel, but no magnifier or clear button.
    searchCell.searchButtonCell = nil;
    searchCell.cancelButtonCell = nil;
    field.accessibilityLabel = NSLocalizedString(@"Enter text", @"Enter text");
    return field;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.sidebarSearchField = [self newInputField];
    self.searchField = self.sidebarSearchField;
    self.searchFieldEditor = [[GASearchFieldEditor alloc] initWithFrame:NSZeroRect];
    self.searchFieldEditor.fieldEditor = YES;
    self.searchFieldEditor.allowsUndo = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(recordFieldEdit:)
        name:NSTextStorageWillProcessEditingNotification object:self.searchFieldEditor.textStorage];

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
    self.sidebarListTopConstraint =
        [self.scrollView.topAnchor constraintEqualToAnchor:self.sidebarSearchField.bottomAnchor
                                                  constant:GASidebarInputSpacing];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.leadingAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.leadingAnchor : self.view.leadingAnchor
                                                        constant:tahoeLayout ? 12 : 9],
        [self.searchField.trailingAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.trailingAnchor : self.view.trailingAnchor
                                                         constant:tahoeLayout ? -12 : -9],
        self.sidebarListTopConstraint,
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:
            tahoeLayout ? safeArea.bottomAnchor : self.view.bottomAnchor
                                                    constant:tahoeLayout ? -8 : 0],
    ]];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self updateSidebarTopConstraint];
}

- (void)enableScrollEdgeEffectForSplitViewItem:(NSSplitViewItem *)item {
    [self view];
    self.searchTopConstraint.active = NO;
    self.searchTopConstraint = nil;
    self.sidebarListTopConstraint.active = NO;
    [self.sidebarSearchField removeFromSuperview];

    NSView *content = [[NSView alloc] initWithFrame:
        NSMakeRect(0, 0, NSWidth(self.view.bounds),
                   self.sidebarSearchField.fittingSize.height + GASidebarInputSpacing)];
    [content addSubview:self.sidebarSearchField];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarSearchField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.sidebarSearchField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.sidebarSearchField.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.sidebarSearchField.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                          constant:-GASidebarInputSpacing],
    ]];

    // Resolve at runtime so builds with an older SDK can use the public class.
    NSSplitViewItemAccessoryViewController *accessory =
        [NSClassFromString(@"NSSplitViewItemAccessoryViewController") new];
    accessory.automaticallyAppliesContentInsets = NO;
    accessory.view = content;
    self.inputAccessory = accessory;
    self.sidebarListTopConstraint =
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    self.sidebarListTopConstraint.active = YES;
    [item addTopAlignedAccessoryViewController:accessory];
}

- (void)updateSidebarTopConstraint {
    self.searchTopConstraint.active = NO;
    self.searchTopConstraint = nil;
    if (self.inputAccessory) return;
    NSLayoutGuide *guide = (NSLayoutGuide *)self.view.window.contentLayoutGuide;
    if (!guide) return;

    CGFloat topOffset = GAUsesMacOS26Layout() ? -8 : -1;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        topOffset = 0;
    self.searchTopConstraint = [self.sidebarSearchField.topAnchor constraintEqualToAnchor:guide.topAnchor constant:topOffset];
    self.searchTopConstraint.active = YES;
}

- (void)setSidebarListTopPinned:(BOOL)pinned {
    self.pinnedSidebarListTopConstraint.active = NO;
    self.pinnedSidebarListTopConstraint = nil;
    self.sidebarListTopConstraint.active = !pinned;
    if (pinned) {
        NSRect frame = self.scrollView.frame;
        NSRect bounds = self.view.bounds;
        CGFloat top = self.view.flipped ? NSMinY(frame) - NSMinY(bounds) : NSMaxY(bounds) - NSMaxY(frame);
        self.pinnedSidebarListTopConstraint =
            [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:top];
        self.pinnedSidebarListTopConstraint.active = YES;
    }
}

- (void)useInputInToolbarContainer:(NSView *)container {
    if (container && !self.toolbarSearchField) {
        GASearchField *field = [self newInputField];
        field.usesUniformIdleTextColor = YES;
        self.toolbarSearchField = field;
        [field setContentHuggingPriority:NSLayoutPriorityFittingSizeCompression
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
        [container addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [field.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [field.topAnchor constraintEqualToAnchor:container.topAnchor],
            [field.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        ]];
    }
    GASearchField *input = container ? self.toolbarSearchField : self.sidebarSearchField;
    if (input == self.searchField) return;
    // Both controls use the same editor and undo history, one at a time.
    self.searchField.editable = NO;
    self.searchField.selectable = NO;
    self.searchField = input;
    self.sidebarSearchField.hidden = container != nil;
    input.editable = YES;
    [self syncDetachedInput];
}

- (void)setToolbarInputPlaceholder:(NSString *)placeholder {
    self.toolbarSearchField.placeholderString = placeholder;
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

/// Returns only the attributes this app understands: the default font,
/// the app-owned foreground color, selection runs, and line-break markers. Everything else
/// (pasted colors, backgrounds, paragraph styles, links, attachments) is
/// discarded.
- (NSAttributedString *)plainCopyOfAttributedText:(NSAttributedString *)text {
    return GANormalizedSidebarInput(text, [self inputFont], NSColor.controlTextColor);
}

- (void)prepareFieldEditor {
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    if (editor == nil) {
        return;
    }
    NSFont *font = [self inputFont];
    NSColor *color = NSColor.controlTextColor;
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
        // AppKit may extend a marker's attributes to adjacent pasted text.
        if (attrs[GALineBreakAttributeName] != nil) {
            if (![attrs[NSForegroundColorAttributeName] isEqual:NSColor.secondaryLabelColor]) {
                needsNormalization = YES;
                *stop = YES;
                return;
            }
            unichar marker = GAInputSeparatorMarker([attrs[GALineBreakAttributeName] unsignedShortValue]);
            for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
                if (!marker || [storage.string characterAtIndex:i] != marker) {
                    needsNormalization = YES;
                    *stop = YES;
                    break;
                }
            }
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

    self.suppressTextChangeCallback = YES;
    GAApplyInputAttributes(storage, GANormalizedSidebarInput(storage, font, color));
    self.suppressTextChangeCallback = wasSuppressed;
}

- (NSAttributedString *)attributedText {
    return GAModelTextFromFieldText([self plainCopyOfAttributedText:self.searchFieldEditor.textStorage]);
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

- (void)setGlyphSelection:(GAGlyphSelection *)selection inRange:(NSRange)range
             registerUndo:(BOOL)registerUndo {
    NSTextStorage *storage = self.searchFieldEditor.textStorage;
    if (NSMaxRange(range) > storage.length) return;
    GAGlyphSelection *previous = [storage attribute:GAGlyphSelectionAttributeName
                                            atIndex:range.location effectiveRange:NULL];
    if (selection == previous) return;
    if (registerUndo) {
        [self.searchFieldEditor.undoManager registerUndoWithTarget:self
            handler:^(GASidebarViewController *target) {
                [target setGlyphSelection:previous inRange:range registerUndo:YES];
            }];
    }
    if (selection) [storage addAttribute:GAGlyphSelectionAttributeName value:selection range:range];
    else [storage removeAttribute:GAGlyphSelectionAttributeName range:range];
}

- (void)updateGlyphSelectionsFromText:(NSAttributedString *)text ranges:(NSArray<NSValue *> *)ranges {
    GASearchFieldEditor *editor = self.searchFieldEditor;
    NSTextStorage *storage = editor.textStorage;
    NSUndoManager *manager = editor.undoManager;
    BOOL registerUndo = self.handlingNativeInputEdit && manager.undoRegistrationEnabled && manager.groupingLevel > 0;
    // Keep the cleanup with its text edit, and prevent the next keystroke
    // from being coalesced into the text operation ahead of this cleanup.
    if (registerUndo) [editor breakUndoCoalescing];
    [storage beginEditing];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        [text enumerateAttribute:GAGlyphSelectionAttributeName inRange:range options:0
            usingBlock:^(GAGlyphSelection *selection, NSRange subrange, BOOL *stop) {
                (void)stop;
                [self setGlyphSelection:selection inRange:subrange registerUndo:registerUndo];
            }];
    }
    [storage endEditing];
    [self syncDetachedInput];
}

- (void)syncDetachedInput {
    if (self.searchField.currentEditor == nil) {
        [self.searchField setIdleAttributedStringValue:self.searchFieldEditor.textStorage];
    }
}

- (BOOL)commitGlyphInput:(NSAttributedString *)attributedText actionName:(NSString *)actionName {
    GASearchFieldEditor *editor = self.searchFieldEditor;
    if (editor.hasMarkedText) return NO;
    NSAttributedString *replacement = [self plainCopyOfAttributedText:GAFieldTextFromModelText(attributedText)];
    NSTextStorage *storage = editor.textStorage;
    if ([storage isEqualToAttributedString:replacement]) return YES;

    NSRange all = NSMakeRange(0, storage.length);
    NSRange selection = editor.selectedRange;
    BOOL changesCharacters = ![storage.string isEqualToString:replacement.string];
    NSUndoManager *undoManager = editor.undoManager;
    BOOL registersUndo = undoManager.undoRegistrationEnabled;
    [editor breakUndoCoalescing];
    if (registersUndo) [undoManager beginUndoGrouping];
    self.suppressTextChangeCallback = YES;
    BOOL applied = [editor shouldChangeTextInRange:all
                               replacementString:changesCharacters ? replacement.string : nil];
    if (applied) {
        if (changesCharacters) {
            self.displayedSourceEdits = nil;
            [storage replaceCharactersInRange:all withAttributedString:replacement];
        } else {
            GAApplyInputAttributes(storage, replacement);
        }
        [editor didChangeText];
        if (self.searchField.currentEditor == editor && selection.location != NSNotFound) {
            NSUInteger location = MIN(selection.location, storage.length);
            editor.selectedRange = NSMakeRange(location, MIN(selection.length, storage.length - location));
        }
        if (registersUndo) [undoManager setActionName:actionName];
    }
    self.suppressTextChangeCallback = NO;
    if (registersUndo) [undoManager endUndoGrouping];
    if (applied) {
        self.pendingSelectionGlyphKey = nil;
        [self syncDetachedInput];
    }
    return applied;
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
    if (self.onGlyphActivated) {
        self.onGlyphActivated(item.group, item.variant,
                              GAModifiersAre(modifiers, NSEventModifierFlagShift));
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
                   selection:(GAGlyphSelection *)selection
                  actionName:(NSString *)actionName {
    if (string.length == 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSMutableAttributedString *text = [self.attributedText mutableCopy];
    NSRange range = NSMakeRange(text.length, string.length);
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:string]];
    if (selection != nil) {
        [text addAttribute:GAGlyphSelectionAttributeName value:selection range:range];
    }
    return [self commitGlyphInput:text actionName:actionName] ? range : NSMakeRange(NSNotFound, 0);
}

- (void)focusInput {
    NSWindow *window = self.searchField.window;
    if (window == nil || ![window makeFirstResponder:self.searchField]) return;
    [self prepareFieldEditor];
}

- (void)restoreInputSelection:(NSRange)selection {
    [self focusInput];
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    NSUInteger start = MIN(selection.location, editor.string.length);
    editor.selectedRange = NSMakeRange(start, MIN(selection.length, editor.string.length - start));
}

- (void)focusGlyphList {
    BOOL inputInSidebar = self.searchField == self.sidebarSearchField;
    [self.searchField.window makeFirstResponder:inputInSidebar ? self.tableView : nil];
}

/// The window asks for a field editor when a control starts editing. Only the
/// search field gets the custom editor; other controls keep the default one.
- (NSTextView *)fieldEditorForControl:(id)control {
    if (control != self.searchField) {
        return nil;
    }
    NSUndoManager *manager = self.searchField.window.undoManager;
    NSUndoManager *previousManager = self.searchFieldEditor.inputUndoManager;
    if (manager != previousManager) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSUndoManagerDidUndoChangeNotification,
                                           NSUndoManagerDidRedoChangeNotification]) {
            if (previousManager) [center removeObserver:self name:name object:previousManager];
            if (manager) [center addObserver:self selector:@selector(didReplayInputEdit:) name:name object:manager];
        }
        self.searchFieldEditor.inputUndoManager = manager;
    }
    return self.searchFieldEditor;
}

- (NSString *)currentFieldText {
    return self.searchFieldEditor.string;
}

- (void)didReplayInputEdit:(NSNotification *)notification {
    if (!self.inputChangedDuringReplay) return;
    self.inputChangedDuringReplay = NO;
    self.displayedSourceEdits = nil;
    [self syncDetachedInput];
    [self prepareFieldEditor];
    if (self.onInputUndoRedo) self.onInputUndoRedo();
}

- (void)recordFieldEdit:(NSNotification *)notification {
    NSTextStorage *storage = notification.object;
    NSUndoManager *manager = self.searchFieldEditor.undoManager;
    if (manager.isUndoing || manager.isRedoing) {
        self.inputChangedDuringReplay = YES;
        return;
    }
    if (!self.displayedSourceEdits || self.suppressTextChangeCallback ||
        self.searchField.currentEditor != self.searchFieldEditor ||
        !(storage.editedMask & NSTextStorageEditedCharacters)) {
        return;
    }
    NSRange changed = storage.editedRange;
    NSString *before = self.trackedFieldText;
    NSString *after = storage.string;
    NSInteger shift = storage.changeInLength;
    NSInteger oldLength = (NSInteger)changed.length - shift;
    if (changed.location > before.length || NSMaxRange(changed) > after.length ||
        oldLength < 0 || (NSUInteger)oldLength > before.length - changed.location ||
        (NSInteger)before.length + shift != (NSInteger)after.length) {
        self.displayedSourceEdits = nil;
        return;
    }
    NSRange replaced = NSMakeRange(changed.location, (NSUInteger)oldLength);
    if (![[before substringToIndex:replaced.location] isEqualToString:[after substringToIndex:changed.location]] ||
        ![[before substringFromIndex:NSMaxRange(replaced)] isEqualToString:[after substringFromIndex:NSMaxRange(changed)]]) {
        self.displayedSourceEdits = nil;
        return;
    }
    GASourceEdit edit = { replaced, shift };
    [self.displayedSourceEdits appendBytes:&edit length:sizeof(edit)];
    self.trackedFieldText = after;
}

- (NSRange)currentInputRangeForDisplayedRange:(NSRange)range {
    if (!self.displayedSourceEdits || ![self.trackedFieldText isEqualToString:self.currentFieldText]) {
        return NSMakeRange(NSNotFound, 0);
    }
    const GASourceEdit *edits = self.displayedSourceEdits.bytes;
    NSUInteger count = self.displayedSourceEdits.length / sizeof(*edits);
    for (NSUInteger index = 0; index < count && range.location != NSNotFound; index++) {
        range = GARemapSourceRange(range, edits[index]);
    }
    return range;
}

- (void)setGlyphListDimmed:(BOOL)dimmed {
    self.tableView.alphaValue = dimmed ? GASidebarInactiveGlyphListAlpha : 1.0;
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object != self.searchField || self.suppressTextChangeCallback) {
        return;
    }
    NSTextView *editor = (NSTextView *)self.searchField.currentEditor;
    NSUndoManager *manager = self.searchFieldEditor.undoManager;
    if (editor.hasMarkedText || manager.isUndoing || manager.isRedoing) {
        return;
    }
    self.pendingSelectionGlyphKey = nil;
    [self prepareFieldEditor];
    if (self.onTextChanged) {
        self.handlingNativeInputEdit = YES;
        self.onTextChanged();
        self.handlingNativeInputEdit = NO;
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

- (void)selectBaseStartingAtRow:(NSInteger)row step:(NSInteger)step
                  skippingGroup:(GACharacterGroup *)group {
    for (NSInteger index = row; index >= 0 && index < (NSInteger)self.rows.count; index += step) {
        GARowItem *item = self.rows[(NSUInteger)index];
        if (item.group != group && item.variant.isBase) {
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
        [self selectBaseStartingAtRow:0 step:1 skippingGroup:nil];
        return;
    }
    GARowItem *item = self.rows[(NSUInteger)row];
    [self selectBaseStartingAtRow:row - 1 step:-1 skippingGroup:item.variant.isBase ? item.group : nil];
}

- (void)selectNextGroupBase {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        [self selectBaseStartingAtRow:0 step:1 skippingGroup:nil];
        return;
    }
    GARowItem *item = self.rows[(NSUInteger)row];
    [self selectBaseStartingAtRow:row + 1 step:1 skippingGroup:item.group];
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

/// Consumes the request when its query publishes, even if there is no target row.
- (BOOL)applyPendingSelection {
    NSInteger row = [self rowForPendingSelection];
    self.pendingSelectionGlyphKey = nil;
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
    self.suppressSelectionCallback = NO;
    [self notifySelectionWithQuickReveal:self.pendingSelectionScroll == GAPendingSelectionScrollGroup];
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
    self.trackedFieldText = self.currentFieldText;
    self.displayedSourceEdits = [NSMutableData data];
    self.temporaryResolution = [self rebindTemporaryForGroups:groups sourceText:text document:document];
    NSArray<GARowItem *> *rows = GARowsForGroups(groups, self.temporaryResolution);
    if ([self updateGroupsWithSameRows:groups rows:rows]) {
        self.displayedText = text;
        return;
    }
    [self setGroups:groups sourceText:text rows:rows];
}

- (void)clearGroups {
    self.pendingSelectionGlyphKey = nil;
    self.displayedSourceEdits = nil;
    self.temporaryResolution = nil;
    [self setGroups:@[] sourceText:nil rows:@[]];
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

        if ([self applyPendingSelection]) return;

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
    [self notifySelectionWithQuickReveal:NO];
}

- (void)notifySelectionWithQuickReveal:(BOOL)quickReveal {
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
    self.onSelectionChanged(self.selectedVariant, quickReveal);
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

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    GAVariantRowView *view = [tableView makeViewWithIdentifier:@"VariantRow" owner:self];
    if (!view) {
        view = [[GAVariantRowView alloc] initWithFrame:NSZeroRect];
        view.identifier = @"VariantRow";
    }
    return view;
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
