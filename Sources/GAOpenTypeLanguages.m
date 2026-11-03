#import "GAOpenTypeLanguages.h"

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
