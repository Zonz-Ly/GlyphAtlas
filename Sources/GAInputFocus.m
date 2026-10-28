#import "GAInputFocus.h"

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

@interface GAInputTextFieldCell : NSTextFieldCell
@end

@implementation GAInputTextFieldCell
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
