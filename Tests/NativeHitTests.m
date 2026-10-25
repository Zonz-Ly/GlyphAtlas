#import "GADisplayGroups.h"
#import "GAFontEngine.h"
#import "GAFontResource.h"
#import "GATextDisplay.h"
#import "GATextHitMap.h"
#import "GATextQueryModel.h"
#import "ReferenceNativeTextHit.h"
static NSUInteger checks;
static void Check(BOOL value, NSString *message) {
  checks++;
  if (!value) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}
static GAFontDocument *Document(NSString *path) {
  CFArrayRef raw = CTFontManagerCreateFontDescriptorsFromURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
  NSArray *descriptors = CFBridgingRelease(raw);
  GAFontResource *resource =
      [GAFontResource resourcesFromDescriptors:descriptors].firstObject;
  return
      [[GAFontDocument alloc] initWithDescriptor:resource.defaultDescriptor
                                             URL:[NSURL fileURLWithPath:path]];
}
static NSArray *Hits(NSAttributedString *display, CGFloat width,
                     NSArray *sourceIndices, NSArray *atomic,
                     NSString *source) {
  NSTextContentStorage *content = [NSTextContentStorage new];
  content.attributedString = display;
  NSTextLayoutManager *layout = [NSTextLayoutManager new];
  [content addTextLayoutManager:layout];
  NSTextContainer *container =
      [[NSTextContainer alloc] initWithSize:NSMakeSize(width, 100000)];
  container.lineFragmentPadding = 0;
  layout.textContainer = container;
  [layout ensureLayoutForRange:content.documentRange];
  NSMutableArray *all = [NSMutableArray array];
  [layout
      enumerateTextLayoutFragmentsFromLocation:nil
                                       options:0
                                    usingBlock:^BOOL(
                                        NSTextLayoutFragment *fragment) {
                                      NSInteger offset = [content
                                          offsetFromLocation:content
                                                                 .documentRange
                                                                 .location
                                                  toLocation:fragment
                                                                 .rangeInElement
                                                                 .location];
                                      for (NSTextLineFragment *line in fragment
                                               .textLineFragments)
                                        for (GANativeGlyphHit *hit in
                                                 GANativeGlyphHitsForLine(line,
                                                                          NO)) {
                                          hit.range = NSMakeRange(
                                              offset + hit.range.location,
                                              hit.range.length);
                                          [all addObject:hit];
                                        }
                                      return YES;
                                    }];
  return GAMapNativeGlyphHits(all, sourceIndices, atomic, source);
}
static NSArray *Prediction(NSAttributedString *display, CGFloat width,
                           NSArray *pins, NSArray *indices, NSArray *atomic,
                           NSString *source, GAFontDocument *document,
                           BOOL contextual, BOOL ligatures, BOOL vertical) {
  NSTextContentStorage *content = [NSTextContentStorage new];
  content.attributedString = display;
  NSTextLayoutManager *layout = [NSTextLayoutManager new];
  [content addTextLayoutManager:layout];
  NSTextContainer *container =
      [[NSTextContainer alloc] initWithSize:NSMakeSize(width, 100000)];
  container.lineFragmentPadding = 0;
  layout.textContainer = container;
  [layout ensureLayoutForRange:content.documentRange];
  return GAMapGlyphLayoutRuns(GAPredictDisplayGlyphRuns(layout, pins, document,
                                                        contextual, ligatures,
                                                        vertical),
                              indices, atomic, source);
}
static void Match(NSArray *hits, NSArray<GACharacterGroup *> *groups,
                  NSString *source, NSString *label) {
  for (GANativeGlyphHit *hit in hits) {
    if ([[source substringWithRange:hit.range]
            rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet
                                        .invertedSet]
            .location == NSNotFound)
      continue;
    BOOL found = NO;
    for (GACharacterGroup *g in groups)
      if (NSEqualRanges(g.textRange, hit.range))
        for (GAGlyphVariant *v in g.variants)
          found |= [v.glyphIDs isEqual:hit.glyphIDs];
    Check(found, [label stringByAppendingFormat:@" %@ GIDs %@",
                                                NSStringFromRange(hit.range),
                                                hit.glyphIDs]);
  }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    Check(NSApp == nil, @"no GUI application");
    NSArray *cases = @[
      @[
        @"/Users/zonz/Library/Fonts/LucidaSubmono.otf",
        @"Wi Wi Objective-C Wi\nWi"
      ],
      @[
        @"/System/Library/Fonts/Supplemental/Zapfino.ttf", @"ffi fi st office"
      ],
      @[
        @"/Users/zonz/Library/Fonts/Futura100CHI-Var.ttf",
        @"QrekӘеж， QrekӘеж，"
      ],
      @[
        @"/Users/zonz/Library/Fonts/ThemeX Hiragino Sans.ttc",
        @"漢字、。『邊骨』"
      ]
    ];
    for (NSArray *item in cases) {
      if (![[NSFileManager defaultManager] fileExistsAtPath:item[0]])
        continue;
      GAFontDocument *base = Document(item[0]);
      for (NSNumber *weight in @[ @300, @700 ]) {
        CTFontDescriptorRef desc = CTFontCopyFontDescriptor(base.fontBox.font);
        CTFontDescriptorRef varied = CTFontDescriptorCreateCopyWithAttributes(
            desc, (__bridge CFDictionaryRef) @{
              (__bridge NSString *)
              kCTFontVariationAttribute : @{@(0x77676874) : weight}
            });
        GAFontDocument *document = [base documentWithDescriptor:varied];
        CFRelease(desc);
        CFRelease(varied);
        GATextQueryModel *model =
            [[GATextQueryModel alloc] initWithFontDocument:document];
        [model analyzeText:item[1] selections:@[] cancelled:nil];
        NSArray *groups =
            GABuildDisplayGroups(model.groups, item[1], @[], document);
        NSMutableArray *indices = [NSMutableArray array];
        for (NSUInteger i = 0; i < [item[1] length]; i++)
          [indices addObject:@(i)];
        for (NSNumber *context in @[ @NO, @YES ])
          for (NSNumber *liga in @[ @NO, @YES ])
            for (NSNumber *vertical in @[ @NO, @YES ]) {
              NSString *name = [item[0] lastPathComponent];
              BOOL sample =
                  ([name hasPrefix:@"Lucida"] && weight.integerValue == 300 &&
                   !vertical.boolValue) ||
                  ([name hasPrefix:@"Zapfino"] && weight.integerValue == 300 &&
                   !vertical.boolValue && !context.boolValue) ||
                  ([name hasPrefix:@"Futura"] && !vertical.boolValue &&
                   !context.boolValue && !liga.boolValue) ||
                  ([name containsString:@"Hiragino"] &&
                   weight.integerValue == 300 && vertical.boolValue &&
                   !context.boolValue && !liga.boolValue);
              if (!sample)
                continue;
              CTFontRef font = GACopyTextDisplayFont(document.fontBox.font, 32,
                                                     context.boolValue, liga.boolValue);
              NSAttributedString *display = [[NSAttributedString alloc]
                  initWithString:item[1]
                      attributes:@{
                        NSFontAttributeName : (__bridge id)font,
                        NSLigatureAttributeName : @1,
                        NSVerticalGlyphFormAttributeName : vertical
                      }];
              NSArray *native = Hits(display, 150, indices, @[], item[1]);
              NSArray *own = Prediction(display, 150, @[], indices, @[],
                                        item[1], document, context.boolValue,
                                        liga.boolValue, vertical.boolValue);
              for (GANativeGlyphHit *hit in native) {
                NSString *part = [item[1] substringWithRange:hit.range];
                if ([part rangeOfCharacterFromSet:NSCharacterSet
                                                      .newlineCharacterSet
                                                      .invertedSet]
                        .location == NSNotFound)
                  continue;
                BOOL found = NO;
                for (GAGlyphLayoutRun *run in own)
                  found |= NSEqualRanges(run.range, hit.range) &&
                           [run.glyphIDs isEqual:hit.glyphIDs];
                Check(
                    found,
                    [NSString
                        stringWithFormat:
                            @"prediction %@ w%@ calt%@ liga%@ vert%@ %@ GIDs%@",
                            name, weight, context, liga, vertical,
                            NSStringFromRange(hit.range), hit.glyphIDs]);
              }
              Match(native, groups, item[1], name);
              CFRelease(font);
            }
      }
    }
    if (argc == 2) {
      GAFontDocument *document = Document([@(argv[1])
          stringByAppendingPathComponent:@"unencoded-neighbor.ttf"]);
      GAGlyphSelectionRun *run = [GAGlyphSelectionRun new];
      run.range = NSMakeRange(0, 1);
      run.selection = [[GAGlyphSelection alloc] initWithSourceText:@"a"
                                                          glyphIDs:@[ @9, @19 ]
                                                    featureSources:@[]
                                                          ligature:NO];
      GATextQueryModel *model =
          [[GATextQueryModel alloc] initWithFontDocument:document];
      [model analyzeText:@"ab" selections:@[ run ] cancelled:nil];
      NSArray *groups =
          GABuildDisplayGroups(model.groups, @"ab", @[ run ], document);
      CTFontRef font = GACopyTextDisplayFont(document.fontBox.font, 32, NO, YES);
      NSDictionary *attrs = @{
        NSFontAttributeName : (__bridge id)font,
        NSLigatureAttributeName : @1
      };
      NSAttributedString *seed = GACreateSeedDisplayString(
          @[ @9, @19 ], @"a", (__bridge NSFont *)font, attrs, nil);
      NSMutableAttributedString *display =
          [[NSMutableAttributedString alloc] initWithString:@"ab"
                                                 attributes:attrs];
      NSMutableArray *indices = [@[ @0, @1 ] mutableCopy];
      GAReplaceSeedDisplayRange(display, indices, NSMakeRange(0, 1), seed);
      NSMutableArray *pins = [NSMutableArray array];
      for (NSNumber *gid in @[ @9, @19 ])
        [pins addObject:[[GAGlyphSelection alloc] initWithSourceText:@"a"
                                                            glyphIDs:@[ gid ]
                                                      featureSources:@[]
                                                            ligature:NO]];
      [pins addObject:NSNull.null];
      for (NSNumber *width in @[ @20, @150 ]) {
        NSArray *native = Hits(display, width.doubleValue, indices,
                               @[ [NSValue valueWithRange:run.range] ], @"ab");
        NSArray *own = Prediction(display, width.doubleValue, pins, indices,
                                  @[ [NSValue valueWithRange:run.range] ],
                                  @"ab", document, NO, YES, NO);
        for (GANativeGlyphHit *hit in native) {
          BOOL found = NO;
          for (GAGlyphLayoutRun *value in own)
            found |= NSEqualRanges(hit.range, value.range) &&
                     [hit.glyphIDs isEqual:value.glyphIDs];
          Check(found,
                [NSString stringWithFormat:@"pinned prediction width%@ %@ %@",
                                           width, NSStringFromRange(hit.range),
                                           hit.glyphIDs]);
        }
        Match(native, groups, @"ab",
              @"expanded seed with neighbor and wrapping");
      }
      CFRelease(font);
      for (NSString *fixture in @[
             @"morx-vertical-only.ttf", @"vertical-only.ttf", @"position.ttf"
           ]) {
        document =
            Document([@(argv[1]) stringByAppendingPathComponent:fixture]);
        NSString *source =
            [fixture isEqualToString:@"position.ttf"] ? @"á" : @"a";
        model = [[GATextQueryModel alloc] initWithFontDocument:document];
        [model analyzeText:source selections:@[] cancelled:nil];
        groups = GABuildDisplayGroups(model.groups, source, @[], document);
        font = GACopyTextDisplayFont(document.fontBox.font, 32, NO, NO);
        NSAttributedString *text = [[NSAttributedString alloc]
            initWithString:source
                attributes:@{
                  NSFontAttributeName : (__bridge id)font,
                  NSLigatureAttributeName : @1,
                  NSVerticalGlyphFormAttributeName : @YES
                }];
        NSMutableArray *mapping = [NSMutableArray array];
        for (NSUInteger i = 0; i < source.length; i++)
          [mapping addObject:@(i)];
        Match(Hits(text, 150, mapping, @[], source), groups, source, fixture);
        CFRelease(font);
      }
    }
    NSString *hira = @"/Users/zonz/Library/Fonts/ThemeX Hiragino Sans.ttc";
    if ([[NSFileManager defaultManager] fileExistsAtPath:hira]) {
      GAFontDocument *document = Document(hira);
      CTFontRef font = GACopyTextDisplayFont(document.fontBox.font, 32, NO, NO);
      for (NSNumber *scalar in @[ @0x201C, @0x201D, @0x2018, @0x2019 ]) {
        unichar c = scalar.unsignedShortValue;
        CGGlyph base = 0;
        CTFontGetGlyphsForCharacters(font, &c, &base, 1);
        NSNumber *vertical = [document verticalSubstituteForGlyph:base];
        if (!vertical)
          continue;
        NSString *source = [NSString stringWithCharacters:&c length:1];
        NSDictionary *attrs = @{
          NSFontAttributeName : (__bridge id)font,
          NSLigatureAttributeName : @1,
          NSVerticalGlyphFormAttributeName : @YES
        };
        NSMutableAttributedString *display =
            [[NSMutableAttributedString alloc] initWithString:@"字"
                                                   attributes:attrs];
        NSGlyphInfo *info =
            [NSGlyphInfo glyphInfoWithGlyph:vertical.unsignedShortValue
                                    forFont:(__bridge NSFont *)font
                                 baseString:@"字"];
        [display addAttribute:NSGlyphInfoAttributeName
                        value:info
                        range:NSMakeRange(0, display.length)];
        GAGlyphSelection *pin =
            [[GAGlyphSelection alloc] initWithSourceText:@"字"
                                                glyphIDs:@[ vertical ]
                                          featureSources:@[]
                                                ligature:NO];
        NSArray *own =
            Prediction(display, 150, @[ pin ], @[ @0 ],
                       @[ [NSValue valueWithRange:NSMakeRange(0, 1)] ], source,
                       document, NO, NO, YES);
        // This verifies our new alias/pin projection only. A standalone
        // typesetter does not reproduce NSTextView's vertical orientation.
        Check(own.count == 1 && [[own[0] glyphIDs] isEqual:@[ vertical ]] &&
                  NSEqualRanges([own[0] range], NSMakeRange(0, 1)),
              @"vertical quote keeps the forced GID and original source range");
      }
      CFRelease(font);
    }
    Check(NSApp == nil, @"no GUI used for native hit mapping");
    printf("OK: %lu layout-choice/hit assertions; CoreText test oracle only, "
           "no GUI\n",
           (unsigned long)checks);
  }
}
