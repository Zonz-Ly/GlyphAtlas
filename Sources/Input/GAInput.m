#import "GAInput.h"
#import "App/GAAppDelegate.h"
#import "Font/GAGlyphSelection.h"
#import "Views/GAViewMode.h"

#pragma mark - Native input menus

typedef NS_OPTIONS(NSUInteger, GAInputMenuOptions) {
    GAInputMenuFont = 1 << 0,
    GAInputMenuSpelling = 1 << 1,
    GAInputMenuSubstitutions = 1 << 2,
};

static BOOL GAMenuHasAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray)
        if (item.action == action) return YES;
    return NO;
}

static void GAFilterInputMenu(NSMenu *menu, GAInputMenuOptions options) {
    for (NSMenuItem *item in [menu.itemArray copy]) {
        NSMenu *submenu = item.submenu;
        if (((options & GAInputMenuFont) && GAMenuHasAction(submenu, @selector(orderFrontFontPanel:))) ||
            ((options & GAInputMenuSpelling) && GAMenuHasAction(submenu, @selector(showGuessPanel:))) ||
            ((options & GAInputMenuSubstitutions) && GAMenuHasAction(submenu, @selector(orderFrontSubstitutionsPanel:))))
            [menu removeItem:item];
    }
    BOOL previousSeparator = YES;
    for (NSMenuItem *item in [menu.itemArray copy]) {
        if (item.separatorItem && previousSeparator) [menu removeItem:item];
        else previousSeparator = item.separatorItem;
    }
    if (menu.itemArray.lastObject.separatorItem) [menu removeItemAtIndex:menu.numberOfItems - 1];
}

static void GAInsertTextMenuItem(NSMenu *menu, NSMenuItem *item) {
    NSInteger index = 0;
    for (NSInteger i = 0; i < menu.numberOfItems; i++) {
        SEL action = [menu itemAtIndex:i].action;
        if (action == @selector(cut:) || action == @selector(copy:) ||
            action == @selector(paste:) || action == @selector(delete:) ||
            action == @selector(selectAll:)) index = i + 1;
    }
    [menu insertItem:item atIndex:index++];
    if (index < menu.numberOfItems && ![menu itemAtIndex:index].separatorItem)
        [menu insertItem:NSMenuItem.separatorItem atIndex:index];
}

#pragma mark - Editing focus

NSNotificationName const GAInputBlankClickNotification = @"GAInputBlankClickNotification";

static BOOL GAWindowHasFocusedInput(NSWindow *window) {
    NSResponder *responder = window.firstResponder;
    return window.visible && [responder isKindOfClass:NSTextView.class] &&
        [(NSTextView *)responder isFieldEditor];
}

static BOOL GAHasFocusedInput(void) {
    for (NSWindow *window in NSApp.windows) {
        if (GAWindowHasFocusedInput(window)) return YES;
    }
    return NO;
}

BOOL GAEndInputEditingOutsideWindow(NSWindow *destination) {
    for (NSWindow *window in NSApp.windows) {
        if (window != destination && GAWindowHasFocusedInput(window) &&
            ![window makeFirstResponder:nil]) return NO;
    }
    return YES;
}

static BOOL GAIsBlankAreaClick(NSEvent *event) {
    NSView *content = event.window.contentView;
    NSView *root = content.superview ?: content;
    if (root == nil) return NO;
    NSPoint point = [root convertPoint:event.locationInWindow fromView:nil];
    NSView *hit = [root hitTest:[root convertPoint:point toView:root.superview]];
    if (hit == nil) return NO;
    for (NSView *view = hit; view != nil; view = view.superview) {
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField *field = (NSTextField *)view;
            if (!field.editable && !field.selectable) continue;
        }
        if ([view isKindOfClass:NSControl.class]) return NO;
        if ([view isKindOfClass:NSTextView.class]) {
            NSTextView *text = (NSTextView *)view;
            if (text.editable || text.selectable) return NO;
        }
    }
    return YES;
}

@interface GAInputClickMonitor : NSObject
@property (nonatomic, strong) id monitor;
+ (instancetype)sharedMonitor;
- (void)removeMonitor;
- (void)installMonitor;
@end

@implementation GAInputClickMonitor
+ (instancetype)sharedMonitor {
    static GAInputClickMonitor *monitor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ monitor = [[self alloc] init]; });
    return monitor;
}

- (void)removeMonitor {
    if (self.monitor == nil) return;
    [NSEvent removeMonitor:self.monitor];
    self.monitor = nil;
}

- (void)installMonitor {
    if (self.monitor != nil) return;
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskLeftMouseDown
        handler:^NSEvent *(NSEvent *event) {
            if (GAIsBlankAreaClick(event)) {
                [NSNotificationCenter.defaultCenter postNotificationName:GAInputBlankClickNotification
                                                                  object:event];
            }
            return event;
        }];
}
@end

static void GAInputEditingDidBegin(void) {
    // A repeated request is a no-op; no input identity or registry is needed.
    [[GAInputClickMonitor sharedMonitor] installMonitor];
}

static void GAInputEditingDidEnd(void) {
    // Check later on the main queue rather than during the current focus handoff.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!GAHasFocusedInput()) [[GAInputClickMonitor sharedMonitor] removeMonitor];
    });
}

#pragma mark - Numeric field editing

@interface GANumericFieldEditor : NSTextView
@end
@implementation GANumericFieldEditor
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu = [super menuForEvent:event];
    GAFilterInputMenu(menu, GAInputMenuSpelling | GAInputMenuSubstitutions);
    return menu;
}
@end

@interface GAInputTextFieldCell : NSTextFieldCell
@property(nonatomic, strong) GANumericFieldEditor *numericEditor;
@end

@implementation GAInputTextFieldCell
- (NSTextView *)fieldEditorForView:(NSView *)controlView {
    (void)controlView;
    if (!self.numericEditor) {
        self.numericEditor = [[GANumericFieldEditor alloc] initWithFrame:NSZeroRect];
        self.numericEditor.fieldEditor = YES;
    }
    return self.numericEditor;
}
- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
    NSTextView *editor = (NSTextView *)[super setUpFieldEditorAttributes:textObj];
    editor.enabledTextCheckingTypes = 0;
    return editor;
}
- (void)editWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor
             delegate:(id)delegate event:(NSEvent *)event {
    [super editWithFrame:rect inView:view editor:editor delegate:delegate event:event];
    if (view.window.firstResponder == editor) GAInputEditingDidBegin();
}

- (void)selectWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor
               delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {
    [super selectWithFrame:rect inView:view editor:editor delegate:delegate start:start length:length];
    if (view.window.firstResponder == editor) GAInputEditingDidBegin();
}

- (void)endEditing:(NSText *)editor {
    [super endEditing:editor];
    GAInputEditingDidEnd();
}
@end

@implementation GAInputTextField
+ (Class)cellClass { return GAInputTextFieldCell.class; }
@end

#pragma mark - Sidebar field editing

/// YES when the shortcut modifiers in `modifiers` are exactly `expected`.
/// Caps Lock, the function key, the numeric keypad, Help, and device-dependent
/// bits do not count.
BOOL GAModifiersAre(NSEventModifierFlags modifiers,
                    NSEventModifierFlags expected) {
  NSEventModifierFlags mask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift |
      NSEventModifierFlagOption | NSEventModifierFlagControl;
  return (modifiers & mask) == expected;
}

#pragma mark - Line-break marker

/// The field uses one visible symbol per separator, with the original UTF-16
/// code unit in this attribute. An unmarked symbol is literal text.
NSString *const GALineBreakAttributeName = @"com.zonz.GlyphAtlas.lineBreak";
static const struct {
  unichar separator;
  unichar marker;
} GASeparatorMarkers[] = {
    {'\n', 0x23CE}, // ⏎ Line feed.
    {'\r', 0x23CE}, // ⏎ Carriage return.
    {'\v', 0x240B}, // ␋ Line tabulation.
    {'\f', 0x240C}, // ␌ Form feed.
    {0x0085, 0x2424}, // ␤ Next line.
    {0x2028, 0x21B5}, // ↵ Line separator.
    {0x2029, 0x00B6}, // ¶ Paragraph separator.
};

unichar GAInputSeparatorMarker(unichar separator) {
  for (NSUInteger i = 0; i < sizeof(GASeparatorMarkers) / sizeof(*GASeparatorMarkers); i++) {
    if (GASeparatorMarkers[i].separator == separator) return GASeparatorMarkers[i].marker;
  }
  return 0;
}

static void GAEnumerateLineBreakMarkers(NSAttributedString *text,
                                        void (^visit)(NSRange, unichar)) {
  NSString *string = text.string;
  [text enumerateAttribute:GALineBreakAttributeName
                   inRange:NSMakeRange(0, text.length) options:0
                usingBlock:^(id value, NSRange range, BOOL *stop) {
    (void)stop;
    if (!value) return;
    unichar separator = [value unsignedShortValue];
    unichar marker = GAInputSeparatorMarker(separator);
    if (!marker) return;
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
      if ([string characterAtIndex:i] == marker) visit(NSMakeRange(i, 1), separator);
    }
  }];
}

static BOOL GANeedsExplicitLineBreakAttributes(NSString *string) {
  static NSCharacterSet *specialCharacters;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet *characters = [NSCharacterSet.newlineCharacterSet mutableCopy];
    for (NSUInteger i = 0; i < sizeof(GASeparatorMarkers) / sizeof(*GASeparatorMarkers); i++) {
      [characters addCharactersInRange:NSMakeRange(GASeparatorMarkers[i].marker, 1)];
    }
    specialCharacters = [characters copy];
  });
  return [string rangeOfCharacterFromSet:specialCharacters].location != NSNotFound;
}

/// Records the separator on its visible symbol and gives it the secondary text
/// colour used by AppKit for auxiliary inline content.
static void GASetLineBreakMarker(NSMutableAttributedString *text,
                                 NSRange range, unichar separator) {
  [text addAttribute:GALineBreakAttributeName value:@(separator) range:range];
  [text addAttribute:NSForegroundColorAttributeName
               value:[NSColor secondaryLabelColor]
               range:range];
}

/// Replaces line breaks with markers and attaches the line-break attribute.
static NSAttributedString *GAMarkerTextFromString(NSString *string,
                                                  NSDictionary *attributes) {
  NSString *normalized = [[string stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                          stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
  return GAFieldTextFromModelText([[NSAttributedString alloc] initWithString:normalized
                                                                  attributes:attributes]);
}

/// Restores the separators for the model text.
NSAttributedString *GAModelTextFromFieldText(NSAttributedString *fieldText) {
  NSMutableAttributedString *model = [fieldText mutableCopy];
  GAEnumerateLineBreakMarkers(fieldText, ^(NSRange range, unichar separator) {
    [model replaceCharactersInRange:range withString:[NSString stringWithCharacters:&separator length:1]];
  });
  [model removeAttribute:GALineBreakAttributeName range:NSMakeRange(0, model.length)];
  return model;
}

/// Substitutes visible symbols for the model's separators in the field.
NSAttributedString *GAFieldTextFromModelText(NSAttributedString *modelText) {
  NSMutableAttributedString *field = [modelText mutableCopy];
  [field removeAttribute:GALineBreakAttributeName range:NSMakeRange(0, field.length)];
  NSString *string = modelText.string;
  for (NSUInteger index = 0; index < string.length; index++) {
    unichar separator = [string characterAtIndex:index];
    unichar marker = GAInputSeparatorMarker(separator);
    if (!marker) continue;
    NSRange range = NSMakeRange(index, 1);
    [field replaceCharactersInRange:range withString:[NSString stringWithCharacters:&marker length:1]];
    GASetLineBreakMarker(field, range, separator);
  }
  return field;
}

/// Converts separators before the single-line field editor turns them into
/// spaces. The attribute distinguishes each separator from its literal symbol.
@interface GASearchFieldEditor ()
@property (nonatomic) BOOL transitioningFieldEditor;
@end

@implementation GASearchFieldEditor

- (NSUndoManager *)undoManager {
  return self.transitioningFieldEditor ? nil : self.inputUndoManager;
}

- (BOOL)shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)replacement {
  NSTextStorage *storage = self.textStorage;
  if (replacement && range.location != NSNotFound && NSMaxRange(range) <= storage.length) {
    __block BOOL touchesSelection = NO;
    if (range.length) {
      [storage enumerateAttribute:GAGlyphSelectionAttributeName inRange:range
                          options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
          usingBlock:^(id value, NSRange span, BOOL *stop) {
            (void)span;
            if (value) {
              touchesSelection = YES;
              *stop = YES;
            }
          }];
    } else if (range.location > 0 && range.location < storage.length) {
      id selection = [storage attribute:GAGlyphSelectionAttributeName atIndex:range.location
                                effectiveRange:NULL];
      touchesSelection = selection &&
          selection == [storage attribute:GAGlyphSelectionAttributeName atIndex:range.location - 1
                             effectiveRange:NULL];
    }
    // The edit needs an open group for any glyph selection it invalidates.
    if (touchesSelection) [self breakUndoCoalescing];
  }
  return [super shouldChangeTextInRange:range replacementString:replacement];
}

- (void)updateFontPanel {
  // This plain-text input does not synchronize the shared font and color panels.
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSMenu *menu = [super menuForEvent:event];
  GAFilterInputMenu(menu, GAInputMenuFont);
  GAInsertTextMenuItem(menu, [(GAAppDelegate *)NSApp.delegate savedTextMenuItemForWindow:self.window]);
  return menu;
}

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
  if (!inserted.length || !GANeedsExplicitLineBreakAttributes(inserted)) {
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
  NSString *string =
      [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  if (string.length && GANeedsExplicitLineBreakAttributes(string)) {
    [self insertText:string replacementRange:self.selectedRange];
    return;
  }
  [super paste:sender];
}

/// Copy the selection as plain text, restoring the original separators.
- (void)copy:(id)sender {
  NSRange range = self.selectedRange;
  if (range.length == 0) {
    [super copy:sender];
    return;
  }
  NSAttributedString *selected =
      [self.textStorage attributedSubstringFromRange:range];
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
  NSAttributedString *selected =
      [self.textStorage attributedSubstringFromRange:range];
  NSString *model = GAModelTextFromFieldText(selected).string;
  [pboard setString:model forType:NSPasteboardTypeString];
  // Older pasteboard readers ask for the legacy name instead.
  [pboard setString:model forType:@"NSStringPboardType"];
  return YES;
}

@end

/// Keep text clear of the native bezel after removing the search button cell:
/// 9 pt on the existing layout, 12 pt inside Tahoe's capsule.
static const CGFloat GASearchFieldTextInset = 9.0;

@interface GASearchFieldCell : NSSearchFieldCell
@end

@implementation GASearchFieldCell

// AppKit clears and refills the editor during focus changes. Keep that
// housekeeping out of the undo history for the retained text storage.
- (void)editWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor
             delegate:(id)delegate event:(NSEvent *)event {
  GASearchFieldEditor *input = (GASearchFieldEditor *)editor;
  BOOL wasTransitioning = input.transitioningFieldEditor;
  input.transitioningFieldEditor = YES;
  [super editWithFrame:rect inView:view editor:editor delegate:delegate event:event];
  if (view.window.firstResponder == editor) GAInputEditingDidBegin();
  input.transitioningFieldEditor = wasTransitioning;
}

- (void)selectWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor
              delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {
  GASearchFieldEditor *input = (GASearchFieldEditor *)editor;
  BOOL wasTransitioning = input.transitioningFieldEditor;
  input.transitioningFieldEditor = YES;
  [super selectWithFrame:rect inView:view editor:editor delegate:delegate start:start length:length];
  if (view.window.firstResponder == editor) GAInputEditingDidBegin();
  input.transitioningFieldEditor = wasTransitioning;
}

- (void)endEditing:(NSText *)editor {
  GASearchFieldEditor *input = (GASearchFieldEditor *)editor;
  NSTextStorage *storage = input.textStorage;
  NSAttributedString *text = [storage copy];
  BOOL wasTransitioning = input.transitioningFieldEditor;
  input.transitioningFieldEditor = YES;
  [super endEditing:editor];
  GAInputEditingDidEnd();
  [storage setAttributedString:text];
  input.transitioningFieldEditor = wasTransitioning;
}

- (NSRect)rectByInsettingTextEdges:(NSRect)rect bounds:(NSRect)bounds {
  CGFloat inset = GAUsesMacOS26Layout() ? 12.0 : GASearchFieldTextInset;
  rect.origin.x = NSMinX(bounds) + inset;
  rect.size.width =
      MAX(0, NSMaxX(bounds) - inset - NSMinX(rect));
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

@implementation GASearchField

+ (Class)cellClass {
  return [GASearchFieldCell class];
}

@end

/// Drops every attribute except the app font, the app foreground color,
/// selection runs, and line-break markers. Shared by the plain copy and the
/// field editor normalization path.
NSAttributedString *GANormalizedSidebarInput(NSAttributedString *source,
                                             NSFont *font, NSColor *color) {
  NSMutableAttributedString *storage =
      [[NSMutableAttributedString alloc] initWithString:source.string];
  NSRange all = NSMakeRange(0, storage.length);
  [storage beginEditing];
  [storage setAttributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
  }
                   range:all];
  [source enumerateAttribute:GAGlyphSelectionAttributeName
                     inRange:NSMakeRange(0, source.length)
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                    (void)stop;
                    if ([value isKindOfClass:GAGlyphSelection.class]) {
                      [storage addAttribute:GAGlyphSelectionAttributeName
                                      value:value
                                      range:range];
                    }
                  }];
  GAEnumerateLineBreakMarkers(source, ^(NSRange range, unichar separator) {
    GASetLineBreakMarker(storage, range, separator);
  });
  [storage endEditing];
  return storage;
}
