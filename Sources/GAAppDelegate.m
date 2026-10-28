#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import "GAFontResource.h"

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
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
    [self rebuildRecentMenu];
}

#pragma mark - Menu delegate

- (void)menuNeedsUpdate:(NSMenu *)menu {
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

    [editMenu addItemWithTitle:NSLocalizedString(@"Undo", @"Undo") action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:NSLocalizedString(@"Redo", @"Redo") action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Delete", @"Delete") action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];

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
    for (NSInteger index = 0; index < 3; index++) {
        NSMenuItem *item = [menu addItemWithTitle:modeTitles[(NSUInteger)index]
                                           action:@selector(switchViewMode:)
                                    keyEquivalent:modeKeys[(NSUInteger)index]];
        item.target = self;
        item.tag = modeTags[(NSUInteger)index].integerValue;
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *metrics = [menu addItemWithTitle:NSLocalizedString(@"Show Bounding Box", @"Show Bounding Box")
                                          action:@selector(toggleShowMetrics:)
                                   keyEquivalent:@"4"];
    metrics.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    if (!includeZoom) {
        menu.delegate = self;
        [self addViewAlignmentItemsToMenu:menu];
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
    NSMenuItem *actualSize = [menu addItemWithTitle:NSLocalizedString(@"Actual Size", @"Actual Size")
                                             action:@selector(resetZoom:)
                                      keyEquivalent:@"0"];
    actualSize.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    [self addViewAlignmentItemsToMenu:menu];
    return menu;
}

- (void)addViewAlignmentItemsToMenu:(NSMenu *)menu {
    NSMenuItem *contextual = [menu
        addItemWithTitle:NSLocalizedString(@"Contextual Alternates", @"Contextual Alternates")
                  action:@selector(toggleContextualAlternates:)
           keyEquivalent:@"5"];
    contextual.target = self;
    NSMenuItem *ligatures = [menu
        addItemWithTitle:NSLocalizedString(@"Ligatures", @"Ligatures")
                  action:@selector(toggleLigatures:)
           keyEquivalent:@"6"];
    ligatures.target = self;
    NSMenuItem *verticalItem = [menu
        addItemWithTitle:NSLocalizedString(@"Vertical", @"Vertical")
                  action:@selector(toggleWritingDirection:)
           keyEquivalent:@"7"];
    verticalItem.target = self;

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
    // Application-level commands do not require an open font window.
    if (action == @selector(showHelp:) ||
        action == @selector(openFont:) || action == @selector(openRecentFont:) ||
        action == @selector(clearRecentFonts:)) {
        return YES;
    }
    GAMainWindowController *controller = [self activeMainWindowController];
    if (controller == nil) {
        return NO;
    }
    if (action == @selector(copyToFontBook:)) {
        return controller.fontURL != nil;
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
