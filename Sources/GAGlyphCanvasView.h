#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSColor *GACanvasBackgroundColor(void);
FOUNDATION_EXPORT NSColor *GAGlyphForegroundColor(void);

/// Fills the definition page with its standard shadow.
FOUNDATION_EXPORT void GADrawPage(NSRect page, NSAppearance *appearance);

/// The canvas margin rule: inset a rect by the same fraction of its width and
/// height. Shared by the single-glyph canvas and the multi-character page.
FOUNDATION_EXPORT NSRect GAInsetRectByFraction(NSRect rect, CGFloat fraction);

/// The one zoom range both canvases share. The maximum inset is
/// `0.5 * (1 - 1 / 1.12^22)`; 0 fills the viewport.
FOUNDATION_EXPORT const CGFloat GACanvasMaxInsetFraction;
/// Default page inset. Two 1.12× zoom-outs from a full page.
FOUNDATION_EXPORT const CGFloat GACanvasDefaultSideInsetFraction;
/// Multiplicative step for keyboard zoom of a glyph or text size.
FOUNDATION_EXPORT const CGFloat GAGlyphZoomStep;
/// Ten zoom steps: `1.12^10`. Used to express the ten- and twenty-step limits.
FOUNDATION_EXPORT const CGFloat GAGlyphZoomStep10;

/// Clamps a page inset to the range the canvas supports.
CGFloat GAClampSideInsetFraction(CGFloat fraction);
/// Page fraction (1 - 2 * inset) for a pinch, 1:1 with the gesture.
CGFloat GACanvasPageFractionForMagnification(CGFloat startPage, CGFloat magnification);

@interface GAGlyphCanvasView : NSView
@property (nonatomic, strong, nullable) GAGlyphVariant *variant;
/// Fraction of the canvas width/height used as page inset. Default: two
/// zoom-outs from a full page.
@property (nonatomic) CGFloat sideInsetFraction;
/// Whether the definition page and its shadow are drawn. Default YES.
@property (nonatomic) BOOL showsMetrics;
/// Called after the inset changes so sibling views can share one zoom state.
@property (nonatomic, copy, nullable) void (^onSideInsetFractionChanged)(CGFloat fraction);
@end

NS_ASSUME_NONNULL_END
