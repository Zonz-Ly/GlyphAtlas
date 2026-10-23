#import <AppKit/AppKit.h>
#import "GAAppDelegate.h"
#import "GAMainWindowController.h"

@interface GAAppDelegate (LocalizationTests)
- (void)buildMainMenu;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
@end

// Menu validation depends on the active window's state. Avoid presenting a
// window or opening a user's documents while exercising both writing modes.
@interface GALocalizationWindow : GAMainWindowController
@property BOOL testVertical;
@end
@implementation GALocalizationWindow
- (instancetype)init { return [super initWithWindow:nil]; }
- (GAViewMode)viewMode { return GAViewModeMultiCharacter; }
- (BOOL)showsMetrics { return YES; }
- (NSTextAlignment)textAlignment { return NSTextAlignmentCenter; }
- (BOOL)verticalWriting { return self.testVertical; }
@end

@interface GALocalizationDelegate : GAAppDelegate
@property (strong) GALocalizationWindow *testWindow;
@end
@implementation GALocalizationDelegate
- (GAMainWindowController *)activeMainWindowController { return self.testWindow; }
@end

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static NSMenuItem *FindAction(NSMenu *menu, NSString *action) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([NSStringFromSelector(item.action) isEqualToString:action]) return item;
        NSMenuItem *child = item.submenu != nil ? FindAction(item.submenu, action) : nil;
        if (child != nil) return child;
    }
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *expected = [NSUserDefaults.standardUserDefaults stringForKey:@"expectedLocale"];
        Require([bundle.preferredLocalizations.firstObject isEqualToString:expected],
                [NSString stringWithFormat:@"Wrong language selection: %@ (expected %@)", bundle.preferredLocalizations, expected]);
        NSString *sentinel = @"__MISSING_LOCALIZATION__";
        // The English catalog is the complete inventory, not an English-only
        // fallback: every key must resolve in each packaged localization.
        NSURL *englishURL = [bundle URLForResource:@"Localizable" withExtension:@"strings"
                                     subdirectory:nil localization:@"en"];
        NSDictionary *english = [NSDictionary dictionaryWithContentsOfURL:englishURL];
        Require(english.count > 0, @"The packaged English catalog is missing");
        for (NSString *key in english) {
            NSString *value = [bundle localizedStringForKey:key value:sentinel table:nil];
            Require(![value isEqualToString:sentinel] && value.length > 0, key);
        }
        NSString *documentType = [bundle localizedStringForKey:@"Font File" value:sentinel table:@"InfoPlist"];
        Require(![documentType isEqualToString:sentinel], @"Document type localization is missing");

        NSMutableArray *formats = [NSMutableArray array];
        NSString *format = NSLocalizedString(@"“%@” contains %lu fonts. Choose a style to inspect.", @"");
        for (NSNumber *count in @[@0, @1, @2, @3, @11, @21]) {
            NSString *text = [NSString localizedStringWithFormat:format, @"Test % Font.ttc", count.unsignedLongValue];
            Require([text containsString:@"Test % Font.ttc"] && ![text containsString:@"%#@"] && ![text containsString:@"%lu"], text);
            [formats addObject:text];
        }
        if ([expected isEqualToString:@"ru"]) {
            Require([formats[1] containsString:@"1 шрифт"], formats[1]);
            Require([formats[2] containsString:@"2 шрифта"], formats[2]);
            Require([formats[4] containsString:@"11 шрифтов"], formats[4]);
        }
        if ([expected isEqualToString:@"ar"]) {
            Require([formats[1] containsString:@"خط واحد"], formats[1]);
            Require([formats[2] containsString:@"خطين"], formats[2]);
            Require([formats[3] containsString:@"خطوط"], formats[3]);
        }

        [NSApplication sharedApplication];
        GALocalizationDelegate *delegate = [[GALocalizationDelegate alloc] init];
        delegate.testWindow = [[GALocalizationWindow alloc] init];
        [delegate buildMainMenu];
        NSMenuItem *copy = FindAction(NSApp.mainMenu, @"copy:");
        Require([copy.title isEqualToString:NSLocalizedString(@"Copy", @"")] && [copy.keyEquivalent isEqualToString:@"c"], @"Copy command or shortcut changed");
        NSMutableArray *alignmentTitles = [NSMutableArray array];
        for (NSNumber *vertical in @[@NO, @YES]) {
            delegate.testWindow.testVertical = vertical.boolValue;
            NSMenu *context = [delegate viewMenuForContext];
            NSMenuItem *first = FindAction(context, @"setTextAlignment:");
            Require(first != nil, @"Context alignment menu missing");
            NSArray *keys = vertical.boolValue ? @[@"Top", @"Center", @"Bottom", @"Justified"]
                                              : @[@"Left", @"Center", @"Right", @"Justified"];
            NSUInteger i = 0;
            for (NSMenuItem *item in first.menu.itemArray) {
                Require([delegate validateMenuItem:item], @"Alignment command unexpectedly disabled");
                Require([item.title isEqualToString:NSLocalizedString(keys[i], @"")], @"Writing-direction labels did not update");
                [alignmentTitles addObject:item.title];
                i++;
            }
        }
        NSDictionary *output = @{@"locale": expected, @"copy": copy.title,
            @"alignment": alignmentTitles, @"pluralExamples": formats,
            @"keys": @(english.count)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
