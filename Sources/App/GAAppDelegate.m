#import "GAAppDelegate.h"
#import "GAMainWindowController.h"
#import "Font/GAFontResource.h"
#import "Font/GAFontFeatures.h"
#import "Input/GAInput.h"
#include <math.h>
#include <sys/stat.h>

static NSString *const GARecentFontPathsKey = @"GAPersistentRecentFontPaths";
static NSString *const GASavedTextsKey = @"GASavedTexts";
static NSString *const GASavedPalettesKey = @"GASavedPalettes";

static const GAPreviewColorRole GAPaletteRoles[] = {
    GAPreviewColorGlyph, GAPreviewColorBoundingBox, GAPreviewColorBackground,
};
enum { GAPaletteRoleCount = sizeof(GAPaletteRoles) / sizeof(*GAPaletteRoles) };

static NSString *GAPaletteRoleTitle(GAPreviewColorRole role) {
    switch (role) {
        case GAPreviewColorGlyph: return NSLocalizedString(@"Glyph…", @"Choose preview glyph color");
        case GAPreviewColorBoundingBox: return NSLocalizedString(@"Bounding Box…", @"Choose shadow color");
        case GAPreviewColorBackground: return NSLocalizedString(@"Background…", @"Choose preview background color");
    }
}

static void GAFillPaletteSwatch(GAPreviewColors *palette, GAPreviewColorRole role, NSRect swatch) {
    if (role == GAPreviewColorBoundingBox) {
        [[palette colorForRole:GAPreviewColorBackground] setFill];
        NSRectFill(swatch);
    }
    [[palette colorForRole:role] setFill];
    NSRectFillUsingOperation(swatch, NSCompositingOperationSourceOver);
}

static NSImage *GAPaletteSwatchImage(GAPreviewColors *palette, NSAppearance *appearance) {
    NSAppearance *light = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    const CGFloat swatchWidth = 15;
    const CGFloat swatchSpacing = 3;
    NSSize size = NSMakeSize(GAPaletteRoleCount * swatchWidth + (GAPaletteRoleCount - 1) * swatchSpacing, 12);
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [appearance performAsCurrentDrawingAppearance:^{
            CGFloat x = NSMinX(rect);
            for (NSUInteger i = 0; i < GAPaletteRoleCount; i++) {
                GAPreviewColorRole role = GAPaletteRoles[i];
                NSRect swatch = NSMakeRect(x, NSMinY(rect), swatchWidth, NSHeight(rect));
                BOOL usesSystemBackground = role == GAPreviewColorBoundingBox &&
                    [palette followsSystemForRole:GAPreviewColorBackground];
                if ([palette followsSystemForRole:role] || usesSystemBackground) {
                    [light performAsCurrentDrawingAppearance:^{ GAFillPaletteSwatch(palette, role, swatch); }];
                    [NSGraphicsContext saveGraphicsState];
                    NSBezierPath *darkHalf = [NSBezierPath bezierPath];
                    [darkHalf moveToPoint:NSMakePoint(NSMinX(swatch), NSMinY(swatch))];
                    [darkHalf lineToPoint:NSMakePoint(NSMaxX(swatch), NSMinY(swatch))];
                    [darkHalf lineToPoint:NSMakePoint(NSMaxX(swatch), NSMaxY(swatch))];
                    [darkHalf closePath];
                    [darkHalf addClip];
                    [dark performAsCurrentDrawingAppearance:^{ GAFillPaletteSwatch(palette, role, swatch); }];
                    [NSGraphicsContext restoreGraphicsState];
                } else {
                    GAFillPaletteSwatch(palette, role, swatch);
                }
                [NSColor.separatorColor set];
                NSFrameRectWithWidth(swatch, 0.5);
                x += swatchWidth + swatchSpacing;
            }
        }];
        return YES;
    }];
}

typedef NS_ENUM(NSInteger, GAFontFolder) {
    GAFontFolderCurrentUser,
    GAFontFolderAllUsers,
    GAFontFolderSystem,
};

static NSURL *GAFontFolderURL(GAFontFolder folder) {
    switch (folder) {
        case GAFontFolderCurrentUser:
            return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Fonts"] isDirectory:YES];
        case GAFontFolderAllUsers:
            return [NSURL fileURLWithPath:@"/Library/Fonts" isDirectory:YES];
        case GAFontFolderSystem:
            return [NSURL fileURLWithPath:@"/System/Library/Fonts" isDirectory:YES];
    }
}

@interface GASavedItemsMenu : NSMenu
@property(nonatomic, weak) GAMainWindowController *controller;
@property(nonatomic, readonly) BOOL paletteMenu;
@property(nonatomic, readonly) BOOL deleting;
- (instancetype)initWithTitle:(NSString *)title paletteMenu:(BOOL)paletteMenu deleting:(BOOL)deleting;
- (NSString *)defaultsKey;
- (NSMenuItem *)addSavedItemWithTitle:(NSString *)title value:(id)value target:(id)target;
@end

@implementation GASavedItemsMenu

- (instancetype)initWithTitle:(NSString *)title paletteMenu:(BOOL)paletteMenu deleting:(BOOL)deleting {
    self = [super initWithTitle:title];
    if (self) {
        _paletteMenu = paletteMenu;
        _deleting = deleting;
        self.autoenablesItems = NO;
    }
    return self;
}

- (NSString *)defaultsKey {
    return self.paletteMenu ? GASavedPalettesKey : GASavedTextsKey;
}

- (NSMenuItem *)addSavedItemWithTitle:(NSString *)title value:(id)value target:(id)target {
    SEL action = self.deleting ? @selector(deleteSavedItem:)
        : (self.paletteMenu ? @selector(useSavedPalette:) : @selector(useSavedText:));
    NSMenuItem *item = [self addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.representedObject = value;
    item.enabled = self.deleting || self.controller.fontURL != nil;
    return item;
}
@end

@interface GAContextViewMenu : NSMenu
@property(nonatomic, weak) NSView *contextView;
@end
@implementation GAContextViewMenu
@end

@interface GAFontFeaturesMenu : NSMenu
@property(nonatomic, weak) GAMainWindowController *controller;
@end
@implementation GAFontFeaturesMenu
@end

@interface GAGlyphFeatureFilterMenu : NSMenu
@property(nonatomic, weak) GAMainWindowController *controller;
@end
@implementation GAGlyphFeatureFilterMenu
@end

@interface GALoclLanguageMenu : NSMenu
@property(nonatomic, weak) GAMainWindowController *controller;
@end
@implementation GALoclLanguageMenu
@end

@interface GAAppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSMutableArray<GAMainWindowController *> *windowControllers;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingFontURLs;
@property (nonatomic, strong, nullable) NSOpenPanel *openPanel;
@property (nonatomic, strong, nullable) NSURL *pendingOpenPanelDirectory;
@property (nonatomic, strong, nullable) NSMenu *recentMenu;
@property(nonatomic, strong) NSMenu *editMenu;
@property(nonatomic, strong) NSMenu *viewMenu;
@property(nonatomic, strong) NSMenuItem *savedTextItem;
@property(nonatomic, strong) NSMenuItem *deleteSavedTextItem;
@property(nonatomic, strong) NSMenuItem *colorsItem;
@property(nonatomic, strong) NSMenuItem *deletePalettesItem;
@property(nonatomic, weak, nullable) NSMenu *trackedSavedItemsRootMenu;
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
    [self restoreSystemRecentDocuments];
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

    self.pendingOpenPanelDirectory = nil;
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
    [self showFontOpenPanelAtDirectory:nil];
}

- (void)openFontFromFolder:(NSMenuItem *)sender {
    [self showFontOpenPanelAtDirectory:GAFontFolderURL(sender.tag)];
}

- (void)showFontOpenPanelAtDirectory:(NSURL *)directory {
    if (self.openPanel != nil) {
        if (directory) {
            // Set the requested location on a fresh panel before presenting it.
            BOOL alreadyClosing = self.pendingOpenPanelDirectory != nil;
            self.pendingOpenPanelDirectory = directory;
            if (!alreadyClosing) [self.openPanel cancel:nil];
            return;
        }
        [NSApp activateIgnoringOtherApps:YES];
        [self.openPanel makeKeyAndOrderFront:nil];
        return;
    }
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = GAFontContentTypes();
    if (directory) panel.directoryURL = directory;
    self.openPanel = panel;

    [NSApp activateIgnoringOtherApps:YES];
    __weak typeof(self) weakSelf = self;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        __strong typeof(weakSelf) self = weakSelf;
        NSURL *nextDirectory = self.pendingOpenPanelDirectory;
        self.pendingOpenPanelDirectory = nil;
        self.openPanel = nil;
        if (result != NSModalResponseOK) {
            if (nextDirectory) [self showFontOpenPanelAtDirectory:nextDirectory];
            return;
        }
        for (NSURL *url in [panel.URLs copy]) {
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
    [NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
    [self rebuildRecentMenu];
}

- (NSArray<NSURL *> *)recentFontURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *path in [self.preferences arrayForKey:GARecentFontPathsKey]) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if (url.isFileURL &&
            [[NSFileManager defaultManager] fileExistsAtPath:url.path] &&
            GAFontURLIsFont(url)) {
            [urls addObject:url];
        }
    }
    return urls;
}

/// Called once after launch; opening a menu never writes recent documents.
- (void)restoreSystemRecentDocuments {
    NSDocumentController *documents = NSDocumentController.sharedDocumentController;
    [documents clearRecentDocuments:nil];
    for (NSURL *url in [self recentFontURLs].reverseObjectEnumerator)
        [documents noteNewRecentDocumentURL:url];
}

- (void)rebuildRecentMenu {
    NSArray<NSURL *> *urls = [self recentFontURLs];
    NSMenu *menu = self.recentMenu;
    if (menu == nil) return;
    [menu removeAllItems];

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
    [NSDocumentController.sharedDocumentController clearRecentDocuments:sender];
    [self rebuildRecentMenu];
}

#pragma mark - Saved text

- (NSMenuItem *)savedTextMenuItemForWindow:(NSWindow *)window {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Saved Text", @"Saved text submenu")
                                               action:nil keyEquivalent:@""];
    GASavedItemsMenu *menu = [[GASavedItemsMenu alloc] initWithTitle:item.title paletteMenu:NO deleting:NO];
    menu.delegate = self;
    menu.controller = window ? (GAMainWindowController *)window.windowController : self.activeMainWindowController;
    [self rebuildSavedTextMenu:menu];
    item.submenu = menu;
    return item;
}

- (NSString *)previewForSavedText:(NSString *)text {
    NSMutableString *label = [text mutableCopy];
    NSCharacterSet *breaks = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger end = text.length; end > 0;) {
        NSRange range = [text rangeOfCharacterFromSet:breaks options:NSBackwardsSearch
                                              range:NSMakeRange(0, end)];
        if (range.location == NSNotFound) break;
        end = range.location;
        unichar character = [text characterAtIndex:end];
        unichar marker = character == '\t' ? 0x21E5 : GAInputSeparatorMarker(character);
        if (marker) [label replaceCharactersInRange:range withString:[NSString stringWithFormat:@" %C ", marker]];
    }
    NSString *preview = label;
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
        preview = [preview stringByReplacingOccurrencesOfString:@" " withString:@"␠"];
    if (preview.length > 48) {
        NSRange range = [preview rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 48)];
        preview = [[preview substringWithRange:range] stringByAppendingString:@"…"];
    }
    return preview;
}

- (void)rebuildSavedTextMenu:(GASavedItemsMenu *)menu {
    [menu removeAllItems];
    NSArray<NSString *> *texts = [self.preferences arrayForKey:GASavedTextsKey];
    NSString *current = menu.controller.inputText;
    BOOL canSave = menu.controller.fontURL && current.length && ![texts containsObject:current];
    NSMenuItem *command = nil;
    if (menu.deleting ? texts.count > 0 : canSave) {
        NSString *title = menu.deleting
            ? NSLocalizedString(@"Clear All Saved Text", @"Delete every saved text")
            : NSLocalizedString(@"Save Current Text", @"Save whole sidebar input as plain text");
        SEL action = menu.deleting ? @selector(clearSavedItems:) : @selector(saveCurrentText:);
        command = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        command.target = self;
    }
    if (command && canSave) {
        [menu addItem:command];
        [menu addItem:NSMenuItem.separatorItem];
    }
    if (!texts.count) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Saved Text", @"Empty saved text list")
                                          action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }
    for (NSString *text in texts) {
        [menu addSavedItemWithTitle:[self previewForSavedText:text] value:text target:self];
    }
    if (command && !canSave) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:command];
    }
}

- (void)saveCurrentText:(NSMenuItem *)sender {
    GAMainWindowController *controller = ((GASavedItemsMenu *)sender.menu).controller;
    NSString *text = controller.inputText;
    if (!controller.fontURL || !text.length) return;
    NSMutableArray *texts = [[self.preferences arrayForKey:GASavedTextsKey] mutableCopy]
        ?: [NSMutableArray array];
    if ([texts containsObject:text]) return;
    [texts insertObject:text atIndex:0];
    [self.preferences setObject:texts forKey:GASavedTextsKey];
}

- (void)useSavedText:(NSMenuItem *)sender {
    [((GASavedItemsMenu *)sender.menu).controller replaceInputText:sender.representedObject];
}

- (void)deleteSavedItem:(NSMenuItem *)sender {
    NSString *key = [(GASavedItemsMenu *)sender.menu defaultsKey];
    NSMutableArray *items = [[self.preferences arrayForKey:key] mutableCopy];
    [items removeObject:sender.representedObject];
    [self.preferences setObject:items forKey:key];
}

- (void)clearSavedItems:(NSMenuItem *)sender {
    [self.preferences setObject:@[] forKey:[(GASavedItemsMenu *)sender.menu defaultsKey]];
}

#pragma mark - Menu delegate

- (NSMenuItem *)addDeleteAlternateToMenu:(NSMenu *)root forItem:(NSMenuItem *)apply {
    GASavedItemsMenu *applyMenu = (GASavedItemsMenu *)apply.submenu;
    NSString *title = applyMenu.paletteMenu
        ? NSLocalizedString(@"Delete Palettes", @"Delete saved palettes submenu")
        : NSLocalizedString(@"Delete Saved Text", @"Delete saved text submenu");
    NSMenuItem *alternate = [root addItemWithTitle:title action:nil keyEquivalent:@""];
    alternate.alternate = YES;
    alternate.keyEquivalentModifierMask = NSEventModifierFlagOption;
    GASavedItemsMenu *deleteMenu = [[GASavedItemsMenu alloc] initWithTitle:title
                                                            paletteMenu:applyMenu.paletteMenu deleting:YES];
    deleteMenu.delegate = self;
    deleteMenu.controller = applyMenu.controller;
    alternate.submenu = deleteMenu;
    [self rebuildSavedItemsMenu:deleteMenu];
    return alternate;
}

- (void)rebuildSavedItemsMenu:(GASavedItemsMenu *)menu {
    if (menu.paletteMenu) [self rebuildColorMenu:menu];
    else [self rebuildSavedTextMenu:menu];
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.editMenu || menu == self.viewMenu) self.trackedSavedItemsRootMenu = menu;
}

- (void)menuDidClose:(NSMenu *)menu {
    if (menu == self.trackedSavedItemsRootMenu) self.trackedSavedItemsRootMenu = nil;
}

- (void)bindSavedItemsInRoot:(NSMenu *)root controller:(GAMainWindowController *)controller {
    if (root == self.trackedSavedItemsRootMenu) return;
    BOOL isEditMenu = root == self.editMenu;
    NSMenuItem *apply = isEditMenu ? self.savedTextItem : self.colorsItem;
    NSMenuItem *alternate = isEditMenu ? self.deleteSavedTextItem : self.deletePalettesItem;
    ((GASavedItemsMenu *)apply.submenu).controller = controller;
    ((GASavedItemsMenu *)alternate.submenu).controller = controller;
    apply.enabled = controller.fontURL != nil;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.editMenu) {
        // Keep both native alternatives bound to the window that opened the menu.
        [self bindSavedItemsInRoot:menu controller:self.activeMainWindowController];
        return;
    }
    if ([menu isKindOfClass:GASavedItemsMenu.class]) {
        [self rebuildSavedItemsMenu:(GASavedItemsMenu *)menu];
        return;
    }
    if (menu == self.recentMenu) {
        [self rebuildRecentMenu];
        return;
    }
    if ([menu isKindOfClass:GAFontFeaturesMenu.class]) {
        [self rebuildFontFeaturesMenu:(GAFontFeaturesMenu *)menu];
        return;
    }
    if ([menu isKindOfClass:GAGlyphFeatureFilterMenu.class]) {
        [self rebuildGlyphFeatureFilterMenu:(GAGlyphFeatureFilterMenu *)menu];
        return;
    }
    if ([menu isKindOfClass:GALoclLanguageMenu.class]) {
        [self rebuildLoclLanguageMenu:(GALoclLanguageMenu *)menu];
        return;
    }
    if (menu == self.viewMenu) {
        GAMainWindowController *controller = self.activeMainWindowController;
        [self bindSavedItemsInRoot:menu controller:controller];
        BOOL textLayoutAvailable = controller && GAViewModeSupportsTextLayout(controller.viewMode);
        for (NSMenuItem *item in menu.itemArray) {
            if (item.action == @selector(toggleWritingDirection:) ||
                [item.identifier isEqualToString:@"TextAlignment"] ||
                [item.identifier isEqualToString:@"WritingDirection"] ||
                [item.identifier isEqualToString:@"TypesettingLanguage"] ||
                [item.identifier isEqualToString:@"FontFeatures"] ||
                [item.identifier isEqualToString:@"TextDecorations"]) {
                item.enabled = textLayoutAvailable;
            }
            if ([item.identifier isEqualToString:@"WritingDirection"])
                item.hidden = !controller.hasRightToLeftLanguages;
            if ([item.identifier isEqualToString:@"GlyphFeatureFilter"]) {
                BOOL allGlyphs = controller && controller.viewMode == GAViewModeAllGlyphs;
                item.enabled = allGlyphs && controller.fontURL != nil;
            }
        }
        return;
    }
    // Re-evaluate context View menus on every open;
    // the same menu is shared by the three views.
    GAMainWindowController *controller = [self controllerForViewMenu:menu];
    GAViewMode mode = controller.viewMode;
    for (NSMenuItem *item in menu.itemArray) {
        BOOL textOnly = [item.identifier isEqualToString:@"FontFeatures"] ||
                        item.action == @selector(toggleWritingDirection:) ||
                        [item.identifier isEqualToString:@"TextAlignment"];
        item.hidden =
            (textOnly && !GAViewModeSupportsTextLayout(mode)) ||
            (item.action == @selector(toggleShowMetrics:) && !GAViewModeSupportsMetrics(mode));
        if ([item.identifier isEqualToString:@"GlyphFeatureFilter"]) {
            item.hidden = !controller || mode != GAViewModeAllGlyphs;
            item.enabled = !item.hidden && controller.fontURL != nil;
        }
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

    NSString *openFromTitle = NSLocalizedString(@"Open Font From", @"Open font folder submenu");
    NSMenuItem *openFrom = [fileMenu addItemWithTitle:openFromTitle action:nil keyEquivalent:@""];
    NSMenu *fontFolders = [[NSMenu alloc] initWithTitle:openFromTitle];
    openFrom.submenu = fontFolders;

    NSMenuItem *recentFolders = [fontFolders
        addItemWithTitle:NSLocalizedString(@"Recent Folders", @"Open panel at its recent folder")
                  action:@selector(openFont:) keyEquivalent:@"o"];
    recentFolders.target = self;
    NSMenuItem *shortcut = [recentFolders copy];
    shortcut.keyEquivalent = @"n";
    shortcut.hidden = YES;
    shortcut.allowsKeyEquivalentWhenHidden = YES;
    [fontFolders addItem:shortcut];

    NSArray<NSString *> *folderTitles = @[
        NSLocalizedString(@"Current User…", @"Open the current user's Fonts folder"),
        NSLocalizedString(@"All Users…", @"Open the shared Fonts folder"),
        NSLocalizedString(@"System Fonts…", @"Open the macOS system Fonts folder"),
    ];
    for (GAFontFolder folder = GAFontFolderCurrentUser; folder <= GAFontFolderSystem; folder++) {
        NSMenuItem *item = [fontFolders addItemWithTitle:folderTitles[folder]
            action:@selector(openFontFromFolder:) keyEquivalent:@""];
        item.target = self;
        item.tag = folder;
    }

    NSString *recentTitle = NSLocalizedString(@"Open Recent", @"Open Recent");
    NSMenuItem *recentItem = [fileMenu addItemWithTitle:recentTitle
                                                 action:nil
                                          keyEquivalent:@""];
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:recentTitle];
    recentMenu.delegate = self;
    recentItem.submenu = recentMenu;
    self.recentMenu = recentMenu;
    [self rebuildRecentMenu];

    NSMenuItem *copyToFontBook = [fileMenu
        addItemWithTitle:NSLocalizedString(@"Copy to Font Book", @"Copy to Font Book")
                  action:@selector(copyToFontBook:)
           keyEquivalent:@""];
    copyToFontBook.target = self;
    NSMenuItem *copyToAllUsers = [fileMenu
        addItemWithTitle:NSLocalizedString(@"Copy to All Users", @"Copy font to the shared Fonts folder")
                  action:@selector(copyToFontBook:)
           keyEquivalent:@""];
    copyToAllUsers.target = self;
    copyToAllUsers.tag = GAFontFolderAllUsers;
    copyToAllUsers.alternate = YES;
    copyToAllUsers.keyEquivalentModifierMask = NSEventModifierFlagOption;

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

    self.savedTextItem = [self savedTextMenuItemForWindow:nil];
    [editMenu addItem:self.savedTextItem];
    self.deleteSavedTextItem = [self addDeleteAlternateToMenu:editMenu forItem:self.savedTextItem];

    // View
    NSMenuItem *viewItem = [mainMenu addItemWithTitle:NSLocalizedString(@"View", @"View")
                                               action:nil
                                        keyEquivalent:@""];
    self.viewMenu = [self buildViewMenuIncludingZoom:YES];
    self.viewMenu.delegate = self;
    viewItem.submenu = self.viewMenu;

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

- (NSString *)accessibilityDescriptionForPalette:(GAPreviewColors *)palette appearance:(NSAppearance *)appearance {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:GAPaletteRoleCount];
    NSCharacterSet *ellipsis = [NSCharacterSet characterSetWithCharactersInString:@"…"];
    NSString *labelFormat = NSLocalizedString(@"%@: %@", @"Accessible palette color role and value");
    [appearance performAsCurrentDrawingAppearance:^{
        for (NSUInteger i = 0; i < GAPaletteRoleCount; i++) {
            GAPreviewColorRole role = GAPaletteRoles[i];
            NSString *title = [GAPaletteRoleTitle(role) stringByTrimmingCharactersInSet:ellipsis];
            if ([palette followsSystemForRole:role]) {
                [lines addObject:[NSString stringWithFormat:labelFormat, title,
                    NSLocalizedString(@"Follow System", @"Restore all preview colors")]];
                continue;
            }
            NSColor *color = [[palette colorForRole:role] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!color) {
                [lines addObject:title];
                continue;
            }
            NSString *hex = [NSString stringWithFormat:@"#%02lX%02lX%02lX",
                (unsigned long)lround(color.redComponent * 255),
                (unsigned long)lround(color.greenComponent * 255),
                (unsigned long)lround(color.blueComponent * 255)];
            if (role == GAPreviewColorBoundingBox)
                hex = [NSString stringWithFormat:NSLocalizedString(@"%@ (%.0f%%)", @"Accessible palette shadow color and opacity"),
                    hex, color.alphaComponent * 100];
            [lines addObject:[NSString stringWithFormat:labelFormat, title, hex]];
        }
    }];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)rebuildColorMenu:(GASavedItemsMenu *)menu {
    [menu removeAllItems];
    NSArray *saved = [self.preferences arrayForKey:GASavedPalettesKey];
    GAPreviewColors *current = menu.controller.previewColors;
    BOOL hasFont = menu.controller.fontURL != nil;
    NSAppearance *appearance = menu.controller.window.effectiveAppearance ?: NSApp.effectiveAppearance;
    if (menu.deleting) {
        menu.showsStateColumn = NO;
        NSString *title = saved.count
            ? NSLocalizedString(@"Clear All Saved Palettes", @"Delete every saved palette")
            : NSLocalizedString(@"No Saved Palettes", @"Empty saved palettes list");
        NSMenuItem *command = [menu addItemWithTitle:title
            action:saved.count ? @selector(clearSavedItems:) : NULL keyEquivalent:@""];
        command.target = self;
        command.enabled = saved.count > 0;
    } else {
        NSMenuItem *command = [menu addItemWithTitle:NSLocalizedString(@"Follow System", @"Restore all preview colors")
            action:@selector(followSystemColors:) keyEquivalent:@""];
        command.target = self;
        command.enabled = hasFont;
        command.state = current.systemState;
    }
    BOOL currentIsSaved = NO;
    for (NSDictionary *entry in saved) {
        GAPreviewColors *palette = [[GAPreviewColors alloc] initWithRepresentation:entry];
        BOOL matches = !menu.deleting && [current matchesColors:palette];
        currentIsSaved |= matches;
        NSMenuItem *item = [menu addSavedItemWithTitle:@"" value:entry target:self];
        if (matches) item.state = NSControlStateValueOn;
        item.image = GAPaletteSwatchImage(palette, appearance);
        item.image.accessibilityDescription = [self accessibilityDescriptionForPalette:palette appearance:appearance];
    }
    if (menu.deleting) return;
    if (hasFont && current.systemState != NSControlStateValueOn && !currentIsSaved) {
        NSMenuItem *save = [menu addItemWithTitle:NSLocalizedString(@"Save Current Palette", @"Save the three current preview colors")
            action:@selector(saveCurrentPalette:) keyEquivalent:@""];
        save.target = self;
    }
    [menu addItem:NSMenuItem.separatorItem];
    for (NSUInteger i = 0; i < GAPaletteRoleCount; i++) {
        GAPreviewColorRole role = GAPaletteRoles[i];
        NSMenuItem *item = [menu addItemWithTitle:GAPaletteRoleTitle(role)
            action:@selector(choosePreviewColor:) keyEquivalent:@""];
        item.target = self;
        item.tag = role;
        item.enabled = hasFont;
    }
}

- (NSMenu *)buildViewMenuIncludingZoom:(BOOL)includeZoom {
    NSMenu *menu = [[(includeZoom ? NSMenu.class : GAContextViewMenu.class) alloc]
        initWithTitle:NSLocalizedString(@"View", @"View")];
    // Menu order is also the shortcut order: Single ⌘1, Multi ⌘2, All ⌘3.
    NSArray<NSString *> *modeTitles = @[NSLocalizedString(@"Single Glyph", @"Single Glyph"), NSLocalizedString(@"Multi-Character", @"Multi-Character"), NSLocalizedString(@"All Glyphs", @"All Glyphs")];
    NSArray<NSNumber *> *modeTags = @[@(GAViewModeSingleGlyph),
                                      @(GAViewModeMultiCharacter),
                                      @(GAViewModeAllGlyphs)];
    NSArray<NSString *> *modeKeys = @[@"1", @"2", @"3"];
    for (NSUInteger index = 0; index < modeTitles.count; index++) {
        NSMenuItem *item = [menu addItemWithTitle:modeTitles[index]
                                           action:@selector(switchViewMode:)
                                    keyEquivalent:modeKeys[index]];
        item.target = self;
        item.tag = modeTags[index].integerValue;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    if (!includeZoom) {
        [self addGlyphFeatureFilterToMenu:menu];
        [menu addItem:NSMenuItem.separatorItem];
    }

    NSMenuItem *metrics = [menu addItemWithTitle:NSLocalizedString(@"Show Bounding Box", @"Show Bounding Box")
                                          action:@selector(toggleShowMetrics:)
                                   keyEquivalent:@"4"];
    metrics.target = self;
    if (includeZoom) {
        NSString *title = NSLocalizedString(@"Colors", @"Preview colors");
        self.colorsItem = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
        GASavedItemsMenu *colors = [[GASavedItemsMenu alloc] initWithTitle:title paletteMenu:YES deleting:NO];
        colors.delegate = self;
        [self rebuildColorMenu:colors];
        self.colorsItem.submenu = colors;
        self.deletePalettesItem = [self addDeleteAlternateToMenu:menu forItem:self.colorsItem];
    }
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
    NSMenuItem *spacingIn = [menu addItemWithTitle:NSLocalizedString(@"Increase Line Spacing", @"Increase preview line spacing")
        action:@selector(increaseLineSpacing:) keyEquivalent:@"+"];
    spacingIn.target = self;
    spacingIn.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
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
    NSMenuItem *spacingOut = [menu addItemWithTitle:NSLocalizedString(@"Decrease Line Spacing", @"Decrease preview line spacing")
        action:@selector(decreaseLineSpacing:) keyEquivalent:@"-"];
    spacingOut.target = self;
    spacingOut.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    spacingOut.alternate = YES;
    NSMenuItem *defaultSize = [menu addItemWithTitle:NSLocalizedString(@"Default Size", @"Reset the current view to its default size")
                                             action:@selector(resetZoom:)
                                      keyEquivalent:@"0"];
    defaultSize.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    [self addViewAlignmentItemsToMenu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *opening = [menu addItemWithTitle:NSLocalizedString(@"Use as Defaults", @"Save a snapshot for future font windows")
        action:@selector(saveOpeningSettings:) keyEquivalent:@""];
    opening.target = self;
    NSMenuItem *restoreOpening = [menu addItemWithTitle:NSLocalizedString(@"Restore to Defaults", @"Restore factory settings for future font windows")
        action:@selector(restoreOpeningSettings:) keyEquivalent:@""];
    restoreOpening.target = self;
    restoreOpening.alternate = YES;
    restoreOpening.keyEquivalentModifierMask = NSEventModifierFlagOption;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *fullScreen = [menu addItemWithTitle:NSLocalizedString(@"Enter Full Screen", @"Enter full screen")
        action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fullScreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    return menu;
}

- (void)addViewAlignmentItemsToMenu:(NSMenu *)menu {
    NSMenuItem *verticalItem = [menu
        addItemWithTitle:NSLocalizedString(@"Vertical", @"Vertical")
                  action:@selector(toggleWritingDirection:)
           keyEquivalent:@"5"];
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
    for (NSUInteger index = 0; index < alignmentTitles.count; index++) {
        NSMenuItem *item = [alignmentMenu addItemWithTitle:alignmentTitles[index]
                                                    action:@selector(setTextAlignment:)
                                             keyEquivalent:@""];
        item.target = self;
        item.tag = alignmentTags[index].integerValue;
    }
    alignmentItem.identifier = @"TextAlignment";
    alignmentItem.submenu = alignmentMenu;
    BOOL isMainViewMenu = ![menu isKindOfClass:GAContextViewMenu.class];
    if (isMainViewMenu) {
        NSMenuItem *direction = [menu addItemWithTitle:NSLocalizedString(@"Writing Direction", @"Paragraph writing direction")
            action:nil keyEquivalent:@""];
        direction.identifier = @"WritingDirection";
        direction.hidden = YES;
        NSMenu *directions = [[NSMenu alloc] initWithTitle:direction.title];
        direction.submenu = directions;
        NSArray *titles = @[NSLocalizedString(@"Default", @"Default"),
            NSLocalizedString(@"Left to Right", @"Paragraph writing direction"),
            NSLocalizedString(@"Right to Left", @"Paragraph writing direction")];
        NSArray *values = @[@(NSWritingDirectionNatural), @(NSWritingDirectionLeftToRight),
            @(NSWritingDirectionRightToLeft)];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSMenuItem *item = [directions addItemWithTitle:titles[i]
                action:@selector(setBaseWritingDirection:) keyEquivalent:@""];
            item.target = self;
            item.tag = [values[i] integerValue];
        }
        NSMenuItem *language = [menu addItemWithTitle:NSLocalizedString(@"Typesetting Language", @"OpenType localized language systems")
            action:nil keyEquivalent:@""];
        language.identifier = @"TypesettingLanguage";
        GALoclLanguageMenu *languages = [[GALoclLanguageMenu alloc] initWithTitle:language.title];
        languages.delegate = self;
        language.submenu = languages;
        [self rebuildLoclLanguageMenu:languages];
    }
    NSMenuItem *features = [menu addItemWithTitle:NSLocalizedString(@"Typography", @"Native font features") action:nil keyEquivalent:@""];
    features.identifier = @"FontFeatures";
    GAFontFeaturesMenu *featureMenu = [[GAFontFeaturesMenu alloc] initWithTitle:features.title];
    featureMenu.delegate = self;
    features.submenu = featureMenu;
    [self rebuildFontFeaturesMenu:featureMenu];
    if (isMainViewMenu) {
        NSMenuItem *decorations = [menu addItemWithTitle:NSLocalizedString(@"Text Decorations", @"Preview text decoration submenu")
            action:nil keyEquivalent:@""];
        decorations.identifier = @"TextDecorations";
        NSMenu *decorationMenu = [[NSMenu alloc] initWithTitle:decorations.title];
        decorations.submenu = decorationMenu;
        NSMenuItem *underline = [decorationMenu addItemWithTitle:NSLocalizedString(@"Underline", @"Text decoration")
            action:@selector(togglePreviewUnderline:) keyEquivalent:@"u"];
        underline.target = self;
        NSMenuItem *strike = [decorationMenu addItemWithTitle:NSLocalizedString(@"Strikethrough", @"Text decoration")
            action:@selector(togglePreviewStrikethrough:) keyEquivalent:@"l"];
        strike.target = self;
        NSMenuItem *outline = [decorationMenu addItemWithTitle:NSLocalizedString(@"Outline", @"Outline text to inspect glyph contours")
            action:@selector(togglePreviewOutline:) keyEquivalent:@"y"];
        outline.target = self;
        [menu addItem:NSMenuItem.separatorItem];
        [self addGlyphFeatureFilterToMenu:menu];
    }
}

- (void)addGlyphFeatureFilterToMenu:(NSMenu *)menu {
    NSString *title = NSLocalizedString(@"Filter by Feature", @"All Glyphs feature output filter");
    NSMenuItem *item = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    item.identifier = @"GlyphFeatureFilter";
    GAGlyphFeatureFilterMenu *choices = [[GAGlyphFeatureFilterMenu alloc] initWithTitle:title];
    choices.delegate = self;
    choices.autoenablesItems = NO;
    item.submenu = choices;
}

- (void)rebuildGlyphFeatureFilterMenu:(GAGlyphFeatureFilterMenu *)menu {
    GAMainWindowController *controller = [self controllerForViewMenu:menu];
    menu.controller = controller;
    [menu removeAllItems];
    if (!controller.fontURL || controller.viewMode != GAViewModeAllGlyphs)
        return;
    NSArray<NSString *> *tags = controller.allGlyphFeatureTags;
    if (!tags.count) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Features to Filter", @"Empty glyph filter menu")
            action:nil keyEquivalent:@""];
        empty.enabled = NO;
        return;
    }
    NSMenuItem *all = [menu addItemWithTitle:NSLocalizedString(@"All Glyphs", @"All Glyphs")
                                    action:@selector(chooseGlyphFeatureFilter:) keyEquivalent:@""];
    all.target = self;
    all.state = controller.allGlyphFeatureTag ? NSControlStateValueOff : NSControlStateValueOn;
    NSMenuItem *unfeatured = [menu addItemWithTitle:NSLocalizedString(@"No Feature", @"Glyphs outside feature outputs")
                                           action:@selector(chooseGlyphFeatureFilter:) keyEquivalent:@""];
    unfeatured.target = self;
    unfeatured.representedObject = @"";
    unfeatured.state = [controller.allGlyphFeatureTag isEqualToString:@""]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:NSMenuItem.separatorItem];
    for (NSString *tag in tags) {
        NSMenuItem *item = [menu addItemWithTitle:tag action:@selector(chooseGlyphFeatureFilter:)
                                  keyEquivalent:@""];
        item.target = self;
        item.representedObject = tag;
        item.state = [tag isEqualToString:controller.allGlyphFeatureTag]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)chooseGlyphFeatureFilter:(NSMenuItem *)sender {
    GAMainWindowController *controller = ((GAGlyphFeatureFilterMenu *)sender.menu).controller;
    if (controller.viewMode == GAViewModeAllGlyphs)
        [controller filterAllGlyphsByFeature:sender.representedObject];
}

- (NSString *)alignmentTitle:(NSTextAlignment)alignment vertical:(BOOL)vertical {
    switch (alignment) {
        case NSTextAlignmentLeft: return vertical ? NSLocalizedString(@"Top", @"Top") : NSLocalizedString(@"Left", @"Left");
        case NSTextAlignmentCenter: return NSLocalizedString(@"Center", @"Center");
        case NSTextAlignmentRight: return vertical ? NSLocalizedString(@"Bottom", @"Bottom") : NSLocalizedString(@"Right", @"Right");
        default: return NSLocalizedString(@"Justified", @"Justified");
    }
}

- (void)rebuildLoclLanguageMenu:(GALoclLanguageMenu *)menu {
    menu.controller = [self controllerForViewMenu:menu];
    [menu removeAllItems];
    NSArray<NSString *> *tags = menu.controller.typesettingLanguageTags;
    BOOL hasSelectableLanguage = NO;
    for (NSString *tag in tags) {
        if (GAIdentifierForOpenTypeLanguage(tag) != nil) {
            hasSelectableLanguage = YES;
            break;
        }
    }
    if (!hasSelectableLanguage) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Selectable Languages", @"No applicable typesetting language choices")
            action:nil keyEquivalent:@""];
        empty.enabled = NO;
        return;
    }
    NSMenuItem *standard = [menu addItemWithTitle:NSLocalizedString(@"Default", @"Default")
        action:@selector(setTypesettingLanguage:) keyEquivalent:@""];
    standard.target = self;
    standard.representedObject = @"";
    [menu addItem:NSMenuItem.separatorItem];
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:NSBundle.mainBundle.preferredLocalizations.firstObject];
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    for (NSString *tag in tags) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:GATitleForOpenTypeLanguage(tag, locale)
            action:@selector(setTypesettingLanguage:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = tag;
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(NSMenuItem *a, NSMenuItem *b) {
        NSComparisonResult order = [a.title compare:b.title options:NSCaseInsensitiveSearch
            range:NSMakeRange(0, a.title.length) locale:locale];
        return order == NSOrderedSame ? [a.representedObject compare:b.representedObject] : order;
    }];
    for (NSMenuItem *item in items) [menu addItem:item];
}

- (NSMenu *)viewMenuForContextInView:(NSView *)view {
    GAContextViewMenu *menu = (GAContextViewMenu *)[self buildViewMenuIncludingZoom:NO];
    menu.contextView = view;
    return menu;
}

- (GAMainWindowController *)controllerForViewMenu:(NSMenu *)menu {
    for (NSMenu *ancestor = menu; ancestor; ancestor = ancestor.supermenu) {
        if ([ancestor isKindOfClass:GAContextViewMenu.class])
            return (GAMainWindowController *)[(GAContextViewMenu *)ancestor contextView].window.windowController;
    }
    return self.activeMainWindowController;
}

#pragma mark - Active window

- (GAMainWindowController *)activeMainWindowController {
    NSWindow *keyWindow = NSApp.keyWindow;
    NSWindowController *controller = keyWindow.windowController;
    if ([controller isKindOfClass:GAMainWindowController.class]) {
        return (GAMainWindowController *)controller;
    }
    // The modeless chooser can be key while a font window remains main.
    if (self.openPanel &&
        (!keyWindow || keyWindow == self.openPanel || keyWindow.sheetParent == self.openPanel)) {
        return nil;
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
    [[self controllerForViewMenu:sender.menu] setViewMode:(GAViewMode)sender.tag];
}

- (void)toggleShowMetrics:(id)sender {
    [[self controllerForViewMenu:[sender menu]] toggleShowsMetrics];
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

- (void)increaseLineSpacing:(id)sender {
    [self.activeMainWindowController adjustLineSpacing:1];
}

- (void)decreaseLineSpacing:(id)sender {
    [self.activeMainWindowController adjustLineSpacing:-1];
}

- (void)followSystemColors:(NSMenuItem *)sender {
    [((GASavedItemsMenu *)sender.menu).controller followSystemColors];
}

- (void)saveCurrentPalette:(NSMenuItem *)sender {
    GAMainWindowController *controller = ((GASavedItemsMenu *)sender.menu).controller;
    if (!controller.fontURL) return;
    GAPreviewColors *current = controller.previewColors;
    NSDictionary *representation = current.representation;
    if (representation.count == 0) return;
    NSMutableArray *palettes = [[self.preferences arrayForKey:GASavedPalettesKey] mutableCopy]
        ?: [NSMutableArray array];
    for (NSDictionary *entry in palettes) {
        GAPreviewColors *palette = [[GAPreviewColors alloc] initWithRepresentation:entry];
        if ([current matchesColors:palette]) return;
    }
    [palettes addObject:representation];
    [self.preferences setObject:palettes forKey:GASavedPalettesKey];
}

- (void)useSavedPalette:(NSMenuItem *)sender {
    [((GASavedItemsMenu *)sender.menu).controller applyPreviewColorRepresentation:sender.representedObject];
}

- (void)choosePreviewColor:(NSMenuItem *)sender {
    self.colorOwner = ((GASavedItemsMenu *)sender.menu).controller;
    self.editingColorRole = (GAPreviewColorRole)sender.tag;
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.target = nil;
    panel.showsAlpha = self.editingColorRole == GAPreviewColorBoundingBox;
    GAPreviewColors *colors = self.colorOwner.previewColors;
    NSColor *color = [colors colorForRole:self.editingColorRole];
    if (panel.showsAlpha && [colors followsSystemForRole:self.editingColorRole]) {
        // Alpha edits on the dynamic system color produce an unarchivable color.
        [self.colorOwner.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            panel.color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        }];
    } else {
        panel.color = color;
    }
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

- (void)saveOpeningSettings:(NSMenuItem *)sender {
    [[self controllerForViewMenu:sender.menu] saveOpeningSettings];
}

- (void)restoreOpeningSettings:(id)sender {
    [GAMainWindowController restoreOpeningSettings];
}

- (void)togglePreviewUnderline:(NSMenuItem *)sender {
    GAMainWindowController *controller = [self controllerForViewMenu:sender.menu];
    [controller setUnderlined:!controller.underlined];
}

- (void)togglePreviewStrikethrough:(NSMenuItem *)sender {
    GAMainWindowController *controller = [self controllerForViewMenu:sender.menu];
    [controller setStruckThrough:!controller.struckThrough];
}

- (void)togglePreviewOutline:(NSMenuItem *)sender {
    GAMainWindowController *controller = [self controllerForViewMenu:sender.menu];
    [controller setOutlined:!controller.outlined];
}

- (void)setBaseWritingDirection:(NSMenuItem *)sender {
    [[self controllerForViewMenu:sender.menu] setBaseWritingDirection:(NSWritingDirection)sender.tag];
}

- (void)setTypesettingLanguage:(NSMenuItem *)sender {
    [((GALoclLanguageMenu *)sender.menu).controller setTypesettingLanguageTag:sender.representedObject];
}

- (void)setTextAlignment:(NSMenuItem *)sender {
    [[self controllerForViewMenu:sender.menu] setTextAlignment:(NSTextAlignment)sender.tag];
}

- (void)changeFontFeature:(NSMenuItem *)sender {
    GAMainWindowController *controller = ((GAFontFeaturesMenu *)sender.menu).controller;
    NSDictionary *choice = sender.representedObject;
    [controller.fontFeatures chooseSelector:choice[@"selector"] inGroup:choice[@"group"]];
    [controller applyFontFeatureChoices];
}

- (NSMenuItem *)addFeatureSelector:(NSDictionary *)selector group:(GAFontFeatureGroup *)group
                            title:(NSString *)title toMenu:(GAFontFeaturesMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:@selector(changeFontFeature:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @{@"group":group, @"selector":selector};
    item.state = [menu.controller.fontFeatures isSelectorSelected:selector inGroup:group]
        ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (void)rebuildFontFeaturesMenu:(GAFontFeaturesMenu *)menu {
    menu.controller = [self controllerForViewMenu:menu];
    [menu removeAllItems];
    GAFontFeatures *features = menu.controller.fontFeatures;
    if (!features.groups.count) {
        NSMenuItem *empty = [menu addItemWithTitle:NSLocalizedString(@"No Typography Features", @"Empty native feature catalogue")
            action:nil keyEquivalent:@""];
        empty.enabled = NO;
    } else {
        // Preserve the native catalogue order within radio groups and checkbox groups.
        NSMutableArray<GAFontFeatureGroup *> *grouped = [NSMutableArray array], *other = [NSMutableArray array];
        for (GAFontFeatureGroup *group in features.groups) {
            if (group.booleanChoice || (!group.exclusive && group.selectors.count == 1)) [other addObject:group];
            else if (group.exclusive) [grouped addObject:group];
        }
        for (GAFontFeatureGroup *group in features.groups)
            if (!group.exclusive && group.selectors.count > 1) [grouped addObject:group];
        for (GAFontFeatureGroup *group in grouped) {
            NSMenuItem *parent = [menu addItemWithTitle:group.name action:nil keyEquivalent:@""];
            GAFontFeaturesMenu *choices = [[GAFontFeaturesMenu alloc] initWithTitle:group.name];
            choices.controller = menu.controller;
            parent.submenu = choices;
            for (NSDictionary *selector in group.selectors)
                [self addFeatureSelector:selector group:group
                    title:selector[(__bridge NSString *)kCTFontFeatureSelectorNameKey] toMenu:choices];
        }
        if (other.count) {
            NSMenuItem *parent = [menu addItemWithTitle:NSLocalizedString(@"Other", @"Other native font features") action:nil keyEquivalent:@""];
            GAFontFeaturesMenu *choices = [[GAFontFeaturesMenu alloc] initWithTitle:parent.title];
            choices.controller = menu.controller;
            parent.submenu = choices;
            for (GAFontFeatureGroup *group in other) {
                NSDictionary *selector = group.selectors[group.booleanChoice ? 1 : 0];
                [self addFeatureSelector:selector group:group title:group.name toMenu:choices];
            }
        }
    }
}

- (void)toggleWritingDirection:(id)sender {
    GAMainWindowController *controller = [self controllerForViewMenu:[sender menu]];
    [controller setVerticalWriting:!controller.verticalWriting];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    // Application-level commands do not require an open font window.
    if (action == @selector(showHelp:) ||
        action == @selector(openFont:) || action == @selector(openFontFromFolder:) ||
        action == @selector(openRecentFont:) ||
        action == @selector(clearRecentFonts:) || action == @selector(restoreOpeningSettings:)) {
        return YES;
    }
    GAMainWindowController *controller = [self controllerForViewMenu:item.menu];
    if (controller == nil) {
        return NO;
    }
    if (action == @selector(copyToFontBook:)) {
        return controller.fontURL != nil;
    }
    if (action == @selector(increaseLineSpacing:) || action == @selector(decreaseLineSpacing:) ||
        action == @selector(zoomMetricsIn:) || action == @selector(zoomMetricsOut:))
        return GAViewModeSupportsTextLayout(controller.viewMode);
    if (action == @selector(switchViewMode:)) {
        item.state = controller.viewMode == (GAViewMode)item.tag
            ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(changeFontFeature:)) {
        GAMainWindowController *owner = ((GAFontFeaturesMenu *)item.menu).controller;
        NSDictionary *choice = item.representedObject;
        item.state = [owner.fontFeatures isSelectorSelected:choice[@"selector"] inGroup:choice[@"group"]]
            ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsTextLayout(owner.viewMode);
    }
    if (action == @selector(togglePreviewUnderline:) || action == @selector(togglePreviewStrikethrough:) ||
        action == @selector(togglePreviewOutline:)) {
        BOOL selected = action == @selector(togglePreviewUnderline:) ? controller.underlined
            : action == @selector(togglePreviewStrikethrough:) ? controller.struckThrough : controller.outlined;
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsTextLayout(controller.viewMode);
    }
    if (action == @selector(setBaseWritingDirection:)) {
        item.state = controller.baseWritingDirection == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        return controller.hasRightToLeftLanguages && GAViewModeSupportsTextLayout(controller.viewMode);
    }
    if (action == @selector(setTypesettingLanguage:)) {
        GAMainWindowController *owner = ((GALoclLanguageMenu *)item.menu).controller;
        NSString *tag = item.representedObject;
        item.state = [owner.typesettingLanguageTag isEqualToString:tag]
            ? NSControlStateValueOn : NSControlStateValueOff;
        return owner != nil && GAViewModeSupportsTextLayout(owner.viewMode) &&
            (!tag.length || GAIdentifierForOpenTypeLanguage(tag) != nil);
    }
    if (action == @selector(toggleShowMetrics:)) {
        item.state = controller.showsMetrics ? NSControlStateValueOn : NSControlStateValueOff;
        return GAViewModeSupportsMetrics(controller.viewMode);
    }
    if (action == @selector(setTextAlignment:)) {
        item.state = controller.textAlignment == (NSTextAlignment)item.tag
            ? NSControlStateValueOn : NSControlStateValueOff;
        item.title = [self alignmentTitle:item.tag vertical:controller.verticalWriting];
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

- (void)copyToFontBook:(NSMenuItem *)sender {
    GAMainWindowController *controller = self.activeMainWindowController;
    NSURL *fontURL = controller.fontURL;
    if (fontURL == nil)
        return;
    NSURL *reference = controller.fontFileReference;
    NSError *error = nil;
    NSURL *source = GAResolveFontFileReference(reference, fontURL, &error);
    if (!source) {
        [NSApp presentError:error];
        return;
    }
    GAFontFolder folder = sender.tag;
    NSURL *directory = GAFontFolderURL(folder);
    NSFileManager *files = [NSFileManager defaultManager];
    NSURLRelationship relationship;
    if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES
                         attributes:nil error:&error] ||
        ![files getRelationship:&relationship ofDirectoryAtURL:directory.URLByResolvingSymlinksInPath
                     toItemAtURL:source error:&error]) {
        [NSApp presentError:error];
        return;
    }
    if (relationship == NSURLRelationshipContains) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString localizedStringWithFormat:
            NSLocalizedString(@"“%@” is already in Font Book.", @"Font already in user Fonts folder"),
            fontURL.lastPathComponent];
        if (folder == GAFontFolderAllUsers) alert.informativeText = directory.path;
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];
        [alert beginSheetModalForWindow:controller.window completionHandler:nil];
        return;
    }
    NSURL *destination = [directory URLByAppendingPathComponent:fontURL.lastPathComponent isDirectory:NO];
    mode_t destinationType = GAFontFileItemType(destination, &error);
    if (error) {
        [NSApp presentError:error];
        return;
    }
    if (!destinationType) {
        error = GACopyFontFile(reference, fontURL, destination, NO);
        if (error) [NSApp presentError:error];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString localizedStringWithFormat:
        NSLocalizedString(@"An item named “%@” already exists in Font Book.", @"Font filename conflict"),
        fontURL.lastPathComponent];
    if (folder == GAFontFolderAllUsers) alert.informativeText = directory.path;
    BOOL canReplace = destinationType != S_IFDIR;
    if (canReplace) {
        NSButton *replace = [alert addButtonWithTitle:NSLocalizedString(@"Replace", @"Finder file conflict button")];
        replace.keyEquivalent = @"";
    }
    NSModalResponse keepBothResponse = canReplace ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn;
    NSButton *keepBoth = [alert addButtonWithTitle:NSLocalizedString(@"Keep Both", @"Finder file conflict button")];
    keepBoth.keyEquivalent = @"";
    NSButton *stop = [alert addButtonWithTitle:NSLocalizedString(@"Stop", @"Finder file conflict button")];
    stop.keyEquivalent = @"\033";
    [alert layout];
    alert.window.defaultButtonCell = stop.cell;
    [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse response) {
        BOOL replace = canReplace && response == NSAlertFirstButtonReturn;
        if (!replace && response != keepBothResponse)
            return;
        NSURL *target = destination;
        if (!replace) {
            NSError *nameError = nil;
            NSString *baseName = fontURL.lastPathComponent.stringByDeletingPathExtension;
            NSString *extension = fontURL.pathExtension;
            NSUInteger suffix = 2;
            do {
                NSString *name = [NSString stringWithFormat:@"%@ %lu", baseName, (unsigned long)suffix++];
                if (extension.length)
                    name = [name stringByAppendingPathExtension:extension];
                target = [directory URLByAppendingPathComponent:name isDirectory:NO];
            } while (GAFontFileItemType(target, &nameError));
            if (nameError) {
                [NSApp presentError:nameError];
                return;
            }
        }
        NSError *copyError = GACopyFontFile(reference, fontURL, target, replace);
        if (copyError) [NSApp presentError:copyError];
    }];
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
        NSLocalizedString(@"Help.14", @"Usage paragraph 14"),
        NSLocalizedString(@"Help.15", @"Usage paragraph 15")
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
