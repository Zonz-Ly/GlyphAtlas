#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import "GAFontTypes.h"

@interface GAAppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSMutableArray<GAMainWindowController *> *windowControllers;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingFontURLs;
@property (nonatomic, strong, nullable) NSOpenPanel *openPanel;
@property (nonatomic, strong, nullable) NSMenu *recentMenu;
@property (nonatomic) BOOL launched;
@property (nonatomic) BOOL handlingOpenFiles;
@end

@implementation GAAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
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

    // Give AppKit a moment to deliver an openFiles: call when launched from Finder.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.launched && self.windowControllers.count == 0 &&
            self.pendingFontURLs.count == 0) {
            [self showOpenPanel];
        }
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag && !self.handlingOpenFiles && self.windowControllers.count == 0) {
        [self showOpenPanel];
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

    if (self.openPanel != nil) {
        [self.openPanel cancel:nil];
    }
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

- (void)showOpenPanel {
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
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    [self rebuildRecentMenu];
}

- (void)rebuildRecentMenu {
    NSMenu *menu = self.recentMenu;
    if (menu == nil) return;
    [menu removeAllItems];

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSArray<NSURL *> *recentURLs =
        [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    for (NSURL *url in recentURLs) {
        if (url.isFileURL &&
            [[NSFileManager defaultManager] fileExistsAtPath:url.path] &&
            GAFontURLIsFont(url)) {
            [urls addObject:url];
        }
    }
    if (urls.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"No Recent Fonts", @"No Recent Fonts")
                                                       action:nil
                                                keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
        return;
    }

    for (NSURL *url in urls) {
        NSString *title = url.lastPathComponent.length > 0
            ? url.lastPathComponent
            : url.path;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(openRecentFont:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = url;
        item.toolTip = url.path;
        [menu addItem:item];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Clear Menu", @"Clear Menu")
                                                   action:@selector(clearRecentFonts:)
                                            keyEquivalent:@""];
    clear.target = self;
    [menu addItem:clear];
}

- (void)openRecentFont:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (![url isKindOfClass:NSURL.class]) return;
    [self openWindowForFontURL:url];
}

- (void)clearRecentFonts:(id)sender {
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
    [self rebuildRecentMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.recentMenu) {
        [self rebuildRecentMenu];
        return;
    }
    // Only context View menus use this delegate. Re-evaluate on every open;
    // the same menu is shared by the three canvases.
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

#pragma mark - Menu

- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSString *appName = @"Glyph Atlas";

    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:appName
                                                     action:nil
                                              keyEquivalent:@""];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    appItem.submenu = appMenu;

    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"About Glyph Atlas", @"About Glyph Atlas")
                                                   action:@selector(showAbout:)
                                            keyEquivalent:@""];
    about.target = self;
    [appMenu addItem:about];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Services", @"Services")];
    NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Services", @"Services")
                                                          action:nil
                                                   keyEquivalent:@""];
    servicesItem.submenu = servicesMenu;
    [appMenu addItem:servicesItem];
    NSApp.servicesMenu = servicesMenu;

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Hide Glyph Atlas", @"Hide Glyph Atlas")
                                                  action:@selector(hide:)
                                           keyEquivalent:@"h"];
    hide.target = NSApp;
    [appMenu addItem:hide];

    NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Hide Others", @"Hide Others")
                                                        action:@selector(hideOtherApplications:)
                                                 keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                          NSEventModifierFlagOption;
    hideOthers.target = NSApp;
    [appMenu addItem:hideOthers];

    NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Show All", @"Show All")
                                                     action:@selector(unhideAllApplications:)
                                              keyEquivalent:@""];
    showAll.target = NSApp;
    [appMenu addItem:showAll];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Quit Glyph Atlas", @"Quit Glyph Atlas")
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target = NSApp;
    [appMenu addItem:quit];

    // File
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"File", @"File")
                                                     action:nil
                                              keyEquivalent:@""];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"File", @"File")];
    fileItem.submenu = fileMenu;

    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open Font…", @"Open Font…")
                                                  action:@selector(openFont:)
                                           keyEquivalent:@"o"];
    open.target = self;
    [fileMenu addItem:open];

    NSMenuItem *recentItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open Recent", @"Open Recent")
                                                        action:nil
                                                 keyEquivalent:@""];
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Open Recent", @"Open Recent")];
    recentMenu.delegate = self;
    recentItem.submenu = recentMenu;
    self.recentMenu = recentMenu;
    [fileMenu addItem:recentItem];
    [self rebuildRecentMenu];

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Close Window", @"Close Window")
                                                   action:@selector(performClose:)
                                            keyEquivalent:@"w"];
    [fileMenu addItem:close];

    // Edit
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit")
                                                      action:nil
                                               keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit")];
    editItem.submenu = editMenu;

    [editMenu addItem:[self menuItem:NSLocalizedString(@"Undo", @"Undo") action:@selector(undo:) key:@"z" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Redo", @"Redo") action:@selector(redo:) key:@"z" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Cut", @"Cut") action:@selector(cut:) key:@"x" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Copy", @"Copy") action:@selector(copy:) key:@"c" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Paste", @"Paste") action:@selector(paste:) key:@"v" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Delete", @"Delete") action:@selector(delete:) key:@"" modifiers:0]];
    [editMenu addItem:[self menuItem:NSLocalizedString(@"Select All", @"Select All") action:@selector(selectAll:) key:@"a" modifiers:NSEventModifierFlagCommand]];

    // View
    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"View", @"View")
                                                     action:nil
                                              keyEquivalent:@""];
    [mainMenu addItem:viewItem];
    viewItem.submenu = [self buildViewMenuIncludingZoom:YES];

    // Window
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Window", @"Window")
                                                        action:nil
                                                 keyEquivalent:@""];
    [mainMenu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Window", @"Window")];
    windowItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    [windowMenu addItem:[self menuItem:NSLocalizedString(@"Minimize", @"Minimize") action:@selector(performMiniaturize:) key:@"m" modifiers:NSEventModifierFlagCommand]];
    [windowMenu addItem:[self menuItem:NSLocalizedString(@"Zoom", @"Zoom") action:@selector(performZoom:) key:@"" modifiers:0]];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[self menuItem:NSLocalizedString(@"Bring All to Front", @"Bring All to Front") action:@selector(arrangeInFront:) key:@"" modifiers:0]];

    // Help
    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Help", @"Help")
                                                      action:nil
                                               keyEquivalent:@""];
    [mainMenu addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Help", @"Help")];
    helpItem.submenu = helpMenu;
    NSApp.helpMenu = helpMenu;

    NSMenuItem *help = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Glyph Atlas Help", @"Glyph Atlas Help")
                                                  action:@selector(showHelp:)
                                           keyEquivalent:@"?"];
    help.target = self;
    [helpMenu addItem:help];

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
    for (NSInteger index = 0; index < 3; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:modeTitles[(NSUInteger)index]
                                                      action:@selector(switchViewMode:)
                                               keyEquivalent:modeKeys[(NSUInteger)index]];
        item.target = self;
        item.tag = modeTags[(NSUInteger)index].integerValue;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *metrics = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Show Metrics", @"Show Metrics")
                                                     action:@selector(toggleShowMetrics:)
                                              keyEquivalent:@"4"];
    metrics.target = self;
    [menu addItem:metrics];
    [menu addItem:[NSMenuItem separatorItem]];

    if (!includeZoom) {
        menu.delegate = self;
        [self addViewAlignmentItemsToMenu:menu];
        return menu;
    }

    NSMenuItem *zoomIn = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Zoom In", @"Zoom In")
                                                    action:@selector(zoomIn:)
                                             keyEquivalent:@"+"];
    zoomIn.target = self;
    [menu addItem:zoomIn];
    NSMenuItem *metricsZoomIn =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Metrics Zoom In", @"Metrics Zoom In")
                                   action:@selector(zoomMetricsIn:)
                            keyEquivalent:@"+"];
    metricsZoomIn.target = self;
    metricsZoomIn.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    metricsZoomIn.alternate = YES;
    [menu addItem:metricsZoomIn];

    NSMenuItem *zoomOut = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Zoom Out", @"Zoom Out")
                                                     action:@selector(zoomOut:)
                                              keyEquivalent:@"-"];
    zoomOut.target = self;
    [menu addItem:zoomOut];
    NSMenuItem *metricsZoomOut =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Metrics Zoom Out", @"Metrics Zoom Out")
                                   action:@selector(zoomMetricsOut:)
                            keyEquivalent:@"-"];
    metricsZoomOut.target = self;
    metricsZoomOut.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    metricsZoomOut.alternate = YES;
    [menu addItem:metricsZoomOut];
    NSMenuItem *actualSize = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Actual Size", @"Actual Size")
                                                        action:@selector(resetZoom:)
                                                 keyEquivalent:@"0"];
    actualSize.target = self;
    [menu addItem:actualSize];
    [menu addItem:[NSMenuItem separatorItem]];

    [self addViewAlignmentItemsToMenu:menu];
    return menu;
}

- (void)addViewAlignmentItemsToMenu:(NSMenu *)menu {
    NSMenuItem *contextual = [[NSMenuItem alloc]
        initWithTitle:NSLocalizedString(@"Contextual Alternates", @"Contextual Alternates")
               action:@selector(toggleContextualAlternates:)
        keyEquivalent:@"5"];
    contextual.target = self;
    [menu addItem:contextual];
    NSMenuItem *ligatures =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Ligatures", @"Ligatures")
                                   action:@selector(toggleLigatures:)
                            keyEquivalent:@"6"];
    ligatures.target = self;
    [menu addItem:ligatures];
    NSMenuItem *verticalItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Vertical", @"Vertical")
                                   action:@selector(toggleWritingDirection:)
                            keyEquivalent:@"7"];
    verticalItem.target = self;
    [menu addItem:verticalItem];

    NSMenuItem *alignmentItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Text Alignment", @"Text Alignment")
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
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:alignmentTitles[(NSUInteger)alignment]
                                                      action:@selector(setTextAlignment:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = alignmentTags[(NSUInteger)alignment].integerValue;
        [alignmentMenu addItem:item];
    }
    alignmentItem.identifier = @"TextAlignment";
    alignmentItem.submenu = alignmentMenu;
    [menu addItem:alignmentItem];
}

- (NSMenu *)viewMenuForContext {
    return [self buildViewMenuIncludingZoom:NO];
}

- (GAMainWindowController *)activeMainWindowController {
    NSWindowController *controller = NSApp.keyWindow.windowController;
    if ([controller isKindOfClass:GAMainWindowController.class]) {
        return (GAMainWindowController *)controller;
    }
    for (GAMainWindowController *candidate in self.windowControllers) {
        if (candidate.window.isVisible) {
            return candidate;
        }
    }
    return nil;
}

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

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    // Application-level commands do not require an open font window.
    if (action == @selector(showAbout:) || action == @selector(showHelp:) ||
        action == @selector(openFont:) || action == @selector(openRecentFont:) ||
        action == @selector(clearRecentFonts:)) {
        return YES;
    }
    GAMainWindowController *controller = [self activeMainWindowController];
    if (controller == nil) {
        return NO;
    }
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
        return controller.viewMode != GAViewModeAllGlyphs;
    }
    if (action == @selector(zoomMetricsIn:) ||
        action == @selector(zoomMetricsOut:)) {
        return controller.viewMode == GAViewModeMultiCharacter;
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
        return controller.viewMode == GAViewModeMultiCharacter;
    }
    if (action == @selector(toggleWritingDirection:)) {
        item.state = controller.verticalWriting
            ? NSControlStateValueOn : NSControlStateValueOff;
        return controller.viewMode == GAViewModeMultiCharacter;
    }
    return YES;
}

- (NSMenuItem *)menuItem:(NSString *)title
                  action:(SEL)action
                     key:(NSString *)key
               modifiers:(NSEventModifierFlags)modifiers {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = modifiers;
    return item;
}

#pragma mark - Menu actions

- (void)openFont:(id)sender {
    [self showOpenPanel];
}

- (void)showAbout:(id)sender {
    // Let AppKit read the icon, version, and localized copyright from the
    // bundle. No custom credits: passing a plain NSString there breaks the
    // standard panel's first initialization (it requires NSAttributedString).
    [NSApp orderFrontStandardAboutPanel:sender];
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
        NSLocalizedString(@"Help.13", @"Usage paragraph 13")
    ];
    alert.informativeText = [@"· " stringByAppendingString:[paragraphs componentsJoinedByString:@"\n· "]];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];

    NSWindow *window = NSApp.keyWindow ?: self.windowControllers.lastObject.window;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

@end
