#import "GASidebarViewController.h"
#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import <AppKit/AppKit.h>

@interface GASidebarViewController (StateTests)
@property(nonatomic, strong) id tableView;
@property(nonatomic, strong) id scrollView;
- (void)reloadRowsPreservingSelection;
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
@end
static NSUInteger checks;
static void Check(BOOL value, const char *message) {
    checks++;
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}
// These doubles exercise production selection/reload orchestration without
// creating a view, window, NSApplication, or a layout/rendering backend.
@interface Clip : NSObject
@property NSRect bounds;
@property CGFloat documentHeight;
- (NSRect)constrainBoundsRect:(NSRect)rect;
- (void)scrollToPoint:(NSPoint)point;
@end
@implementation Clip
- (NSRect)constrainBoundsRect:(NSRect)rect {
    rect.origin.y = MIN(MAX(0, rect.origin.y), MAX(0, self.documentHeight - rect.size.height));
    return rect;
}
- (void)scrollToPoint:(NSPoint)point {
    NSRect r = self.bounds;
    r.origin = point;
    self.bounds = r;
}
@end
@interface Scroll : NSObject
@property Clip *contentView;
- (void)reflectScrolledClipView:(id)clip;
@end
@implementation Scroll
- (void)reflectScrolledClipView:(id)clip {
}
@end
@interface Table : NSObject
@property(weak) GASidebarViewController *controller;
@property Clip *clip;
@property NSInteger selectedRow;
@property NSUInteger count, reloads, reveals;
@property(readonly) NSRect visibleRect;
- (NSRange)rowsInRect:(NSRect)rect;
- (NSRect)rectOfRow:(NSInteger)row;
- (void)reloadData;
- (void)noteHeightOfRowsWithIndexesChanged:(NSIndexSet *)rows;
- (void)tile;
- (void)selectRowIndexes:(NSIndexSet *)rows byExtendingSelection:(BOOL)extend;
- (void)scrollRowToVisible:(NSInteger)row;
- (void)layoutSubtreeIfNeeded;
- (id)viewAtColumn:(NSInteger)column row:(NSInteger)row makeIfNecessary:(BOOL)make;
@end
@implementation Table
- (NSRect)visibleRect {
    return self.clip.bounds;
}
- (NSRange)rowsInRect:(NSRect)rect {
    NSUInteger first = MAX(0, floor(NSMinY(rect) / 44));
    return first < self.count ? NSMakeRange(first, MIN(self.count - first, 3))
                              : NSMakeRange(NSNotFound, 0);
}
- (NSRect)rectOfRow:(NSInteger)row {
    return NSMakeRect(0, row * 44, 200, 44);
}
- (void)reloadData {
    self.reloads++;
    self.count = [[self.controller valueForKey:@"rows"] count];
    self.clip.documentHeight = self.count * 44;
}
- (void)noteHeightOfRowsWithIndexesChanged:(NSIndexSet *)rows {
}
- (void)tile {
}
- (void)selectRowIndexes:(NSIndexSet *)rows byExtendingSelection:(BOOL)extend {
    self.selectedRow = rows.firstIndex;
}
- (void)scrollRowToVisible:(NSInteger)row {
    self.reveals++;
    NSRect r = self.clip.bounds;
    r.origin.y = MAX(0, (row + 1) * 44 - r.size.height);
    [self.clip scrollToPoint:[self.clip constrainBoundsRect:r].origin];
}
- (void)layoutSubtreeIfNeeded {
}
- (id)viewAtColumn:(NSInteger)column row:(NSInteger)row makeIfNecessary:(BOOL)make {
    return nil;
}
@end
@interface GAAppDelegate (MenuStateTests)
- (void)menuNeedsUpdate:(NSMenu *)menu;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
@end
@interface MenuController : NSObject
@property GAViewMode viewMode;
@property BOOL usesContextualAlternates, usesLigatures, showsMetrics;
@end
@implementation MenuController
@end
@interface MenuDelegate : GAAppDelegate
@property MenuController *controller;
@end
@implementation MenuDelegate
- (GAMainWindowController *)activeMainWindowController {
    return (id)self.controller;
}
@end
@interface MenuItem : NSObject
@property SEL action;
@property NSString *identifier;
@property BOOL hidden;
@property(getter=isSeparatorItem) BOOL separatorItem;
@property NSControlStateValue state;
@end
@implementation MenuItem
@end
@interface Menu : NSObject
@property NSArray *itemArray;
@end
@implementation Menu
@end
static void MenuChecks(void) {
    MenuDelegate *delegate = [MenuDelegate new];
    MenuController *controller = [MenuController new];
    delegate.controller = controller;
    MenuItem *mode = [MenuItem new], *separator = [MenuItem new], *metrics = [MenuItem new];
    MenuItem *context = [MenuItem new], *ligatures = [MenuItem new], *vertical = [MenuItem new];
    MenuItem *alignment = [MenuItem new], *trailing = [MenuItem new];
    separator.separatorItem = trailing.separatorItem = YES;
    metrics.action = NSSelectorFromString(@"toggleShowMetrics:");
    context.action = NSSelectorFromString(@"toggleContextualAlternates:");
    ligatures.action = NSSelectorFromString(@"toggleLigatures:");
    vertical.action = NSSelectorFromString(@"toggleWritingDirection:");
    alignment.identifier = @"TextAlignment";
    Menu *menu = [Menu new];
    menu.itemArray =
        @[ mode, separator, metrics, trailing, context, ligatures, vertical, alignment ];
    controller.viewMode = GAViewModeAllGlyphs;
    [delegate menuNeedsUpdate:(id)menu];
    Check(metrics.hidden && context.hidden && ligatures.hidden && vertical.hidden &&
              alignment.hidden && separator.hidden && trailing.hidden,
          "all-glyph menu hides unsupported options and separators");
    controller.viewMode = GAViewModeSingleGlyph;
    [delegate menuNeedsUpdate:(id)menu];
    Check(!metrics.hidden && context.hidden && alignment.hidden && !separator.hidden &&
              trailing.hidden,
          "single-glyph menu retains metrics but hides native text controls");
    controller.viewMode = GAViewModeMultiCharacter;
    [delegate menuNeedsUpdate:(id)menu];
    Check(!metrics.hidden && !context.hidden && !ligatures.hidden && !vertical.hidden &&
              !alignment.hidden,
          "shared context menu restores supported options when view changes");
    Check([delegate validateMenuItem:(id)context] && context.state == NSControlStateValueOff &&
              [delegate validateMenuItem:(id)ligatures] &&
              ligatures.state == NSControlStateValueOff,
          "native shaping switches validate independently in the off state");
}
static GACharacterGroup *Group(NSRange range, NSArray<NSNumber *> *ids) {
    GACharacterGroup *g = [GACharacterGroup new];
    g.textRange = range;
    g.text = @"a";
    NSMutableArray *variants = [NSMutableArray array];
    for (NSNumber *glyph in ids) {
        GAGlyphVariant *v = [GAGlyphVariant new];
        v.glyphIDs = @[ glyph ];
        v.base = variants.count == 0;
        [variants addObject:v];
    }
    g.variants = variants;
    return g;
}
int main(void) {
    @autoreleasepool {
        Check(NSApp == nil, "no GUI application initialized");
        GASidebarViewController *sidebar = [GASidebarViewController new];
        Clip *clip = [Clip new];
        clip.bounds = NSMakeRect(0, 0, 200, 88);
        Scroll *scroll = [Scroll new];
        scroll.contentView = clip;
        Table *table = [Table new];
        table.clip = clip;
        table.controller = sidebar;
        table.selectedRow = -1;
        sidebar.tableView = table;
        sidebar.scrollView = scroll;
        NSMutableArray *groups = [NSMutableArray array];
        for (NSUInteger i = 0; i < 10; i++)
            [groups addObject:Group(NSMakeRange(i, 1), @[ @(i + 1) ])];
        [sidebar setGroups:groups];
        clip.bounds = NSMakeRect(0, 176, 200, 88);
        groups[0] = Group(NSMakeRange(0, 1), @[ @1, @101 ]);
        [sidebar setGroups:groups];
        Check(clip.bounds.origin.y == 220 && table.selectedRow == 0,
              "new candidates above viewport retain top-row identity without revealing selection");
        [sidebar reloadRowsPreservingSelection];
        Check(clip.bounds.origin.y == 220 && table.reveals == 0,
              "width relayout does not scroll to old selected row");
        __block NSUInteger notifications = 0;
        sidebar.onSelectionChanged = ^(GAGlyphVariant *v) {
          (void)v;
          notifications++;
        };
        groups[9] = Group(NSMakeRange(9, 1), @[ @10, @999 ]);
        [sidebar selectGlyphKeyAfterNextReload:@"999" textRange:NSMakeRange(9, 1)];
        [sidebar setGroups:groups];
        Check([[sidebar valueForKey:@"selectedVariant"] glyphIDs][0].unsignedIntegerValue == 999 &&
                  notifications == 1 && table.reveals > 0,
              "all-glyph append selects exact GID at appended range and reveals it once");
        NSUInteger reloads = table.reloads;
        Check([sidebar updateGroupsWithSameRows:groups] && table.reloads == reloads,
              "identical row inventory rebinds without reloading");
        [sidebar selectGlyphKeyAfterNextReload:@"1234" textRange:NSMakeRange(9, 1)];
        table.selectedRow = 2;
        [sidebar tableViewSelectionDidChange:nil];
        [sidebar setGroups:groups];
        Check(table.selectedRow == 2, "manual selection overrides pending automatic reveal");
        [sidebar selectGlyphKeyAfterNextReload:@"8" textRange:NSMakeRange(1, 1)];
        [sidebar setGroups:@[ Group(NSMakeRange(0, 2), @[ @7, @8 ]) ]];
        Check([[sidebar valueForKey:@"selectedVariant"] glyphIDs][0].unsignedIntegerValue == 8,
              "appended combining character resolves inside expanded composed group");
        MenuChecks();
        Check(NSApp == nil, "state tests never create a GUI application");
        printf("OK: %lu sidebar state assertions; test doubles only, no GUI\n",
               (unsigned long)checks);
    }
}
