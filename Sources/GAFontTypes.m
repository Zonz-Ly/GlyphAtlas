#import "GAFontTypes.h"

NSArray<UTType *> *GAFontContentTypes(void) {
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypeFont];
    for (NSString *identifier in @[@"org.w3c.woff", @"org.w3c.woff2"]) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type != nil) {
            [types addObject:type];
        }
    }
    return types;
}

BOOL GAFontURLIsFont(NSURL *url) {
    id value = nil;
    NSError *error = nil;
    if (![url getResourceValue:&value forKey:NSURLContentTypeKey error:&error]) {
        return NO;
    }
    if (![value isKindOfClass:UTType.class]) {
        return NO;
    }
    UTType *type = (UTType *)value;
    if ([type conformsToType:UTTypeFont]) {
        return YES;
    }
    NSString *identifier = type.identifier.lowercaseString;
    return [identifier isEqualToString:@"org.w3c.woff"] ||
           [identifier isEqualToString:@"org.w3c.woff2"];
}
