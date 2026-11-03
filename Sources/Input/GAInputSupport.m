#import "GAInputSupport.h"

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

@implementation GAInputSearchFieldCell
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

#pragma mark - Native input menus

static BOOL GAMenuHasAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray)
        if (item.action == action) return YES;
    return NO;
}

void GAFilterInputMenu(NSMenu *menu, GAInputMenuOptions options) {
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

void GAInsertTextMenuItem(NSMenu *menu, NSMenuItem *item) {
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
