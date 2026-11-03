#import <AppKit/AppKit.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 260000
/// Public Tahoe API, declared here for builds using an earlier SDK.
@interface NSSplitViewItem (GAMacOS26SDKDeclarations)
@property (nonatomic) BOOL automaticallyAdjustsSafeAreaInsets API_AVAILABLE(macos(26.0));
@end
#endif

/// Tahoe layout adjustments must not change the UI on earlier or later systems.
NS_INLINE BOOL GAUsesMacOS26Layout(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26;
}
