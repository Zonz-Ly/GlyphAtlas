#import "GAFontFeatures.h"

@interface GAFontFeatureGroup ()
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL exclusive;
@property(nonatomic) BOOL booleanChoice;
@property(nonatomic, strong, nullable) NSNumber *type;
@property(nonatomic, copy, nullable) NSString *tag;
@property(nonatomic, copy) NSArray<NSDictionary *> *selectors;
@end
@implementation GAFontFeatureGroup
@end

static NSString *GASelectorKey(NSDictionary *selector) {
    NSNumber *identifier = selector[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
    return identifier ? identifier.stringValue
        : [selector[(__bridge NSString *)kCTFontOpenTypeFeatureValue] stringValue];
}

static BOOL GASelectorDefault(NSDictionary *selector) {
    NSNumber *setting = selector[(__bridge NSString *)kCTFontFeatureSelectorSettingKey];
    return setting ? setting.boolValue
        : [selector[(__bridge NSString *)kCTFontFeatureSelectorDefaultKey] boolValue];
}

@implementation GAFontFeatures {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *_choices;
}

- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (!self) return nil;
    _choices = [NSMutableDictionary dictionary];
    NSMutableArray *groups = [NSMutableArray array];
    NSArray *catalogue = CFBridgingRelease(CTFontCopyFeatures(font));
    for (NSDictionary *definition in catalogue) {
        NSNumber *type = definition[(__bridge NSString *)kCTFontFeatureTypeIdentifierKey];
        NSString *tag = definition[(__bridge NSString *)kCTFontOpenTypeFeatureTag];
        // Type zero is the umbrella command, not an individual font feature.
        if ((type && type.integerValue == 0) || (!type && !tag)) continue;
        GAFontFeatureGroup *group = [GAFontFeatureGroup new];
        group.identifier = type ? [@"aat:" stringByAppendingString:type.stringValue]
                                : [@"ot:" stringByAppendingString:tag];
        NSString *name = definition[(__bridge NSString *)kCTFontFeatureTypeNameKey];
        group.name = name.length ? name : (tag.length ? tag : type.stringValue);
        group.type = type;
        group.tag = tag;
        group.exclusive = [definition[(__bridge NSString *)kCTFontFeatureTypeExclusiveKey] boolValue];
        NSArray *selectors = definition[(__bridge NSString *)kCTFontFeatureTypeSelectorsKey];
        if (type && !group.exclusive) {
            NSMutableSet *identifiers = [NSMutableSet set];
            for (NSDictionary *selector in selectors) {
                NSNumber *identifier = selector[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
                if (identifier) [identifiers addObject:identifier];
            }
            NSMutableArray *visible = [NSMutableArray array];
            NSMutableSet *visibleIdentifiers = [NSMutableSet set];
            for (NSDictionary *selector in selectors) {
                NSNumber *identifier = selector[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
                if (identifier) {
                    NSUInteger value = identifier.unsignedIntegerValue;
                    // CoreText can report both names of an on/off pair under
                    // the same even ID. The sorted AAT names put On first.
                    if ([visibleIdentifiers containsObject:identifier] ||
                        ((value & 1) && [identifiers containsObject:@(value ^ 1)])) continue;
                    [visibleIdentifiers addObject:identifier];
                }
                [visible addObject:selector];
            }
            selectors = visible;
        }
        NSMutableArray *namedSelectors = [NSMutableArray arrayWithCapacity:selectors.count];
        for (NSDictionary *selector in selectors) {
            NSDictionary *namedSelector = selector;
            if (![selector[(__bridge NSString *)kCTFontFeatureSelectorNameKey] length]) {
                NSMutableDictionary *named = [selector mutableCopy];
                named[(__bridge NSString *)kCTFontFeatureSelectorNameKey] = GASelectorKey(selector);
                namedSelector = named;
            }
            [namedSelectors addObject:namedSelector];
        }
        group.selectors = namedSelectors;
        // A pure OpenType off/on pair is one checkbox in the Other group.
        group.booleanChoice = !type && group.selectors.count == 2 &&
            [group.selectors[0][(__bridge NSString *)kCTFontOpenTypeFeatureValue] integerValue] == 0 &&
            [group.selectors[1][(__bridge NSString *)kCTFontOpenTypeFeatureValue] integerValue] == 1;
        if (group.selectors.count) [groups addObject:group];
    }
    _groups = groups.copy;
    return self;
}

- (BOOL)isSelectorSelected:(NSDictionary *)selector inGroup:(GAFontFeatureGroup *)group {
    NSDictionary *choices = _choices[group.identifier];
    NSNumber *choice = choices[GASelectorKey(selector)];
    if (choice) return choice.boolValue;
    if ((group.exclusive || group.booleanChoice) && choices.count) return NO;
    return GASelectorDefault(selector);
}

- (void)chooseSelector:(NSDictionary *)selector inGroup:(GAFontFeatureGroup *)group {
    BOOL selected = [self isSelectorSelected:selector inGroup:group];
    if (group.booleanChoice) {
        NSDictionary *other = group.selectors[selected ? 0 : 1];
        [self setExclusiveSelector:other inGroup:group];
    } else if (group.exclusive) {
        [self setExclusiveSelector:selector inGroup:group];
    } else {
        NSMutableDictionary *choices = _choices[group.identifier];
        if (!choices) _choices[group.identifier] = choices = [NSMutableDictionary dictionary];
        NSString *key = GASelectorKey(selector);
        if ((!selected) == GASelectorDefault(selector)) [choices removeObjectForKey:key];
        else choices[key] = @(!selected);
        if (!choices.count) [_choices removeObjectForKey:group.identifier];
    }
}

- (void)setExclusiveSelector:(NSDictionary *)selector inGroup:(GAFontFeatureGroup *)group {
    if (GASelectorDefault(selector)) [_choices removeObjectForKey:group.identifier];
    else _choices[group.identifier] = [@{GASelectorKey(selector):@YES} mutableCopy];
}

- (NSArray<NSDictionary *> *)settings {
    NSMutableArray *result = [NSMutableArray array];
    for (GAFontFeatureGroup *group in self.groups) {
        NSDictionary *choices = _choices[group.identifier];
        if (!choices.count) continue;
        NSNumber *type = group.type;
        for (NSDictionary *selector in group.selectors) {
            NSNumber *choice = choices[GASelectorKey(selector)];
            if (!choice) continue;
            if (type) {
                NSUInteger value = [selector[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey] unsignedIntegerValue];
                [result addObject:@{(__bridge NSString *)kCTFontFeatureTypeIdentifierKey:type,
                    (__bridge NSString *)kCTFontFeatureSelectorIdentifierKey:@(choice.boolValue ? value : (value ^ 1))}];
            } else {
                NSString *tag = selector[(__bridge NSString *)kCTFontOpenTypeFeatureTag]
                    ?: group.tag;
                [result addObject:@{(__bridge NSString *)kCTFontOpenTypeFeatureTag:tag,
                    (__bridge NSString *)kCTFontOpenTypeFeatureValue:
                        choice.boolValue ? selector[(__bridge NSString *)kCTFontOpenTypeFeatureValue] : @0}];
            }
        }
    }
    return result;
}

- (NSArray<NSDictionary *> *)replaySettings {
    NSMutableArray *result = [self.settings mutableCopy];
    for (GAFontFeatureGroup *group in self.groups) {
        if (!_choices[group.identifier].count) continue;
        NSMutableDictionary<NSString *, NSNumber *> *values = [NSMutableDictionary dictionary];
        for (NSDictionary *selector in group.selectors) {
            NSString *tag = selector[(__bridge NSString *)kCTFontOpenTypeFeatureTag];
            if (tag) values[tag] = @0;
        }
        for (NSDictionary *selector in group.selectors) {
            NSString *tag = selector[(__bridge NSString *)kCTFontOpenTypeFeatureTag];
            if (tag && [self isSelectorSelected:selector inGroup:group])
                values[tag] = selector[(__bridge NSString *)kCTFontOpenTypeFeatureValue] ?: @1;
        }
        for (NSString *tag in [values.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [result addObject:@{(__bridge NSString *)kCTFontOpenTypeFeatureTag:tag,
                (__bridge NSString *)kCTFontOpenTypeFeatureValue:values[tag]}];
    }
    return result;
}
@end

CTFontRef GACopyFontWithFeatureSettings(CTFontRef font, CGFloat size, NSArray<NSDictionary *> *settings) {
    if (!settings.count) return CTFontCreateCopyWithAttributes(font, size, NULL, NULL);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCTFontFeatureSettingsAttribute:settings});
    CTFontRef copy = CTFontCreateCopyWithAttributes(font, size, NULL, descriptor);
    CFRelease(descriptor);
    return copy;
}

#pragma mark - OpenType language names

static NSDictionary *GALanguageRegistry(void) {
    static NSDictionary *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"OpenTypeLanguages" withExtension:@"plist"];
        languages = [NSDictionary dictionaryWithContentsOfURL:url][@"languages"];
    });
    return languages;
}

NSString *GAIdentifierForOpenTypeLanguage(NSString *tag) {
    if (!tag.length) return nil;
    NSString *identifier = GALanguageRegistry()[tag][@"identifier"];
    return identifier.length ? [NSLocale canonicalLanguageIdentifierFromString:identifier] : nil;
}

NSString *GATitleForOpenTypeLanguage(NSString *tag, NSLocale *locale) {
    NSDictionary *entry = GALanguageRegistry()[tag];
    NSString *identifier = GAIdentifierForOpenTypeLanguage(tag);
    NSString *title = identifier && ![entry[@"usesRegistryName"] boolValue]
        ? [locale displayNameForKey:NSLocaleIdentifier value:identifier] : nil;
    return title ?: entry[@"name"] ?: [tag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}
