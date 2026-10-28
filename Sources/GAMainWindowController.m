#import "GAMainWindowController.h"
#import "GADetailViewController.h"
#import "GASidebarViewController.h"
#import "GAFontEngine.h"
#import "GATextQueryModel.h"
#import "GAUnicode.h"
#import "GAFontResource.h"
#import "GAVariationViewController.h"
#import "GAInputFocus.h"
#import <CoreText/CoreText.h>

/// A line break is layout, not a glyph: its character group is kept for text
/// ranges but hidden from the glyph list.
static BOOL GAGroupIsLineBreak(GACharacterGroup *group) {
    return group.text.length == 1 && [group.text characterAtIndex:0] == '\n';
}

/// A missing glyph is represented by GID 0. Seeds are explicit replacements
/// and keep their source text; line breaks are layout, not glyphs.
/// The caller excludes inserted ligatures and validates the source range.
static BOOL GAGroupIsMissing(GACharacterGroup *group) {
    if (group.seeded || GAGroupIsLineBreak(group)) {
        return NO;
    }
    GAGlyphVariant *base = group.variants.firstObject;
    return base.glyphIDs.count > 0 &&
           base.glyphIDs.firstObject.unsignedShortValue == 0;
}

#pragma mark - Drop window

@interface GADropWindow : NSWindow
@property (nonatomic, copy, nullable) void (^onFontDrop)(NSURL *url);
@end

@implementation GADropWindow

- (instancetype)initWithContentRect:(NSRect)contentRect
                           styleMask:(NSWindowStyleMask)style
                             backing:(NSBackingStoreType)backingStoreType
                               defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect
                            styleMask:style
                              backing:backingStoreType
                                defer:flag];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSArray<NSURL *> *)fontURLsFromDraggingInfo:(id<NSDraggingInfo>)sender {
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                       options:@{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES,
    }];
    NSMutableArray<NSURL *> *fonts = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (GAFontURLIsFont(url)) {
            [fonts addObject:url];
        }
    }
    return fonts;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self fontURLsFromDraggingInfo:sender].count > 0
        ? NSDragOperationCopy
        : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [self fontURLsFromDraggingInfo:sender];
    if (urls.count == 0) {
        return NO;
    }
    for (NSURL *url in urls) {
        if (self.onFontDrop) {
            self.onFontDrop(url);
        }
    }
    return YES;
}

@end

#pragma mark - Selection run

/// Finds needle in haystack only when it occurs exactly once. Used to trim a
/// selection attribute back after standard field-editor insertion at a run
/// boundary (typing there inherits the run's attributes).
static NSRange GAFindUniqueSubstring(NSString *haystack, NSString *needle) {
    if (needle.length == 0 || haystack.length < needle.length) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSRange search = NSMakeRange(0, haystack.length);
    NSRange found = NSMakeRange(NSNotFound, 0);
    while (search.length > 0) {
        NSRange candidate = [haystack rangeOfString:needle options:0 range:search];
        if (candidate.location == NSNotFound) {
            break;
        }
        if (found.location != NSNotFound) {
            return NSMakeRange(NSNotFound, 0);
        }
        found = candidate;
        // Advance one UTF-16 unit so overlapping occurrences are also
        // detected and treated as ambiguous.
        NSUInteger next = candidate.location + 1;
        if (next >= haystack.length) {
            break;
        }
        search = NSMakeRange(next, haystack.length - next);
    }
    return found;
}

@interface GAScanDisplaySnapshot : NSObject
@property (nonatomic, strong) NSArray<GACharacterGroup *> *display;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nonnull) NSString *multiText;
@property (nonatomic, strong, nonnull) NSArray<GACharacterGroup *> *multiGroups;
@property (nonatomic, strong, nonnull) NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiGroupSources;
@end

@implementation GAScanDisplaySnapshot
@end

#pragma mark - Main window

@interface GAMainWindowController () <NSWindowDelegate, NSToolbarDelegate, NSPopoverDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) GASidebarViewController *sidebarViewController;
@property (nonatomic, strong) GADetailViewController *detailViewController;
@property (nonatomic, strong, nullable) GAFontDocument *fontDocument;
@property (nonatomic, strong) NSTextField *titleFontNameField;
@property (nonatomic, strong) NSStackView *fontTitleView;
@property (nonatomic, strong) NSButton *variationButton;
@property (nonatomic, strong) NSPopover *variationPopover;
@property (nonatomic) CGFloat attachedVariationWindowHeight;
@property (nonatomic, strong, nullable) GAFontResource *fontResource;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *variationCoordinates;
@property (nonatomic) NSUInteger fontLoadGeneration;
/// Owned by analysisQueue, independently of the main-thread display document.
@property (nonatomic, strong, nullable) GAFontDocument *workerFontDocument;
@property (nonatomic, strong) dispatch_queue_t fontQueue;
@property (nonatomic, strong) dispatch_queue_t analysisQueue;
@property(nonatomic, strong, nullable) GATextQueryModel *queryModel;
@property (nonatomic, copy, nullable) NSString *pendingWorkerText;
@property (nonatomic, copy, nullable) NSArray<GAGlyphSelectionRun *> *pendingWorkerSelections;
@property (nonatomic) NSUInteger workerGeneration;
@property (nonatomic) BOOL didFocusInitialField;
@property (nonatomic, copy) NSString *multiText;
@property (nonatomic, strong) NSArray<GACharacterGroup *> *multiGroups;
/// Multi-view groups are filtered copies; map each copy back to its sidebar
/// group so a click can still select the original source range.
@property (nonatomic, strong) NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiGroupSources;
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic) BOOL verticalWriting;
@property(nonatomic) BOOL usesContextualAlternates;
@property(nonatomic) BOOL usesLigatures;
@property (nonatomic, strong, nullable) GAGlyphVariant *lastSelectedVariant;
/// Set by an all-glyph double-click append; consumed by the next reveal.
@property (nonatomic) BOOL appendRevealPending;
@end

@implementation GAMainWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 600, 400);
    GADropWindow *window = [[GADropWindow alloc] initWithContentRect:frame
                                                          styleMask:(NSWindowStyleMaskTitled |
                                                                     NSWindowStyleMaskClosable |
                                                                     NSWindowStyleMaskMiniaturizable |
                                                                     NSWindowStyleMaskResizable |
                                                                     NSWindowStyleMaskFullSizeContentView)
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
    window.restorable = NO;
    window.minSize = NSMakeSize(600, 390);
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

    self = [super initWithWindow:window];
    if (self) {
        _usesContextualAlternates = YES;
        _usesLigatures = YES;
        window.delegate = self;
        [self configureInterfaceWithWindow:window];

        __weak typeof(self) weakSelf = self;
        window.onFontDrop = ^(NSURL *url) {
            if (weakSelf.onFontDropRequest != nil) {
                weakSelf.onFontDropRequest(url);
            }
        };

        NSRect windowFrame = window.frame;
        windowFrame.size = NSMakeSize(600, 400);
        [window setFrame:windowFrame display:NO];
        [window center];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                 name:GAInputBlankClickNotification object:nil];
}

- (void)configureInterfaceWithWindow:(NSWindow *)window {
    _showsMetrics = YES;
    _multiText = @"";
    _multiGroups = @[];
    _multiGroupSources = [NSMapTable weakToStrongObjectsMapTable];
    self.fontQueue = dispatch_queue_create("com.zonz.GlyphAtlas.font", DISPATCH_QUEUE_SERIAL);
    self.analysisQueue = dispatch_queue_create("com.zonz.GlyphAtlas.analysis",
                                               DISPATCH_QUEUE_SERIAL);

    self.sidebarViewController = [[GASidebarViewController alloc] init];
    self.detailViewController = [[GADetailViewController alloc] init];
    self.detailViewController.viewMode = _viewMode;

    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    split.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    self.splitViewController = split;

    NSSplitViewItem *sidebarItem =
        [NSSplitViewItem sidebarWithViewController:self.sidebarViewController];
    sidebarItem.minimumThickness = 200;
    sidebarItem.maximumThickness = 1000;
    sidebarItem.canCollapse = NO;
    sidebarItem.allowsFullHeightLayout = YES;
    [split addSplitViewItem:sidebarItem];

    NSSplitViewItem *detailItem =
        [NSSplitViewItem splitViewItemWithViewController:self.detailViewController];
    detailItem.minimumThickness = 300;
    [split addSplitViewItem:detailItem];

    window.contentViewController = split;

    self.titleFontNameField = [NSTextField labelWithString:@""];
    self.titleFontNameField.autoresizingMask = NSViewWidthSizable;
    self.titleFontNameField.lineBreakMode = NSLineBreakByTruncatingTail;
    NSFont *titleBarFont = [NSFont titleBarFontOfSize:13];
    NSFontDescriptor *titleDescriptor = [titleBarFont.fontDescriptor
        fontDescriptorByAddingAttributes:@{
            NSFontTraitsAttribute: @{NSFontWeightTrait: @(NSFontWeightMedium)},
        }];
    self.titleFontNameField.font = [NSFont fontWithDescriptor:titleDescriptor size:13]
        ?: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.titleFontNameField.textColor = [NSColor windowFrameTextColor];

    self.variationButton = [NSButton buttonWithImage:
        [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil]
                                             target:self action:@selector(showVariations:)];
    self.variationButton.bordered = NO;
    self.variationButton.hidden = YES;
    self.variationButton.toolTip = NSLocalizedString(@"Variable", @"Variable font controls");
    self.variationButton.accessibilityLabel = self.variationButton.toolTip;
    self.fontTitleView = [NSStackView stackViewWithViews:@[self.variationButton, self.titleFontNameField]];
    self.fontTitleView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.fontTitleView.alignment = NSLayoutAttributeCenterY;
    self.fontTitleView.spacing = 5;
    [self.titleFontNameField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"GATitleToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    window.toolbar = toolbar;
    window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;

    __weak typeof(self) weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleInputBlankClick:)
                                              name:GAInputBlankClickNotification object:nil];
    self.sidebarViewController.onTextChanged = ^{
        [weakSelf scheduleAnalysis];
    };
    self.sidebarViewController.onSelectionChanged = ^(GAGlyphVariant *variant) {
        weakSelf.lastSelectedVariant = variant;
        [weakSelf.detailViewController setVariant:variant];
        [weakSelf revealGlyphForVariant:variant];
    };
    self.sidebarViewController.onGlyphActivated = ^(GACharacterGroup *group,
                                                    GAGlyphVariant *variant) {
        [weakSelf activateGlyphVariant:variant inGroup:group];
    };
    self.sidebarViewController.onGlyphShiftActivated = ^(GACharacterGroup *group,
                                                         GAGlyphVariant *variant) {
        [weakSelf insertGlyphVariant:variant inGroup:group];
    };
    self.detailViewController.onAllGlyphDoubleClick = ^(GAAllGlyphEntry *entry) {
        [weakSelf appendAllGlyphEntry:entry];
    };
    self.detailViewController.onGlyphSelected = ^(NSArray<NSNumber *> *glyphIDs, NSRange range) {
      [weakSelf selectLayoutGlyphIDs:glyphIDs multiRange:range];
    };
}

#pragma mark - View actions

- (void)revealGlyphForVariant:(GAGlyphVariant *)variant {
    if (self.viewMode != GAViewModeAllGlyphs || variant.glyphIDs.count == 0) {
        return;
    }
    BOOL quick = self.appendRevealPending;
    self.appendRevealPending = NO;
    [self.detailViewController revealAllGlyphID:variant.glyphIDs.firstObject quick:quick];
}

- (void)setViewMode:(GAViewMode)viewMode {
    _viewMode = viewMode;
    self.detailViewController.viewMode = viewMode;
    [self revealGlyphForVariant:self.lastSelectedVariant];
    if (viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController setMultiText:self.multiText
                                         groups:self.multiGroups ?: @[]];
        [self.detailViewController setTextAlignment:self.textAlignment];
        [self.detailViewController setWritingDirectionVertical:self.verticalWriting];
        [self.detailViewController setUsesContextualAlternates:self.usesContextualAlternates];
        [self.detailViewController setUsesLigatures:self.usesLigatures];
    }
}

- (void)selectLayoutGlyphIDs:(NSArray<NSNumber *> *)glyphIDs multiRange:(NSRange)range {
    NSRange source = NSMakeRange(NSNotFound, 0);
    for (GACharacterGroup *group in self.multiGroups)
        if (NSIntersectionRange(group.textRange, range).length) {
            GACharacterGroup *original = [self.multiGroupSources objectForKey:group] ?: group;
            source = source.location == NSNotFound ? original.textRange
                                                   : NSUnionRange(source, original.textRange);
        }
    if (source.location != NSNotFound)
        [self.sidebarViewController selectGlyphIDs:glyphIDs textRange:source];
}

- (void)toggleShowsMetrics {
    if (_viewMode == GAViewModeAllGlyphs) {
        return;
    }
    _showsMetrics = !_showsMetrics;
    [self.detailViewController setShowsMetrics:_showsMetrics];
}

- (void)zoomIn {
    if (_viewMode == GAViewModeAllGlyphs) {
        [self.detailViewController zoomAllGlyphsIn];
    } else if (_viewMode == GAViewModeSingleGlyph) {
        [self.detailViewController zoomBoundingBoxIn];
    } else if (_viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController zoomMultiTextIn];
    }
}

- (void)zoomOut {
    if (_viewMode == GAViewModeAllGlyphs) {
        [self.detailViewController zoomAllGlyphsOut];
    } else if (_viewMode == GAViewModeSingleGlyph) {
        [self.detailViewController zoomBoundingBoxOut];
    } else if (_viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController zoomMultiTextOut];
    }
}

- (void)zoomMetricsIn {
    [self.detailViewController zoomBoundingBoxIn];
}

- (void)zoomMetricsOut {
    [self.detailViewController zoomBoundingBoxOut];
}

- (void)resetZoom {
    if (_viewMode == GAViewModeAllGlyphs) {
        [self.detailViewController resetAllGlyphsZoom];
    } else if (_viewMode == GAViewModeSingleGlyph) {
        [self.detailViewController resetBoundingBoxZoom];
    } else if (_viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController resetMultiTextZoom];
    }
}

- (void)setTextAlignment:(NSTextAlignment)alignment {
    _textAlignment = alignment;
    [self.detailViewController setTextAlignment:alignment];
}

- (void)setVerticalWriting:(BOOL)vertical {
    _verticalWriting = vertical;
    [self.detailViewController setWritingDirectionVertical:vertical];
}

- (void)setUsesContextualAlternates:(BOOL)enabled {
    _usesContextualAlternates = enabled;
    [self.detailViewController setUsesContextualAlternates:enabled];
}

- (void)setUsesLigatures:(BOOL)enabled {
    _usesLigatures = enabled;
    [self.detailViewController setUsesLigatures:enabled];
}

- (void)appendAllGlyphEntry:(GAAllGlyphEntry *)entry {
    NSNumber *scalar = entry.unicodeScalars.firstObject;
    BOOL needsSelection = scalar == nil;
    if (scalar == nil) {
        // The clicked glyph has no Unicode mapping of its own. Borrow the first
        // mapping from its replacement set and pin the clicked glyph with a run.
        NSArray<GACharacterGroup *> *groups =
            [self.fontDocument analyzeGlyphIDs:@[entry.glyphID]];
        for (GAGlyphVariant *variant in groups.firstObject.variants) {
            if (variant.unicodeScalars.count > 0) {
                scalar = variant.unicodeScalars.firstObject;
                break;
            }
        }
    } else if (scalar.unsignedIntValue <= 0x1F || scalar.unsignedIntValue == 0x7F) {
        for (NSUInteger index = 1; index < entry.unicodeScalars.count; index++) {
            NSNumber *candidate = entry.unicodeScalars[index];
            uint32_t value = candidate.unsignedIntValue;
            if (value > 0x1F && value != 0x7F) {
                scalar = candidate;
                break;
            }
        }
    }
    NSString *string = scalar != nil ? GAStringFromUnicodeScalars(@[scalar]) : @"\uFFFD";
    if (string.length == 0) {
        return;
    }
    GAGlyphSelection *selection = nil;
    if (needsSelection) {
        selection = [[GAGlyphSelection alloc] initWithSourceText:string
                                                        glyphIDs:@[entry.glyphID]
                                                  featureSources:@[]
                                                        ligature:NO];
    }
    NSRange range = [self.sidebarViewController appendInputString:string
                                                       selection:selection];
    if (range.location == NSNotFound) {
        return;
    }
    self.appendRevealPending = YES;
    [self.sidebarViewController selectGlyphKeyAfterNextReload:entry.glyphID.stringValue
                                                    textRange:range
                                                       scroll:GAPendingSelectionScrollGroup];
    [self scheduleAnalysis];
    [self.sidebarViewController focusInput];
}

#pragma mark - Window and input focus

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self.sidebarViewController setGlyphListDimmed:NO];
    if (self.didFocusInitialField) {
        return;
    }
    self.didFocusInitialField = YES;
    [self.splitViewController.splitView setPosition:200 ofDividerAtIndex:0];
    [self.sidebarViewController focusInput];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self.sidebarViewController setGlyphListDimmed:YES];
}

- (NSText *)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)client {
    return [self.sidebarViewController fieldEditorForControl:client];
}

- (void)handleInputBlankClick:(NSNotification *)notification {
    NSEvent *event = notification.object;
    NSWindow *window = event.window;
    if (window == nil) return;
    BOOL mainClick = window == self.window;
    if (!mainClick && window != self.variationPopover.contentViewController.view.window) return;
    if (!GAEndInputEditingOutsideWindow(window)) return;
    if (mainClick) {
        [self.sidebarViewController focusGlyphList];
    } else {
        [(GAVariationViewController *)self.variationPopover.contentViewController focusWindow];
    }
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"GAFontName", NSToolbarSidebarTrackingSeparatorItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:NSToolbarSidebarTrackingSeparatorItemIdentifier]) {
        return [NSTrackingSeparatorToolbarItem
            trackingSeparatorToolbarItemWithIdentifier:itemIdentifier
                                             splitView:self.splitViewController.splitView
                                          dividerIndex:0];
    }
    if (![itemIdentifier isEqualToString:@"GAFontName"]) {
        return nil;
    }
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = NSLocalizedString(@"Font Name", @"Font Name");
    item.paletteLabel = NSLocalizedString(@"Font Name", @"Font Name");
    item.view = self.fontTitleView;
    // Keep the custom title and Variable button free of toolbar glass.
    item.bordered = NO;
    CGFloat titleHeight = MAX(22, self.titleFontNameField.fittingSize.height);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    item.minSize = NSMakeSize(0, titleHeight);
    item.maxSize = NSMakeSize(500, titleHeight);
#pragma clang diagnostic pop
    return item;
}

#pragma mark - Opening fonts

- (NSURL *)fontURL {
    return self.fontDocument.fontURL;
}

- (void)loadFontAtURL:(NSURL *)url {
    CFArrayRef array = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    NSArray *descriptors = array ? CFBridgingRelease(array) : @[];
    if (descriptors.count == 0) {
        [self showErrorWithTitle:NSLocalizedString(@"Cannot Open Font", @"Cannot Open Font")
                         message:NSLocalizedString(@"This file does not contain a font that CoreText can read.", @"Cannot read font file")];
        return;
    }
    NSArray<GAFontResource *> *resources = [GAFontResource resourcesFromDescriptors:descriptors];
    if (resources.count == 1) {
        [self loadResource:resources.firstObject url:url];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Choose Font Style", @"Choose Font Style");
    alert.informativeText = [NSString localizedStringWithFormat:
        NSLocalizedString(@"“%@” contains %lu fonts.", @"Font collection choice"),
        url.lastPathComponent, (unsigned long)resources.count];
    [alert addButtonWithTitle:NSLocalizedString(@"Open", @"Open")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 290, 26) pullsDown:NO];
    for (GAFontResource *resource in resources) {
        NSMenuItem *item = [popup.menu addItemWithTitle:resource.name action:nil keyEquivalent:@""];
        item.representedObject = resource;
    }
    alert.accessoryView = popup;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            [weakSelf.window close];
            return;
        }
        [weakSelf loadResource:popup.selectedItem.representedObject url:url];
    }];
}

- (void)loadResource:(GAFontResource *)resource url:(NSURL *)url {
    [self.variationPopover close];
    self.fontResource = resource;
    self.variationCoordinates = resource.defaultCoordinates;
    self.variationButton.hidden = resource.axes.count == 0;
    [self loadDescriptor:resource.defaultDescriptor url:url preservingSelection:NO];
}

#pragma mark - Variation controls

- (void)showVariations:(id)sender {
    (void)sender;
    if (self.variationPopover.detached) {
        [self.variationPopover.contentViewController.view.window makeKeyAndOrderFront:nil];
        return;
    }
    if (self.variationPopover.shown) {
        [self.variationPopover close];
        return;
    }
    if (self.fontDocument == nil || self.fontResource.axes.count == 0) return;
    GAVariationViewController *controller = [[GAVariationViewController alloc]
        initWithResource:self.fontResource coordinates:self.variationCoordinates];
    __weak typeof(self) weakSelf = self;
    controller.onCoordinatesChanged = ^(NSDictionary *coordinates) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) return;
        if ([self.variationCoordinates isEqualToDictionary:coordinates]) return;
        self.variationCoordinates = coordinates;
        CTFontDescriptorRef descriptor = [self.fontResource copyDescriptorWithCoordinates:coordinates];
        [self loadDescriptor:descriptor url:self.fontDocument.fontURL preservingSelection:YES];
        CFRelease(descriptor);
    };
    self.variationPopover = [[NSPopover alloc] init];
    controller.title = @"";
    self.variationPopover.delegate = self;
    self.variationPopover.behavior = NSPopoverBehaviorTransient;
    self.variationPopover.contentViewController = controller;
    [self.variationPopover showRelativeToRect:self.variationButton.bounds
                                      ofView:self.variationButton preferredEdge:NSRectEdgeMinY];
}

- (BOOL)popoverShouldDetach:(NSPopover *)popover {
    return popover == self.variationPopover;
}

- (void)popoverDidShow:(NSNotification *)notification {
    if (notification.object != self.variationPopover) return;
    NSView *content = self.variationPopover.contentViewController.view;
    self.attachedVariationWindowHeight = NSHeight(content.window.frame);
    [(GAVariationViewController *)self.variationPopover.contentViewController
        prepareWindowFocus];
}

- (void)popoverDidDetach:(NSPopover *)popover {
    if (popover != self.variationPopover) return;
    NSWindow *window = popover.contentViewController.view.window;
    NSRect frame = window.frame;
    frame.origin.y += NSHeight(frame) - self.attachedVariationWindowHeight;
    frame.size.height = self.attachedVariationWindowHeight;
    [window setFrame:frame display:YES];
    [(GAVariationViewController *)popover.contentViewController
        prepareWindowFocus];
}

- (void)popoverDidClose:(NSNotification *)notification {
    if (notification.object != self.variationPopover) return;
    if ([notification.userInfo[NSPopoverCloseReasonKey]
            isEqual:NSPopoverCloseReasonDetachToWindow]) return;
    if (self.sidebarViewController.inputFocused) return;
    [self.sidebarViewController focusGlyphList];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.window) {
        [self.variationPopover close];
    }
}

#pragma mark - Font loading

- (void)loadDescriptor:(CTFontDescriptorRef)descriptor
                   url:(NSURL *)url preservingSelection:(BOOL)preserve {
    CTFontDescriptorRef retained = (CTFontDescriptorRef)CFRetain(descriptor);
    NSUInteger request;
    @synchronized (self) { request = ++self.fontLoadGeneration; }
    GAFontDocument *source = preserve ? self.fontDocument : nil;
    __weak typeof(self) weakSelf = self;
    // Serial construction coalesces queued slider events without delaying live previews.
    dispatch_async(self.fontQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) { CFRelease(retained); return; }
        @synchronized (self) {
            if (request != self.fontLoadGeneration) { CFRelease(retained); return; }
        }
        GAFontDocument *document = source != nil ? [source documentWithDescriptor:retained]
            : [[GAFontDocument alloc] initWithDescriptor:retained URL:url];
        CFRelease(retained);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (request != self.fontLoadGeneration) return;
            if (document == nil) {
                [self showErrorWithTitle:NSLocalizedString(@"Cannot Read Font", @"Cannot Read Font")
                                 message:NSLocalizedString(@"CoreText could not create this font.", @"Cannot create font")];
                return;
            }
            GAGlyphVariant *selected = preserve ? self.lastSelectedVariant : nil;
            self.fontDocument = document;
            @synchronized (self) {
                self.pendingWorkerText = nil;
                self.pendingWorkerSelections = nil;
                self.workerGeneration += 1;
            }
            // Swap all model-owned state on its queue after the old batch yields.
            dispatch_async(self.analysisQueue, ^{
                self.workerFontDocument = document;
                if (preserve && self.queryModel != nil) {
                    [self.queryModel updateFontDocument:document];
                } else {
                    self.queryModel = [[GATextQueryModel alloc] initWithFontDocument:document];
                }
                // Schedule from the latest input only after the old worker has
                // yielded and the new model is installed. Otherwise that old
                // worker could consume the pending text before this reset.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (request == self.fontLoadGeneration && self.fontDocument == document) {
                        [self scheduleAnalysis];
                    }
                });
            });
            [self.detailViewController setFontDocument:document];
            if (!preserve && self.onFontLoaded != nil) self.onFontLoaded(document.fontURL ?: url);
            self.window.title = document.fullName;
            self.window.subtitle = document.fontURL.lastPathComponent ?: @"";
            self.titleFontNameField.stringValue = document.fullName;
            self.titleFontNameField.toolTip = document.fullName;
            [self.titleFontNameField invalidateIntrinsicContentSize];
            if (!preserve) [self.sidebarViewController setGroups:@[]];
            if (selected != nil) {
                GAGlyphVariant *updated = [document rebindVariant:selected content:self.sidebarViewController.selectedGlyphSourceText];
                self.lastSelectedVariant = updated;
                [self.detailViewController setVariant:updated];
            }
            if (self.sidebarViewController.text.length == 0) {
                [self.detailViewController setVariant:nil];
            }
        });
    });
}

#pragma mark - Selection runs and activation

- (NSArray<GAGlyphSelectionRun *> *)selectionRunsInAttributedText:(NSMutableAttributedString *)text
                                                        didChange:(BOOL *)didChange {
    NSMutableArray<GAGlyphSelectionRun *> *runs = [NSMutableArray array];
    NSMutableArray<NSValue *> *invalidRanges = [NSMutableArray array];
    NSMutableArray<GAGlyphSelectionRun *> *trimmedRuns = [NSMutableArray array];
    NSMutableArray<NSValue *> *trimmedOldRanges = [NSMutableArray array];
    NSRange inputSelection = self.sidebarViewController.inputSelectionRange;
    [text enumerateAttribute:GAGlyphSelectionAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        (void)stop;
        if (value == nil) {
            return;
        }
        if (![value isKindOfClass:[GAGlyphSelection class]] ||
            range.length == 0) {
            [invalidRanges addObject:[NSValue valueWithRange:range]];
            return;
        }
        GAGlyphSelection *selection = value;
        if (selection.sourceText.length == 0 || selection.glyphIDs.count == 0) {
            [invalidRanges addObject:[NSValue valueWithRange:range]];
            return;
        }

        NSString *current = [text.string substringWithRange:range];
        GAGlyphSelectionRun *run = [[GAGlyphSelectionRun alloc] init];
        run.selection = selection;
        if ([current isEqualToString:selection.sourceText]) {
            run.range = range;
            [runs addObject:run];
            return;
        }

        if (current.length > selection.sourceText.length) {
            // The field editor extends the run's attributes when text is
            // inserted at a run boundary. Use the caret to tell which side
            // grew; this disambiguates duplicate source strings such as "11".
            NSString *source = selection.sourceText;
            NSUInteger insertedLength = current.length - source.length;
            BOOL caretAtStart = inputSelection.location != NSNotFound &&
                inputSelection.length == 0 &&
                inputSelection.location == range.location + insertedLength;
            BOOL caretAtEnd = inputSelection.location != NSNotFound &&
                inputSelection.length == 0 &&
                inputSelection.location == NSMaxRange(range);

            NSRange match = NSMakeRange(NSNotFound, 0);
            if (caretAtEnd && [current hasPrefix:source]) {
                match = NSMakeRange(range.location, source.length);
            } else if (caretAtStart && [current hasSuffix:source]) {
                match = NSMakeRange(NSMaxRange(range) - source.length,
                                    source.length);
            } else {
                match = GAFindUniqueSubstring(current, source);
                if (match.location != NSNotFound) {
                    match.location += range.location;
                }
            }
            if (match.location != NSNotFound) {
                run.range = match;
                [runs addObject:run];
                [trimmedRuns addObject:run];
                [trimmedOldRanges addObject:[NSValue valueWithRange:range]];
                return;
            }
        }

        // The user edited inside the run. The stored source text no longer
        // matches this range, so dissolve the run instead of guessing.
        [invalidRanges addObject:[NSValue valueWithRange:range]];
    }];

    for (NSValue *value in trimmedOldRanges) {
        [text removeAttribute:GAGlyphSelectionAttributeName
                        range:value.rangeValue];
    }
    for (GAGlyphSelectionRun *run in trimmedRuns) {
        [text addAttribute:GAGlyphSelectionAttributeName
                     value:run.selection
                     range:run.range];
    }
    for (NSValue *value in invalidRanges) {
        [text removeAttribute:GAGlyphSelectionAttributeName
                        range:value.rangeValue];
    }
    if (didChange != NULL) {
        *didChange = invalidRanges.count > 0 || trimmedRuns.count > 0;
    }
    return runs;
}

- (NSRange)fullSelectionRangeCoveringRange:(NSRange)range
                          inAttributedText:(NSAttributedString *)text {
    if (range.location == NSNotFound || range.length == 0 || text.length == 0) {
        return range;
    }
    __block NSRange expanded = range;
    [text enumerateAttribute:GAGlyphSelectionAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(id value, NSRange candidate, BOOL *stop) {
        (void)stop;
        if (value != nil && NSIntersectionRange(candidate, expanded).length > 0) {
            expanded = NSUnionRange(expanded, candidate);
        }
    }];
    return expanded;
}

- (NSRange)sourceRangeForVariant:(GAGlyphVariant *)variant
                         inGroup:(GACharacterGroup *)group
                            text:(NSString *)text {
    NSRange range = NSMakeRange(NSNotFound, 0);
    if (variant.isLigature) {
        range = variant.sourceTextRange;
    }
    if (range.location == NSNotFound || range.length == 0 ||
        NSMaxRange(range) > text.length) {
        range = group.textRange;
    }
    if (range.location == NSNotFound || range.length == 0 ||
        NSMaxRange(range) > text.length) {
        if (group.text.length > 0) {
            range = [text rangeOfString:group.text];
        }
    }
    return range;
}

/// Returns the text that activation puts at the source range. An encoded glyph
/// contributes its first Unicode scalar; an unencoded glyph contributes the
/// existing source text and a run through `outSelection`.
/// The caller must provide a variable to receive the optional selection.
- (NSString *)activationPayloadForVariant:(GAGlyphVariant *)variant
                               sourceText:(NSString *)sourceText
                                selection:(GAGlyphSelection **)outSelection {
    NSArray<NSNumber *> *scalars = variant.unicodeScalars;
    if (variant.glyphIDs.count == 1 && scalars.count > 0) {
        NSString *replacement =
            GAStringFromUnicodeScalars(@[scalars.firstObject]);
        if (replacement.length == 0) {
            return nil;
        }
        *outSelection = nil;
        return replacement;
    }
    if (variant.glyphIDs.count == 0) {
        *outSelection = nil;
        return @""; // A multiple-substitution deletion removes its source.
    }
    GAGlyphSelection *selection = [[GAGlyphSelection alloc]
        initWithSourceText:sourceText
                  glyphIDs:variant.glyphIDs
            featureSources:variant.featureSources
                  ligature:variant.isLigature || sourceText.length > 1];
    *outSelection = selection;
    return sourceText;
}

- (void)activateGlyphVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group {
    NSAttributedString *currentText = self.sidebarViewController.attributedText;
    NSString *text = currentText.string;
    NSRange range = [self sourceRangeForVariant:variant inGroup:group text:text];
    if (range.location == NSNotFound || range.length == 0 ||
        NSMaxRange(range) > text.length) {
        NSBeep();
        return;
    }

    NSMutableAttributedString *attributedText = [currentText mutableCopy];
    NSRange removalRange = [self fullSelectionRangeCoveringRange:range
                                              inAttributedText:attributedText];
    if (removalRange.location != NSNotFound && removalRange.length > 0 &&
        NSMaxRange(removalRange) <= attributedText.length) {
        [attributedText removeAttribute:GAGlyphSelectionAttributeName
                                  range:removalRange];
    }

    GAGlyphSelection *selection = nil;
    NSString *payload =
        [self activationPayloadForVariant:variant
                               sourceText:[text substringWithRange:range]
                                selection:&selection];
    if (payload == nil) {
        NSBeep();
        return;
    }

    NSRange selectedRange = range;
    if (selection != nil) {
        [attributedText addAttribute:GAGlyphSelectionAttributeName
                              value:selection
                              range:range];
    } else {
        // Activation inserts a single source character. Copy still uses all
        // encodings of the glyph.
        [attributedText replaceCharactersInRange:range withString:payload];
        selectedRange = NSMakeRange(range.location, payload.length);
    }

    [self.sidebarViewController
        selectGlyphKeyAfterNextReload:variant.glyphKey
                            textRange:selectedRange
                               scroll:GAPendingSelectionScrollSelectedToTopIfNeeded];
    [self.sidebarViewController setAttributedText:attributedText];
    [self scheduleAnalysis];
}

- (void)insertGlyphVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group {
    NSAttributedString *currentText = self.sidebarViewController.attributedText;
    NSString *text = currentText.string;
    NSRange range = [self sourceRangeForVariant:variant inGroup:group text:text];
    if (range.location == NSNotFound || range.length == 0 ||
        NSMaxRange(range) > text.length) {
        NSBeep();
        return;
    }

    GAGlyphSelection *selection = nil;
    NSString *payload =
        [self activationPayloadForVariant:variant
                               sourceText:[text substringWithRange:range]
                                selection:&selection];
    if (payload == nil) {
        NSBeep();
        return;
    }

    NSUInteger location = NSMaxRange(range);
    NSMutableAttributedString *inserted =
        [[NSMutableAttributedString alloc] initWithString:payload];
    if (selection != nil) {
        [inserted addAttribute:GAGlyphSelectionAttributeName
                         value:selection
                         range:NSMakeRange(0, inserted.length)];
    }

    NSMutableAttributedString *attributedText = [currentText mutableCopy];
    [attributedText insertAttributedString:inserted atIndex:location];
    // Shift insertion keeps the current selection; only normal activation
    // selects the resulting glyph.
    [self.sidebarViewController setAttributedText:attributedText];
    [self scheduleAnalysis];
}

#pragma mark - Analysis

- (void)scheduleAnalysis {
    NSMutableAttributedString *attributedText =
        [self.sidebarViewController.attributedText mutableCopy];
    BOOL didDissolveSelections = NO;
    NSArray<GAGlyphSelectionRun *> *selections =
        [self selectionRunsInAttributedText:attributedText
                                  didChange:&didDissolveSelections];
    if (didDissolveSelections) {
        [self.sidebarViewController setAttributedText:attributedText];
    }
    NSString *text = attributedText.string;

    if (self.fontDocument == nil) {
        return;
    }

    @synchronized (self) {
        self.pendingWorkerText = text;
        self.pendingWorkerSelections = selections;
        self.workerGeneration += 1;
    }
    if (text.length == 0) {
        [self clearScanDisplay];
    }
    dispatch_async(self.analysisQueue, ^{
        [self workerRun];
    });
}

/// Main-thread-only reset for an empty input.
- (void)clearScanDisplay {
    [self.sidebarViewController setGroups:@[]];
    [self.detailViewController setVariant:nil];
    self.multiText = @"";
    self.multiGroups = @[];
    self.multiGroupSources = [NSMapTable weakToStrongObjectsMapTable];
    [self.detailViewController setMultiText:@"" groups:@[]];
}

#pragma mark - Worker (analysisQueue only)

- (void)workerRun {
    if (!self.queryModel || !self.workerFontDocument)
        return;
    while (YES) {
        NSString *text;
        NSArray<GAGlyphSelectionRun *> *selections;
        NSUInteger generation;
        @synchronized (self) {
            text = self.pendingWorkerText;
            selections = self.pendingWorkerSelections ?: @[];
            generation = self.workerGeneration;
            self.pendingWorkerText = nil;
            self.pendingWorkerSelections = nil;
        }
        if (!text)
            return;
        BOOL complete = [self.queryModel analyzeText:text
                                          selections:selections
                                           cancelled:^BOOL {
                                             @synchronized(self) {
                                                 return generation != self.workerGeneration;
                                             }
                                           }];
        if (complete)
            [self publishWorkerSnapshotWithText:text selections:selections generation:generation];
    }
}

- (void)publishWorkerSnapshotWithText:(NSString *)text
                           selections:(NSArray<GAGlyphSelectionRun *> *)selections
                           generation:(NSUInteger)generation {
    @synchronized (self) {
        if (generation != self.workerGeneration) {
            return;
        }
    }
    NSArray<GACharacterGroup *> *display =
        GABuildDisplayGroups(self.queryModel.groups, text, selections, self.workerFontDocument);
    GAScanDisplaySnapshot *snapshot = [self buildDisplaySnapshotWithText:text groups:display];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.fontDocument == nil ||
            generation != self.workerGeneration) {
            return;
        }
        [self applyScanSnapshot:snapshot];
    });
}

- (void)applyScanSnapshot:(GAScanDisplaySnapshot *)snapshot {
    if (![snapshot.text isEqualToString:self.sidebarViewController.text]) {
        return;
    }
    [self.sidebarViewController updateGroups:snapshot.display sourceText:snapshot.text];
    self.multiText = snapshot.multiText;
    self.multiGroups = snapshot.multiGroups;
    self.multiGroupSources = snapshot.multiGroupSources;
    [self.detailViewController setMultiText:self.multiText groups:self.multiGroups];
}

/// Builds the sidebar/multi-character snapshot. Missing glyph groups are
/// omitted from the multi-character text; the sidebar keeps the original text
/// and the full display list.
- (GAScanDisplaySnapshot *)buildDisplaySnapshotWithText:(NSString *)text
                                               groups:(NSArray<GACharacterGroup *> *)groups {
    NSMutableString *multiText = [NSMutableString string];
    NSMutableArray<GACharacterGroup *> *multiGroups = [NSMutableArray array];
    NSMapTable<GACharacterGroup *, GACharacterGroup *> *sources =
        [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger cursor = 0;
    for (GACharacterGroup *group in groups) {
        if (group.insertedLigature) {
            continue;
        }
        NSRange range = group.textRange;
        if (range.location == NSNotFound || range.length == 0 ||
            NSMaxRange(range) > text.length || range.location < cursor) {
            continue;
        }
        if (range.location > cursor) {
            [multiText appendString:
                [text substringWithRange:NSMakeRange(cursor, range.location - cursor)]];
        }
        cursor = NSMaxRange(range);
        if (GAGroupIsMissing(group)) {
            continue;
        }
        NSString *groupText = [text substringWithRange:range];
        GACharacterGroup *copy = [[GACharacterGroup alloc] init];
        copy.text = groupText;
        copy.textRange = NSMakeRange(multiText.length, groupText.length);
        copy.variants = group.variants;
        copy.seeded = group.seeded;
        [sources setObject:group forKey:copy];
        [multiGroups addObject:copy];
        [multiText appendString:groupText];
    }
    if (cursor < text.length) {
        [multiText appendString:
            [text substringWithRange:NSMakeRange(cursor, text.length - cursor)]];
    }
    GAScanDisplaySnapshot *snapshot = [[GAScanDisplaySnapshot alloc] init];
    snapshot.display = groups;
    snapshot.text = text;
    snapshot.multiText = [multiText copy];
    snapshot.multiGroups = multiGroups;
    snapshot.multiGroupSources = sources;
    return snapshot;
}

#pragma mark - Errors

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];
    if (self.window != nil && self.window.isVisible) {
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

@end
