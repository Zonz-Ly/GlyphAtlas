#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>

NS_ASSUME_NONNULL_BEGIN

@interface GAFontFeatureGroup : NSObject
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL exclusive;
@property(nonatomic, readonly) BOOL booleanChoice;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *selectors;
@end

/// A font's native catalogue and this window's explicit choices. Discovery of
/// sidebar candidates is independent of these display settings.
@interface GAFontFeatures : NSObject
- (instancetype)initWithFont:(CTFontRef)font;
@property(nonatomic, copy, readonly) NSArray<GAFontFeatureGroup *> *groups;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *settings;
/// Includes CoreText's own OpenType mappings for the application's replay.
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *replaySettings;
- (BOOL)isSelectorSelected:(NSDictionary *)selector inGroup:(GAFontFeatureGroup *)group;
- (void)chooseSelector:(NSDictionary *)selector inGroup:(GAFontFeatureGroup *)group;
@end

FOUNDATION_EXPORT CTFontRef GACopyFontWithFeatureSettings(CTFontRef font, CGFloat size,
    NSArray<NSDictionary *> *settings) CF_RETURNS_RETAINED;

/// Language labels for the typesetting menu.
/// OpenType tags and BCP 47 language identifiers are different namespaces.
FOUNDATION_EXPORT NSString * _Nullable GAIdentifierForOpenTypeLanguage(NSString *tag);
FOUNDATION_EXPORT NSString *GATitleForOpenTypeLanguage(NSString *tag, NSLocale *locale);

NS_ASSUME_NONNULL_END
