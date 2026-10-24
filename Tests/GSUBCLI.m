#import "GAFontEngine.h"
#import "GAFontResource.h"
#import "GASubstitutionEngine.h"
#import "GATextScanModel.h"
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
static void Emit(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}
static NSArray *Names(CTFontRef font, NSArray<NSNumber *> *glyphs) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSNumber *g in glyphs)
        [names addObject:CFBridgingRelease(CTFontCopyNameForGlyph(font, g.unsignedShortValue))
                             ?: [NSString stringWithFormat:@"gid%@", g]];
    return names;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        NSMutableDictionary *features = [NSMutableDictionary dictionary],
                            *coordinates = [NSMutableDictionary dictionary];
        for (int i = 1; i < argc; i++) {
            NSString *key = @(argv[i]);
            if ([@[ @"--shape", @"--model", @"--reference-coretext" ] containsObject:key]) {
                options[key] = @YES;
                continue;
            }
            if (i + 1 >= argc) {
                fprintf(stderr, "Missing argument for %s\n", argv[i]);
                return 2;
            }
            NSString *value = @(argv[++i]);
            if ([key isEqual:@"--feature"]) {
                NSArray *p = [value componentsSeparatedByString:@"="];
                features[p[0]] = @(p.count > 1 ? [p[1] intValue] : 1);
            } else if ([key isEqual:@"--axis"]) {
                NSArray *p = [value componentsSeparatedByString:@"="];
                if (p.count != 2 || [p[0] length] != 4)
                    return 2;
                NSData *d = [p[0] dataUsingEncoding:NSASCIIStringEncoding];
                const uint8_t *b = d.bytes;
                uint32_t tag =
                    ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
                coordinates[@(tag)] = @([p[1] doubleValue]);
            } else
                options[key] = value;
        }
        NSString *path = options[@"--font"];
        if (!path) {
            fprintf(stderr, "Usage: gsub-cli --font PATH --text TEXT [--shape] [--feature "
                            "tag=value] [--axis tag=value] [--branch N] [--model]\n");
            return 2;
        }
        CFArrayRef array = CTFontManagerCreateFontDescriptorsFromURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        NSArray *descriptors = array ? CFBridgingRelease(array) : @[];
        NSArray<GAFontResource *> *resources =
            [GAFontResource resourcesFromDescriptors:descriptors];
        NSUInteger face = [options[@"--face"] integerValue];
        if (face >= resources.count) {
            Emit(@{@"error" : @"No readable resource at requested face"});
            return 2;
        }
        GAFontResource *resource = resources[face];
        NSMutableDictionary *coords = [resource.defaultCoordinates mutableCopy];
        [coords addEntriesFromDictionary:coordinates];
        CTFontDescriptorRef descriptor =
            coords.count ? [resource copyDescriptorWithCoordinates:coords]
                         : (CTFontDescriptorRef)CFRetain(resource.defaultDescriptor);
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 200, NULL);
        GASubstitutionEngine *engine = [[GASubstitutionEngine alloc] initWithFont:font
                                                                      coordinates:coords
                                                                          sharing:nil];
        NSString *text = options[@"--text"] ?: @"";
        @try {
            if (options[@"--positions"]) {
                NSMutableArray *g = [NSMutableArray array];
                for (NSString *part in [options[@"--positions"] componentsSeparatedByString:@","])
                    [g addObject:@(part.intValue)];
                NSMutableArray *positions = [NSMutableArray array];
                for (NSValue *v in [engine positionsForGlyphIDs:g content:text])
                    [positions addObject:@[ @(v.pointValue.x), @(v.pointValue.y) ]];
                Emit(@{@"positions" : positions});
            } else if (options[@"--gids"]) {
                NSMutableArray *g = [NSMutableArray array];
                for (NSString *part in [options[@"--gids"] componentsSeparatedByString:@","])
                    [g addObject:@(part.intValue)];
                NSMutableArray *out = [NSMutableArray array];
                for (GASubstitutionMatch *m in [engine discoverGlyphIDs:g])
                    [out addObject:@{
                        @"glyphs" : m.glyphIDs,
                        @"names" : Names(font, m.glyphIDs),
                        @"sources" : m.sources,
                        @"base" : @(m.base)
                    }];
                Emit(@{@"matches" : out});
            } else if (options[@"--reference-coretext"]) {
                NSMutableArray *settings = [NSMutableArray array];
                for (NSString *tag in features)
                    [settings addObject:@{
                        (__bridge NSString *)kCTFontOpenTypeFeatureTag : tag,
                        (__bridge NSString *)kCTFontOpenTypeFeatureValue : features[tag]
                    }];
                CTFontDescriptorRef d = CTFontDescriptorCreateCopyWithAttributes(
                    descriptor,
                    (__bridge CFDictionaryRef)
                        @{(__bridge NSString *)kCTFontFeatureSettingsAttribute : settings});
                CTFontRef configured = CTFontCreateWithFontDescriptor(d, 200, NULL);
                CFRelease(d);
                CTLineRef line = CTLineCreateWithAttributedString(
                    (__bridge CFAttributedStringRef)[[NSAttributedString alloc]
                        initWithString:text
                            attributes:@{
                                (__bridge NSString *)kCTFontAttributeName : (__bridge id)configured
                            }]);
                NSMutableArray *glyphs = [NSMutableArray array], *clusters = [NSMutableArray array];
                for (id obj in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
                    CTRunRef run = (__bridge CTRunRef)obj;
                    CFIndex n = CTRunGetGlyphCount(run);
                    CGGlyph *g = calloc(n, sizeof(*g));
                    CFIndex *s = calloc(n, sizeof(*s));
                    CTRunGetGlyphs(run, CFRangeMake(0, n), g);
                    CTRunGetStringIndices(run, CFRangeMake(0, n), s);
                    for (CFIndex j = 0; j < n; j++) {
                        [glyphs addObject:@(g[j])];
                        [clusters addObject:@(s[j])];
                    }
                    free(g);
                    free(s);
                }
                Emit(@{
                    @"glyphs" : glyphs,
                    @"names" : Names(configured, glyphs),
                    @"clusters" : clusters
                });
                CFRelease(line);
                CFRelease(configured);
            } else if (options[@"--shape"]) {
                NSMutableDictionary *result =
                    [[engine shapeText:text
                              features:features
                                script:options[@"--script"]
                              language:options[@"--language"]
                                branch:[options[@"--branch"] integerValue]] mutableCopy];
                result[@"names"] = Names(font, result[@"glyphs"]);
                Emit(result);
            } else if (options[@"--model"]) {
                GAFontDocument *document =
                    [[GAFontDocument alloc] initWithDescriptor:descriptor
                                                           URL:[NSURL fileURLWithPath:path]];
                GATextScanModel *model = [[GATextScanModel alloc] initWithFontDocument:document];
                CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
                [model updateText:text];
                NSUInteger tasks = 0;
                GATextScanSubitem *s;
                while ((s = [model startNextSubitem])) {
                    [model completeSubitem:s result:[document rawScanContent:s.content]];
                    tasks++;
                }
                NSMutableArray *groups = [NSMutableArray array];
                for (GACharacterGroup *group in model.groups) {
                    NSMutableArray *variants = [NSMutableArray array];
                    for (GAGlyphVariant *v in group.variants)
                        [variants addObject:@{
                            @"glyphs" : v.glyphIDs,
                            @"names" : Names(font, v.glyphIDs),
                            @"sources" : v.featureSources,
                            @"base" : @(v.base),
                            @"ligature" : @(v.ligature),
                            @"range" :
                                @[ @(v.sourceTextRange.location), @(v.sourceTextRange.length) ]
                        }];
                    [groups addObject:@{
                        @"text" : group.text,
                        @"range" : @[ @(group.textRange.location), @(group.textRange.length) ],
                        @"variants" : variants
                    }];
                }
                Emit(@{
                    @"tasks" : @(tasks),
                    @"milliseconds" : @((CFAbsoluteTimeGetCurrent() - begin) * 1000),
                    @"groups" : groups
                });
            } else {
                CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
                NSArray *matches = [engine discoverText:text];
                NSMutableArray *output = [NSMutableArray array];
                for (GASubstitutionMatch *m in matches)
                    [output addObject:@{
                        @"glyphs" : m.glyphIDs,
                        @"names" : Names(font, m.glyphIDs),
                        @"sources" : m.sources,
                        @"base" : @(m.base),
                        @"range" : @[ @(m.sourceRange.location), @(m.sourceRange.length) ]
                    }];
                Emit(@{
                    @"matches" : output,
                    @"milliseconds" : @((CFAbsoluteTimeGetCurrent() - begin) * 1000),
                    @"features" : engine.featureSpecifications
                });
            }
        } @catch (NSException *exception) {
            Emit(@{@"error" : exception.reason ?: exception.name});
            CFRelease(font);
            CFRelease(descriptor);
            return 1;
        }
        CFRelease(font);
        CFRelease(descriptor);
        return 0;
    }
}
