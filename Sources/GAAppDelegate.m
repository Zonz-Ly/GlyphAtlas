#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import "GAFontResource.h"
#import "GAViewDefaults.h"

static NSString *const GARecentFontPathsKey = @"GAPersistentRecentFontPaths";
static NSString *const GASavedTextsKey = @"GASavedTexts";

@interface GASavedTextMenu : NSMenu
@property(nonatomic, weak) GAMainWindowController *controller;
@end
@implementation GASavedTextMenu
@end

@interface GAAppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSMutableArray<GAMainWindowController *> *windowControllers;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingFontURLs;
@property (nonatomic, strong, nullable) NSOpenPanel *openPanel;
@property (nonatomic, strong, nullable) NSMenu *recentMenu;
@property(nonatomic, strong) NSMenu *editMenu;
@property(nonatomic, strong) NSUserDefaults *preferences;
@property(nonatomic, weak) GAMainWindowController *colorOwner;
@property(nonatomic) GAPreviewColorRole editingColorRole;
@property (nonatomic) BOOL launched;
@property (nonatomic) BOOL handlingOpenFiles;
@end

@implementation GAAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    self.preferences = NSUserDefaults.standardUserDefaults;
    if (![self.preferences objectForKey:GARecentFontPathsKey]) {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSURL *url in NSDocumentController.sharedDocumentController.recentDocumentURLs)
            if (url.isFileURL && GAFontURLIsFont(url) && ![paths containsObject:url.path])
                [paths addObject:url.path];
        [self.preferences setObject:paths forKey:GARecentFontPathsKey];
    }
    self.windowControllers = [NSMutableArray array];
    self.pendingFontURLs = [NSMutableArray array];
    [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.launched = YES;
    [NSApp activateIgnoringOtherApps:YES];

    if (self.pendingFontURLs.count > 0) {
        NSArray<NSURL *> *urls = [self.pendingFontURLs copy];
        [self.pendingFontURLs removeAllObjects];
        for (NSURL *url in urls) {
            [self openWindowForFontURL:url];
        }
        return;
    }

    [self openFont:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag && !self.handlingOpenFiles && self.windowControllers.count == 0) {
        [self openFont:nil];
    }
    return YES;
}

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
    if (filenames.count == 0) {
        [application replyToOpenOrPrint:NSApplicationDelegateReplyFailure];
        return;
    }
    if (!self.launched) {
        for (NSString *filename in filenames) {
            [self.pendingFontURLs addObject:[NSURL fileURLWithPath:filename]];
        }
        [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
        return;
    }

    [self.openPanel cancel:nil];
    self.handlingOpenFiles = YES;
    for (NSString *filename in filenames) {
        [self openWindowForFontURL:[NSURL fileURLWithPath:filename]];
    }
    self.handlingOpenFiles = NO;
    [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

#pragma mark - Windows

- (void)openWindowForFontURL:(NSURL *)url {
    GAMainWindowController *controller = [[GAMainWindowController alloc] init];
    [self.windowControllers addObject:controller];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:controller.window];
    __weak typeof(self) weakSelf = self;
    controller.onFontLoaded = ^(NSURL *loadedURL) {
        [weakSelf noteRecentFontURL:loadedURL];
    };
    controller.onFontDropRequest = ^(NSURL *url) {
        [weakSelf openWindowForFontURL:url];
    };

    [controller showWindow:nil];
    NSUInteger count = self.windowControllers.count;
    if (count > 1) {
        GAMainWindowController *previous = self.windowControllers[count - 2];
        NSRect frame = controller.window.frame;
        frame.origin.x = previous.window.frame.origin.x + 24;
        frame.origin.y = previous.window.frame.origin.y - 24;
        [controller.window setFrame:frame display:NO];
    }
    [controller.window makeKeyAndOrderFront:nil];
    [controller loadFontAtURL:url];
}

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    for (GAMainWindowController *controller in [self.windowControllers copy]) {
        if (controller.window == window) {
            [[NSNotificationCenter defaultCenter] removeObserver:self
                                                            name:NSWindowWillCloseNotification
                                                          object:window];
            [self.windowControllers removeObject:controller];
            break;
        }
    }
}

#pragma mark - Open panel

- (void)openFont:(id)sender {
    if (self.openPanel != nil) {
        [NSApp activateIgnoringOtherApps:YES];
        [self.openPanel makeKeyAndOrderFront:nil];
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = GAFontContentTypes();
    self.openPanel = panel;

    [NSApp activateIgnoringOtherApps:YES];
    __weak typeof(self) weakSelf = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        __strong typeof(weakSelf) self = weakSelf;
        NSArray<NSURL *> *urls = [panel.URLs copy];
        self.openPanel = nil;
        if (result != NSModalResponseOK) {
            return;
        }
        for (NSURL *url in urls) {
            [self openWindowForFontURL:url];
        }
    }];
}

#pragma mark - Recent files

- (void)noteRecentFontURL:(NSURL *)url {
    if (url.path.length == 0) return;
    NSMutableArray *paths = [[self.preferences arrayForKey:GARecentFontPathsKey] mutableCopy];
    [paths removeObject:url.path];
    [paths insertObject:url.path atIndex:0];
    NSUInteger limit = NSDocumentController.sharedDocumentController.maximumRecentDocumentCount;
    if (paths.count > limit) [paths removeObjectsInRange:NSMakeRange(limit, paths.count - limit)];
    [self.preferences setObject:paths forKey:GARecentFontPathsKey];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    [self rebuildRecentMenu];
}

- (void)rebuildRecentMenu {
    NSMenu *menu = self.recentMenu;
    if (menu == nil) return;
    [menu removeAllItems];

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *path in [self.preferences arrayForKey:GARecentFontPathsKey]) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if (url.isFileURL &&
            [[NSFileManager defaultManager] fileExistsAtPath:url.path] &&
            GAFontURLIsFont(url)) {
            [urls addObject:url];
        }
    }
    if (urls.count == 0) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Recent Fonts", @"No Recent Fonts")
                                            action:nil
                                     keyEquivalent:@""];
        empty.enabled = NO;
        return;
    }

    for (NSURL *url in urls) {
        NSString *title = url.lastPathComponent.length > 0
            ? url.lastPathComponent
            : url.path;
        NSMenuItem *item = [menu addItemWithTitle:title
                                           action:@selector(openRecentFont:)
                                    keyEquivalent:@""];
        item.target = self;
        item.representedObject = url;
        item.toolTip = url.path;
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [menu addItemWithTitle:NSLocalizedString(@"Clear Menu", @"Clear Menu")
                                        action:@selector(clearRecentFonts:)
                                 keyEquivalent:@""];
    clear.target = self;
}

- (void)openRecentFont:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (![url isKindOfClass:NSURL.class]) return;
    [self openWindowForFontURL:url];
}

- (void)clearRecentFonts:(id)sender {
    [self.preferences setObject:@[] forKey:GARecentFontPathsKey];
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
    [self rebuildRecentMenu];
}

#pragma mark - Saved text

- (NSMenuItem *)savedTextMenuItemForWindow:(NSWindow *)window {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Saved Text", @"Saved text submenu")
                                               action:nil keyEquivalent:@""];
    GASavedTextMenu *menu = [[GASavedTextMenu alloc] initWithTitle:item.title];
    menu.delegate = self;
    menu.controller = window ? (GAMainWindowController *)window.windowController : self.activeMainWindowController;
    [self rebuildSavedTextMenu:menu];
    item.submenu = menu;
    return item;
}

- (NSString *)previewForSavedText:(NSString *)text {
    NSString *preview = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
    preview = [preview stringByReplacingOccurrencesOfString:@"\r" withString:@" ⏎ "];
    preview = [preview stringByReplacingOccurrencesOfString:@"\t" withString:@" ⇥ "];
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
        preview = [preview stringByReplacingOccurrencesOfString:@" " withString:@"␠"];
    if (preview.length > 48) {
        NSRange range = [preview rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 48)];
        preview = [[preview substringWithRange:range] stringByAppendingString:@"…"];
    }
    return preview;
}

- (void)rebuildSavedTextMenu:(GASavedTextMenu *)menu {
    [menu removeAllItems];
    NSArray<NSString *> *texts = [self.preferences arrayForKey:GASavedTextsKey] ?: @[];
    NSString *current = menu.controller.inputText;
    NSString *title = [texts containsObject:current ?: @""]
        ? NSLocalizedString(@"Remove from Saved Text", @"Remove current text from saved list")
        : NSLocalizedString(@"Save Current Text", @"Save whole sidebar input as plain text");
    NSMenuItem *save = [menu addItemWithTitle:title action:@selector(toggleSavedText:) keyEquivalent:@""];
    save.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    if (!texts.count) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Saved Text", @"Empty saved text list")
                                          action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }
    for (NSString *text in texts) {
        NSMenuItem *item = [menu addItemWithTitle:[self previewForSavedText:text]
                                         action:@selector(useSavedText:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = text;
        item.toolTip = text;
    }
}

- (void)toggleSavedText:(NSMenuItem *)sender {
    NSString *text = ((GASavedTextMenu *)sender.menu).controller.inputText;
    if (!text.length) return;
    NSMutableArray *texts = [[self.preferences arrayForKey:GASavedTextsKey] mutableCopy]
        ?: [NSMutableArray array];
    if ([texts containsObject:text]) [texts removeObject:text];
    else [texts insertObject:text atIndex:0];
    [self.preferences setObject:texts forKey:GASavedTextsKey];
}

- (void)useSavedText:(NSMenuItem *)sender {
    [((GASavedTextMenu *)sender.menu).controller replaceInputText:sender.representedObject];
}

#pragma mark - Menu delegate

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.editMenu) {
        // Keep the command attached to the window that opened the Edit menu;
        // ending menu tracking or another field editor can change keyWindow.
        for (NSMenuItem *item in menu.itemArray) {
            if ([item.submenu isKindOfClass:GASavedTextMenu.class]) {
                GASavedTextMenu *saved = (GASavedTextMenu *)item.submenu;
                saved.controller = self.activeMainWindowController;
                [self rebuildSavedTextMenu:saved];
            }
        }
        return;
    }
    if ([menu isKindOfClass:GASavedTextMenu.class]) {
        [self rebuildSavedTextMenu:(GASavedTextMenu *)menu];
        return;
    }
    if (menu == self.recentMenu) {
        [self rebuildRecentMenu];
        return;
    }
    // Only context View menus use this delegate. Re-evaluate on every open;
    // the same menu is shared by the three views.
    GAViewMode mode = self.activeMainWindowController.viewMode;
    for (NSMenuItem *item in menu.itemArray) {
        BOOL textOnly = item.action == @selector(toggleContextualAlternates:) ||
                        item.action == @selector(toggleLigatures:) ||
                        item.action == @selector(toggleWritingDirection:) ||
                        [item.identifier isEqualToString:@"TextAlignment"];
        item.hidden =
            (textOnly && !GAViewModeSupportsTextLayout(mode)) ||
            (item.action == @selector(toggleShowMetrics:) && !GAViewModeSupportsMetrics(mode));
    }
    NSMenuItem *separator = nil;
    BOOL hasVisibleItem = NO;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.separatorItem) {
            item.hidden = YES;
            if (hasVisibleItem)
                separator = item;
        } else if (!item.hidden) {
            separator.hidden = NO;
            separator = nil;
            hasVisibleItem = YES;
        }
    }
}

#pragma mark - Menu construction

- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSString *appName = @"Glyph Atlas";

    NSMenuItem *appItem = [mainMenu addItemWithTitle:appName
                                              action:nil
                                       keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    appItem.submenu = appMenu;

    NSMenuItem *about = [appMenu addItemWithTitle:NSLocalizedString(@"About Glyph Atlas", @"About Glyph Atlas")
                                           action:@selector(orderFrontStandardAboutPanel:)
                                    keyEquivalent:@""];
    about.target = NSApp;
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Services", @"Services")];
    NSMenuItem *servicesItem = [appMenu addItemWithTitle:NSLocalizedString(@"Services", @"Services")
                                                  action:nil
                                           keyEquivalent:@""];
    servicesItem.submenu = servicesMenu;
    NSApp.servicesMenu = servicesMenu;

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hide = [appMenu addItemWithTitle:NSLocalizedString(@"Hide Glyph Atlas", @"Hide Glyph Atlas")
                                          action:@selector(hide:)
                                   keyEquivalent:@"h"];
    hide.target = NSApp;

    NSMenuItem *hideOthers = [appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", @"Hide Others")
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                          NSEventModifierFlagOption;
    hideOthers.target = NSApp;

    NSMenuItem *showAll = [appMenu addItemWithTitle:NSLocalizedString(@"Show All", @"Show All")
                                             action:@selector(unhideAllApplications:)
                                      keyEquivalent:@""];
    showAll.target = NSApp;

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [appMenu addItemWithTitle:NSLocalizedString(@"Quit Glyph Atlas", @"Quit Glyph Atlas")
                                          action:@selector(terminate:)
                                   keyEquivalent:@"q"];
    quit.target = NSApp;

    // File
    NSMenuItem *fileItem = [mainMenu addItemWithTitle:NSLocalizedString(@"File", @"File")
                                               action:nil
                                        keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"File", @"File")];
    fileItem.submenu = fileMenu;

    NSMenuItem *open = [fileMenu
        addItemWithTitle:NSLocalizedString(@"Open Font…", @"Open Font…")
                  action:@selector(openFont:)
           keyEquivalent:@"o"];
    open.target = self;

    NSMenuItem *openWithNewShortcut = [open copy];
    openWithNewShortcut.keyEquivalent = @"n";
    openWithNewShortcut.hidden = YES;
    openWithNewShortcut.allowsKeyEquivalentWhenHidden = YES;
    [fileMenu addItem:openWithNewShortcut];

    NSMenuItem *recentItem = [fileMenu addItemWithTitle:NSLocalizedString(@"Open Recent", @"Open Recent")
                                                 action:nil
                                          keyEquivalent:@""];
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Open Recent", @"Open Recent")];
    recentMenu.delegate = self;
    recentItem.submenu = recentMenu;
    self.recentMenu = recentMenu;
    [self rebuildRecentMenu];

    NSMenuItem *copyToFontBook = [fileMenu
        addItemWithTitle:NSLocalizedString(@"Copy to Font Book", @"Copy to Font Book")
                  action:@selector(copyToFontBook:)
           keyEquivalent:@""];
    copyToFontBook.target = self;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    [fileMenu addItemWithTitle:NSLocalizedString(@"Close Window", @"Close Window")
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];

    // Edit
    NSMenuItem *editItem = [mainMenu addItemWithTitle:NSLocalizedString(@"Edit", @"Edit")
                                               action:nil
                                        keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit")];
    editItem.submenu = editMenu;
    self.editMenu = editMenu;
    editMenu.delegate = self;

    [editMenu addItemWithTitle:NSLocalizedString(@"Undo", @"Undo") action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:NSLocalizedString(@"Redo", @"Redo") action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Delete", @"Delete") action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];

    [editMenu addItem:[self savedTextMenuItemForWindow:nil]];

    // View
    NSMenuItem *viewItem = [mainMenu addItemWithTitle:NSLocalizedString(@"View", @"View")
                                               action:nil
                                        keyEquivalent:@""];
    viewItem.submenu = [self buildViewMenuIncludingZoom:YES];

    // Window
    NSMenuItem *windowItem = [mainMenu addItemWithTitle:NSLocalizedString(@"Window", @"Window")
                                                 action:nil
                                          keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Window", @"Window")];
    windowItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", @"Minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Zoom", @"Zoom") action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Bring All to Front", @"Bring All to Front") action:@selector(arrangeInFront:) keyEquivalent:@""];

    // Help
    NSMenuItem *helpItem = [mainMenu addItemWithTitle:NSLocalizedString(@"Help", @"Help")
                                               action:nil
                                        keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Help", @"Help")];
    helpItem.submenu = helpMenu;
    NSApp.helpMenu = helpMenu;

    NSMenuItem *help = [helpMenu addItemWithTitle:NSLocalizedString(@"Glyph Atlas Help", @"Glyph Atlas Help")
                                           action:@selector(showHelp:)
                                    keyEquivalent:@"?"];
    help.target = self;

    NSApp.mainMenu = mainMenu;
}

- (NSMenu *)buildViewMenuIncludingZoom:(BOOL)includeZoom {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"View", @"View")];
    // Menu order is also the shortcut order: Single ⌘1, Multi ⌘2, All ⌘3.
    NSArray<NSString *> *modeTitles = @[NSLocalizedString(@"Single Glyph", @"Single Glyph"), NSLocalizedString(@"Multi-Character", @"Multi-Character"), NSLocalizedString(@"All Glyphs", @"All Glyphs")];
    NSArray<NSNumber *> *modeTags = @[@(GAViewModeSingleGlyph),
                                      @(GAViewModeMultiCharacter),
                                      @(GAViewModeAllGlyphs)];
    NSArray<NSString *> *modeKeys = @[@"1", @"2", @"3"];
    NSArray<NSString *> *defaultModeTitles = @[
        NSLocalizedString(@"Default to Single Glyph", @"Default view mode"),
        NSLocalizedString(@"Default to Multi-Character", @"Default view mode"),
        NSLocalizedString(@"Default to All Glyphs", @"Default view mode")];
    for (NSInteger index = 0; index < 3; index++) {
        NSMenuItem *item = [menu addItemWithTitle:modeTitles[(NSUInteger)index]
                                           action:@selector(switchViewMode:)
                                    keyEquivalent:modeKeys[(NSUInteger)index]];
        item.target = self;
        item.tag = modeTags[(NSUInteger)index].integerValue;
        if (includeZoom) [self addDefaultAlternativeForItem:item
            title:defaultModeTitles[(NSUInteger)index] key:GAViewModeDefaultKey menu:menu];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *metrics = [menu addItemWithTitle:NSLocalizedString(@"Show Bounding Box", @"Show Bounding Box")
                                          action:@selector(toggleShowMetrics:)
                                   keyEquivalent:@"4"];
    metrics.target = self;
    if (includeZoom) [self addDefaultAlternativeForItem:metrics
        title:NSLocalizedString(@"Show Bounding Box by Default", @"Default bounding box visibility")
        key:GABoundingBoxDefaultKey menu:menu];

    if (includeZoom) {
        NSMenuItem *colorsItem = [menu addItemWithTitle:NSLocalizedString(@"Colors", @"Preview colors")
                                               action:nil keyEquivalent:@""];
        NSMenu *colorsMenu = [[NSMenu alloc] initWithTitle:colorsItem.title];
        colorsItem.submenu = colorsMenu;
        NSMenuItem *systemColors = [colorsMenu
            addItemWithTitle:NSLocalizedString(@"Follow System", @"Restore all preview colors")
                      action:@selector(followSystemColors:) keyEquivalent:@""];
        systemColors.target = self;
        NSArray<NSString *> *colorTitles = @[
            NSLocalizedString(@"Glyph Color…", @"Choose preview glyph color"),
            NSLocalizedString(@"Background Color…", @"Choose preview background color"),
            NSLocalizedString(@"Bounding Box Color…", @"Choose bounding box fill color")];
        for (NSInteger role = GAPreviewColorGlyph; role <= GAPreviewColorBoundingBox; role++) {
            NSMenuItem *item = [colorsMenu addItemWithTitle:colorTitles[(NSUInteger)role]
                                                    action:@selector(choosePreviewColor:)
                                             keyEquivalent:@""];
            item.target = self;
            item.tag = role;
        }
    }
    [menu addItem:[NSMenuItem separatorItem]];

    if (!includeZoom) {
        menu.delegate = self;
        [self addViewAlignmentItemsToMenu:menu includingDefaults:NO];
        return menu;
    }

    NSMenuItem *zoomIn = [menu addItemWithTitle:NSLocalizedString(@"Zoom In", @"Zoom In")
                                         action:@selector(zoomIn:)
                                  keyEquivalent:@"+"];
    zoomIn.target = self;
    NSMenuItem *metricsZoomIn = [menu addItemWithTitle:NSLocalizedString(@"Bounding Box Zoom In", @"Bounding Box Zoom In")
                                                action:@selector(zoomMetricsIn:)
                                         keyEquivalent:@"+"];
    metricsZoomIn.target = self;
    metricsZoomIn.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    metricsZoomIn.alternate = YES;
    NSMenuItem *spacingIn = [menu
        addItemWithTitle:NSLocalizedString(@"Increase Line Spacing", @"Increase preview line spacing")
                  action:@selector(adjustLineSpacing:) keyEquivalent:@"+"];
    spacingIn.target = self;
    spacingIn.tag = 1;
    spacingIn.keyEquivalentModifierMask = NSEventModifierFlagCommand |
        NSEventModifierFlagOption | NSEventModifierFlagControl;
    spacingIn.alternate = YES;

    NSMenuItem *zoomOut = [menu addItemWithTitle:NSLocalizedString(@"Zoom Out", @"Zoom Out")
                                          action:@selector(zoomOut:)
                                   keyEquivalent:@"-"];
    zoomOut.target = self;
    NSMenuItem *metricsZoomOut = [menu addItemWithTitle:NSLocalizedString(@"Bounding Box Zoom Out", @"Bounding Box Zoom Out")
                                                 action:@selector(zoomMetricsOut:)
                                          keyEquivalent:@"-"];
    metricsZoomOut.target = self;
    metricsZoomOut.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    metricsZoomOut.alternate = YES;
    NSMenuItem *spacingOut = [spacingIn copy];
    spacingOut.title = NSLocalizedString(@"Decrease Line Spacing", @"Decrease preview line spacing");
    spacingOut.keyEquivalent = @"-";
    spacingOut.tag = -1;
    [menu addItem:spacingOut];
    NSMenuItem *actualSize = [menu addItemWithTitle:NSLocalizedString(@"Actual Size", @"Actual Size")
                                             action:@selector(resetZoom:)
                                      keyEquivalent:@"0"];
    actualSize.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    [self addViewAlignmentItemsToMenu:menu includingDefaults:YES];
    return menu;
}

- (void)addDefaultAlternativeForItem:(NSMenuItem *)item title:(NSString *)title
                                key:(NSString *)key menu:(NSMenu *)menu {
    NSMenuItem *alternative = [item copy];
    alternative.title = title;
    alternative.action = @selector(setDefaultViewSetting:);
    alternative.representedObject = key;
    alternative.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    alternative.alternate = YES;
    [menu addItem:alternative];
}

- (void)addViewAlignmentItemsToMenu:(NSMenu *)menu includingDefaults:(BOOL)includeDefaults {
    NSMenuItem *contextual = [menu
        addItemWithTitle:NSLocalizedString(@"Contextual Alternates", @"Contextual Alternates")
                  action:@selector(toggleContextualAlternates:)
           keyEquivalent:@"5"];
    contextual.target = self;
    if (includeDefaults) [self addDefaultAlternativeForItem:contextual
        title:NSLocalizedString(@"Enable Contextual Alternates by Default", @"Default contextual alternates")
        key:GAContextualAlternatesDefaultKey menu:menu];
    NSMenuItem *ligatures = [menu
        addItemWithTitle:NSLocalizedString(@"Ligatures", @"Ligatures")
                  action:@selector(toggleLigatures:)
           keyEquivalent:@"6"];
    ligatures.target = self;
    if (includeDefaults) [self addDefaultAlternativeForItem:ligatures
        title:NSLocalizedString(@"Enable Ligatures by Default", @"Default ligatures")
        key:GALigaturesDefaultKey menu:menu];
    NSMenuItem *verticalItem = [menu
        addItemWithTitle:NSLocalizedString(@"Vertical", @"Vertical")
                  action:@selector(toggleWritingDirection:)
           keyEquivalent:@"7"];
    verticalItem.target = self;
    if (includeDefaults) [self addDefaultAlternativeForItem:verticalItem
        title:NSLocalizedString(@"Use Vertical Writing by Default", @"Default writing direction")
        key:GAVerticalWritingDefaultKey menu:menu];

    NSMenuItem *alignmentItem = [menu addItemWithTitle:NSLocalizedString(@"Text Alignment", @"Text Alignment")
                                                action:nil
                                         keyEquivalent:@""];
    NSMenu *alignmentMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Text Alignment", @"Text Alignment")];
    NSArray<NSString *> *alignmentTitles =
        @[NSLocalizedString(@"Left", @"Left"), NSLocalizedString(@"Center", @"Center"), NSLocalizedString(@"Right", @"Right"), NSLocalizedString(@"Justified", @"Justified")];
    NSArray<NSNumber *> *alignmentTags = @[@(NSTextAlignmentLeft),
                                           @(NSTextAlignmentCenter),
                                           @(NSTextAlignmentRight),
                                           @(NSTextAlignmentJustified)];
    for (NSInteger alignment = 0; alignment < 4; alignment++) {
        NSMenuItem *item = [alignmentMenu addItemWithTitle:alignmentTitles[(NSUInteger)alignment]
                                                    action:@selector(setTextAlignment:)
                                             keyEquivalent:@""];
        item.target = self;
        item.tag = alignmentTags[(NSUInteger)alignment].integerValue;
    }
    alignmentItem.identifier = @"TextAlignment";
    alignmentItem.submenu = alignmentMenu;
}

- (NSMenu *)viewMenuForContext {
    return [self buildViewMenuIncludingZoom:NO];
}

#pragma mark - Active window

- (GAMainWindowController *)activeMainWindowController {
    NSWindowController *controller = NSApp.keyWindow.windowController;
    if ([controller isKindOfClass:GAMainWindowController.class]) {
        return (GAMainWindowController *)controller;
    }
    controller = NSApp.mainWindow.windowController;
    if ([controller isKindOfClass:GAMainWindowController.class]) return (GAMainWindowController *)controller;
    for (GAMainWindowController *candidate in self.windowControllers) {
        if (candidate.window.isVisible) {
            return candidate;
        }
    }
    return nil;
}

#pragma mark - View actions

- (void)switchViewMode:(NSMenuItem *)sender {
    [self.activeMainWindowController setViewMode:(GAViewMode)sender.tag];
}

- (void)toggleShowMetrics:(id)sender {
    [self.activeMainWindowController toggleShowsMetrics];
}

- (void)zoomIn:(id)sender {
    [self.activeMainWindowController zoomIn];
}

- (void)zoomOut:(id)sender {
    [self.activeMainWindowController zoomOut];
}

- (void)zoomMetricsIn:(id)sender {
    [self.activeMainWindowController zoomMetricsIn];
}

- (void)zoomMetricsOut:(id)sender {
    [self.activeMainWindowController zoomMetricsOut];
}

- (void)adjustLineSpacing:(NSMenuItem *)sender {
    [self.activeMainWindowController adjustLineSpacing:sender.tag];
}

- (void)setDefaultViewSetting:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    NSInteger value = [key isEqualToString:GAViewModeDefaultKey]
        ? sender.tag : !GAViewDefaultValue(self.preferences, key);
    [self.preferences setObject:@(value) forKey:key];
}

- (void)followSystemColors:(id)sender {
    [self.activeMainWindowController followSystemColors];
}

- (void)choosePreviewColor:(NSMenuItem *)sender {
    self.colorOwner = self.activeMainWindowController;
    self.editingColorRole = (GAPreviewColorRole)sender.tag;
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.target = nil;
    panel.showsAlpha = NO;
    panel.color = [self.colorOwner.previewColors colorForRole:self.editingColorRole];
    panel.target = self;
    panel.action = @selector(changePreviewColor:);
    panel.continuous = YES;
    [panel makeKeyAndOrderFront:nil];
}

- (void)changePreviewColor:(NSColorPanel *)sender {
    if (self.colorOwner.window.isVisible)
        [self.colorOwner setPreviewColor:sender.color forRole:self.editingColorRole];
}

- (void)resetZoom:(id)sender {
    [self.activeMainWindowController resetZoom];
}

- (void)setTextAlignment:(NSMenuItem *)sender {
    [self.activeMainWindowController setTextAlignment:(NSTextAlignment)sender.tag];
}

- (void)toggleContextualAlternates:(id)sender {
    GAMainWindowController *controller = self.activeMainWindowController;
    [controller setUsesContextualAlternates:!controller.usesContextualAlternates];
}

- (void)toggleLigatures:(id)sender {
    GAMainWindowController *controller = self.activeMainWindowController;
    [controller setUsesLigatures:!controller.usesLigatures];
}

- (void)toggleWritingDirection:(id)sender {
    GAMainWindowController *controller = [self activeMainWindowController];
    [controller setVerticalWriting:!controller.verticalWriting];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(setDefaultViewSetting:)) {
        NSString *key = item.representedObject;
        NSInteger value = GAViewDefaultValue(self.preferences, key);
        BOOL selected = [key isEqualToString:GAViewModeDefaultKey] ? value == item.tag : value;
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    // Application-level commands do not require an open font window.
    if (action == @selector(showHelp:) ||
        action == @selector(openFont:) || action == @selector(openRecentFont:) ||
        action == @selector(clearRecentFonts:)) {
        return YES;
    }
    if (action == @selector(toggleSavedText:) || action == @selector(useSavedText:)) {
        GAMainWindowController *owner = ((GASavedTextMenu *)item.menu).controller;
        return owner.fontURL != nil && (action != @selector(toggleSavedText:) || owner.inputText.length > 0);
    }
    GAMainWindowController *controller = [self activeMainWindowController];
    if (controller == nil) {
        return NO;
    }
    if (action == @selector(copyToFontBook:)) {
        return controller.fontURL != nil;
    }
    if (action == @selector(followSystemColors:)) {
        item.state = controller.previewColors.followsSystem
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(choosePreviewColor:)) return YES;
    if (action == @selector(adjustLineSpacing:))
        return GAViewModeSupportsTextLayout(controller.viewMode);
    if (action == @selector(switchViewMode:)) {
        item.state = controller.viewMode == (GAViewMode)item.tag
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(toggleContextualAlternates:) || action == @selector(toggleLigatures:)) {
        BOOL enabled = action == @selector(toggleContextualAlternates:)
                           ? controller.usesContextualAlternates
                           : controller.usesLigatures;
        item.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsTextLayout(controller.viewMode);
    }
    if (action == @selector(toggleShowMetrics:)) {
        item.state = controller.showsMetrics ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsMetrics(controller.viewMode);
    }
    if (action == @selector(zoomMetricsIn:) ||
        action == @selector(zoomMetricsOut:)) {
        return GAViewModeSupportsTextLayout(controller.viewMode);
    }
    if (action == @selector(zoomIn:) ||
        action == @selector(zoomOut:) ||
        action == @selector(resetZoom:)) {
        return YES;
    }
    if (action == @selector(setTextAlignment:)) {
        item.state = controller.textAlignment == (NSTextAlignment)item.tag
            ? NSControlStateValueOn : NSControlStateValueOff;
        BOOL vertical = controller.verticalWriting;
        switch ((NSTextAlignment)item.tag) {
            case NSTextAlignmentLeft: item.title = vertical ? NSLocalizedString(@"Top", @"Top") : NSLocalizedString(@"Left", @"Left"); break;
            case NSTextAlignmentCenter: item.title = NSLocalizedString(@"Center", @"Center"); break;
            case NSTextAlignmentRight: item.title = vertical ? NSLocalizedString(@"Bottom", @"Bottom") : NSLocalizedString(@"Right", @"Right"); break;
            default: item.title = NSLocalizedString(@"Justified", @"Justified"); break;
        }
        return GAViewModeSupportsTextLayout(controller.viewMode);
    }
    if (action == @selector(toggleWritingDirection:)) {
        item.state = controller.verticalWriting
            ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsTextLayout(controller.viewMode);
    }
    return YES;
}

#pragma mark - File and application actions

- (void)copyToFontBook:(id)sender {
    GAMainWindowController *controller = self.activeMainWindowController;
    NSURL *fontURL = controller.fontURL;
    if (fontURL == nil)
        return;
    NSURL *directory = [NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Fonts"] isDirectory:YES];
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *error = nil;
    NSURLRelationship relationship;
    if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES
                         attributes:nil error:&error] ||
        ![files getRelationship:&relationship ofDirectoryAtURL:directory.URLByResolvingSymlinksInPath
                     toItemAtURL:fontURL.URLByResolvingSymlinksInPath error:&error]) {
        [NSApp presentError:error];
        return;
    }
    if (relationship == NSURLRelationshipContains) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString localizedStringWithFormat:
            NSLocalizedString(@"“%@” is already in Font Book.", @"Font already in user Fonts folder"),
            fontURL.lastPathComponent];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];
        [alert beginSheetModalForWindow:controller.window completionHandler:nil];
        return;
    }
    NSURL *destination = [directory URLByAppendingPathComponent:fontURL.lastPathComponent];
    if (![files fileExistsAtPath:destination.path]) {
        [self copyFontAtURL:fontURL toURL:destination replacing:NO];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString localizedStringWithFormat:
        NSLocalizedString(@"An item named “%@” already exists in Font Book.", @"Font filename conflict"),
        fontURL.lastPathComponent];
    NSButton *replace = [alert addButtonWithTitle:NSLocalizedString(@"Replace", @"Finder file conflict button")];
    replace.keyEquivalent = @"";
    [alert addButtonWithTitle:NSLocalizedString(@"Keep Both", @"Finder file conflict button")];
    NSButton *stop = [alert addButtonWithTitle:NSLocalizedString(@"Stop", @"Finder file conflict button")];
    stop.keyEquivalent = @"\033";
    [alert layout];
    alert.window.defaultButtonCell = stop.cell;
    [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn && response != NSAlertSecondButtonReturn)
            return;
        NSURL *target = destination;
        if (response == NSAlertSecondButtonReturn) {
            NSString *baseName = fontURL.lastPathComponent.stringByDeletingPathExtension;
            NSString *extension = fontURL.pathExtension;
            NSUInteger suffix = 2;
            do {
                NSString *name = [NSString stringWithFormat:@"%@ %lu", baseName, (unsigned long)suffix++];
                if (extension.length)
                    name = [name stringByAppendingPathExtension:extension];
                target = [directory URLByAppendingPathComponent:name];
            } while ([files fileExistsAtPath:target.path]);
        }
        [self copyFontAtURL:fontURL toURL:target replacing:response == NSAlertFirstButtonReturn];
    }];
}

- (void)copyFontAtURL:(NSURL *)source toURL:(NSURL *)destination replacing:(BOOL)replace {
    NSFileManager *files = [NSFileManager defaultManager];
    NSError *error = nil;
    if (replace) {
        // Replace a temporary copy so the opened source file stays in place.
        NSURL *temporaryDirectory = [files URLForDirectory:NSItemReplacementDirectory
                                                  inDomain:NSUserDomainMask
                                         appropriateForURL:destination create:YES error:&error];
        if (temporaryDirectory) {
            NSURL *copy = [temporaryDirectory URLByAppendingPathComponent:source.lastPathComponent];
            if ([files copyItemAtURL:source toURL:copy error:&error])
                [files replaceItemAtURL:destination withItemAtURL:copy backupItemName:nil
                                options:NSFileManagerItemReplacementUsingNewMetadataOnly
                       resultingItemURL:NULL error:&error];
            [files removeItemAtURL:temporaryDirectory error:NULL];
        }
    } else {
        [files copyItemAtURL:source toURL:destination error:&error];
    }
    if (error)
        [NSApp presentError:error];
}

- (void)showHelp:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Glyph Atlas";
    NSArray<NSString *> *paragraphs = @[
        NSLocalizedString(@"Help.01", @"Usage paragraph 1"),
        NSLocalizedString(@"Help.02", @"Usage paragraph 2"),
        NSLocalizedString(@"Help.03", @"Usage paragraph 3"),
        NSLocalizedString(@"Help.04", @"Usage paragraph 4"),
        NSLocalizedString(@"Help.05", @"Usage paragraph 5"),
        NSLocalizedString(@"Help.06", @"Usage paragraph 6"),
        NSLocalizedString(@"Help.07", @"Usage paragraph 7"),
        NSLocalizedString(@"Help.08", @"Usage paragraph 8"),
        NSLocalizedString(@"Help.09", @"Usage paragraph 9"),
        NSLocalizedString(@"Help.10", @"Usage paragraph 10"),
        NSLocalizedString(@"Help.11", @"Usage paragraph 11"),
        NSLocalizedString(@"Help.12", @"Usage paragraph 12"),
        NSLocalizedString(@"Help.13", @"Usage paragraph 13"),
        NSLocalizedString(@"Help.14", @"Usage paragraph 14")
    ];
    alert.informativeText = [@"• " stringByAppendingString:[paragraphs componentsJoinedByString:@"\n• "]];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];

    NSWindow *window = NSApp.keyWindow ?: self.windowControllers.lastObject.window;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

@end
