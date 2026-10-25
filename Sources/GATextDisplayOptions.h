#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Native display settings only. Candidate discovery is independent of these switches.
FOUNDATION_EXPORT
    CTFontRef _Nullable GACopyTextDisplayFont(CTFontRef font, CGFloat size,
                                              BOOL contextualAlternates) CF_RETURNS_RETAINED;
NS_ASSUME_NONNULL_END
