#import "GAMainWindowController.h"
#import "GADetailViewController.h"
#import "GASidebarViewController.h"
#import "GAFontEngine.h"
#import "GATextScanModel.h"
#import "GAUnicode.h"
#import "GAFontTypes.h"
#import <CoreText/CoreText.h>
#import <math.h>

/// A line break is layout, not a glyph: its character group is kept for text
/// ranges but hidden from the glyph list.
static BOOL GAGroupIsLineBreak(GACharacterGroup *group) {
    return group.text.length == 1 && [group.text characterAtIndex:0] == '\n';
}

/// A missing glyph is represented by GID 0. Seeds are explicit replacements
/// and keep their source text; line breaks are layout, not glyphs.
static BOOL GAGroupIsMissing(GACharacterGroup *group, NSString *text) {
    if (group.seeded || group.insertedLigature || GAGroupIsLineBreak(group)) {
        return NO;
    }
    if (group.textRange.location == NSNotFound || group.textRange.length == 0 ||
        NSMaxRange(group.textRange) > text.length) {
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
    NSURL *url = [self fontURLsFromDraggingInfo:sender].firstObject;
    if (url == nil) {
        return NO;
    }
    if (self.onFontDrop) {
        self.onFontDrop(url);
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

@interface GAGlyphSelectionRun : NSObject
@property (nonatomic) NSRange range;
@property (nonatomic, strong) GAGlyphSelection *selection;
@end

@implementation GAGlyphSelectionRun
@end

@interface GAScanDisplaySnapshot : NSObject
@property (nonatomic, strong) NSArray<GACharacterGroup *> *display;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL shouldUpdateMulti;
@property (nonatomic, copy, nullable) NSString *multiText;
@property (nonatomic, strong, nullable) NSArray<GACharacterGroup *> *multiGroups;
@property (nonatomic, strong, nullable) NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiGroupSources;
@end

@implementation GAScanDisplaySnapshot
@end

#pragma mark - Main window

@interface GAMainWindowController () <NSWindowDelegate, NSToolbarDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) GASidebarViewController *sidebarViewController;
@property (nonatomic, strong) GADetailViewController *detailViewController;
@property (nonatomic, strong, nullable) GAFontDocument *fontDocument;
@property (nonatomic, strong) NSTextField *titleFontNameField;
@property (nonatomic, strong) dispatch_queue_t fontQueue;
@property (nonatomic, strong) dispatch_queue_t analysisQueue;
@property (nonatomic, strong, nullable) GATextScanModel *scanModel;
@property (nonatomic) BOOL scanDisplayPublished;
@property (nonatomic, copy, nullable) NSString *pendingWorkerText;
@property (nonatomic, copy, nullable) NSArray<GAGlyphSelectionRun *> *pendingWorkerSelections;
@property (nonatomic) NSUInteger workerGeneration;
@property (nonatomic, copy, nullable) NSString *workerLastMultiText;
@property (nonatomic, copy, nullable) NSArray<NSString *> *workerLastMultiSeeds;
@property (nonatomic, strong) dispatch_queue_t multiScanQueue;
@property (nonatomic) BOOL multiScanInFlight;
@property (nonatomic, copy, nullable) NSString *workerText;
@property (nonatomic, copy, nullable) NSArray<GAGlyphSelectionRun *> *workerSelections;
@property (nonatomic) NSUInteger workerTextGeneration;
@property (nonatomic) BOOL didFocusInitialField;
@property (nonatomic, strong, nullable) NSArray<GACharacterGroup *> *displayGroups;
@property (nonatomic, copy) NSString *analysisText;
@property (nonatomic, copy) NSString *multiText;
@property (nonatomic, strong) NSArray<GACharacterGroup *> *multiGroups;
/// Multi-view groups are filtered copies; map each copy back to its sidebar
/// group so a click can still select the original source range.
@property (nonatomic, strong) NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiGroupSources;
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic) BOOL verticalWriting;
@property (nonatomic, strong, nullable) GAGlyphVariant *lastSelectedVariant;
/// Set by an all-glyph double-click append; consumed by the next reveal.
@property (nonatomic) BOOL appendRevealPending;
@property (nonatomic) BOOL didSetInitialSidebarWidth;
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

- (void)configureInterfaceWithWindow:(NSWindow *)window {
    _showsMetrics = YES;
    _analysisText = @"";
    _multiText = @"";
    _multiGroups = @[];
    _multiGroupSources = [NSMapTable weakToStrongObjectsMapTable];
    self.fontQueue = dispatch_queue_create("com.zonz.GlyphAtlas.font", DISPATCH_QUEUE_SERIAL);
    self.analysisQueue = dispatch_queue_create("com.zonz.GlyphAtlas.analysis",
                                               DISPATCH_QUEUE_SERIAL);
    self.multiScanQueue = dispatch_queue_create("com.zonz.GlyphAtlas.multiscan",
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

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"GATitleToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    window.toolbar = toolbar;
    window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;

    __weak typeof(self) weakSelf = self;
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
    self.detailViewController.onAllGlyphDoubleClick = ^(GAAllGlyphEntry *entry) {
        [weakSelf appendAllGlyphEntry:entry];
    };
    self.detailViewController.onGroupSelected = ^(GACharacterGroup *group) {
        [weakSelf selectBaseGlyphForGroup:group];
    };
}

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
    }
}

- (void)selectBaseGlyphForGroup:(GACharacterGroup *)group {
    GACharacterGroup *sourceGroup = [self.multiGroupSources objectForKey:group] ?: group;
    GAGlyphVariant *base = sourceGroup.variants.firstObject;
    if (base == nil) {
        return;
    }
    [self.sidebarViewController
        selectGlyphKeyAfterNextReload:base.glyphKey
                            textRange:sourceGroup.textRange];
    [self.sidebarViewController setGroups:self.displayGroups ?: @[]];
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
        [self.detailViewController zoomCanvasIn];
    } else if (_viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController zoomMultiTextIn];
    }
}

- (void)zoomOut {
    if (_viewMode == GAViewModeAllGlyphs) {
        [self.detailViewController zoomAllGlyphsOut];
    } else if (_viewMode == GAViewModeSingleGlyph) {
        [self.detailViewController zoomCanvasOut];
    } else if (_viewMode == GAViewModeMultiCharacter) {
        [self.detailViewController zoomMultiTextOut];
    }
}

- (void)zoomMetricsIn {
    [self.detailViewController zoomCanvasIn];
}

- (void)zoomMetricsOut {
    [self.detailViewController zoomCanvasOut];
}

- (void)resetZoom {
    if (_viewMode == GAViewModeAllGlyphs) {
        [self.detailViewController resetAllGlyphsZoom];
    } else if (_viewMode == GAViewModeSingleGlyph) {
        [self.detailViewController resetCanvasZoom];
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
                                                    textRange:range];
    [self scheduleAnalysis];
    [self.sidebarViewController focusInput];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self.sidebarViewController setGlyphListDimmed:NO];
    if (self.didFocusInitialField) {
        return;
    }
    self.didFocusInitialField = YES;
    if (!self.didSetInitialSidebarWidth) {
        self.didSetInitialSidebarWidth = YES;
        [self.splitViewController.splitView setPosition:200 ofDividerAtIndex:0];
    }
    [self.sidebarViewController focusInput];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self.sidebarViewController setGlyphListDimmed:YES];
}

- (NSText *)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)client {
    return [self.sidebarViewController fieldEditorForControl:client];
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"GAFontName", NSToolbarSidebarTrackingSeparatorItemIdentifier];
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
    item.label = @"Font Name";
    item.paletteLabel = @"Font Name";
    item.view = self.titleFontNameField;
    CGFloat titleHeight = self.titleFontNameField.fittingSize.height;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    item.minSize = NSMakeSize(0, titleHeight);
    item.maxSize = NSMakeSize(500, titleHeight);
#pragma clang diagnostic pop
    return item;
}

#pragma mark - Opening fonts

- (void)loadFontAtURL:(NSURL *)url {
    CFArrayRef array = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    NSArray *descriptors = array ? CFBridgingRelease(array) : @[];
    if (descriptors.count == 0) {
        [self showErrorWithTitle:@"Cannot Open Font"
                         message:@"This file does not contain a font that CoreText can read."];
        return;
    }

    if (descriptors.count == 1) {
        CTFontDescriptorRef descriptor =
            (__bridge CTFontDescriptorRef)descriptors.firstObject;
        [self loadDescriptor:descriptor url:url];
        return;
    }

    [self chooseDescriptorFromDescriptors:descriptors url:url];
}


- (void)chooseDescriptorFromDescriptors:(NSArray *)descriptors
                                    url:(NSURL *)url {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Choose Font Style";
    alert.informativeText = [NSString stringWithFormat:
        @"“%@” contains %lu fonts. Choose a style to inspect.",
        url.lastPathComponent, (unsigned long)descriptors.count];
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 290, 26)
                                                       pullsDown:NO];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *titleCounts = [NSMutableDictionary dictionary];
    NSNumber *weightAxisTag = @(0x77676874); // 'wght'
    NSNumber *defaultWeight = nil;
    CTFontDescriptorRef firstDescriptor = (__bridge CTFontDescriptorRef)descriptors.firstObject;
    CTFontRef firstFont = CTFontCreateWithFontDescriptor(firstDescriptor, 16, NULL);
    if (firstFont != NULL) {
        NSArray<NSDictionary *> *axes =
            CFBridgingRelease(CTFontCopyVariationAxes(firstFont));
        for (NSDictionary *axis in axes) {
            NSNumber *identifier = axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey];
            if (identifier.unsignedIntValue == weightAxisTag.unsignedIntValue) {
                defaultWeight = axis[(__bridge NSString *)kCTFontVariationAxisDefaultValueKey];
                break;
            }
        }
        CFRelease(firstFont);
    }

    BOOL foundDefaultWeight = NO;
    NSInteger defaultWeightIndex = 0;
    for (NSUInteger index = 0; index < descriptors.count; index++) {
        CTFontDescriptorRef descriptor = (__bridge CTFontDescriptorRef)descriptors[index];
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 16, NULL);
        NSString *name = nil;
        NSDictionary *variation = nil;
        if (font != NULL) {
            name = CFBridgingRelease(CTFontCopyFullName(font));
            if (defaultWeight != nil) {
                variation = CFBridgingRelease(CTFontCopyVariation(font));
            }
            CFRelease(font);
        }
        if (defaultWeight != nil && !foundDefaultWeight) {
            NSNumber *weight = variation[weightAxisTag] ?: defaultWeight;
            if (fabs(weight.doubleValue - defaultWeight.doubleValue) < 0.001) {
                foundDefaultWeight = YES;
                defaultWeightIndex = (NSInteger)index;
            }
        }
        NSString *title = name.length > 0 ? name : @"Untitled Font";
        [titles addObject:title];
        titleCounts[title] = @([titleCounts[title] integerValue] + 1);
    }

    NSMutableDictionary<NSString *, NSNumber *> *seenCounts = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < titles.count; index++) {
        NSString *title = titles[index];
        if (titleCounts[title].integerValue > 1) {
            NSUInteger occurrence = (NSUInteger)seenCounts[title].integerValue + 1;
            seenCounts[title] = @(occurrence);
            title = [title stringByAppendingFormat:@"  (%lu)", (unsigned long)occurrence];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:nil
                                               keyEquivalent:@""];
        item.tag = (NSInteger)index;
        [popup.menu addItem:item];
    }

    if (foundDefaultWeight) {
        NSInteger itemIndex = [popup indexOfItemWithTag:defaultWeightIndex];
        if (itemIndex >= 0) {
            [popup selectItemAtIndex:itemIndex];
        }
    }

    alert.accessoryView = popup;

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            [weakSelf.window close];
            return;
        }
        NSInteger index = popup.selectedItem.tag;
        CTFontDescriptorRef descriptor =
            (__bridge CTFontDescriptorRef)descriptors[(NSUInteger)index];
        [weakSelf loadDescriptor:descriptor url:url];
    }];
}

- (void)loadDescriptor:(CTFontDescriptorRef)descriptor
                    url:(NSURL *)url {
    CTFontDescriptorRef retainedDescriptor = (CTFontDescriptorRef)CFRetain(descriptor);
    NSURL *copiedURL = [url copy];
    __weak typeof(self) weakSelf = self;

    dispatch_async(self.fontQueue, ^{
        GAFontDocument *document = [[GAFontDocument alloc] initWithDescriptor:retainedDescriptor
                                                                          URL:copiedURL];
        CFRelease(retainedDescriptor);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            if (document == nil) {
                [self showErrorWithTitle:@"Cannot Read Font"
                                 message:@"CoreText could not create this font."];
                return;
            }

            self.fontDocument = document;
            self.scanModel = [[GATextScanModel alloc] initWithFontDocument:document];
            self.scanDisplayPublished = NO;
            self.pendingWorkerText = nil;
            self.pendingWorkerSelections = nil;
            self.workerGeneration += 1;
            self.workerLastMultiText = nil;
            self.workerLastMultiSeeds = nil;
            self.multiScanInFlight = NO;
            self.workerText = nil;
            self.workerSelections = nil;
            self.workerTextGeneration = 0;
            [self.detailViewController setFontDocument:document];
            if (self.onFontLoaded != nil) {
                self.onFontLoaded(document.fontURL ?: url);
            }
            self.window.title = document.fullName;
            self.window.subtitle = document.fontURL.lastPathComponent ?: @"";
            self.titleFontNameField.stringValue = document.fullName;
            self.titleFontNameField.toolTip = document.fullName;
            [self.titleFontNameField invalidateIntrinsicContentSize];
            [self.sidebarViewController setGroups:@[]];
            if (self.sidebarViewController.text.length == 0) {
                [self.detailViewController setVariant:nil];
            } else {
                [self scheduleAnalysis];
            }
        });
    });
}

- (GACharacterGroup *)displayCopyOfCharacterGroup:(GACharacterGroup *)group {
    GACharacterGroup *copy = [[GACharacterGroup alloc] init];
    copy.text = group.text;
    copy.textRange = group.textRange;
    NSMutableArray<GAGlyphVariant *> *variants = [NSMutableArray array];
    for (GAGlyphVariant *variant in group.variants) {
        if (!variant.isLigature) [variants addObject:variant];
    }
    copy.variants = variants;
    return copy;
}

- (BOOL)rangeIntersectsSelectionRuns:(NSRange)range
                                 runs:(NSArray<GAGlyphSelectionRun *> *)runs {
    if (range.location == NSNotFound || range.length == 0) {
        return NO;
    }
    for (GAGlyphSelectionRun *run in runs) {
        if (NSIntersectionRange(range, run.range).length > 0) {
            return YES;
        }
    }
    return NO;
}

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

- (GACharacterGroup *)groupForSelectionRun:(GAGlyphSelectionRun *)run
                                  document:(GAFontDocument *)document {
    if (document == nil) {
        return nil;
    }
    GAGlyphSelection *selection = run.selection;
    GACharacterGroup *storedGroup =
        [document analyzeGlyphIDs:selection.glyphIDs].firstObject;
    GAGlyphVariant *base = storedGroup.variants.firstObject;
    if (base == nil) {
        return nil;
    }

    [base addFeatureSources:selection.featureSources];
    for (GAGlyphVariant *variant in storedGroup.variants) {
        variant.base = (variant == base);
    }
    base.base = YES;
    if (selection.ligature) {
        base.ligature = YES;
        base.sourceTextRange = run.range;
    }

    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = selection.sourceText;
    group.textRange = run.range;
    group.variants = storedGroup.variants;
    group.seeded = YES;
    return group;
}

- (NSArray<GACharacterGroup *> *)buildDisplayGroupsFromBaseGroups:(NSArray<GACharacterGroup *> *)groups
                                                             text:(NSString *)text
                                                       selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                                         document:(GAFontDocument *)document {
    NSMutableArray<GAGlyphSelectionRun *> *validSelections = [NSMutableArray array];
    NSMutableArray<GACharacterGroup *> *selectionGroups = [NSMutableArray array];
    for (GAGlyphSelectionRun *run in selections) {
        GACharacterGroup *selectionGroup = [self groupForSelectionRun:run
                                                             document:document];
        if (selectionGroup != nil) {
            [validSelections addObject:run];
            [selectionGroups addObject:selectionGroup];
        }
    }

    NSMutableArray<GAGlyphVariant *> *ligatureVariants = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            if (variant.isLigature && variant.sourceTextRange.length > 0 &&
                ![self rangeIntersectsSelectionRuns:variant.sourceTextRange
                                               runs:validSelections]) {
                [ligatureVariants addObject:variant];
            }
        }
    }

    NSMutableArray<GACharacterGroup *> *sourceGroups = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        if (GAGroupIsLineBreak(group) ||
            [self rangeIntersectsSelectionRuns:group.textRange
                                         runs:validSelections]) {
            continue;
        }
        [sourceGroups addObject:[self displayCopyOfCharacterGroup:group]];
    }
    [sourceGroups addObjectsFromArray:selectionGroups];
    [sourceGroups sortUsingComparator:^NSComparisonResult(GACharacterGroup *a,
                                                          GACharacterGroup *b) {
        if (a.textRange.location != b.textRange.location) {
            return a.textRange.location < b.textRange.location
                ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.textRange.length != b.textRange.length) {
            return a.textRange.length < b.textRange.length
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphVariant *> *> *byRange =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSValue *, NSNumber *> *spanLengths =
        [NSMutableDictionary dictionary];
    for (GAGlyphVariant *variant in ligatureVariants) {
        NSRange range = variant.sourceTextRange;
        if (range.location == NSNotFound || range.length == 0 ||
            NSMaxRange(range) > text.length) {
            continue;
        }
        NSValue *rangeValue = [NSValue valueWithRange:range];
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        if (variants == nil) {
            variants = [NSMutableArray array];
            byRange[rangeValue] = variants;
            NSUInteger spanLength = 0;
            for (GACharacterGroup *group in groups) {
                if (group.textRange.location != NSNotFound &&
                    NSIntersectionRange(group.textRange, range).length > 0) {
                    spanLength++;
                }
            }
            spanLengths[rangeValue] = @(spanLength);
        }
        [variants addObject:variant];
    }
    // The whole-text scan runs in ascending context length, so combination
    // groups are listed in that order after the character groups: every result
    // found later appears below the results found earlier.
    NSArray<NSValue *> *rangeOrder =
        [byRange.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSValue *a,
                                                                        NSValue *b) {
            NSUInteger lengthA = spanLengths[a].unsignedIntegerValue;
            NSUInteger lengthB = spanLengths[b].unsignedIntegerValue;
            if (lengthA != lengthB) {
                return lengthA < lengthB ? NSOrderedAscending : NSOrderedDescending;
            }
            NSRange rangeA = a.rangeValue;
            NSRange rangeB = b.rangeValue;
            if (rangeA.location != rangeB.location) {
                return rangeA.location < rangeB.location
                    ? NSOrderedAscending : NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
    NSMutableArray<GACharacterGroup *> *display = [sourceGroups mutableCopy];
    for (NSValue *rangeValue in rangeOrder) {
        NSRange range = rangeValue.rangeValue;
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        NSMutableArray<GAGlyphVariant *> *unique = [NSMutableArray array];
        NSMutableSet<NSString *> *glyphKeys = [NSMutableSet set];
        for (GAGlyphVariant *variant in variants) {
            if (variant.glyphKey.length == 0) continue;
            if ([glyphKeys containsObject:variant.glyphKey]) continue;
            [glyphKeys addObject:variant.glyphKey];
            [unique addObject:variant];
        }
        if (unique.count == 0) continue;

        GAGlyphVariant *base = unique.firstObject;
        for (GAGlyphVariant *variant in unique) variant.base = NO;
        base.base = YES;

        GACharacterGroup *ligatureGroup = [[GACharacterGroup alloc] init];
        ligatureGroup.text = [text substringWithRange:range];
        ligatureGroup.textRange = range;
        ligatureGroup.variants = unique;
        ligatureGroup.insertedLigature = YES;

        // A combination belongs after its last source character. Insert after
        // the last display item ending at this range's end so earlier results
        // with the same anchor stay ahead of later ones.
        NSUInteger insertIndex = display.count;
        NSUInteger rangeEnd = NSMaxRange(range);
        for (NSInteger index = (NSInteger)display.count - 1; index >= 0; index--) {
            GACharacterGroup *item = display[(NSUInteger)index];
            if (NSMaxRange(item.textRange) == rangeEnd) {
                insertIndex = (NSUInteger)index + 1;
                break;
            }
        }
        [display insertObject:ligatureGroup atIndex:insertIndex];
    }

    return display;
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

- (void)activateGlyphVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group {
    NSArray<NSNumber *> *scalars = variant.unicodeScalars;
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

    NSRange selectedRange = range;
    if (scalars.count > 0) {
        // Activation inserts a single source character. Copy still uses all
        // encodings of the glyph.
        NSString *replacement =
            GAStringFromUnicodeScalars(@[scalars.firstObject]);
        if (replacement.length == 0) {
            NSBeep();
            return;
        }
        [attributedText replaceCharactersInRange:range withString:replacement];
        selectedRange = NSMakeRange(range.location, replacement.length);
    } else {
        if (variant.glyphIDs.count == 0) {
            NSBeep();
            return;
        }
        NSString *sourceText = [text substringWithRange:range];
        GAGlyphSelection *selection = [[GAGlyphSelection alloc]
            initWithSourceText:sourceText
                      glyphIDs:variant.glyphIDs
                featureSources:variant.featureSources
                      ligature:variant.isLigature || range.length > 1];
        [attributedText addAttribute:GAGlyphSelectionAttributeName
                              value:selection
                              range:range];
    }

    [self.sidebarViewController
        selectGlyphKeyAfterNextReload:variant.glyphKey
                            textRange:selectedRange
                               scroll:GAPendingSelectionScrollSelectedToTopIfNeeded];
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

    if (self.fontDocument == nil || self.scanModel == nil) {
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
    if (![self.analysisText isEqualToString:text]) {
        self.scanDisplayPublished = NO;
    }
    dispatch_async(self.analysisQueue, ^{
        [self workerRun];
    });
}

/// Main-thread-only reset for an empty input.
- (void)clearScanDisplay {
    [self.sidebarViewController setGroups:@[]];
    [self.detailViewController setVariant:nil];
    self.displayGroups = @[];
    self.analysisText = @"";
    self.multiText = @"";
    self.multiGroups = @[];
    self.multiGroupSources = [NSMapTable weakToStrongObjectsMapTable];
    // The next text may equal the pre-clear text (for example "a" -> "" -> "a");
    // force a rebuild instead of trusting the stale worker-side signature.
    self.workerLastMultiText = nil;
    [self.detailViewController setMultiText:@"" groups:@[]];
}

#pragma mark - Worker (analysisQueue only)

- (void)workerRun {
    if (self.scanModel == nil || self.fontDocument == nil) {
        return;
    }
    while (YES) {
        NSString *text = nil;
        NSArray<GAGlyphSelectionRun *> *selections = nil;
        NSUInteger generation = 0;
        @synchronized (self) {
            if (self.pendingWorkerText != nil) {
                text = self.pendingWorkerText;
                selections = self.pendingWorkerSelections ?: @[];
                generation = self.workerGeneration;
                self.pendingWorkerText = nil;
                self.pendingWorkerSelections = nil;
            }
        }
        if (text != nil) {
            self.workerText = text;
            self.workerSelections = selections;
            self.workerTextGeneration = generation;
            if (![self.scanModel.text isEqualToString:text]) {
                [self.scanModel updateText:text];
            }
        }
        if (self.workerText == nil) {
            return;
        }

        // Single-character scans run inline on the model queue. They are short
        // and the display needs their base variants first. Only length-1
        // subitems are started here so a multi item is never marked Scanning
        // while another multi raw is still in flight; otherwise that item would
        // be lost and never dispatched.
        GATextScanSubitem *subitem = nil;
        while ((subitem = [self.scanModel startNextSubitemWithMaximumLength:1]) != nil) {
            GARawScanResult *result = [self.fontDocument rawScanContent:subitem.content];
            [self.scanModel completeSubitem:subitem result:result];
            @synchronized (self) {
                if (self.pendingWorkerText != nil) {
                    break;
                }
            }
        }

        [self publishWorkerSnapshotWithText:self.workerText
                                 selections:self.workerSelections
                                 generation:self.workerTextGeneration];
        @synchronized (self) {
            if (self.pendingWorkerText != nil) {
                continue;
            }
        }
        if (self.multiScanInFlight) {
            return;
        }
        GATextScanSubitem *multiSubitem = [self.scanModel startNextSubitem];
        if (multiSubitem != nil) {
            self.multiScanInFlight = YES;
            dispatch_async(self.multiScanQueue, ^{
                GARawScanResult *result =
                    [self.fontDocument rawScanContent:multiSubitem.content];
                dispatch_async(self.analysisQueue, ^{
                    self.multiScanInFlight = NO;
                    [self.scanModel completeSubitem:multiSubitem result:result];
                    [self workerRun];
                });
            });
            return;
        }

        [self publishWorkerSnapshotWithText:self.workerText
                                 selections:self.workerSelections
                                 generation:self.workerTextGeneration];
        @synchronized (self) {
            if (self.pendingWorkerText == nil) {
                return;
            }
        }
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
        [self buildDisplayGroupsFromBaseGroups:self.scanModel.groups
                                          text:text
                                    selections:selections
                                      document:self.fontDocument];
    NSArray<NSString *> *seeds = [self multiSeedSignatureForDisplay:display];
    BOOL textChanged = self.workerLastMultiText == nil ||
                       ![self.workerLastMultiText isEqualToString:text];
    BOOL seedsChanged = self.workerLastMultiSeeds == nil ||
                        ![self.workerLastMultiSeeds isEqualToArray:seeds];
    BOOL shouldUpdateMulti = (textChanged && [self singleCharacterScanComplete]) || seedsChanged;

    NSString *multiText = nil;
    NSArray<GACharacterGroup *> *multiGroups = nil;
    NSMapTable<GACharacterGroup *, GACharacterGroup *> *multiSources = nil;
    if (shouldUpdateMulti) {
        self.workerLastMultiText = text;
        self.workerLastMultiSeeds = seeds;
        [self buildMultiDisplayWithText:text
                                 groups:display
                              multiText:&multiText
                            multiGroups:&multiGroups
                                sources:&multiSources];
    }

    GAScanDisplaySnapshot *snapshot = [[GAScanDisplaySnapshot alloc] init];
    snapshot.display = display;
    snapshot.text = text;
    snapshot.generation = generation;
    snapshot.shouldUpdateMulti = shouldUpdateMulti;
    snapshot.multiText = multiText;
    snapshot.multiGroups = multiGroups;
    snapshot.multiGroupSources = multiSources;

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
    self.displayGroups = snapshot.display;
    self.analysisText = snapshot.text;
    if (!self.scanDisplayPublished) {
        self.scanDisplayPublished = YES;
        [self.sidebarViewController setGroups:snapshot.display];
    } else {
        [self.sidebarViewController applyStreamedGroups:snapshot.display];
    }
    if (snapshot.shouldUpdateMulti) {
        self.multiText = snapshot.multiText ?: @"";
        self.multiGroups = snapshot.multiGroups ?: @[];
        self.multiGroupSources = snapshot.multiGroupSources;
        [self.detailViewController setMultiText:self.multiText groups:self.multiGroups];
    }
}

/// Builds the text/group pair handed to the multi-character view. Missing
/// glyph groups are omitted here, before the view sees the text; the sidebar
/// keeps the original text and the full display list.
- (void)buildMultiDisplayWithText:(NSString *)text
                           groups:(NSArray<GACharacterGroup *> *)groups
                        multiText:(NSString *__autoreleasing *)outText
                      multiGroups:(NSArray<GACharacterGroup *> *__autoreleasing *)outGroups
                          sources:(NSMapTable<GACharacterGroup *, GACharacterGroup *> *__autoreleasing *)outSources {
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
        if (GAGroupIsMissing(group, text)) {
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
    if (outText) {
        *outText = [multiText copy];
    }
    if (outGroups) {
        *outGroups = multiGroups;
    }
    if (outSources) {
        *outSources = sources;
    }
}

- (BOOL)singleCharacterScanComplete {
    for (GATextScanGroup *group in self.scanModel.scanGroups) {
        if (group.length != 1) {
            continue;
        }
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *subitem in item.subitems) {
                if (subitem.state != GATextScanSubitemStateCompleted) {
                    return NO;
                }
            }
        }
    }
    return YES;
}

- (NSArray<NSString *> *)multiSeedSignatureForDisplay:(NSArray<GACharacterGroup *> *)display {
    NSMutableArray<NSString *> *signature = [NSMutableArray array];
    for (GACharacterGroup *group in display) {
        if (!group.seeded) {
            continue;
        }
        NSString *key = group.variants.firstObject.glyphKey ?: @"";
        [signature addObject:[NSString stringWithFormat:@"%lu:%lu:%@",
                              (unsigned long)group.textRange.location,
                              (unsigned long)group.textRange.length, key]];
    }
    return signature;
}

#pragma mark - Alerts

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    if (self.window != nil && self.window.isVisible) {
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

@end
