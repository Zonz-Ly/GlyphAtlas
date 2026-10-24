#import "GASidebarViewController.h"
#import "GAGlyphViews.h"
#import "GAUnicode.h"

/// YES when the shortcut modifiers in `modifiers` are exactly `expected`.
/// Caps Lock, the function key, the numeric keypad, Help, and device-dependent
/// bits do not count.
static BOOL GAModifiersAre(NSEventModifierFlags modifiers,
                           NSEventModifierFlags expected) {
    NSEventModifierFlags mask =
        NSEventModifierFlagCommand |
        NSEventModifierFlagShift |
        NSEventModifierFlagOption |
        NSEventModifierFlagControl;
    return (modifiers & mask) == expected;
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

#pragma mark - Line-break marker

/// The input field keeps a line break as U+23CE RETURN SYMBOL carrying this
/// attribute. A literal U+23CE typed by the user has no attribute and stays a
/// normal character. The model text handed to the window uses U+000A instead;
/// the conversion is one UTF-16 unit for one, so ranges never move.
static NSString * const GALineBreakAttributeName = @"com.zonz.GlyphAtlas.lineBreak";
static NSString * const GALineBreakCharacter = @"\u23CE";

/// Marks one visible line-break character and gives it the secondary text
/// colour used by AppKit for auxiliary inline content.
static void GASetLineBreakMarker(NSMutableAttributedString *text, NSRange range) {
    [text addAttribute:GALineBreakAttributeName value:@YES range:range];
    [text addAttribute:NSForegroundColorAttributeName
                 value:[NSColor secondaryLabelColor]
                 range:range];
}

/// Replaces line breaks with markers and attaches the line-break attribute.
static NSAttributedString *GAMarkerTextFromString(NSString *string,
                                                  NSDictionary *attributes) {
    NSMutableString *converted = [NSMutableString stringWithCapacity:string.length];
    NSMutableIndexSet *markers = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar character = [string characterAtIndex:index];
        if (character == '\r') {
            if (index + 1 < string.length &&
                [string characterAtIndex:index + 1] == '\n') {
                index++;
            }
            [markers addIndex:converted.length];
            [converted appendString:GALineBreakCharacter];
        } else if (character == '\n') {
            [markers addIndex:converted.length];
            [converted appendString:GALineBreakCharacter];
        } else {
            [converted appendString:[string substringWithRange:NSMakeRange(index, 1)]];
        }
    }
    NSMutableAttributedString *text =
        [[NSMutableAttributedString alloc] initWithString:converted
                                                attributes:attributes];
    [markers enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        (void)stop;
        GASetLineBreakMarker(text, NSMakeRange(index, 1));
    }];
    return text;
}

/// Replaces the marker attribute with real line breaks for the model text.
static NSAttributedString *GAModelTextFromFieldText(NSAttributedString *fieldText) {
    if (fieldText.length == 0) {
        return [[NSAttributedString alloc] init];
    }
    NSRange all = NSMakeRange(0, fieldText.length);
    NSMutableArray<NSValue *> *markerRanges = [NSMutableArray array];
    [fieldText enumerateAttribute:GALineBreakAttributeName
                          inRange:all
                          options:0
                       usingBlock:^(id value, NSRange range, BOOL *stop) {
        (void)stop;
        if (value != nil) {
            [markerRanges addObject:[NSValue valueWithRange:range]];
        }
    }];
    NSMutableString *string = [fieldText.string mutableCopy];
    for (NSValue *value in markerRanges) {
        NSRange range = value.rangeValue;
        for (NSUInteger index = range.location; index < NSMaxRange(range); index++) {
            [string replaceCharactersInRange:NSMakeRange(index, 1) withString:@"\n"];
        }
    }
    NSMutableAttributedString *model = [[NSMutableAttributedString alloc] initWithString:string];
    [fieldText enumerateAttributesInRange:all
                                  options:0
                               usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                            NSRange range, BOOL *stop) {
        (void)stop;
        NSMutableDictionary *clean = [attrs mutableCopy];
        [clean removeObjectForKey:GALineBreakAttributeName];
        [model setAttributes:clean range:range];
    }];
    return model;
}

/// Replaces model line breaks with the visible marked character for the field.
static NSAttributedString *GAFieldTextFromModelText(NSAttributedString *modelText) {
    if (modelText.length == 0) {
        return [[NSAttributedString alloc] init];
    }
    NSRange all = NSMakeRange(0, modelText.length);
    NSMutableString *string = [modelText.string mutableCopy];
    NSMutableIndexSet *markers = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < string.length; index++) {
        if ([string characterAtIndex:index] == '\n') {
            [string replaceCharactersInRange:NSMakeRange(index, 1)
                                  withString:GALineBreakCharacter];
            [markers addIndex:index];
        }
    }
    NSMutableAttributedString *field = [[NSMutableAttributedString alloc] initWithString:string];
    [modelText enumerateAttributesInRange:all
                                  options:0
                               usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs,
                                            NSRange range, BOOL *stop) {
        (void)stop;
        NSMutableDictionary *clean = [attrs mutableCopy];
        [clean removeObjectForKey:GALineBreakAttributeName];
        [field setAttributes:clean range:range];
    }];
    [markers enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        (void)stop;
        GASetLineBreakMarker(field, NSMakeRange(index, 1));
    }];
    return field;
}

/// Converts newlines before the single-line field editor can turn them into
/// spaces. A newline is inserted as a marked U+23CE, so the field stays one
/// line tall and the character can be told apart from a literal U+23CE.
@interface GASearchFieldEditor : NSTextView
@end

@implementation GASearchFieldEditor

/// AppKit's single-line field editor does not map all four Command-arrow
/// variants to the document start/end (Command-Down is a no-op). Handle them
/// explicitly so the whole field behaves as one document.
- (void)keyDown:(NSEvent *)event {
    BOOL commandOnly =
        GAModifiersAre(event.modifierFlags, NSEventModifierFlagCommand);
    if (commandOnly) {
        if (event.keyCode == 123 || event.keyCode == 126) { // Left, Up
            [self moveToBeginningOfDocument:nil];
            return;
        }
        if (event.keyCode == 124 || event.keyCode == 125) { // Right, Down
            [self moveToEndOfDocument:nil];
            return;
        }
    }
    [super keyDown:event];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *inserted = nil;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        inserted = [(NSAttributedString *)string string];
    } else if ([string isKindOfClass:[NSString class]]) {
        inserted = string;
    }
    if (inserted.length == 0) {
        [super insertText:string replacementRange:replacementRange];
        return;
    }
    if ([inserted rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location ==
        NSNotFound) {
        [super insertText:string replacementRange:replacementRange];
        return;
    }
    NSRange range = replacementRange;
    if (range.location == NSNotFound) {
        range = self.selectedRange;
    }
    NSMutableDictionary *attributes = [self.typingAttributes mutableCopy];
    [attributes removeObjectForKey:GALineBreakAttributeName];
    NSAttributedString *text = GAMarkerTextFromString(inserted, attributes);
    if ([self shouldChangeTextInRange:range replacementString:text.string]) {
        [self.textStorage replaceCharactersInRange:range withAttributedString:text];
        [self didChangeText];
        [self setSelectedRange:NSMakeRange(range.location + text.length, 0)];
        self.typingAttributes = attributes;
    }
}

- (void)paste:(id)sender {
    NSString *string = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (string != nil &&
        [string rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location !=
            NSNotFound) {
        [self insertText:string replacementRange:self.selectedRange];
        return;
    }
    [super paste:sender];
}

/// Copy the selection as plain text, turning marked line breaks back into
/// U+000A. A literal U+23CE has no marker attribute and is copied as is.
- (void)copy:(id)sender {
    NSRange range = self.selectedRange;
    if (range.length == 0) {
        [super copy:sender];
        return;
    }
    NSAttributedString *selected = [self.textStorage attributedSubstringFromRange:range];
    NSString *model = GAModelTextFromFieldText(selected).string;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:model forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender {
    NSRange range = self.selectedRange;
    if (range.length == 0) {
        [super cut:sender];
        return;
    }
    [self copy:sender];
    if ([self shouldChangeTextInRange:range replacementString:@""]) {
        [self.textStorage replaceCharactersInRange:range withString:@""];
        [self didChangeText];
        [self setSelectedRange:NSMakeRange(range.location, 0)];
    }
}

/// Dragging out of the field also carries real line breaks. The superclass
/// writes the selection for every requested type; the plain-text entries are
/// then replaced with the model text.
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
                             types:(NSArray<NSPasteboardType> *)types {
    BOOL result = [super writeSelectionToPasteboard:pboard types:types];
    NSRange range = self.selectedRange;
    if (range.length == 0) {
        return result;
    }
    NSAttributedString *selected = [self.textStorage attributedSubstringFromRange:range];
    NSString *model = GAModelTextFromFieldText(selected).string;
    [pboard setString:model forType:NSPasteboardTypeString];
    // Older pasteboard readers ask for the legacy name instead.
    [pboard setString:model forType:@"NSStringPboardType"];
    return YES;
}

@end

/// macOS 26+ search fields drop the leading text inset when the search button
/// cell is removed; the text then starts at the bezel edge. Use a fixed 9 pt
/// text inset on both edges without changing the field's frame, font or text.
static const CGFloat GASearchFieldTextInset = 9.0;

@interface GASearchFieldCell : NSSearchFieldCell
@end

@implementation GASearchFieldCell

- (NSRect)rectByInsettingTextEdges:(NSRect)rect bounds:(NSRect)bounds {
    rect.origin.x = NSMinX(bounds) + GASearchFieldTextInset;
    rect.size.width = MAX(0, NSMaxX(bounds) - GASearchFieldTextInset - NSMinX(rect));
    return rect;
}

- (NSRect)searchTextRectForBounds:(NSRect)bounds {
    return [self rectByInsettingTextEdges:[super searchTextRectForBounds:bounds]
                                   bounds:bounds];
}

- (NSRect)titleRectForBounds:(NSRect)bounds {
    return [self rectByInsettingTextEdges:[super titleRectForBounds:bounds]
                                   bounds:bounds];
}

- (NSRect)drawingRectForBounds:(NSRect)bounds {
    return [self rectByInsettingTextEdges:[super drawingRectForBounds:bounds]
                                   bounds:bounds];
}

@end

@interface GASearchField : NSSearchField
@end

@implementation GASearchField

+ (Class)cellClass {
    return [GASearchFieldCell class];
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
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
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

- (void)collectSelectionRunsFrom:(NSAttributedString *)text
                          ranges:(NSMutableArray<NSValue *> *)ranges
                          values:(NSMutableArray<GAGlyphSelection *> *)values {
    [text enumerateAttribute:GAGlyphSelectionAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        (void)stop;
        if ([value isKindOfClass:[GAGlyphSelection class]]) {
            [ranges addObject:[NSValue valueWithRange:range]];
            [values addObject:value];
        }
    }];
}

/// Drops every attribute except the app font, the app foreground color,
/// selection runs, and line-break markers. Shared by the plain copy and the
/// field editor normalization path.
- (void)applyPlainAttributesToStorage:(NSMutableAttributedString *)storage
                             fromText:(NSAttributedString *)source {
    NSRange all = NSMakeRange(0, storage.length);
    NSMutableArray<NSValue *> *runRanges = [NSMutableArray array];
    NSMutableArray<GAGlyphSelection *> *runValues = [NSMutableArray array];
    [self collectSelectionRunsFrom:source ranges:runRanges values:runValues];
    NSMutableArray<NSValue *> *markerRanges = [NSMutableArray array];
    [source enumerateAttribute:GALineBreakAttributeName
                       inRange:all
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL *stop) {
        (void)stop;
        if (value != nil) {
            [markerRanges addObject:[NSValue valueWithRange:range]];
        }
    }];

    [storage beginEditing];
    [storage setAttributes:@{
        NSFontAttributeName: [self inputFont],
        NSForegroundColorAttributeName: [self inputTextColor],
    } range:all];
    for (NSUInteger index = 0; index < runRanges.count; index++) {
        [storage addAttribute:GAGlyphSelectionAttributeName
                        value:runValues[index]
                        range:runRanges[index].rangeValue];
    }
    for (NSValue *value in markerRanges) {
        GASetLineBreakMarker(storage, value.rangeValue);
    }
    [storage endEditing];
}

/// Returns only the attributes this app understands: the default font,
/// the app-owned foreground color, and selection runs. Everything else
/// (pasted colors, backgrounds, paragraph styles, links, attachments) is
/// discarded.
- (NSAttributedString *)plainCopyOfAttributedText:(NSAttributedString *)text {
    NSMutableAttributedString *plain =
        [[NSMutableAttributedString alloc] initWithString:text.string];
    [self applyPlainAttributesToStorage:plain fromText:text];
    return plain;
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
    [self applyPlainAttributesToStorage:storage fromText:storage];
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
        return NSNotFound;
    }
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
    CGFloat maximum = MAX(0.0, self.tableView.frame.size.height -
                               clipView.bounds.size.height);
    y = MIN(MAX(0.0, y), maximum);
    [clipView scrollToPoint:NSMakePoint(clipView.bounds.origin.x, y)];
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

- (BOOL)updateCoordinateGroups:(NSArray<GACharacterGroup *> *)groups {
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

- (void)setGroups:(NSArray<GACharacterGroup *> *)groups {
    NSPoint scrollOrigin = self.scrollView.contentView.bounds.origin;
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
    [self.tableView reloadData];

    BOOL hasPending = self.pendingSelectionGlyphKey.length > 0;
    if (hasPending) {
        if ([self resolvePendingSelectionIfPossible]) {
            return;
        }
        // The appended character group is not in this snapshot yet (or has no
        // rows). Wait; do not restore the old selection or jump to the first.
        self.selectedVariant = nil;
        self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
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
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)rowToSelect]
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
    [self restoreScrollOrigin:scrollOrigin];
}

- (void)applyStreamedGroups:(NSArray<GACharacterGroup *> *)groups {
    NSPoint scrollOrigin = self.scrollView.contentView.bounds.origin;

    // The table selection is the user's click, not necessarily the cached
    // selectedVariant. Capture its identity before reloading; the row order can
    // change while the scan inserts new groups.
    NSInteger previousRow = self.tableView.selectedRow;
    NSString *currentKey = nil;
    NSRange currentRange = NSMakeRange(NSNotFound, 0);
    if (previousRow >= 0 && previousRow < (NSInteger)self.rows.count) {
        GARowItem *item = self.rows[(NSUInteger)previousRow];
        if (item.variant != nil && item.group != nil) {
            currentKey = item.variant.glyphKey;
            currentRange = item.group.textRange;
        }
    }

    _groups = [groups copy];
    self.rows = GARowsForGroups(groups);

    self.suppressSelectionCallback = YES;
    [self.tableView reloadData];

    BOOL hasPending = self.pendingSelectionGlyphKey.length > 0;
    if (hasPending) {
        if ([self resolvePendingSelectionIfPossible]) {
            return;
        }
        self.selectedVariant = nil;
        self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
        self.suppressSelectionCallback = NO;
        return;
    }

    NSInteger row = NSNotFound;
    if (currentKey.length > 0) {
        GACharacterGroup *group = [self groupForGlyphKey:currentKey
                                               textRange:currentRange];
        if (group != nil) {
            row = [self rowForGlyphKey:currentKey inGroup:group];
        }
    }
    if (row != NSNotFound) {
        [self.tableView rectOfRow:row];
        if (row != self.tableView.selectedRow) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                        byExtendingSelection:NO];
        }
        self.selectedVariant = self.rows[(NSUInteger)row].variant;
        self.selectedVariantTextRange = self.rows[(NSUInteger)row].group.textRange;
    } else {
        // Do not fall back to the cached selectedVariant; that is the stale
        // value that snapped back over the user's click.
        self.selectedVariant = nil;
        self.selectedVariantTextRange = NSMakeRange(NSNotFound, 0);
    }
    self.suppressSelectionCallback = NO;
    [self restoreScrollOrigin:scrollOrigin];
}

- (void)restoreScrollOrigin:(NSPoint)origin {
    CGFloat maxY = MAX(0.0, self.tableView.frame.size.height -
                            self.scrollView.contentView.bounds.size.height);
    CGFloat maxX = MAX(0.0, self.tableView.frame.size.width -
                            self.scrollView.contentView.bounds.size.width);
    NSPoint clamped = NSMakePoint(MIN(MAX(0.0, origin.x), maxX),
                                  MIN(MAX(0.0, origin.y), maxY));
    [self.scrollView.contentView scrollToPoint:clamped];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
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
