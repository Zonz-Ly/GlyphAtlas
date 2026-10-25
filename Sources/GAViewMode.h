#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, GAViewMode) {
    GAViewModeAllGlyphs = 0,
    GAViewModeMultiCharacter = 1,
    GAViewModeSingleGlyph = 2
};

/// TextKit-only controls are unavailable in the two glyph canvases.
NS_INLINE BOOL GAViewModeSupportsTextLayout(GAViewMode mode) {
    return mode == GAViewModeMultiCharacter;
}
NS_INLINE BOOL GAViewModeSupportsMetrics(GAViewMode mode) {
    return mode != GAViewModeAllGlyphs;
}
