#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import "GASidebarInput.h"
#import "GASidebarViewController.h"
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
  rect.origin.y = MIN(MAX(0, rect.origin.y),
                      MAX(0, self.documentHeight - rect.size.height));
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
- (id)viewAtColumn:(NSInteger)column
                row:(NSInteger)row
    makeIfNecessary:(BOOL)make;
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
- (id)viewAtColumn:(NSInteger)column
                row:(NSInteger)row
    makeIfNecessary:(BOOL)make {
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
@property(getter=isHidden) BOOL hidden;
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
  MenuItem *mode = [MenuItem new], *separator = [MenuItem new],
           *metrics = [MenuItem new];
  MenuItem *context = [MenuItem new], *ligatures = [MenuItem new],
           *vertical = [MenuItem new];
  MenuItem *alignment = [MenuItem new], *trailing = [MenuItem new];
  separator.separatorItem = trailing.separatorItem = YES;
  metrics.action = NSSelectorFromString(@"toggleShowMetrics:");
  context.action = NSSelectorFromString(@"toggleContextualAlternates:");
  ligatures.action = NSSelectorFromString(@"toggleLigatures:");
  vertical.action = NSSelectorFromString(@"toggleWritingDirection:");
  alignment.identifier = @"TextAlignment";
  Menu *menu = [Menu new];
  menu.itemArray = @[
    mode, separator, metrics, trailing, context, ligatures, vertical, alignment
  ];
  controller.viewMode = GAViewModeAllGlyphs;
  [delegate menuNeedsUpdate:(id)menu];
  Check(metrics.hidden && context.hidden && ligatures.hidden &&
            vertical.hidden && alignment.hidden && separator.hidden &&
            trailing.hidden,
        "all-glyph menu hides unsupported options and separators");
  controller.viewMode = GAViewModeSingleGlyph;
  [delegate menuNeedsUpdate:(id)menu];
  Check(!metrics.hidden && context.hidden && alignment.hidden &&
            !separator.hidden && trailing.hidden,
        "single-glyph menu retains metrics but hides native text controls");
  controller.viewMode = GAViewModeMultiCharacter;
  [delegate menuNeedsUpdate:(id)menu];
  Check(!metrics.hidden && !context.hidden && !ligatures.hidden &&
            !vertical.hidden && !alignment.hidden,
        "shared context menu restores supported options when view changes");
  Check([delegate validateMenuItem:(id)context] &&
            context.state == NSControlStateValueOff &&
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
static NSArray<GACharacterGroup *> *RangeShiftGroups(NSIndexSet *lineBreaks) {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSUInteger i = 0; i < 10; i++) {
        NSMutableArray *glyphs = [NSMutableArray array];
        for (NSUInteger j = 0; j < 5; j++)
            [glyphs addObject:@((i + 1) * 100 + j)];
        NSUInteger shift = [lineBreaks countOfIndexesInRange:NSMakeRange(0, i + 1)];
        GACharacterGroup *group = Group(NSMakeRange(i + shift, 1), glyphs);
        group.text = [NSString stringWithFormat:@"%lu", i];
        [groups addObject:group];
    }
    return groups;
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
          "new candidates above viewport retain top-row identity without "
          "revealing selection");
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
    Check([[sidebar valueForKey:@"selectedVariant"] glyphIDs][0]
                      .unsignedIntegerValue == 999 &&
              notifications == 1 && table.reveals > 0,
          "all-glyph append selects exact GID at appended range and reveals it "
          "once");
    NSUInteger reloads = table.reloads;
    Check([sidebar updateGroupsWithSameRows:groups] && table.reloads == reloads,
          "identical row inventory rebinds without reloading");
    [sidebar selectGlyphKeyAfterNextReload:@"1234" textRange:NSMakeRange(9, 1)];
    table.selectedRow = 2;
    [sidebar tableViewSelectionDidChange:nil];
    [sidebar setGroups:groups];
    Check(table.selectedRow == 2,
          "manual selection overrides pending automatic reveal");
    [sidebar selectGlyphKeyAfterNextReload:@"8" textRange:NSMakeRange(1, 1)];
    [sidebar setGroups:@[ Group(NSMakeRange(0, 2), @[ @7, @8 ]) ]];
    Check(
        [[sidebar
            valueForKey:@"selectedVariant"] glyphIDs][0].unsignedIntegerValue ==
            8,
        "appended combining character resolves inside expanded composed group");
    [sidebar setGroups:@[
      Group(NSMakeRange(0, 1), @[ @7 ]), Group(NSMakeRange(0, 2), @[ @22 ]),
      Group(NSMakeRange(0, 3), @[ @22 ])
    ]];
    NSUInteger priorReloads = table.reloads;
    Check([sidebar selectGlyphIDs:@[ @22 ] textRange:NSMakeRange(0, 3)] &&
              table.selectedRow == 2 && table.reloads == priorReloads,
          "native hit chooses exact consumed span when overlapping ligatures "
          "share a GID");
    [sidebar setGroups:@[
        Group(NSMakeRange(0, 1), @[ @100, @101, @102, @103, @104, @105, @106, @107 ]),
        Group(NSMakeRange(1, 1), @[ @200, @201, @202, @203 ])
    ]];
    clip.bounds = NSMakeRect(0, 0, 200, 88);
    Check([sidebar selectGlyphIDs:@[ @106 ] textRange:NSMakeRange(0, 1)] &&
              table.selectedRow == 6 && clip.bounds.origin.y == 220,
          "TextView link in a tall group places selected row at viewport bottom");
    [sidebar selectGlyphKeyAfterNextReload:@"106" textRange:NSMakeRange(0, 1)];
    [sidebar setGroups:[sidebar valueForKey:@"groups"]];
    Check(clip.bounds.origin.y == 0,
          "existing group navigation still aligns an oversized group to its top");
    [sidebar selectGlyphKeyAfterNextReload:@"106" textRange:NSMakeRange(0, 1)
                                   scroll:GAPendingSelectionScrollSelectedToTopIfNeeded];
    [sidebar setGroups:[sidebar valueForKey:@"groups"]];
    Check(clip.bounds.origin.y == 264,
          "existing activation still aligns an invisible selected row to the top");
    clip.bounds = NSMakeRect(0, 0, 200, 88);
    Check([sidebar selectGlyphIDs:@[ @101 ] textRange:NSMakeRange(0, 1)] &&
              clip.bounds.origin.y == 0,
          "TextView link near the group top keeps original group positioning");
    [sidebar setGroups:RangeShiftGroups(NSIndexSet.indexSet)];
    clip.bounds = NSMakeRect(0, 1638, 200, 88);
    table.selectedRow = 37;
    [sidebar tableViewSelectionDidChange:nil];
    NSUInteger rangeReloads = table.reloads, rangeReveals = table.reveals;
    NSMutableIndexSet *bothBreaks = [NSMutableIndexSet indexSetWithIndex:0];
    [bothBreaks addIndex:5];
    for (NSIndexSet *breaks in @[ [NSIndexSet indexSetWithIndex:0], bothBreaks,
                                [NSIndexSet indexSetWithIndex:5], NSIndexSet.indexSet ]) {
        Check([sidebar updateGroupsWithSameRows:RangeShiftGroups(breaks)] &&
                  table.reloads == rangeReloads && table.reveals == rangeReveals &&
                  clip.bounds.origin.y == 1638 && table.selectedRow == 37,
              "inserting/removing leading and middle line breaks rebinds without scrolling");
        NSRange selectedRange = [[sidebar valueForKey:@"selectedVariantTextRange"] rangeValue];
        NSUInteger shift = [breaks countOfIndexesInRange:NSMakeRange(0, 8)];
        Check(NSEqualRanges(selectedRange, NSMakeRange(7 + shift, 1)) &&
                  [[[sidebar valueForKey:@"selectedVariant"] glyphIDs] isEqual:@[ @802 ]],
              "the selected glyph keeps its new UTF-16 source range after a range-only edit");
    }
    NSArray<GACharacterGroup *> *differentText = RangeShiftGroups(NSIndexSet.indexSet);
    differentText[7].text = @"X";
    Check(![sidebar updateGroupsWithSameRows:differentText],
          "different source content is not mistaken for a position-only update");
    MenuChecks();
    NSAttributedString *modelText =
        [[NSAttributedString alloc] initWithString:@"a\n⏎b"];
    NSAttributedString *fieldText = GAFieldTextFromModelText(modelText);
    Check([fieldText.string isEqualToString:@"a⏎⏎b"] &&
              [fieldText attribute:GALineBreakAttributeName
                           atIndex:1
                    effectiveRange:NULL] &&
              ![fieldText attribute:GALineBreakAttributeName
                            atIndex:2
                     effectiveRange:NULL],
          "input conversion distinguishes marked line breaks from literal "
          "return symbols");
    Check([GAModelTextFromFieldText(fieldText).string
              isEqualToString:modelText.string],
          "input marker conversion preserves original UTF-16 ranges and "
          "literal symbols");
    NSMutableAttributedString *decorated = [fieldText mutableCopy];
    GAGlyphSelection *selection =
        [[GAGlyphSelection alloc] initWithSourceText:@"a"
                                            glyphIDs:@[ @19 ]
                                      featureSources:@[ @"aalt" ]
                                            ligature:NO];
    [decorated addAttribute:GAGlyphSelectionAttributeName
                      value:selection
                      range:NSMakeRange(0, 1)];
    [decorated addAttribute:NSLinkAttributeName
                      value:@"https://example.invalid/"
                      range:NSMakeRange(0, 1)];
    NSAttributedString *normalized = GANormalizedSidebarInput(
        decorated, [NSFont systemFontOfSize:13.5], NSColor.controlTextColor);
    Check([normalized attribute:GAGlyphSelectionAttributeName
                        atIndex:0
                 effectiveRange:NULL] == selection &&
              ![normalized attribute:NSLinkAttributeName
                             atIndex:0
                      effectiveRange:NULL] &&
              [GAModelTextFromFieldText(normalized).string
                  isEqualToString:modelText.string],
          "input normalization keeps explicit GIDs/line breaks and drops "
          "pasted styling");
    Check(NSApp == nil, "state tests never create a GUI application");
    printf("OK: %lu sidebar state assertions; test doubles only, no GUI\n",
           (unsigned long)checks);
  }
}
