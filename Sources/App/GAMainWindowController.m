#import "GAMainWindowController.h"
#import "Views/GADetailViewController.h"
#import "Views/GASidebarViewController.h"
#import "Font/GAFontEngine.h"
#import "Font/GATextQueryModel.h"
#import "Font/GAUnicode.h"
#import "Font/GAFontResource.h"
#import "Views/GAVariationViewController.h"
#import "Views/GAInput.h"
#import "Font/GAFontFeatures.h"
#import <CoreText/CoreText.h>

static NSString *const GAOpeningSettingsKey = @"GAOpeningSettings";
static NSToolbarItemIdentifier const GAFontNameItem = @"GAFontName";
static NSToolbarItemIdentifier const GATextInputItem = @"GATextInput";
static NSToolbarItemIdentifier const GAVariationItem = @"GAVariation";
static const CGFloat GAMacOS26SidebarInputTopOffset = -8;

/// Prefer a non-C0/DEL mapping for input, keeping the first if none qualifies.
static NSNumber *GAInputScalarForGlyph(NSArray<NSNumber *> *scalars) {
    for (NSNumber *scalar in scalars) {
        uint32_t value = scalar.unsignedIntValue;
        if (value > 0x1F && value != 0x7F) {
            return scalar;
        }
    }
    return scalars.firstObject;
}

#pragma mark - Font title

@interface GAFontTitleField : NSTextField
@end

@implementation GAFontTitleField

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [self.window performZoom:self];
        return;
    }
    [super mouseDown:event];
}

@end

#pragma mark - Drop window

@interface GADropWindow : NSWindow
@property (nonatomic, copy, nullable) void (^onFontDrop)(NSURL *url);
@end

@implementation GADropWindow

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagShift);
    GAMainWindowController *controller = (id)self.windowController;
    if ([controller isKindOfClass:GAMainWindowController.class] &&
        controller.viewMode == GAViewModeMultiCharacter &&
        (flags & ~NSEventModifierFlagShift) ==
            (NSEventModifierFlagCommand | NSEventModifierFlagControl)) {
        NSString *key = event.charactersIgnoringModifiers;
        if ([key isEqualToString:@"+"] || [key isEqualToString:@"="]) {
            [controller adjustLineHeight:1];
            return YES;
        }
        if ([key isEqualToString:@"-"] || [key isEqualToString:@"_"]) {
            [controller adjustLineHeight:-1];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

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

#pragma mark - Main window

@interface GAPendingGlyphEdit : NSObject
@property (nonatomic, strong) GACharacterGroup *group;
@property (nonatomic, strong) GAGlyphVariant *variant;
@property (nonatomic) BOOL insert;
@end
@implementation GAPendingGlyphEdit
@end

static NSRange GAExactGlyphSourceRange(GAGlyphVariant *variant, GACharacterGroup *group) {
    return variant.isLigature ? variant.sourceTextRange : group.textRange;
}

@interface GAMainWindowController () <NSWindowDelegate, NSToolbarDelegate, NSPopoverDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) NSSplitViewItem *sidebarItem;
@property (nonatomic) CGFloat sidebarExpandedWidth;
@property (nonatomic, strong) NSView *toolbarInputContainer;
@property (nonatomic) BOOL sidebarTransitionInProgress;
@property (nonatomic, strong) GASidebarViewController *sidebarViewController;
@property (nonatomic, strong) GADetailViewController *detailViewController;
@property (nonatomic, strong, nullable) GAFontDocument *fontDocument;
@property (nonatomic, strong) NSTextField *titleFontNameField;
@property (nonatomic, strong) NSStackView *fontTitleView;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *pinnedSidebarTitleConstraints;
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
@property (nonatomic, strong) dispatch_queue_t glyphFilterQueue;
@property (nonatomic, strong, nullable) NSProgress *glyphFilterRequest;
@property (nonatomic, copy, nullable) NSString *pendingGlyphFilterTag;
@property (nonatomic, copy, readwrite, nullable) NSString *allGlyphFeatureTag;
@property (nonatomic, weak, nullable) GAFontDocument *appliedGlyphFilterDocument;
@property(nonatomic, strong, nullable) GATextQueryModel *queryModel;
@property (nonatomic, copy, nullable) NSString *pendingWorkerText;
@property (nonatomic, copy, nullable) NSArray<GAGlyphSelectionRun *> *pendingWorkerSelections;
@property (nonatomic, strong, nullable) GAFontDocument *pendingWorkerDocument;
@property (nonatomic) BOOL didFocusInitialField;
@property (nonatomic) BOOL opensFullScreen;
@property (nonatomic) NSSize windowedSize;
@property (nonatomic, strong, nullable) GAScanDisplaySnapshot *scanSnapshot;
@property (nonatomic) NSUInteger scanSnapshotGeneration;
@property (nonatomic, strong, nullable) GAPendingGlyphEdit *pendingGlyphEdit;
@property (nonatomic, strong, nullable) NSProgress *layoutLookup;
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic) BOOL verticalWriting;
@property(nonatomic, strong) GAFontFeatures *fontFeatures;
@property(nonatomic) BOOL underlined;
@property(nonatomic) BOOL struckThrough;
@property(nonatomic) BOOL outlined;
@property(nonatomic) NSWritingDirection baseWritingDirection;
@property(nonatomic, copy) NSString *typesettingLanguageTag;
@property (nonatomic, strong, nullable) GAGlyphVariant *lastSelectedVariant;
@end

@implementation GAMainWindowController {
    _Atomic(NSUInteger) _workerGeneration;
}

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
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

    self = [super initWithWindow:window];
    if (self) {
        NSDictionary *settings = [NSUserDefaults.standardUserDefaults dictionaryForKey:GAOpeningSettingsKey];
        _opensFullScreen = [settings[@"fullScreen"] boolValue];
        _viewMode = (GAViewMode)[settings[@"viewMode"] integerValue];
        _showsMetrics = settings[@"showsMetrics"] ? [settings[@"showsMetrics"] boolValue] : YES;
        _verticalWriting = [settings[@"vertical"] boolValue];
        _textAlignment = (NSTextAlignment)[settings[@"alignment"] integerValue];
        _underlined = [settings[@"underlined"] boolValue];
        _struckThrough = [settings[@"struckThrough"] boolValue];
        _outlined = [settings[@"outlined"] boolValue];
        _baseWritingDirection = settings[@"baseWritingDirection"]
            ? [settings[@"baseWritingDirection"] integerValue] : NSWritingDirectionNatural;
        _typesettingLanguageTag = settings[@"typesettingLanguageTag"] ?: @"";
        window.delegate = self;
        [self configureInterfaceWithWindow:window];
        [self.detailViewController applyOpeningSettings:settings];
        [self.detailViewController setShowsMetrics:_showsMetrics];
        [self.detailViewController setUnderlined:_underlined];
        [self.detailViewController setStruckThrough:_struckThrough];
        [self.detailViewController setOutlined:_outlined];
        [self.detailViewController setTextAlignment:_textAlignment];
        [self.detailViewController setWritingDirectionVertical:_verticalWriting];
        [self.detailViewController setBaseWritingDirection:_baseWritingDirection];
        [self.detailViewController setTypesettingLanguage:
            GAIdentifierForOpenTypeLanguage(_typesettingLanguageTag) ?: @""];
        [self setViewMode:_viewMode];

        __weak typeof(self) weakSelf = self;
        window.onFontDrop = ^(NSURL *url) {
            if (weakSelf.onFontDropRequest != nil) {
                weakSelf.onFontDropRequest(url);
            }
        };

        NSRect windowFrame = window.frame;
        windowFrame.size = settings[@"windowSize"]
            ? NSSizeFromString(settings[@"windowSize"]) : NSMakeSize(600, 400);
        [window setFrame:windowFrame display:NO];
        [window.contentView.superview layoutSubtreeIfNeeded];
        CGFloat sidebarWidth = settings[@"sidebarWidth"] ? [settings[@"sidebarWidth"] doubleValue] : 200;
        [self.splitViewController.splitView setPosition:sidebarWidth ofDividerAtIndex:0];
        if ([settings[@"sidebarHidden"] boolValue]) [self toggleSidebar];
        [window center];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                 name:GAInputBlankClickNotification object:nil];
}

- (void)configureInterfaceWithWindow:(NSWindow *)window {
    self.fontQueue = dispatch_queue_create("com.zonz.GlyphAtlas.font", DISPATCH_QUEUE_SERIAL);
    self.analysisQueue = dispatch_queue_create("com.zonz.GlyphAtlas.analysis",
                                               DISPATCH_QUEUE_SERIAL);
    self.glyphFilterQueue = dispatch_queue_create("com.zonz.GlyphAtlas.glyphFilter", DISPATCH_QUEUE_SERIAL);

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
    sidebarItem.collapseBehavior = NSSplitViewItemCollapseBehaviorPreferResizingSiblingsWithFixedSplitView;
    self.sidebarItem = sidebarItem;
    [split addSplitViewItem:sidebarItem];

    NSSplitViewItem *detailItem =
        [NSSplitViewItem splitViewItemWithViewController:self.detailViewController];
    if (GAUsesMacOS26Layout()) {
        if (@available(macOS 26.0, *)) detailItem.automaticallyAdjustsSafeAreaInsets = YES;
    }
    [split addSplitViewItem:detailItem];

    window.contentViewController = split;

    self.titleFontNameField = [GAFontTitleField labelWithString:@""];
    self.titleFontNameField.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleFontNameField.allowsExpansionToolTips = YES;
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
    self.variationButton.accessibilityLabel = NSLocalizedString(@"Variable", @"Variable font controls");
    self.fontTitleView = [NSStackView stackViewWithViews:@[self.variationButton, self.titleFontNameField]];
    self.fontTitleView.spacing = 0;
    [self.fontTitleView setCustomSpacing:5 afterView:self.variationButton];
    self.variationButton.hidden = YES;
    [self.titleFontNameField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    // AppKit synchronizes item changes between toolbars with the same identifier.
    NSString *toolbarIdentifier = [@"GATitleToolbar." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:toolbarIdentifier];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    if (@available(macOS 15.0, *)) toolbar.allowsDisplayModeCustomization = NO;
    window.toolbar = toolbar;
    window.toolbarStyle = GAUsesMacOS26Layout()
        ? NSWindowToolbarStyleUnified : NSWindowToolbarStyleUnifiedCompact;
    if (@available(macOS 26.0, *)) {
        [self.sidebarViewController enableScrollEdgeEffectForSplitViewItem:sidebarItem];
    }
    [self updateSidebarAccessoryTopInsetForHiddenSidebar:NO];

    __weak typeof(self) weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleInputBlankClick:)
                                              name:GAInputBlankClickNotification object:nil];
    self.sidebarViewController.onTextChanged = ^{
        [weakSelf scheduleAnalysis];
    };
    self.sidebarViewController.onInputUndoRedo = ^{
        GAMainWindowController *controller = weakSelf;
        controller.pendingGlyphEdit = nil;
        [controller scheduleAnalysis];
    };
    self.sidebarViewController.onSelectionChanged = ^(GAGlyphVariant *variant, BOOL quickReveal) {
        [weakSelf cancelLayoutLookup];
        weakSelf.lastSelectedVariant = variant;
        [weakSelf.detailViewController setVariant:variant];
        [weakSelf revealGlyphForVariant:variant quick:quickReveal];
    };
    self.sidebarViewController.onGlyphActivated = ^(GACharacterGroup *group,
                                                     GAGlyphVariant *variant, BOOL insert) {
        [weakSelf editGlyphVariant:variant inGroup:group insert:insert];
    };
    self.detailViewController.onAllGlyphDoubleClick = ^(GAAllGlyphEntry *entry) {
        [weakSelf appendAllGlyphEntry:entry];
    };
    self.detailViewController.onGlyphSelected = ^(NSArray<NSNumber *> *glyphIDs, NSRange range,
                                                   NSArray<NSNumber *> *leadingGlyphIDs, NSRange leadingRange) {
        [weakSelf selectLayoutGlyphIDs:glyphIDs multiRange:range
                       leadingGlyphIDs:leadingGlyphIDs leadingRange:leadingRange];
    };
}

#pragma mark - View actions

- (NSString *)inputText {
    return self.sidebarViewController.text;
}

- (void)replaceInputText:(NSString *)text {
    if (!GAEndInputEditingOutsideWindow(self.window)) return;
    [self.window makeKeyAndOrderFront:nil];
    [self.sidebarViewController replaceInputText:text];
}

- (void)revealGlyphForVariant:(GAGlyphVariant *)variant {
    [self revealGlyphForVariant:variant quick:NO];
}

- (void)revealGlyphForVariant:(GAGlyphVariant *)variant quick:(BOOL)quick {
    if (self.viewMode != GAViewModeAllGlyphs || variant.glyphIDs.count == 0) {
        return;
    }
    [self.detailViewController revealAllGlyphID:variant.glyphIDs.firstObject quick:quick];
}

- (NSArray<NSString *> *)allGlyphFeatureTags {
    return self.fontDocument.glyphFeatureTags ?: @[];
}

- (void)filterAllGlyphsByFeature:(NSString *)tag {
    [self.glyphFilterRequest cancel];
    self.glyphFilterRequest = nil;
    self.pendingGlyphFilterTag = tag;
    if (!tag) {
        self.allGlyphFeatureTag = nil;
        self.appliedGlyphFilterDocument = nil;
        [self.detailViewController setAllGlyphVisibleIDs:nil];
        [self revealGlyphForVariant:self.lastSelectedVariant];
        return;
    }
    GAFontDocument *document = self.fontDocument;
    NSProgress *request = [NSProgress discreteProgressWithTotalUnitCount:1];
    self.glyphFilterRequest = request;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.glyphFilterQueue, ^{
        NSIndexSet *outputs = [document glyphOutputsForFeatureTag:tag
                                                       cancelled:^BOOL { return request.cancelled; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || request.cancelled || self.glyphFilterRequest != request ||
                self.fontDocument != document)
                return;
            self.glyphFilterRequest = nil;
            self.pendingGlyphFilterTag = nil;
            // Keep a complete result for this font when the new query fails.
            if (!outputs && (!self.allGlyphFeatureTag || self.appliedGlyphFilterDocument == document))
                return;
            self.allGlyphFeatureTag = outputs ? tag : nil;
            self.appliedGlyphFilterDocument = outputs ? document : nil;
            [self.detailViewController setAllGlyphVisibleIDs:outputs];
            [self revealGlyphForVariant:self.lastSelectedVariant];
        });
    });
}

- (void)setViewMode:(GAViewMode)viewMode {
    [self cancelLayoutLookup];
    _viewMode = viewMode;
    self.detailViewController.viewMode = viewMode;
    [self revealGlyphForVariant:self.lastSelectedVariant];
}

- (void)selectLayoutGlyphIDs:(NSArray<NSNumber *> *)glyphIDs multiRange:(NSRange)range
              leadingGlyphIDs:(NSArray<NSNumber *> *)leadingGlyphIDs leadingRange:(NSRange)leadingRange {
    if (![self canEditFromScanSnapshotForText:self.sidebarViewController.text]) return;
    GAScanDisplaySnapshot *snapshot = self.scanSnapshot;
    GAFontDocument *document = self.fontDocument;
    if (!snapshot || !document) return;
    [self cancelLayoutLookup];
    NSRange source = NSMakeRange(NSNotFound, 0);
    NSRange leadingSource = NSMakeRange(NSNotFound, 0);
    for (GACharacterGroup *group in snapshot.multiGroups)
        if (NSIntersectionRange(group.textRange, range).length) {
            NSRange original = [snapshot sourceRangeForMultiGroup:group];
            if (leadingGlyphIDs.count && leadingRange.length < range.length &&
                NSLocationInRange(leadingRange.location, group.textRange) &&
                NSMaxRange(leadingRange) <= NSMaxRange(group.textRange)) {
                NSUInteger offset = leadingRange.location - group.textRange.location;
                leadingSource = NSMakeRange(original.location + offset, leadingRange.length);
            }
            if (source.location == NSNotFound) {
                source = original;
            } else {
                if (NSMaxRange(source) != original.location) {
                    // A missing component can leave a gap in the original
                    // text even when the preview shapes one visible cluster.
                    if (leadingSource.location == NSNotFound ||
                        ![self.sidebarViewController selectGlyphIDs:leadingGlyphIDs textRange:leadingSource])
                        [self.sidebarViewController selectBaseForTextRange:source];
                    return;
                }
                source.length += original.length;
            }
        }
    if (source.location == NSNotFound) return;
    if ([self.sidebarViewController selectGlyphIDs:glyphIDs textRange:source]) return;
    BOOL vertical = self.verticalWriting;
    NSWritingDirection direction = self.baseWritingDirection;
    NSString *languageTag = self.typesettingLanguageTag;
    NSArray *features = self.fontFeatures.replaySettings ?: @[];
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:1];
    self.layoutLookup = progress;
    dispatch_async(self.analysisQueue, ^{
        if (progress.cancelled) return;
        GAGlyphResolution *resolution = [document resolveGlyphIDs:glyphIDs textRange:source
            text:snapshot.text selections:snapshot.selections groups:snapshot.display
            vertical:vertical featureSettings:features
            baseWritingDirection:direction
            languageTag:languageTag
            cancelled:^BOOL { return progress.cancelled; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progress.cancelled || self.scanSnapshot != snapshot ||
                ![self canEditFromScanSnapshotForText:self.sidebarViewController.text] ||
                self.fontDocument != document || self.viewMode != GAViewModeMultiCharacter ||
                self.verticalWriting != vertical ||
                self.baseWritingDirection != direction ||
                ![self.typesettingLanguageTag isEqualToString:languageTag] ||
                ![(self.fontFeatures.replaySettings ?: @[]) isEqualToArray:features]) return;
            if (resolution)
                [self.sidebarViewController showGlyphResolution:resolution];
            else if (leadingSource.location == NSNotFound ||
                     ![self.sidebarViewController selectGlyphIDs:leadingGlyphIDs textRange:leadingSource])
                [self.sidebarViewController selectBaseForTextRange:source];
            if (self.layoutLookup == progress) self.layoutLookup = nil;
        });
    });
}

- (void)cancelLayoutLookup {
    [self.layoutLookup cancel];
    self.layoutLookup = nil;
}

- (void)toggleShowsMetrics {
    if (!GAViewModeSupportsMetrics(_viewMode)) return;
    _showsMetrics = !_showsMetrics;
    [self.detailViewController setShowsMetrics:_showsMetrics];
}

- (void)zoomIn {
    [self.detailViewController zoomIn];
}

- (void)zoomOut {
    [self.detailViewController zoomOut];
}

- (void)zoomMetricsIn {
    [self.detailViewController zoomBoundingBoxIn];
}

- (void)zoomMetricsOut {
    [self.detailViewController zoomBoundingBoxOut];
}

- (void)resetZoom {
    [self.detailViewController resetZoom];
}

- (void)saveOpeningSettings {
    NSMutableDictionary *settings = [self.detailViewController.currentPreviewSettings mutableCopy];
    BOOL fullScreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    NSSize windowSize = fullScreen ? self.windowedSize : self.window.frame.size;
    CGFloat sidebarWidth = self.sidebarHidden ? self.sidebarExpandedWidth
        : NSWidth(self.sidebarViewController.view.frame);
    [settings addEntriesFromDictionary:@{
        @"viewMode":@(self.viewMode), @"showsMetrics":@(self.showsMetrics),
        @"vertical":@(self.verticalWriting), @"alignment":@(self.textAlignment),
        @"underlined":@(self.underlined), @"struckThrough":@(self.struckThrough),
        @"outlined":@(self.outlined), @"baseWritingDirection":@(self.baseWritingDirection),
        @"typesettingLanguageTag":self.typesettingLanguageTag,
        @"windowSize":NSStringFromSize(windowSize), @"fullScreen":@(fullScreen),
        @"sidebarHidden":@(self.sidebarHidden),
        @"sidebarWidth":@(sidebarWidth),
    }];
    [NSUserDefaults.standardUserDefaults setObject:settings forKey:GAOpeningSettingsKey];
}

+ (void)restoreOpeningSettings {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:GAOpeningSettingsKey];
}

- (void)setUnderlined:(BOOL)enabled {
    _underlined = enabled;
    [self.detailViewController setUnderlined:enabled];
}

- (void)setStruckThrough:(BOOL)enabled {
    _struckThrough = enabled;
    [self.detailViewController setStruckThrough:enabled];
}

- (void)setOutlined:(BOOL)enabled {
    _outlined = enabled;
    [self.detailViewController setOutlined:enabled];
}

- (void)setBaseWritingDirection:(NSWritingDirection)direction {
    [self cancelLayoutLookup];
    _baseWritingDirection = direction;
    [self.detailViewController setBaseWritingDirection:direction];
}

- (BOOL)hasRightToLeftLanguages {
    return self.fontDocument.hasRightToLeftLanguages;
}

- (NSArray<NSString *> *)typesettingLanguageTags {
    return self.fontDocument.typesettingLanguageTags ?: @[];
}

- (void)setTypesettingLanguageTag:(NSString *)tag {
    NSString *identifier = GAIdentifierForOpenTypeLanguage(tag);
    if (tag.length && (!identifier || ![self.typesettingLanguageTags containsObject:tag])) return;
    [self cancelLayoutLookup];
    _typesettingLanguageTag = tag.copy;
    [self.detailViewController setTypesettingLanguage:identifier ?: @""];
}

- (void)adjustLineHeight:(NSInteger)steps {
    if (GAViewModeSupportsTextLayout(self.viewMode))
        [self.detailViewController adjustLineHeight:steps];
}

- (GAPreviewColors *)previewColors {
    return self.detailViewController.previewColors;
}

- (void)applyPreviewColorRepresentation:(NSDictionary<NSString *, NSData *> *)representation {
    [self.detailViewController applyPreviewColorRepresentation:representation];
}

- (void)setPreviewColor:(NSColor *)color forRole:(GAPreviewColorRole)role {
    [self.previewColors setColor:color forRole:role];
    [self.detailViewController refreshPreviewColors];
}

- (void)followSystemColors {
    [self.previewColors followSystem];
    [self.detailViewController refreshPreviewColors];
}

- (void)setTextAlignment:(NSTextAlignment)alignment {
    _textAlignment = alignment;
    [self.detailViewController setTextAlignment:alignment];
}

- (void)setVerticalWriting:(BOOL)vertical {
    [self cancelLayoutLookup];
    _verticalWriting = vertical;
    [self.detailViewController setWritingDirectionVertical:vertical];
}

- (void)applyFontFeatureChoices {
    [self cancelLayoutLookup];
    [self.detailViewController setFeatureSettings:self.fontFeatures.settings ?: @[]];
}

- (void)appendAllGlyphEntry:(GAAllGlyphEntry *)entry {
    NSNumber *scalar = GAInputScalarForGlyph(entry.unicodeScalars);
    BOOL needsSelection = scalar == nil;
    if (scalar == nil) {
        // The clicked glyph has no Unicode mapping of its own. Borrow the first
        // mapping from its replacement set and pin the clicked glyph with a run.
        NSArray<GAGlyphVariant *> *variants =
            [self.fontDocument variantsForGlyphIDs:@[entry.glyphID] cancelled:nil];
        for (GAGlyphVariant *variant in variants) {
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
    GAGlyphSelection *selection;
    if (needsSelection) {
        selection = [[GAGlyphSelection alloc] initWithSourceText:string
                                                        glyphIDs:@[entry.glyphID]
                                                  featureSources:@[]
                                                        ligature:NO];
    }
    [self.sidebarViewController appendInputString:string
                                       selection:selection
                               selectingGlyphIDs:@[entry.glyphID]
                                      actionName:NSLocalizedString(@"Add Glyph", @"Undo action for adding a glyph")];
}

#pragma mark - Window and input focus

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    self.windowedSize = self.window.frame.size;
    self.opensFullScreen = NO;
}

- (BOOL)windowShouldZoom:(NSWindow *)window toFrame:(NSRect)newFrame {
    NSEvent *event = NSApp.currentEvent;
    BOOL doubleClick = (event.type == NSEventTypeLeftMouseDown ||
                        event.type == NSEventTypeLeftMouseUp) && event.clickCount == 2;
    return !(doubleClick && event.window == window &&
             [self.detailViewController containsAllGlyphAtWindowPoint:event.locationInWindow]);
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self.sidebarViewController setGlyphListDimmed:NO];
    if (self.didFocusInitialField) {
        return;
    }
    self.didFocusInitialField = YES;
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

- (BOOL)isSidebarHidden {
    return self.sidebarItem.isCollapsed;
}

- (void)pinSidebarTitleAtFrame:(NSRect)frame {
    NSView *sidebar = self.sidebarViewController.view;
    [sidebar addSubview:self.fontTitleView];
    self.fontTitleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pinnedSidebarTitleConstraints = @[
        [self.fontTitleView.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:NSMinX(frame)],
        [self.fontTitleView.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:GATopOffsetInView(sidebar, frame)],
        [self.fontTitleView.heightAnchor constraintEqualToConstant:NSHeight(frame)],
        [self.fontTitleView.widthAnchor constraintLessThanOrEqualToAnchor:sidebar.widthAnchor
                                                               constant:-NSMinX(frame)],
    ];
    [NSLayoutConstraint activateConstraints:self.pinnedSidebarTitleConstraints];
}

- (void)unpinSidebarTitle {
    [NSLayoutConstraint deactivateConstraints:self.pinnedSidebarTitleConstraints];
    self.pinnedSidebarTitleConstraints = nil;
    [self.fontTitleView removeFromSuperview];
}

- (void)toggleSidebar {
    if (self.sidebarTransitionInProgress) return;
    BOOL hidden = !self.sidebarHidden;
    NSWindow *window = self.window;
    NSRange selection = self.sidebarViewController.inputSelectionRange;
    if (selection.location != NSNotFound && ![window makeFirstResponder:nil]) return;

    self.sidebarTransitionInProgress = YES;
    if (self.variationPopover.shown && !self.variationPopover.detached)
        [self.variationPopover close];

    BOOL animate = window.isVisible && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    NSRect titleFrame = NSZeroRect;
    if (hidden) {
        [window.contentView.superview layoutSubtreeIfNeeded];
        self.sidebarExpandedWidth = NSWidth(self.sidebarViewController.view.frame);
        titleFrame = [self.sidebarViewController.view convertRect:self.fontTitleView.bounds
                                                       fromView:self.fontTitleView];
        [self.sidebarViewController setSidebarContentTopPinned:YES];
    }
    window.toolbarStyle = hidden || GAUsesMacOS26Layout()
        ? NSWindowToolbarStyleUnified : NSWindowToolbarStyleUnifiedCompact;
    [self updateSidebarAccessoryTopInsetForHiddenSidebar:hidden];
    [self.detailViewController setUsesToolbarSafeArea:hidden];
    if (!hidden) [self unpinSidebarTitle];
    [self updateToolbarForHiddenSidebar:hidden];
    if (hidden) [self pinSidebarTitleAtFrame:titleFrame];
    [window.contentView.superview layoutSubtreeIfNeeded];
    __weak typeof(self) weakSelf = self;
    void (^finish)(void) = ^{
        GAMainWindowController *controller = weakSelf;
        if (!controller.sidebarTransitionInProgress) return;
        NSWindow *currentWindow = controller.window;
        NSRange restoreSelection = selection;
        if (!hidden) {
            if (controller.sidebarViewController.inputFocused) {
                restoreSelection = controller.sidebarViewController.inputSelectionRange;
                [currentWindow makeFirstResponder:nil];
            }
            [controller.sidebarViewController setSidebarContentTopPinned:NO];
        }
        controller.sidebarTransitionInProgress = NO;
        if (currentWindow.firstResponder == currentWindow) {
            if (restoreSelection.location != NSNotFound) {
                [currentWindow.contentView.superview layoutSubtreeIfNeeded];
                [controller.sidebarViewController restoreInputSelection:restoreSelection];
            } else if (!hidden) {
                [controller.sidebarViewController focusGlyphList];
            }
        }
    };
    if (animate) {
        [NSAnimationContext runAnimationGroup:^(__unused NSAnimationContext *context) {
            self.sidebarItem.animator.collapsed = hidden;
        } completionHandler:finish];
    } else {
        self.sidebarItem.collapsed = hidden;
        finish();
    }
}

- (void)updateToolbarForHiddenSidebar:(BOOL)hidden {
    NSWindow *window = self.window;
    NSToolbar *toolbar = window.toolbar;
    if (hidden && !self.toolbarInputContainer) {
        self.toolbarInputContainer = [NSView new];
        [self.toolbarInputContainer.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
    }
    [self.sidebarViewController useInputInToolbarContainer:hidden ? self.toolbarInputContainer : nil];
    if (hidden) [self.sidebarViewController setToolbarInputPlaceholder:self.titleFontNameField.stringValue];
    while (toolbar.items.count > 0) [toolbar removeItemAtIndex:toolbar.items.count - 1];
    if (hidden) {
        [toolbar insertItemWithItemIdentifier:GATextInputItem atIndex:0];
        [toolbar insertItemWithItemIdentifier:NSToolbarFlexibleSpaceItemIdentifier atIndex:1];
        [self updateToolbarVariationItem];
    } else {
        [toolbar insertItemWithItemIdentifier:GAFontNameItem atIndex:0];
        [toolbar insertItemWithItemIdentifier:NSToolbarSidebarTrackingSeparatorItemIdentifier atIndex:1];
    }
}

- (void)updateSidebarAccessoryTopInsetForHiddenSidebar:(BOOL)hidden {
    if (!GAUsesMacOS26Layout()) return;
    // Move the accessory's safe area, rather than clipping its input above
    // the accessory. Keep the detail pane's inherited top safe area unchanged.
    CGFloat offset = hidden ? 0 : GAMacOS26SidebarInputTopOffset;
    self.splitViewController.view.additionalSafeAreaInsets = NSEdgeInsetsMake(offset, 0, 0, 0);
    self.detailViewController.view.additionalSafeAreaInsets = NSEdgeInsetsMake(-offset, 0, 0, 0);
}

- (void)updateToolbarVariationItem {
    NSToolbar *toolbar = self.window.toolbar;
    BOOL hasItem = [toolbar.items.firstObject.itemIdentifier isEqualToString:GAVariationItem];
    BOOL needsItem = self.fontResource.axes.count > 0;
    if (needsItem && !hasItem) {
        [toolbar insertItemWithItemIdentifier:GAVariationItem atIndex:0];
        if (@available(macOS 26.0, *))
            [toolbar insertItemWithItemIdentifier:NSToolbarSpaceItemIdentifier atIndex:1];
    }
    if (!needsItem && hasItem) {
        if (@available(macOS 26.0, *)) [toolbar removeItemAtIndex:1];
        [toolbar removeItemAtIndex:0];
    }
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[GAFontNameItem, NSToolbarSidebarTrackingSeparatorItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[GAFontNameItem, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             GATextInputItem, GAVariationItem, NSToolbarSpaceItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSSet<NSToolbarItemIdentifier> *)toolbarImmovableItemIdentifiers:(NSToolbar *)toolbar {
    return [NSSet setWithArray:[self toolbarAllowedItemIdentifiers:toolbar]];
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
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    if ([itemIdentifier isEqualToString:GATextInputItem]) {
        item.label = NSLocalizedString(@"Enter text", @"Enter text");
        item.view = self.toolbarInputContainer;
        item.bordered = YES;
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        return item;
    }
    if ([itemIdentifier isEqualToString:GAVariationItem]) {
        item.label = self.variationButton.accessibilityLabel;
        item.image = self.variationButton.image;
        item.target = self;
        item.action = @selector(showVariations:);
        item.bordered = YES;
        if (@available(macOS 14.0, *)) return item;
        NSButton *button = [NSButton buttonWithImage:item.image target:self action:item.action];
        button.bezelStyle = NSBezelStyleToolbar;
        button.accessibilityLabel = item.label;
        item.view = button;
        return item;
    }
    if (![itemIdentifier isEqualToString:GAFontNameItem]) return nil;
    item.label = NSLocalizedString(@"Font Name", @"Font Name");
    item.view = self.fontTitleView;
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
    NSURL *fileReference = url.URLByResolvingSymlinksInPath.fileReferenceURL;
    CFArrayRef array = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    NSArray *descriptors = array ? CFBridgingRelease(array) : @[];
    if (descriptors.count == 0) {
        [self showErrorWithTitle:NSLocalizedString(@"Cannot Open Font", @"Cannot Open Font")
                         message:NSLocalizedString(@"This file does not contain a font that CoreText can read.", @"Cannot read font file")];
        return;
    }
    NSArray<GAFontResource *> *resources = [GAFontResource resourcesFromDescriptors:descriptors];
    if (resources.count == 1) {
        [self loadResource:resources.firstObject url:url fileReference:fileReference];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Choose Font Style", @"Choose Font Style");
    alert.informativeText = [NSString localizedStringWithFormat:
        NSLocalizedString(@"“%@” contains %lu styles.", @"Number of styles in the font collection"),
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
        [weakSelf loadResource:popup.selectedItem.representedObject url:url fileReference:fileReference];
    }];
}

- (void)loadResource:(GAFontResource *)resource url:(NSURL *)url fileReference:(NSURL *)fileReference {
    [self.variationPopover close];
    self.fontResource = resource;
    self.variationCoordinates = resource.defaultCoordinates;
    self.variationButton.hidden = resource.axes.count == 0;
    if (self.sidebarHidden) [self updateToolbarVariationItem];
    [self loadDescriptor:resource.defaultDescriptor url:url fileReference:fileReference preservingSelection:NO];
}

#pragma mark - Variation controls

- (void)showVariations:(id)sender {
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
        [self loadDescriptor:descriptor url:self.fontURL fileReference:self.fontFileReference preservingSelection:YES];
        CFRelease(descriptor);
    };
    self.variationPopover = [[NSPopover alloc] init];
    controller.title = @"";
    self.variationPopover.delegate = self;
    self.variationPopover.behavior = NSPopoverBehaviorTransient;
    self.variationPopover.contentViewController = controller;
    if (@available(macOS 14.0, *)) {
        if ([sender isKindOfClass:NSToolbarItem.class]) {
            [self.variationPopover showRelativeToToolbarItem:sender];
            return;
        }
    }
    NSView *anchor = sender;
    [self.variationPopover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
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
    if (self.sidebarTransitionInProgress || self.sidebarViewController.inputFocused) return;
    [self.sidebarViewController focusGlyphList];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self cancelLayoutLookup];
    if (notification.object == self.window) {
        self.sidebarTransitionInProgress = NO;
        [self.glyphFilterRequest cancel];
        self.glyphFilterRequest = nil;
        self.pendingGlyphFilterTag = nil;
        @synchronized (self) {
            self.fontLoadGeneration += 1;
        }
        [self invalidateWorkerQueries];
        self.pendingGlyphEdit = nil;
        [self.variationPopover close];
    }
}

#pragma mark - Font loading

- (void)loadDescriptor:(CTFontDescriptorRef)descriptor
                   url:(NSURL *)url fileReference:(NSURL *)fileReference
   preservingSelection:(BOOL)preserve {
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
            [self cancelLayoutLookup];
            self.pendingGlyphEdit = nil;
            self.fontDocument = document;
            self->_fontFileReference = fileReference;
            if (!document.hasRightToLeftLanguages)
                [self setBaseWritingDirection:NSWritingDirectionNatural];
            NSString *languageTag = self.typesettingLanguageTag;
            if (![document.typesettingLanguageTags containsObject:languageTag] ||
                !GAIdentifierForOpenTypeLanguage(languageTag)) languageTag = @"";
            [self setTypesettingLanguageTag:languageTag];
            if (!preserve) self.fontFeatures = [[GAFontFeatures alloc] initWithFont:document.fontBox.font];
            [self applyFontFeatureChoices];
            [self invalidateWorkerQueries];
            // Swap all model-owned state on its queue after the old batch yields.
            dispatch_async(self.analysisQueue, ^{
                BOOL (^cancelled)(void) = ^BOOL {
                    @synchronized (self) { return request != self.fontLoadGeneration; }
                };
                if (cancelled()) return;
                if (preserve && self.queryModel != nil) {
                    if (![self.queryModel updateFontDocument:document cancelled:cancelled]) return;
                } else {
                    self.queryModel = [[GATextQueryModel alloc] initWithFontDocument:document];
                }
                self.workerFontDocument = document;
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
            NSString *filter = self.pendingGlyphFilterTag ?: self.allGlyphFeatureTag;
            if (preserve && (filter.length || self.allGlyphFeatureTag.length)) {
                NSArray<NSString *> *tags = self.allGlyphFeatureTags;
                if (self.allGlyphFeatureTag.length && ![tags containsObject:self.allGlyphFeatureTag])
                    [self filterAllGlyphsByFeature:nil];
                if (filter.length && ![tags containsObject:filter])
                    filter = self.allGlyphFeatureTag;
            }
            if (!preserve || filter || self.allGlyphFeatureTag || self.glyphFilterRequest)
                [self filterAllGlyphsByFeature:preserve ? filter : nil];
            if (!preserve && self.onFontLoaded != nil) self.onFontLoaded(document.fontURL ?: url);
            NSString *displayName = self.fontResource.usesFamilyName ? self.fontResource.name : document.fullName;
            self.window.title = displayName;
            self.window.subtitle = document.fontURL.lastPathComponent ?: @"";
            [self.sidebarViewController setToolbarInputPlaceholder:displayName];
            if (![self.titleFontNameField.stringValue isEqualToString:displayName]) {
                self.titleFontNameField.stringValue = displayName;
                [self.titleFontNameField invalidateIntrinsicContentSize];
                // The native expansion region can stay cached if the title's bounds do not change.
                if (self.titleFontNameField.window == self.window)
                    [self.window invalidateCursorRectsForView:self.titleFontNameField];
            }
            if (!preserve) [self.sidebarViewController clearGroups];
            if (selected != nil) {
                GAGlyphVariant *updated = [document rebindVariant:selected content:self.sidebarViewController.selectedGlyphSourceText];
                self.lastSelectedVariant = updated;
                [self.detailViewController setVariant:updated];
            }
            if (self.sidebarViewController.text.length == 0) {
                [self.detailViewController setVariant:nil];
            }
            if (!preserve && self.opensFullScreen && self.window.isVisible) {
                self.opensFullScreen = NO;
                [self.window toggleFullScreen:nil];
            }
        });
    });
}

#pragma mark - Selection runs and activation

- (NSArray<GAGlyphSelectionRun *> *)selectionRunsInAttributedText:(NSMutableAttributedString *)text
                                                   changedRanges:(NSArray<NSValue *> **)changedRanges {
    NSMutableArray<GAGlyphSelectionRun *> *runs = [NSMutableArray array];
    NSMutableArray<NSValue *> *rangesToClear = [NSMutableArray array];
    NSMutableArray<GAGlyphSelectionRun *> *trimmedRuns = [NSMutableArray array];
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
            [rangesToClear addObject:[NSValue valueWithRange:range]];
            return;
        }
        GAGlyphSelection *selection = value;
        if (selection.sourceText.length == 0 || selection.glyphIDs.count == 0) {
            [rangesToClear addObject:[NSValue valueWithRange:range]];
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

            NSRange match;
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
                [rangesToClear addObject:[NSValue valueWithRange:range]];
                return;
            }
        }

        // The user edited inside the run. The stored source text no longer
        // matches this range, so dissolve the run instead of guessing.
        [rangesToClear addObject:[NSValue valueWithRange:range]];
    }];

    for (NSValue *value in rangesToClear) {
        [text removeAttribute:GAGlyphSelectionAttributeName
                        range:value.rangeValue];
    }
    for (GAGlyphSelectionRun *run in trimmedRuns) {
        [text addAttribute:GAGlyphSelectionAttributeName
                     value:run.selection
                     range:run.range];
    }
    *changedRanges = rangesToClear;
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
/// contributes its preferred input scalar; an unencoded glyph contributes the
/// existing source text and a run through `outSelection`.
/// The caller must provide a variable to receive the optional selection.
- (NSString *)activationPayloadForVariant:(GAGlyphVariant *)variant
                               sourceText:(NSString *)sourceText
                                selection:(GAGlyphSelection **)outSelection {
    NSArray<NSNumber *> *scalars = variant.unicodeScalars;
    if (variant.glyphIDs.count == 1 && scalars.count > 0) {
        NSString *replacement =
            GAStringFromUnicodeScalars(@[GAInputScalarForGlyph(scalars)]);
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

- (BOOL)canEditFromScanSnapshotForText:(NSString *)text {
    return self.scanSnapshotGeneration == self.workerGeneration &&
        [self.scanSnapshot.text isEqualToString:text];
}

- (void)deferGlyphEditForVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group
                         insert:(BOOL)insert {
    GAPendingGlyphEdit *edit = [[GAPendingGlyphEdit alloc] init];
    edit.group = group;
    edit.variant = variant;
    edit.insert = insert;
    self.pendingGlyphEdit = edit;
}

/// Resolve against the new rows while the sidebar still has the old source map.
- (GAPendingGlyphEdit *)resolvedGlyphEditInSnapshot:(GAScanDisplaySnapshot *)snapshot {
    GAPendingGlyphEdit *edit = self.pendingGlyphEdit;
    self.pendingGlyphEdit = nil;
    if (!edit) return nil;

    NSRange source = GAExactGlyphSourceRange(edit.variant, edit.group);
    if (source.location == NSNotFound || !source.length ||
        NSMaxRange(source) > self.scanSnapshot.text.length) {
        return nil;
    }
    NSRange mapped = [self.sidebarViewController currentInputRangeForDisplayedRange:source];
    if (mapped.location == NSNotFound || NSMaxRange(mapped) > snapshot.text.length ||
        ![[self.scanSnapshot.text substringWithRange:source]
            isEqualToString:[snapshot.text substringWithRange:mapped]]) {
        return nil;
    }

    GAPendingGlyphEdit *match;
    for (GACharacterGroup *group in snapshot.display) {
        if (!NSIntersectionRange(group.textRange, mapped).length ||
            group.seeded != edit.group.seeded ||
            group.insertedLigature != edit.group.insertedLigature) continue;
        for (GAGlyphVariant *variant in group.variants) {
            if (variant.isLigature != edit.variant.isLigature ||
                !NSEqualRanges(GAExactGlyphSourceRange(variant, group), mapped) ||
                ![variant.glyphIDs isEqualToArray:edit.variant.glyphIDs]) continue;
            if (match) return nil;
            match = [[GAPendingGlyphEdit alloc] init];
            match.group = group;
            match.variant = variant;
            match.insert = edit.insert;
        }
    }
    return match;
}

- (void)editGlyphVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group insert:(BOOL)insert {
    NSAttributedString *currentText = self.sidebarViewController.attributedText;
    NSString *text = currentText.string;
    if (![self canEditFromScanSnapshotForText:text]) {
        [self deferGlyphEditForVariant:variant inGroup:group insert:insert];
        return;
    }
    NSRange range = [self sourceRangeForVariant:variant inGroup:group text:text];
    if (range.location == NSNotFound || !range.length || NSMaxRange(range) > text.length) {
        NSBeep();
        return;
    }

    GAGlyphSelection *selection;
    NSString *payload = [self activationPayloadForVariant:variant sourceText:[text substringWithRange:range]
                                               selection:&selection];
    if (payload == nil) {
        NSBeep();
        return;
    }
    NSMutableAttributedString *attributedText = [currentText mutableCopy];
    if (insert) {
        NSMutableAttributedString *inserted = [[NSMutableAttributedString alloc] initWithString:payload];
        if (selection) {
            [inserted addAttribute:GAGlyphSelectionAttributeName value:selection
                             range:NSMakeRange(0, inserted.length)];
        }
        // Shift insertion keeps the current selection.
        [attributedText insertAttributedString:inserted atIndex:NSMaxRange(range)];
    } else {
        NSRange removalRange = [self fullSelectionRangeCoveringRange:range inAttributedText:attributedText];
        if (removalRange.location != NSNotFound && removalRange.length > 0 &&
            NSMaxRange(removalRange) <= attributedText.length) {
            [attributedText removeAttribute:GAGlyphSelectionAttributeName range:removalRange];
        }
        if (selection) {
            [attributedText addAttribute:GAGlyphSelectionAttributeName value:selection range:range];
        } else {
            [attributedText replaceCharactersInRange:range withString:payload];
            range.length = payload.length;
        }
    }
    NSString *actionName = insert
        ? NSLocalizedString(@"Add Glyph", @"Undo action for adding a glyph")
        : NSLocalizedString(@"Replace Glyph", @"Undo action for replacing a glyph");
    if (![self.sidebarViewController commitGlyphInput:attributedText actionName:actionName]) return;
    if (!insert) {
        [self.sidebarViewController selectGlyphIDsAfterNextReload:variant.glyphIDs textRange:range
            scroll:GAPendingSelectionScrollSelectedToTopIfNeeded];
    }
    [self scheduleAnalysis];
}

#pragma mark - Analysis

- (NSUInteger)workerGeneration {
    return _workerGeneration;
}

- (void)invalidateWorkerQueries {
    @synchronized (self) {
        self.pendingWorkerText = nil;
        self.pendingWorkerSelections = nil;
        self.pendingWorkerDocument = nil;
        _workerGeneration += 1;
    }
}

- (void)scheduleAnalysis {
    [self cancelLayoutLookup];
    NSMutableAttributedString *attributedText =
        [self.sidebarViewController.attributedText mutableCopy];
    NSArray<NSValue *> *changedRanges;
    NSArray<GAGlyphSelectionRun *> *selections =
        [self selectionRunsInAttributedText:attributedText
                             changedRanges:&changedRanges];
    if (changedRanges.count) {
        [self.sidebarViewController updateGlyphSelectionsFromText:attributedText ranges:changedRanges];
    }
    NSString *text = attributedText.string;

    if (self.fontDocument == nil) {
        return;
    }

    @synchronized (self) {
        self.pendingWorkerText = text;
        self.pendingWorkerSelections = selections;
        self.pendingWorkerDocument = self.fontDocument;
        self->_workerGeneration += 1;
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
    [self cancelLayoutLookup];
    self.pendingGlyphEdit = nil;
    self.scanSnapshot = nil;
    [self.sidebarViewController clearGroups];
    [self.detailViewController setVariant:nil];
    [self.detailViewController setMultiText:@"" groups:@[] omissions:NSIndexSet.indexSet];
}

#pragma mark - Worker (analysisQueue only)

- (void)workerRun {
    if (!self.queryModel || !self.workerFontDocument)
        return;
    while (YES) @autoreleasepool {
        NSString *text;
        NSArray<GAGlyphSelectionRun *> *selections;
        NSUInteger generation;
        @synchronized (self) {
            if (self.pendingWorkerDocument != self.workerFontDocument)
                return;
            text = self.pendingWorkerText;
            selections = self.pendingWorkerSelections ?: @[];
            generation = self->_workerGeneration;
            self.pendingWorkerText = nil;
            self.pendingWorkerSelections = nil;
            self.pendingWorkerDocument = nil;
        }
        if (!text)
            return;
        BOOL (^cancelled)(void) = ^BOOL {
            return generation != self->_workerGeneration;
        };
        if ([self.queryModel analyzeText:text selections:selections cancelled:cancelled])
            [self publishWorkerSnapshotWithText:text selections:selections generation:generation
                                       cancelled:cancelled];
    }
}

- (void)publishWorkerSnapshotWithText:(NSString *)text
                           selections:(NSArray<GAGlyphSelectionRun *> *)selections
                           generation:(NSUInteger)generation
                            cancelled:(BOOL (^)(void))cancelled {
    if (cancelled())
        return;
    NSArray<GACharacterGroup *> *display =
        GABuildDisplayGroups(self.queryModel.groups, text, selections, self.workerFontDocument,
                             cancelled);
    if (!display)
        return;
    GAScanDisplaySnapshot *snapshot = GABuildScanDisplaySnapshot(text, display, cancelled);
    if (!snapshot || cancelled())
        return;
    snapshot.selections = selections;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyScanSnapshot:snapshot generation:generation];
    });
}

- (void)applyScanSnapshot:(GAScanDisplaySnapshot *)snapshot generation:(NSUInteger)generation {
    if (self.fontDocument == nil || generation != self.workerGeneration ||
        ![snapshot.text isEqualToString:self.sidebarViewController.text]) {
        return;
    }
    [self cancelLayoutLookup];
    GAPendingGlyphEdit *edit = [self resolvedGlyphEditInSnapshot:snapshot];
    self.scanSnapshot = snapshot;
    self.scanSnapshotGeneration = generation;
    [self.sidebarViewController updateGroups:snapshot.display sourceText:snapshot.text
                                  fontDocument:self.fontDocument];
    [self.detailViewController setMultiText:snapshot.multiText groups:snapshot.multiGroups
                                  omissions:snapshot.multiOmissions];
    if (edit) {
        [self editGlyphVariant:edit.variant inGroup:edit.group insert:edit.insert];
    }
}

#pragma mark - Errors

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];
    __weak typeof(self) weakSelf = self;
    void (^dismiss)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn && weakSelf.fontDocument == nil) {
            [weakSelf.window close];
        }
    };
    if (self.window != nil && self.window.isVisible) {
        [alert beginSheetModalForWindow:self.window completionHandler:dismiss];
    } else {
        dismiss([alert runModal]);
    }
}

@end
