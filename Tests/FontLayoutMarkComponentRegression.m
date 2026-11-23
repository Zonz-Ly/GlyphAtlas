#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import "Font/GAFontEngine.h"
#import "Font/GATextQueryModel.h"
#import "FontLayout/GASubstitutionEngine.h"

static void require(BOOL condition, NSString *message) { NSCAssert(condition, @"%@", message); }
static const NSUInteger WeightTag=0x77676874;
static NSArray *target(void) { return @[@3,@4]; }
static NSArray *points(NSArray<NSValue *> *values, GAFontDocument *doc) {
    double scale=CTFontGetUnitsPerEm(doc.fontBox.font)/CTFontGetSize(doc.fontBox.font);
    NSMutableArray *result=[NSMutableArray array];
    for (NSValue *v in values) { NSPoint p=v.pointValue; [result addObject:@[@(p.x*scale),@(p.y*scale)]]; }
    return result;
}
static GAFontDocument *document(NSString *path) {
    NSURL *url=[NSURL fileURLWithPath:path];
    NSArray *descriptors=CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    require(descriptors.count==1,@"Fixture did not load");
    return [[GAFontDocument alloc] initWithDescriptor:(__bridge CTFontDescriptorRef)descriptors[0] URL:url];
}
static NSArray<GAScanCandidate *> *combinations(GARawScanResult *raw) {
    require(raw!=nil && !raw.incomplete,@"Uncancelled discovery failed");
    NSMutableArray *result=[NSMutableArray array];
    for (GAScanCandidate *c in raw.candidates) if ([c.glyphIDs isEqual:target()]) [result addObject:c];
    return result;
}
static id transcript(GARawScanResult *raw, GAFontDocument *doc) {
    NSMutableArray *result=[NSMutableArray array];
    for (GAScanCandidate *c in raw.candidates)
        [result addObject:@[c.glyphIDs,c.markComponents,points(c.positions,doc),c.sources,
                           NSStringFromRange(c.sourceRange),@(c.base),@(c.ligature)]];
    return result;
}
static void checkKnown(GARawScanResult *raw, GAFontDocument *doc, NSUInteger count) {
    NSArray *found=combinations(raw); require(found.count==count,@"Missing known combinations");
    for (GAScanCandidate *c in found) {
        require([c.markComponents isEqual:@[@-1,@0]],@"Component association lost");
        require([points(c.positions,doc) isEqual:@[@[@0,@0],@[@100,@500]]],@"Wrong first-component anchor");
    }
}
static void checkDeduplication(GAFontDocument *doc, GARawScanResult *original) {
    for (unsigned mode=0;mode<2;mode++) {
        BOOL indexed=mode!=0;
        GARawScanResult *raw=[doc rebindResult:original content:@"f\u0301i" cancelled:nil];
        GAScanCandidate *second=[[GAScanCandidate alloc] init], *duplicate=[[GAScanCandidate alloc] init];
        for (GAScanCandidate *c in @[second,duplicate]) {
            c.glyphIDs=target(); c.sourceRange=NSMakeRange(0,3); c.targetGroupIndex=2; c.ligature=YES;
        }
        second.markComponents=@[@-1,@1]; second.sources=@[@"second"];
        second.positions=@[[NSValue valueWithPoint:NSZeroPoint],[NSValue valueWithPoint:NSMakePoint(180,100)]];
        duplicate.markComponents=@[@-1,@0]; duplicate.sources=@[@"duplicate"];
        raw.candidates=[raw.candidates arrayByAddingObjectsFromArray:@[second,duplicate]];
        NSArray<GACharacterGroup *> *groups=GAGroupsForScanResult(@"f\u0301i",raw);
        if (indexed) {
            NSMutableArray *filler=[NSMutableArray array];
            for (unsigned i=0;i<32;i++) { GAGlyphVariant *v=[[GAGlyphVariant alloc] init]; v.glyphIDs=@[@0]; [filler addObject:v]; }
            groups.lastObject.variants=filler;
        }
        require([doc applyRawResult:raw groups:groups cancelled:nil],@"Apply failed");
        NSMutableArray *found=[NSMutableArray array];
        for (GAGlyphVariant *v in groups.lastObject.variants) if ([v.glyphIDs isEqual:target()]) [found addObject:v];
        require(found.count==2,@"Different component paths merged or exact duplicate retained");
        require([((GAGlyphVariant *)found[0]).markComponents isEqual:@[@-1,@0]] &&
                  [((GAGlyphVariant *)found[1]).markComponents isEqual:@[@-1,@1]],@"Candidate order changed");
        require([((GAGlyphVariant *)found[0]).featureSources containsObject:@"duplicate"],@"Duplicate label lost");
        NSArray *display=GABuildDisplayGroups(groups,@"f\u0301i",@[],doc,nil);
        NSUInteger inserted=0;
        for (GACharacterGroup *g in display) if (g.insertedLigature) {
            inserted++;
            require(g.variants.count==2,@"Combination projection merged component paths");
        }
        require(inserted==1,@"Unexpected combination groups");
        GAGlyphSelectionRun *selected=[[GAGlyphSelectionRun alloc] init]; selected.range=NSMakeRange(0,3);
        selected.selection=[[GAGlyphSelection alloc] initWithSourceText:@"f\u0301i" glyphIDs:target()
            markComponents:@[@-1,@0] featureSources:@[] ligature:YES];
        display=GABuildDisplayGroups(groups,@"f\u0301i",@[selected],doc,nil);
        inserted=0;
        for (GACharacterGroup *g in display) if (g.insertedLigature) {
            inserted++;
            require(g.variants.count==1 && [g.variants.firstObject.markComponents isEqual:@[@-1,@1]],
                    @"Selection suppressed a different component path");
        }
        require(inserted==1,@"Missing alternative to selected component path");
    }
}
static void checkSelections(GAFontDocument *doc) {
    NSMutableArray *keys=[NSMutableArray array];
    for (NSArray *components in @[@[@-1,@0],@[@-1,@1],@[]]) {
        GAGlyphSelectionRun *run=[[GAGlyphSelectionRun alloc] init]; run.range=NSMakeRange(0,3);
        run.selection=[[GAGlyphSelection alloc] initWithSourceText:@"f\u0301i" glyphIDs:target()
            markComponents:components featureSources:@[@"liga"] ligature:YES];
        GAGlyphQueryIdentity *key=GAGlyphQueryKey(@"f\u0301i",@[run]);
        for (id previous in keys) require(![previous isEqual:key],@"Query identity lost known components");
        [keys addObject:key];
        NSArray *expected=@[@[@0,@0],@[@(components.count && [components.lastObject intValue]==0 ? 100:900),@500]];
        NSArray *found=combinations([doc rawScanContent:@"f\u0301i" selections:@[run] cancelled:nil]);
        require(found.count==1,@"Selected root missing");
        GAScanCandidate *base=found.firstObject;
        require([base.markComponents isEqual:components] && [points(base.positions,doc) isEqual:expected],@"Selected root lost its component");
        GATextQueryModel *model=[[GATextQueryModel alloc] initWithFontDocument:doc];
        require([model analyzeText:@"f\u0301i" selections:@[run] cancelled:nil],@"Selected model query failed");
        NSArray<GACharacterGroup *> *display=GABuildDisplayGroups(model.groups,@"f\u0301i",@[run],doc,nil);
        require(display.count==1 && display.firstObject.seeded,@"Selected group changed");
        GAGlyphVariant *v=display.firstObject.variants.firstObject;
        require([v.markComponents isEqual:components] && [points(v.positions,doc) isEqual:expected],@"Selection projection lost component");
    }
}
static void checkGlyphEntryPoints(NSString *dir) {
    GAFontDocument *doc=document([dir stringByAppendingPathComponent:@"v6-entry.ttf"]);
    BOOL ligature=NO;
    for (GAGlyphVariant *v in [doc variantsForGlyphIDs:@[@1,@4,@2] cancelled:nil])
        if ([v.glyphIDs isEqual:target()]) {
            ligature=YES; require([v.markComponents isEqual:@[@-1,@0]],@"GID executor lost new component");
            require([points(v.positions,doc) isEqual:@[@[@0,@0],@[@100,@500]]],@"GID ligature wrong anchor");
        }
    require(ligature,@"GID ligature absent");
    for (NSArray *input in @[@[@-1,@0],@[@-1,@1],@[]]) {
        NSArray *variants=[doc variantsForGlyphIDs:target() markComponents:input content:@"f\u0301i" cancelled:nil];
        NSArray *cached=[doc variantsForGlyphIDs:target() markComponents:input content:@"f\u0301i" cancelled:nil];
        require(variants.count==cached.count,@"Seed cache changed count");
        BOOL single=NO,multiple=NO,deletion=NO;
        for (GAGlyphVariant *v in variants) {
            if ([v.glyphIDs isEqual:@[@3,@5]]) {
                single=YES; require([v.markComponents isEqual:input],@"Single substitution lost seed component");
                NSArray *expected=@[@(input.count && [input.lastObject intValue]==0 ? 100:900),@500];
                require([[points(v.positions,doc) lastObject] isEqual:expected],@"Derived seed candidate used fallback positioning");
            }
            if ([v.glyphIDs isEqual:@[@3,@5,@4]]) {
                multiple=YES; NSArray *wanted=input.count ? @[@-1,input.lastObject,input.lastObject]:@[];
                require([v.markComponents isEqual:wanted],@"Multiple substitution misaligned components");
            }
            if ([v.glyphIDs isEqual:@[@3]]) { deletion=YES; require(!v.markComponents.count,@"Deletion left stale component"); }
        }
        require(single && multiple && deletion,@"Seed derivation fixture incomplete");
    }
    GAGlyphSelectionRun *run=[GAGlyphSelectionRun new]; run.range=NSMakeRange(0,3);
    run.selection=[[GAGlyphSelection alloc] initWithSourceText:@"f\u0301i" glyphIDs:target()
        markComponents:@[@-1,@0] featureSources:@[] ligature:YES];
    GATextQueryModel *model=[[GATextQueryModel alloc] initWithFontDocument:doc];
    require([model analyzeText:@"f\u0301i" selections:@[run] cancelled:nil],@"Derived selection query failed");
    NSArray *display=GABuildDisplayGroups(model.groups,@"f\u0301i",@[run],doc,nil);
    NSUInteger derived=0;
    for (GACharacterGroup *g in display) if (g.seeded) for (GAGlyphVariant *v in g.variants)
        if ([v.glyphIDs isEqual:@[@3,@5]]) { derived++; require([v.markComponents isEqual:@[@-1,@0]],@"Selection retained an unknown derived duplicate"); }
    require(derived==1,@"Selection duplicated or lost a derived candidate");
}
static void checkFallback(GAFontDocument *doc, GAFontDocument *varied) {
    NSArray *disabled=@[@{(__bridge NSString *)kCTFontOpenTypeFeatureTag:@"liga",(__bridge NSString *)kCTFontOpenTypeFeatureValue:@0}];
    GASubstitutionEngine *engine=[[GASubstitutionEngine alloc] initWithFont:doc.fontBox.font coordinates:nil sharing:nil];
    GASubstitutionOrigin *o=[engine originForGlyphIDs:target() sourceRange:NSMakeRange(0,3) text:@"f\u0301i"
        selections:@[] candidates:@[@[@1,@4,@2]] vertical:NO featureSettings:disabled
        baseWritingDirection:-1 languageTag:@"" cancelled:^BOOL { return NO; }];
    require([o.markComponents isEqual:@[@-1,@0]],@"BFS lost newly discovered component");
    GACharacterGroup *group=[[GACharacterGroup alloc] init]; group.text=@"f\u0301i"; group.textRange=NSMakeRange(0,3);
    GAGlyphVariant *parent=[[GAGlyphVariant alloc] init]; parent.fontBox=doc.fontBox; parent.glyphIDs=@[@1,@4,@2]; group.variants=@[parent];
    GAGlyphResolution *resolution=[doc resolveGlyphIDs:target() textRange:group.textRange text:group.text selections:@[] groups:@[group]
        vertical:NO featureSettings:disabled baseWritingDirection:-1 languageTag:@"" cancelled:^BOOL { return NO; }];
    require(resolution.variant.temporary && [resolution.variant.markComponents isEqual:@[@-1,@0]],@"Temporary BFS candidate lost context");
    GAGlyphVariant *rebound=[varied rebindVariant:resolution.variant content:group.text];
    require([points(rebound.positions,varied) isEqual:@[@[@0,@0],@[@100,@500]]],@"BFS rebind lost anchor");
    o=[engine originForGlyphIDs:target() sourceRange:group.textRange text:group.text selections:@[] candidates:@[target()]
        vertical:NO featureSettings:disabled baseWritingDirection:-1 languageTag:@"" cancelled:^BOOL { return NO; }];
    require(o && !o.markComponents.count,@"Unknown BFS source gained guessed components");
}
static void checkMarkBoundaries(NSString *dir) {
    GAFontDocument *doc=document([dir stringByAppendingPathComponent:@"v6-boundary.ttf"]);
    NSArray *texts=@[@"f\u0301\u0300if",@"f\u0301i\u0300f",@"fi\u0301\u0300f"];
    NSArray *expected=@[@[@100,@700],@[@500,@500],@[@500,@700]];
    for (NSUInteger i=0;i<texts.count;i++) {
        GARawScanResult *raw=[doc rawScanContent:texts[i] selections:@[] cancelled:nil];
        BOOL found=NO;
        for (GAScanCandidate *c in raw.candidates) if ([c.glyphIDs isEqual:@[@3,@4,@5]]) {
            found=YES; require([[points(c.positions,doc) lastObject] isEqual:expected[i]],@"Native mkmk crossed components");
        }
        require(found,@"Boundary candidate absent");
    }
    GASubstitutionEngine *engine=[[GASubstitutionEngine alloc] initWithFont:doc.fontBox.font coordinates:nil sharing:nil];
    NSArray *ids=@[@3,@4,@5], *components=@[@-1,@0,@0], *owners=@[@0,@1,@2];
    NSArray *origins=[engine positionsForGlyphIDs:ids markComponents:components markLigatures:owners content:@""];
    require([[points(origins,doc) lastObject] isEqual:@[@100,@500]],@"Equal component numbers from different owners attached");
    NSArray *variants=[doc variantsForGlyphIDs:ids markComponents:components markLigatures:owners content:@"" cancelled:nil];
    require(variants.count==1,@"Owner seed fixture changed candidate count");
    GAGlyphVariant *v=variants.firstObject;
    require([v.markLigatures isEqual:owners] && [[points(v.positions,doc) lastObject] isEqual:@[@100,@500]],@"Owner seed lost its relationship");
    v=[doc rebindVariant:v content:@""];
    require([v.markLigatures isEqual:owners],@"Owner context lost during rebind");
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        require(argc==2,@"Expected fixture directory");
        NSString *dir=@(argv[1]);
        GAFontDocument *doc=document([dir stringByAppendingPathComponent:@"mark-components.ttf"]);
        NSString *text=@"f\u0301i";
        GARawScanResult *raw=[doc rawScanContent:text selections:@[] cancelled:nil];
        checkKnown(raw,doc,1);
        require([transcript(raw,doc) isEqual:transcript([doc rawScanContent:text selections:@[] cancelled:nil],doc)],@"Query cache changed associations");
        checkKnown([doc rebindResult:raw content:text cancelled:nil],doc,1);
        NSString *lines=@"f\u0301i\nfi\nf\u0301i";
        checkKnown([doc rawScanContent:lines selections:@[] cancelled:nil],doc,2);
        NSString *shifted=[@"fi\n" stringByAppendingString:lines];
        GARawScanResult *reused=[doc rawScanContent:shifted selections:@[] cancelled:nil];
        checkKnown(reused,doc,2);
        GAFontDocument *fresh=document([dir stringByAppendingPathComponent:@"mark-components.ttf"]);
        require([transcript(reused,doc) isEqual:transcript([fresh rawScanContent:shifted selections:@[] cancelled:nil],fresh)],@"Paragraph reuse differs from fresh discovery");
        CTFontDescriptorRef base=CTFontCopyFontDescriptor(doc.fontBox.font);
        CTFontDescriptorRef changed=CTFontDescriptorCreateCopyWithAttributes(base,(__bridge CFDictionaryRef)
            @{(__bridge NSString *)kCTFontVariationAttribute:@{@(WeightTag):@900}});
        GAFontDocument *varied=[doc documentWithDescriptor:changed]; CFRelease(base); CFRelease(changed);
        NSDictionary *coords=CFBridgingRelease(CTFontCopyVariation(varied.fontBox.font));
        require([coords[@(WeightTag)] doubleValue]==900,@"Variation not applied");
        checkKnown([varied rebindResult:raw content:text cancelled:nil],varied,1);
        NSArray<GACharacterGroup *> *groups=GAGroupsForScanResult(text,raw);
        require([doc applyRawResult:raw groups:groups cancelled:nil],@"Apply failed");
        BOOL saw=NO;
        for (GACharacterGroup *g in groups) for (GAGlyphVariant *v in g.variants) if ([v.glyphIDs isEqual:target()]) {
            GAGlyphVariant *rebound=[varied rebindVariant:v content:text]; saw=YES;
            require([rebound.markComponents isEqual:@[@-1,@0]] &&
                      [points(rebound.positions,varied) isEqual:@[@[@0,@0],@[@100,@500]]],@"Variant rebind lost component");
        }
        require(saw,@"No variant after projection");
        for (GAGlyphVariant *v in [doc variantsForGlyphIDs:target() cancelled:nil]) if ([v.glyphIDs isEqual:target()])
            require(!v.markComponents.count && [points(v.positions,doc) isEqual:@[@[@0,@0],@[@900,@500]]],@"Unknown GID fallback changed");
        checkDeduplication(doc,raw);
        checkSelections(doc);
        checkGlyphEntryPoints(dir);
        checkFallback(doc,varied);
        checkMarkBoundaries(dir);
        GASubstitutionEngine *engine=[[GASubstitutionEngine alloc] initWithFont:doc.fontBox.font coordinates:nil sharing:nil];
        GASubstitutionOrigin *origin=[engine originForGlyphIDs:target() sourceRange:NSMakeRange(0,3)
            text:text selections:@[] candidates:@[@[@1,@4,@2]] vertical:NO featureSettings:@[]
            baseWritingDirection:NSWritingDirectionNatural languageTag:@"" cancelled:^BOOL { return NO; }];
        require([origin.markComponents isEqual:@[@-1,@0]],@"Verified replay origin lost component");
        GAFontDocument *paths=document([dir stringByAppendingPathComponent:@"mark-component-paths.ttf"]);
        NSArray<GAScanCandidate *> *found=combinations([paths rawScanContent:text selections:@[] cancelled:nil]);
        BOOL first=NO,second=NO;
        for (GAScanCandidate *c in found) {
            if ([c.markComponents isEqual:@[@-1,@0]]) { first=YES; require([points(c.positions,paths) isEqual:@[@[@0,@0],@[@100,@500]]],@"First path wrong"); }
            if ([c.markComponents isEqual:@[@-1,@1]]) { second=YES; require([points(c.positions,paths) isEqual:@[@[@0,@0],@[@900,@500]]],@"Second path wrong"); }
        }
        require(first && second,@"GSUB discovery merged same-GID component paths");
        puts("Mark component discovery, cache, paragraph reuse, rebind, selection, origin, deduplication and GID controls PASS");
    }
}
