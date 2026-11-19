#import <Foundation/Foundation.h>
#import "Views/GAAppKit.h"

NS_ASSUME_NONNULL_BEGIN

@interface GAGlyphNavigationStep : NSObject <NSCopying>
@property (nonatomic) GAViewMode mode;
@property (nonatomic, copy, nullable) NSString *filterTag;
@property (nonatomic) BOOL filterChange;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *glyphIDs;
@property (nonatomic) NSRange range;
@property (nonatomic, copy, nullable) NSString *sourceText;
@property (nonatomic, copy, nullable) NSString *glyphLabel;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSValue *> *sourceRecoveryRanges;
@property (nonatomic, readonly) BOOL allowsViewOnly;
- (BOOL)matchesLocation:(nullable GAGlyphNavigationStep *)other;
- (BOOL)matchesSourceInText:(nullable NSString *)text;
- (BOOL)matchesSourceAtRange:(NSRange)range inText:(nullable NSString *)text;
- (void)rememberSourceRange:(NSRange)range inText:(NSString *)text;
@end

/// Positions on either side of the current view, including unavailable sources.
@interface GAGlyphNavigationHistory : NSObject
@property (nonatomic, strong, readonly) NSArray<GAGlyphNavigationStep *> *backSteps;
@property (nonatomic, strong, readonly) NSArray<GAGlyphNavigationStep *> *forwardSteps;
@property (nonatomic, strong, readonly, nullable) GAGlyphNavigationStep *restoredStep;
/// Start a new navigation, optionally omitting the departing location.
- (void)recordStep:(nullable GAGlyphNavigationStep *)step;
/// Only the nearest forward entry (above the current position in the menu) can pair with the grid.
- (BOOL)canReplaceGridOrigin:(GAGlyphNavigationStep *)origin;
- (BOOL)moveToStep:(GAGlyphNavigationStep *)step leavingStep:(GAGlyphNavigationStep *)current;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
