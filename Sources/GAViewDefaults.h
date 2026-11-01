#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const GAViewModeDefaultKey;
FOUNDATION_EXPORT NSString *const GABoundingBoxDefaultKey;
FOUNDATION_EXPORT NSString *const GAContextualAlternatesDefaultKey;
FOUNDATION_EXPORT NSString *const GALigaturesDefaultKey;
FOUNDATION_EXPORT NSString *const GAVerticalWritingDefaultKey;

/// Explicit saved defaults, otherwise the app's original factory values.
FOUNDATION_EXPORT NSInteger GAViewDefaultValue(NSUserDefaults *defaults, NSString *key);
