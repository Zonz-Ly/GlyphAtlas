#import <Foundation/Foundation.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GATextScanSubitemState) {
    GATextScanSubitemStatePending = 0,
    GATextScanSubitemStateScanning,
    GATextScanSubitemStateCompleted,
};

/// One desired context of the current text. Text plus literal selections form the cache key; the
/// range/startGroup only describe where this instance is displayed.
@interface GATextScanSubitem : NSObject
@property (nonatomic, copy) NSString *content;
@property(nonatomic, copy) NSArray<GAGlyphSelectionRun *> *selections;
@property(nonatomic, readonly) GAGlyphQueryIdentity *cacheKey;
@property (nonatomic) NSRange range;
@property (nonatomic) NSUInteger startGroup;
@property (nonatomic) NSUInteger length;
@property (nonatomic) GATextScanSubitemState state;
@property (nonatomic, strong, nullable) GARawScanResult *result;
@end

/// One batch of scan work produced by a text change.
@interface GATextScanItem : NSObject
@property (nonatomic, strong) NSMutableArray<GATextScanSubitem *> *subitems;
@end

/// All items of one context length.
@interface GATextScanGroup : NSObject
@property (nonatomic) NSUInteger length;
@property (nonatomic, strong) NSMutableArray<GATextScanItem *> *items;
@end

@class GATextScanModel;

@protocol GATextScanModelDelegate <NSObject>
- (void)textScanModelDidUpdate:(GATextScanModel *)model;
- (void)textScanModelDidFinish:(GATextScanModel *)model;
@end

/// Incremental scan model: the complete desired set is reconciled against the
/// content cache and the pending queue on every text change. Raw results are
/// cached by text and literal selections; range-bound variants are applied to `groups` on demand.
@interface GATextScanModel : NSObject
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, strong, readonly) NSArray<GACharacterGroup *> *groups;
@property (nonatomic, weak, nullable) id<GATextScanModelDelegate> delegate;
@property (nonatomic, strong, readonly) NSArray<GATextScanGroup *> *scanGroups;

- (instancetype)initWithFontDocument:(GAFontDocument *)fontDocument NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Switches coordinates while retaining the resource-wide union of discoveries.
- (void)updateFontDocument:(GAFontDocument *)document;


/// Rebuilds the desired subitem set, applies cached results, keeps still-valid
/// pending work, and enqueues each group's new missing items at the group end.
- (void)updateText:(NSString *)text;
- (void)updateText:(NSString *)text selections:(NSArray<GAGlyphSelectionRun *> *)selections;

/// Returns the next pending subitem and marks it scanning, or nil. Cached
/// pending subitems are completed inline and skipped.
- (nullable GATextScanSubitem *)startNextSubitem;
- (nullable GATextScanSubitem *)startNextSubitemWithMaximumLength:(NSUInteger)maxLength;

/// Stores the raw result under its query identity and applies it to every current
/// subitem with that identity, including instances added by a newer text.
- (void)completeSubitem:(GATextScanSubitem *)subitem result:(GARawScanResult *)result;

@end

NS_ASSUME_NONNULL_END
