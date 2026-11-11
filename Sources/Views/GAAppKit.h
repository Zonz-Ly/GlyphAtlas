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

NS_INLINE CGFloat GATopOffsetInView(NSView *view, NSRect rect) {
    NSRect bounds = view.bounds;
    return view.flipped ? NSMinY(rect) - NSMinY(bounds) : NSMaxY(bounds) - NSMaxY(rect);
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 260000
static const NSControlSize NSControlSizeExtraLarge API_AVAILABLE(macos(26.0)) = 4;

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

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 270000
@interface NSGestureRecognizer (GAMacOS27SDKDeclarations)
@property (getter=isCancellableByScrollGesture) BOOL cancellableByScrollGesture API_AVAILABLE(macos(27.0));
@end
#endif

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 260100
API_AVAILABLE(macos(26.1))
@interface NSScrollEdgeEffectStyle : NSObject
@property (class, strong, readonly) NSScrollEdgeEffectStyle *softStyle;
@end

@interface NSSplitViewItemAccessoryViewController (GAMacOS26_1SDKDeclarations)
@property (strong) NSScrollEdgeEffectStyle *preferredScrollEdgeEffectStyle API_AVAILABLE(macos(26.1));
@end
#endif

/// Tahoe layout adjustments must not change the UI on earlier or later systems.
NS_INLINE BOOL GAUsesMacOS26Layout(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26;
}
