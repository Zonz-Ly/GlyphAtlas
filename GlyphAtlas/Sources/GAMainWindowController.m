#import "GAMainWindowController.h"
#import "GADetailViewController.h"
#import "GASidebarViewController.h"
#import "GAFontEngine.h"
#import "GAUnicode.h"
#import "GAFontTypes.h"
#import <CoreText/CoreText.h>
#import <math.h>

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

#pragma mark - Main window

@interface GAMainWindowController () <NSWindowDelegate, NSToolbarDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) GASidebarViewController *sidebarViewController;
@property (nonatomic, strong) GADetailViewController *detailViewController;
@property (nonatomic, strong, nullable) GAFontDocument *fontDocument;
@property (nonatomic, strong) NSMutableArray<GACharacterGroup *> *seedGroups;
@property (nonatomic, strong) NSTextField *titleFontNameField;
@property (nonatomic, strong) dispatch_queue_t fontQueue;
@property (nonatomic, strong) dispatch_queue_t analysisQueue;
@property (nonatomic) NSUInteger loadGeneration;
@property (nonatomic) NSUInteger analysisGeneration;
@property (nonatomic, strong, nullable) NSProgress *analysisProgress;
@property (nonatomic) BOOL didFocusInitialField;
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
    window.title = @"";
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
    self.fontQueue = dispatch_queue_create("com.zonz.GlyphAtlas.font", DISPATCH_QUEUE_SERIAL);
    self.analysisQueue = dispatch_queue_create("com.zonz.GlyphAtlas.analysis",
                                               DISPATCH_QUEUE_SERIAL);

    self.sidebarViewController = [[GASidebarViewController alloc] init];
    self.detailViewController = [[GADetailViewController alloc] init];
    self.seedGroups = [NSMutableArray array];

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
    toolbar.allowsUserCustomization = NO;
    toolbar.autosavesConfiguration = NO;
    window.toolbar = toolbar;
    window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;

    __weak typeof(self) weakSelf = self;
    self.sidebarViewController.onTextChanged = ^{
        [weakSelf scheduleAnalysis];
    };
    self.sidebarViewController.onSelectionChanged = ^(GAGlyphVariant *variant) {
        [weakSelf.detailViewController setVariant:variant];
    };
    self.sidebarViewController.onGlyphActivated = ^(GACharacterGroup *group,
                                                    GAGlyphVariant *variant) {
        [weakSelf activateGlyphVariant:variant inGroup:group];
    };
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
    if (url == nil) {
        return;
    }
    self.loadGeneration += 1;
    NSUInteger generation = self.loadGeneration;

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
        [self loadDescriptor:descriptor url:url generation:generation];
        return;
    }

    [self chooseDescriptorFromDescriptors:descriptors
                                      url:url
                                generation:generation];
}


- (void)chooseDescriptorFromDescriptors:(NSArray *)descriptors
                                    url:(NSURL *)url
                              generation:(NSUInteger)generation {
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
        if (index < 0 || index >= (NSInteger)descriptors.count) {
            index = 0;
        }
        CTFontDescriptorRef descriptor =
            (__bridge CTFontDescriptorRef)descriptors[(NSUInteger)index];
        [weakSelf loadDescriptor:descriptor url:url generation:generation];
    }];
}

- (void)loadDescriptor:(CTFontDescriptorRef)descriptor
                    url:(NSURL *)url
             generation:(NSUInteger)generation {
    CTFontDescriptorRef retainedDescriptor = (CTFontDescriptorRef)CFRetain(descriptor);
    NSURL *copiedURL = [url copy];
    __weak typeof(self) weakSelf = self;

    dispatch_async(self.fontQueue, ^{
        GAFontDocument *document = [[GAFontDocument alloc] initWithDescriptor:retainedDescriptor
                                                                          URL:copiedURL];
        CFRelease(retainedDescriptor);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil || generation != self.loadGeneration) {
                return;
            }
            if (document == nil) {
                [self showErrorWithTitle:@"Cannot Read Font"
                                 message:@"CoreText could not create this font."];
                return;
            }

            [self.analysisProgress cancel];
            self.analysisProgress = nil;
            self.analysisGeneration += 1;
            self.fontDocument = document;
            if (self.onFontLoaded != nil) {
                self.onFontLoaded(document.fontURL ?: url);
            }
            [self.seedGroups removeAllObjects];
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

- (NSUInteger)occurrenceCountBeforeRange:(NSRange)sourceRange
                                 forText:(NSString *)text {
    if (text.length == 0 || sourceRange.location == NSNotFound) return 0;
    NSString *fullText = self.sidebarViewController.text;
    NSUInteger occurrence = 0;
    NSRange search = NSMakeRange(0, fullText.length);
    while (search.length > 0) {
        NSRange found = [fullText rangeOfString:text options:0 range:search];
        if (found.location == NSNotFound || found.location >= sourceRange.location) {
            break;
        }
        occurrence++;
        NSUInteger next = NSMaxRange(found);
        if (next <= search.location || next >= fullText.length) break;
        search = NSMakeRange(next, fullText.length - next);
    }
    return occurrence;
}

- (NSRange)spanForSeedText:(NSString *)text
                 occurrence:(NSUInteger)occurrence
                   inGroups:(NSArray<GACharacterGroup *> *)groups {
    if (text.length == 0) return NSMakeRange(NSNotFound, 0);
    NSUInteger seen = 0;
    for (NSUInteger start = 0; start < groups.count; start++) {
        NSMutableString *concat = [NSMutableString string];
        for (NSUInteger end = start; end < groups.count; end++) {
            [concat appendString:groups[end].text ?: @""];
            if ([concat isEqualToString:text]) {
                if (seen == occurrence) {
                    return NSMakeRange(start, end - start + 1);
                }
                seen++;
                break;
            }
            if (concat.length >= text.length) break;
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

- (void)matchSeedGroupsToBaseGroups:(NSArray<GACharacterGroup *> *)groups {
    NSMutableArray<GACharacterGroup *> *matched = [NSMutableArray array];
    for (GACharacterGroup *seed in [self.seedGroups copy]) {
        NSRange span = [self spanForSeedText:seed.text
                                  occurrence:seed.seedOccurrence
                                    inGroups:groups];
        if (span.location == NSNotFound) continue;

        NSUInteger lastIndex = span.location + span.length - 1;
        NSRange firstRange = groups[span.location].textRange;
        NSRange lastRange = groups[lastIndex].textRange;
        if (firstRange.location == NSNotFound || lastRange.location == NSNotFound) {
            continue;
        }
        seed.textRange = NSMakeRange(firstRange.location,
            NSMaxRange(lastRange) - firstRange.location);
        seed.groupIndex = span.location;
        seed.seedSpanLength = span.length;
        [matched addObject:seed];
    }

    [matched sortUsingComparator:^NSComparisonResult(GACharacterGroup *a,
                                                     GACharacterGroup *b) {
        if (a.textRange.location != b.textRange.location) {
            return a.textRange.location < b.textRange.location
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return a.seedSpanLength < b.seedSpanLength
            ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray<GACharacterGroup *> *nonOverlapping = [NSMutableArray array];
    NSRange previous = NSMakeRange(NSNotFound, 0);
    for (GACharacterGroup *seed in matched) {
        if (previous.location != NSNotFound &&
            NSIntersectionRange(previous, seed.textRange).length > 0) {
            continue;
        }
        [nonOverlapping addObject:seed];
        previous = seed.textRange;
    }
    self.seedGroups = nonOverlapping;
}

- (void)removeSeedGroupsOverlappingRange:(NSRange)range {
    if (range.location == NSNotFound) return;
    NSMutableArray<GACharacterGroup *> *kept = [NSMutableArray array];
    for (GACharacterGroup *seed in self.seedGroups) {
        if (NSIntersectionRange(seed.textRange, range).length == 0) {
            [kept addObject:seed];
        }
    }
    self.seedGroups = kept;
}

- (void)addSeedGroup:(GACharacterGroup *)seed sourceRange:(NSRange)sourceRange {
    [self removeSeedGroupsOverlappingRange:sourceRange];
    NSUInteger index = 0;
    while (index < self.seedGroups.count &&
           self.seedGroups[index].textRange.location < sourceRange.location) {
        index++;
    }
    [self.seedGroups insertObject:seed atIndex:index];
}

- (void)recordSeedWithGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                          text:(NSString *)seedText
                   sourceRange:(NSRange)sourceRange
                   selectedKey:(NSString *)selectedKey {
    NSArray<GACharacterGroup *> *analyzedGroups =
        [self.fontDocument analyzeGlyphIDs:glyphIDs];
    if (analyzedGroups.count == 0) {
        NSBeep();
        return;
    }
    GACharacterGroup *seedGroup = analyzedGroups.firstObject;
    seedGroup.text = seedText;
    seedGroup.seedOccurrence = [self occurrenceCountBeforeRange:sourceRange
                                                       forText:seedText];
    [self addSeedGroup:seedGroup sourceRange:sourceRange];
    [self.sidebarViewController selectGlyphKeyAfterNextReload:selectedKey];
    [self scheduleAnalysis];
}

- (NSArray<GACharacterGroup *> *)buildDisplayGroupsFromBaseGroups:
    (NSArray<GACharacterGroup *> *)groups text:(NSString *)text {
    NSMutableArray<GAGlyphVariant *> *ligatureVariants = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        for (GAGlyphVariant *variant in group.variants) {
            if (variant.isLigature && variant.sourceTextRange.length > 0) {
                [ligatureVariants addObject:variant];
            }
        }
    }

    [self matchSeedGroupsToBaseGroups:groups];
    NSMutableDictionary<NSNumber *, GACharacterGroup *> *seedByStart =
        [NSMutableDictionary dictionary];
    for (GACharacterGroup *seed in self.seedGroups) {
        seedByStart[@(seed.groupIndex)] = seed;
    }

    NSMutableArray<GACharacterGroup *> *display = [NSMutableArray array];
    NSMutableArray<NSValue *> *seedRanges = [NSMutableArray array];
    for (NSUInteger index = 0; index < groups.count; index++) {
        GACharacterGroup *seed = seedByStart[@(index)];
        if (seed != nil) {
            [display addObject:seed];
            [seedRanges addObject:[NSValue valueWithRange:seed.textRange]];
            index += MAX((NSUInteger)1, seed.seedSpanLength) - 1;
        } else {
            [display addObject:[self displayCopyOfCharacterGroup:groups[index]]];
        }
    }

    NSMutableDictionary<NSValue *, NSMutableArray<GAGlyphVariant *> *> *byRange =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSValue *> *rangeOrder = [NSMutableArray array];
    for (GAGlyphVariant *variant in ligatureVariants) {
        NSRange range = variant.sourceTextRange;
        if (range.location == NSNotFound || range.length == 0 ||
            NSMaxRange(range) > text.length) {
            continue;
        }
        BOOL overlapsSeed = NO;
        for (NSValue *seedValue in seedRanges) {
            if (NSIntersectionRange(range, seedValue.rangeValue).length > 0) {
                overlapsSeed = YES;
                break;
            }
        }
        if (overlapsSeed) continue;
        NSValue *rangeValue = [NSValue valueWithRange:range];
        NSMutableArray<GAGlyphVariant *> *variants = byRange[rangeValue];
        if (variants == nil) {
            variants = [NSMutableArray array];
            byRange[rangeValue] = variants;
            [rangeOrder addObject:rangeValue];
        }
        [variants addObject:variant];
    }

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
        ligatureGroup.ligatureGroup = YES;
        ligatureGroup.text = [text substringWithRange:range];
        ligatureGroup.textRange = range;
        ligatureGroup.variants = unique;

        NSUInteger insertion = display.count;
        for (NSUInteger i = 0; i < display.count; i++) {
            NSRange groupRange = display[i].textRange;
            if (groupRange.location != NSNotFound &&
                groupRange.location < NSMaxRange(range)) {
                insertion = i + 1;
            }
        }
        [display insertObject:ligatureGroup atIndex:insertion];
    }

    return display;
}

- (void)activateGlyphVariant:(GAGlyphVariant *)variant inGroup:(GACharacterGroup *)group {
    NSArray<NSNumber *> *scalars = variant.unicodeScalars;
    NSString *text = self.sidebarViewController.text;

    if (variant.isLigature) {
        NSRange sourceRange = variant.sourceTextRange;
        if (sourceRange.location == NSNotFound || sourceRange.length == 0 ||
            NSMaxRange(sourceRange) > text.length) {
            sourceRange = group.textRange;
        }
        if (sourceRange.location == NSNotFound || sourceRange.length == 0) {
            NSBeep();
            return;
        }

        if (scalars.count > 0) {
            NSString *replacement =
                GAStringFromUnicodeScalars(@[scalars.firstObject]);
            NSString *newText = [text stringByReplacingCharactersInRange:sourceRange
                                                              withString:replacement];
            [self removeSeedGroupsOverlappingRange:sourceRange];
            [self.sidebarViewController selectGlyphKeyAfterNextReload:variant.glyphKey];
            [self.sidebarViewController setText:newText];
            [self scheduleAnalysis];
            return;
        }

        NSString *spanText = [text substringWithRange:sourceRange];
        [self recordSeedWithGlyphIDs:variant.glyphIDs
                                text:spanText
                         sourceRange:sourceRange
                         selectedKey:variant.glyphKey];
        return;
    }

    if (scalars.count > 0) {
        NSString *replacement =
            GAStringFromUnicodeScalars(@[scalars.firstObject]);
        NSRange range = group.textRange;
        BOOL validRange = range.location != NSNotFound &&
            NSMaxRange(range) <= text.length &&
            group.text.length > 0 &&
            [[text substringWithRange:range] isEqualToString:group.text];
        if (!validRange) {
            range = group.text.length > 0
                ? [text rangeOfString:group.text]
                : NSMakeRange(NSNotFound, 0);
        }
        NSString *newText = (range.location == NSNotFound ||
                             NSMaxRange(range) > text.length)
            ? replacement
            : [text stringByReplacingCharactersInRange:range withString:replacement];
        [self removeSeedGroupsOverlappingRange:range];
        [self.sidebarViewController selectGlyphKeyAfterNextReload:variant.glyphKey];
        [self.sidebarViewController setText:newText];
        [self scheduleAnalysis];
        return;
    }

    [self recordSeedWithGlyphIDs:variant.glyphIDs
                            text:group.text
                     sourceRange:group.textRange
                     selectedKey:variant.glyphKey];
}

#pragma mark - Analysis

- (void)scheduleAnalysis {
    [self.analysisProgress cancel];
    self.analysisProgress = nil;
    self.analysisGeneration += 1;
    NSUInteger generation = self.analysisGeneration;
    NSString *text = self.sidebarViewController.text;

    if (text.length == 0) {
        // Deleting all text clears every seed record.
        [self.seedGroups removeAllObjects];
        [self.sidebarViewController setGroups:@[]];
        [self.detailViewController setVariant:nil];
        return;
    }

    if (self.fontDocument == nil) {
        return;
    }

    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    self.analysisProgress = progress;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || progress.isCancelled ||
            generation != self.analysisGeneration) {
            return;
        }
        [self performAnalysisWithGeneration:generation text:text progress:progress];
    });
}

- (void)performAnalysisWithGeneration:(NSUInteger)generation
                                 text:(NSString *)text
                             progress:(NSProgress *)progress {
    GAFontDocument *document = self.fontDocument;
    if (document == nil || progress.isCancelled) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.analysisQueue, ^{
        @autoreleasepool {
            NSArray<GACharacterGroup *> *groups =
                [document analyzeText:text progress:progress];
            if (progress.isCancelled) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self == nil ||
                    generation != self.analysisGeneration ||
                    document != self.fontDocument ||
                    progress.isCancelled ||
                    ![text isEqualToString:self.sidebarViewController.text]) {
                    return;
                }
                NSArray<GACharacterGroup *> *display =
                    [self buildDisplayGroupsFromBaseGroups:groups text:text];
                [self.sidebarViewController setGroups:display];
                if (self.analysisProgress == progress) {
                    self.analysisProgress = nil;
                }
            });
        }
    });
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
