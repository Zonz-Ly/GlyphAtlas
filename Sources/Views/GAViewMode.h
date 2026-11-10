#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, GAViewMode) {
    GAViewModeAllGlyphs = 0,
    GAViewModeMultiCharacter = 1,
    GAViewModeSingleGlyph = 2
};

/// TextKit-only controls are unavailable in the two glyph views.
NS_INLINE BOOL GAViewModeSupportsTextLayout(GAViewMode mode) {
    return mode == GAViewModeMultiCharacter;
}
NS_INLINE BOOL GAViewModeSupportsMetrics(GAViewMode mode) {
    return mode != GAViewModeAllGlyphs;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 260000
/// Public Tahoe API, declared here for builds using an earlier SDK.
API_AVAILABLE(macos(26.0))
@interface NSSplitViewItemAccessoryViewController : NSViewController
@property (nonatomic) BOOL automaticallyAppliesContentInsets;
@end

@interface NSSplitViewItem (GAMacOS26SDKDeclarations)
@property (nonatomic) BOOL automaticallyAdjustsSafeAreaInsets API_AVAILABLE(macos(26.0));
- (void)addTopAlignedAccessoryViewController:(NSSplitViewItemAccessoryViewController *)controller
    API_AVAILABLE(macos(26.0));
@end
#endif

/// Tahoe layout adjustments must not change the UI on earlier or later systems.
NS_INLINE BOOL GAUsesMacOS26Layout(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26;
}
