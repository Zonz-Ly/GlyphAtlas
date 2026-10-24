// Optional snapshot comparison. Compile against Glyph Atlas Old without writing
// into that folder. This executable is a test oracle and is never shipped.
#import "GAFontEngine.h"
#import "GAFontResource.h"
#import "GATextScanModel.h"
#import <Foundation/Foundation.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3)
            return 2;
        NSString *path = @(argv[1]), *text = @(argv[2]);
        CFArrayRef a = CTFontManagerCreateFontDescriptorsFromURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        NSArray *descriptors = CFBridgingRelease(a);
        GAFontResource *resource =
            [GAFontResource resourcesFromDescriptors:descriptors].firstObject;
        if (!resource)
            return 2;
        GAFontDocument *doc =
            [[GAFontDocument alloc] initWithDescriptor:resource.defaultDescriptor
                                                   URL:[NSURL fileURLWithPath:path]];
        GATextScanModel *model = [[GATextScanModel alloc] initWithFontDocument:doc];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [model updateText:text];
        NSUInteger tasks = 0;
        GATextScanSubitem *s;
        while ((s = [model startNextSubitem])) {
            [model completeSubitem:s result:[doc rawScanContent:s.content]];
            tasks++;
        }
        NSMutableArray *groups = [NSMutableArray array];
        for (GACharacterGroup *g in model.groups) {
            NSMutableArray *variants = [NSMutableArray array];
            for (GAGlyphVariant *v in g.variants)
                [variants addObject:@{
                    @"glyphs" : v.glyphIDs,
                    @"ligature" : @(v.isLigature),
                    @"range" : @[ @(v.sourceTextRange.location), @(v.sourceTextRange.length) ]
                }];
            [groups addObject:@{@"text" : g.text, @"variants" : variants}];
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:@{
            @"groups" : groups,
            @"tasks" : @(tasks),
            @"milliseconds" : @((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
                                                      options:0
                                                        error:nil];
        fwrite(out.bytes, 1, out.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
