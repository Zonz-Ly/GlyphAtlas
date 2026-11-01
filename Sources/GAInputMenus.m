#import "GAInputMenus.h"

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
