#import "GASubstitutionEngine.h"
#import "GAAAT.h"
#import "GACmap.h"
#import "GAKerning.h"
#import "GATextPreparation.h"
#import "GAVariation.h"
#include <map>

using namespace ga::layout;
@implementation GASubstitutionMatch
@end

namespace {
View tableBytes(CTFontRef font, Tag name) {
    NSData *data = CFBridgingRelease(CTFontCopyTable(font, name, 0));
    if (!data.length)
        return {};
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    return View(std::vector<uint8_t>(bytes, bytes + data.length));
}
struct Domain {
    bool apple = false;
    size_t branch = 0;
    std::optional<AATSelector> selector;
};
struct Resource {
    Cmap cmap;
    GDEF gdef;
    OpenType gsub, gpos{{}, true};
    AAT aat;
    Kerning kerning;
    View fvar, avar;
    bool verticalAAT = false;
    unsigned glyphCount = 0;
    double unitsPerEm = 1000;
    std::vector<Domain> domains;
    std::vector<Feature> featureSpecs;
    std::vector<std::string> diagnostics;
    Resource(CTFontRef font) {
        glyphCount = unsigned(CTFontGetGlyphCount(font));
        unitsPerEm = CTFontGetUnitsPerEm(font);
        auto read = [&](Tag name, auto &&assign) {
            try {
                assign(tableBytes(font, name));
            } catch (const InvalidTable &error) {
                diagnostics.push_back(tagName(name) + ": " + error.what());
            }
        };
        read(tag('c', 'm', 'a', 'p'), [&](View data) { cmap = Cmap(data); });
        read(tag('G', 'D', 'E', 'F'), [&](View data) { gdef = GDEF(data); });
        read(tag('G', 'S', 'U', 'B'), [&](View data) { gsub = OpenType(data); });
        read(tag('G', 'P', 'O', 'S'), [&](View data) { gpos = OpenType(data, true); });
        read(tag('m', 'o', 'r', 'x'), [&](View data) { aat = AAT(data, true); });
        if (aat.empty())
            read(tag('m', 'o', 'r', 't'), [&](View data) { aat = AAT(data, false); });
        kerning = Kerning(tableBytes(font, tag('k', 'e', 'r', 'n')),
                          tableBytes(font, tag('k', 'e', 'r', 'x')));
        fvar = tableBytes(font, tag('f', 'v', 'a', 'r'));
        avar = tableBytes(font, tag('a', 'v', 'a', 'r'));
        if (!aat.empty()) {
            domains.push_back({true, 0, {}});
            for (auto selector : aat.selectors())
                domains.push_back({true, 0, selector});
        }
        if (aat.empty() || !gsub.features().empty())
            for (size_t i = 0; i < gsub.branchCount(); i++)
                domains.push_back({false, i, {}});
        featureSpecs = collectFeatures();
        verticalAAT = aat.hasVerticalSubstitutions();
    }
    const std::vector<Feature> &specifications() const {
        return featureSpecs;
    }
    std::vector<Feature> collectFeatures() const {
        std::vector<Feature> result;
        for (size_t branch = 0; branch < gsub.branchCount(); branch++)
            for (const auto &f : gsub.features(branch)) {
                auto found = std::find_if(result.begin(), result.end(), [&](const Feature &other) {
                    return other.name == f.name;
                });
                if (found == result.end())
                    result.push_back(f);
                else
                    found->maximum = std::max(found->maximum, f.maximum);
            }
        return result;
    }
    void substitute(Buffer &items, const Domain &domain, const Settings &settings,
                    Trace *trace = nullptr) const {
        if (domain.apple)
            aat.substitute(items, domain.selector, settings.rtl, settings.vertical, trace);
        else
            gsub.substitute(items, gdef, settings, domain.branch, trace);
    }
};
#if GA_FONT_LAYOUT_TESTING
std::string sourceName(const Resource &resource, const Domain &domain) {
    if (!domain.apple)
        return "";
    std::string name = resource.aat.name();
    if (domain.selector)
        name += ":" + std::to_string(domain.selector->type) + ":" +
                std::to_string(domain.selector->setting);
    return name;
}
#endif
NSArray<NSNumber *> *glyphArray(const std::vector<Glyph> &glyphs) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:glyphs.size()];
    for (Glyph glyph : glyphs)
        [array addObject:@(glyph)];
    return array;
}
std::vector<Glyph> glyphVector(NSArray<NSNumber *> *glyphs) {
    std::vector<Glyph> result;
    for (NSNumber *glyph in glyphs)
        result.push_back(glyph.unsignedShortValue);
    return result;
}
NSString *matchKey(Span span, NSArray *glyphs) {
    return [NSString stringWithFormat:@"%u:%u:%@", span.start, span.end, glyphs];
}
void merge(NSMutableDictionary *seen, NSMutableArray<GASubstitutionMatch *> *matches, Span span,
           const std::vector<Glyph> &glyphs, NSString *source, BOOL base) {
    if (span.empty())
        return;
    NSArray *ids = glyphArray(glyphs);
    NSString *key = matchKey(span, ids);
    GASubstitutionMatch *match = seen[key];
    if (!match) {
        match = [[GASubstitutionMatch alloc] init];
        match.glyphIDs = ids;
        match.sourceRange = NSMakeRange(span.start, span.end - span.start);
        match.sources = @[];
        match.base = base;
        seen[key] = match;
        [matches addObject:match];
    }
    match.base |= base;
    if (source.length && ![match.sources containsObject:source])
        match.sources = [match.sources arrayByAddingObject:source];
}
Buffer literalBuffer(const std::vector<Glyph> &glyphs) {
    Buffer buffer;
    for (size_t i = 0; i < glyphs.size(); i++) {
        Item item;
        item.glyph = glyphs[i];
        item.source = {uint32_t(i), uint32_t(i + 1)};
        item.identity = i + 1;
        buffer.push_back(item);
    }
    return buffer;
}
std::vector<Glyph> identifiers(const Buffer &buffer) {
    std::vector<Glyph> result;
    for (const auto &item : buffer)
        result.push_back(item.glyph);
    return result;
}
std::vector<std::pair<Tag, unsigned>> plans(const Resource &resource, const Domain &domain) {
    std::vector<std::pair<Tag, unsigned>> result{{0, 0}};
    if (!domain.apple)
        for (const auto &feature : resource.specifications())
            for (unsigned value = 1; value <= feature.maximum; value++)
                result.emplace_back(feature.name, value);
    return result;
}
} // namespace

// The resource program owns only immutable table bytes. Coordinate-specific
// fonts and layout state belong to an engine instance, outside the shared cache.
@interface GAFontProgram : NSObject {
  @public
    std::shared_ptr<Resource> resource;
}
@property(nonatomic, strong) NSCache<id, NSDictionary *> *cache;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *errors;
@property(nonatomic, strong) NSCache<NSNumber *, NSArray<NSDictionary *> *> *relatedCache;
@end
@implementation GAFontProgram
- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (self) {
        resource = std::make_shared<Resource>(font);
        _errors = [NSMutableOrderedSet orderedSet];
        for (const auto &message : resource->diagnostics)
            [_errors addObject:@(message.c_str())];
        _cache = [[NSCache alloc] init];
        _relatedCache = [[NSCache alloc] init];
        _relatedCache.countLimit = 2048;
        _relatedCache.totalCostLimit = 16 * 1024 * 1024;
        _cache.countLimit = 2048;
        _cache.totalCostLimit = 32 * 1024 * 1024;
    }
    return self;
}
@end

@interface GASubstitutionEngine ()
@property(nonatomic, strong) GAFontProgram *program;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
- (NSArray<NSDictionary *> *)relatedOutputs:(Glyph)glyph;
- (NSDictionary *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections;
@end
@implementation GASubstitutionEngine {
    CTFontRef _font;
}
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(NSDictionary *)coordinates
                     sharing:(GASubstitutionEngine *)source {
    self = [super init];
    if (self) {
        _font = (CTFontRef)CFRetain(font);
        _program = source.program ?: [[GAFontProgram alloc] initWithFont:font];
        _coordinates = [coordinates copy] ?: @{};
    }
    return self;
}
- (void)dealloc {
    if (_font)
        CFRelease(_font);
}
- (NSArray<NSString *> *)diagnostics {
    @synchronized(self.program) {
        return self.program.errors.array;
    }
}
- (void)recordError:(const std::exception &)error {
    @synchronized(self.program) {
        [self.program.errors addObject:@(error.what())];
    }
}
#if GA_FONT_LAYOUT_TESTING
- (NSArray *)featureSpecifications {
    const auto &r = *self.program->resource;
    NSMutableArray *result = [NSMutableArray array];
    for (const auto &f : r.specifications())
        [result addObject:@{@"tag" : @(tagName(f.name).c_str()), @"max" : @(f.maximum)}];
    for (const auto &domain : r.domains)
        if (domain.apple)
            [result addObject:@{
                @"tag" : @(sourceName(r, domain).c_str()),
                @"max" : @1,
                @"engine" : @(r.aat.name().c_str())
            }];
    return result;
}
#endif
- (NSArray<NSDictionary *> *)relatedOutputs:(Glyph)glyph {
    NSArray *cached = [self.program.relatedCache objectForKey:@(glyph)];
    if (cached)
        return cached;
    NSMutableArray *outputs = [NSMutableArray array];
    try {
        const auto &r = *self.program->resource;
        for (const auto &output : r.gsub.relatedSubstitutions(glyph, r.gdef)) {
            std::string label = tagName(output.feature);
            if (output.value > 1)
                label += " " + std::to_string(output.value);
            [outputs addObject:@{
                @"glyphs" : glyphArray(output.glyphs),
                @"source" : @(label.c_str()),
                @"family" : @(output.directFamily)
            }];
        }
        if (r.verticalAAT)
            for (const auto &domain : r.domains) {
                if (!domain.apple || (domain.selector && domain.selector->type != 4)) continue;
                Buffer input = literalBuffer({glyph});
                Trace trace;
                r.aat.substitute(input,domain.selector,false,true,&trace,true);
                auto ids = identifiers(input);
                if (ids == std::vector<Glyph>{glyph}) continue;
                std::string source = r.aat.name();
                if (domain.selector) source += ":" + std::to_string(domain.selector->type) + ":" + std::to_string(domain.selector->setting);
                [outputs addObject:@{@"glyphs":glyphArray(ids),@"source":@(source.c_str()),@"family":@YES}];
            }
    } catch (const InvalidTable &error) {
        [self recordError:error];
    }
    [self.program.relatedCache setObject:outputs forKey:@(glyph) cost:outputs.count * 128];
    return outputs;
}
- (NSDictionary *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    GAGlyphQueryIdentity *queryKey = GAGlyphQueryKey(text, selections);
    NSDictionary *cached = [self.program.cache objectForKey:queryKey];
    if (cached)
        return cached;
    const auto &r = *self.program->resource;
    auto runs = prepareText(text, r.cmap, selections);
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    // Baselines are a glyph-level projection, not independent text queries.
    // Cache repeated input sequences within this request, then attach each to
    // its own UTF-16 span. Explicit seeds keep their exact original GIDs.
    using BaseKey = std::tuple<Tag, bool, bool, std::vector<Glyph>>;
    using BaseValue = std::pair<std::vector<Glyph>, std::vector<std::string>>;
    std::map<BaseKey, BaseValue> baselines;
    for (const auto &run : runs)
        for (const auto &cluster : clusters(run.glyphs)) {
            bool selected = false;
            for (GAGlyphSelectionRun *selection in selections)
                selected |= NSIntersectionRange(selection.range,
                    NSMakeRange(cluster.source.start, cluster.source.end-cluster.source.start)).length > 0;
            auto key = std::make_tuple(run.script, bool(run.level & 1), selected, cluster.glyphs);
            auto found = baselines.find(key);
            if (found == baselines.end()) {
                Buffer basis;
                for (const auto &item : run.glyphs)
                    if (item.source.start < cluster.source.end && item.source.end > cluster.source.start) {
                        basis.push_back(item);
                        if (basis.back().form) basis.back().form = tag('i','s','o','l');
                    }
                Trace baselineTrace;
                Settings settings; settings.script = run.script; settings.rtl = run.level & 1;
                if (!selected && !r.domains.empty())
                    r.substitute(basis, r.domains.front(), settings, &baselineTrace);
                if (settings.rtl) std::reverse(basis.begin(), basis.end());
                BaseValue value{identifiers(basis), {}};
                for (const auto &change : baselineTrace.changes)
                    if (std::find(value.second.begin(), value.second.end(), change.feature) == value.second.end())
                        value.second.push_back(change.feature);
                found = baselines.emplace(std::move(key), std::move(value)).first;
            }
            merge(seen, matches, cluster.source, found->second.first, nil, YES);
            for (const auto &source : found->second.second)
                merge(seen, matches, cluster.source, found->second.first, @(source.c_str()), YES);
        }
    for (size_t di = 0; di < r.domains.size(); di++) {
        const auto &domain = r.domains[di];
        for (const auto &run : runs) {
            std::vector<Tag> scripts{run.script};
            if (!domain.apple)
                for (GAGlyphSelectionRun *selection : selections)
                    if (NSIntersectionRange(
                            selection.range,
                            NSMakeRange(run.source.start, run.source.end - run.source.start))
                            .length) {
                        for (const auto &script : r.gsub.scripts())
                            if (std::find(scripts.begin(), scripts.end(), script.name) ==
                                scripts.end())
                                scripts.push_back(script.name);
                        break;
                    }
            for (Tag script : scripts) {
                auto languages = domain.apple ? std::vector<Tag>{0} : r.gsub.languages(script);
                for (Tag language : languages)
                    for (auto plan : plans(r, domain)) {
                        Settings settings;
                        settings.script = script;
                        settings.language = language;
                        settings.rtl = run.level & 1;
                        if (plan.first)
                            settings.features[plan.first] = plan.second;
                        Buffer items = run.glyphs;
                        Trace trace;
                        trace.inventory = true;
                        try {
                            r.substitute(items, domain, settings, &trace);
                        } catch (const InvalidTable &error) {
                            [self recordError:error];
                            items = run.glyphs;
                            trace = {};
                        }
                        for (auto &item : items)
                            if (item.glyph >= r.glyphCount)
                                item.glyph = 0;
                        bool base = false;
                        for (auto change : trace.changes) {
                            if (settings.rtl)
                                std::reverse(change.glyphs.begin(), change.glyphs.end());
                            merge(seen, matches, change.source, change.glyphs,
                                  @(change.feature.c_str()), NO);
                        }
                        if (settings.rtl)
                            std::reverse(items.begin(), items.end());
                        for (const auto &cluster : clusters(items)) {
                            merge(seen, matches, cluster.source, cluster.glyphs, nil, base);
                            for (const auto &change : trace.changes)
                                if (change.source.start < cluster.source.end &&
                                    change.source.end > cluster.source.start)
                                    merge(seen, matches, cluster.source, cluster.glyphs,
                                          @(change.feature.c_str()), base);
                        }
                        if (items.empty() && !run.source.empty()) {
                            merge(seen, matches, run.source, {}, nil, base);
                            for (const auto &change : trace.changes)
                                merge(seen, matches, run.source, {}, @(change.feature.c_str()),
                                      base);
                        }
                    }
            }
        }
    }
    // Context-free inventory: expose only the queried component's replacement,
    // preserving other GIDs belonging to the same atomic input cluster.
    for (const auto &run : runs)
        for (const auto &cluster : clusters(run.glyphs))
            for (size_t i = 0; i < cluster.glyphs.size(); i++)
                for (NSDictionary *output in [self relatedOutputs:cluster.glyphs[i]]) {
                    auto sequence = cluster.glyphs;
                    auto replacement = glyphVector(output[@"glyphs"]);
                    sequence.erase(sequence.begin() + i);
                    sequence.insert(sequence.begin() + i, replacement.begin(), replacement.end());
                    merge(seen, matches, cluster.source, sequence, output[@"source"], NO);
                }
    // Default shaping may itself change the input GID. Its direct families
    // share the same cached catalogue; contextual candidates belong to the
    // original queried GID above, not an unconstrained transitive closure.
    NSArray *bases = [matches copy];
    for (GASubstitutionMatch *base in bases)
        if (base.base && base.glyphIDs.count == 1)
            for (NSDictionary *output in
                 [self relatedOutputs:base.glyphIDs.firstObject.unsignedShortValue]) {
                if (![output[@"family"] boolValue])
                    continue;
                merge(seen, matches,
                      {uint32_t(base.sourceRange.location), uint32_t(NSMaxRange(base.sourceRange))},
                      glyphVector(output[@"glyphs"]), output[@"source"], NO);
            }
    NSDictionary *result = @{@"matches" : matches};
    [self.program.cache setObject:result
                           forKey:queryKey
                             cost:text.length * 2 + matches.count * 128];
    return result;
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text {
    return [self discoverText:text selections:@[]];
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                      selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    if (!text.length)
        return @[];
    try {
        NSDictionary *result = [self discoverContent:text selections:selections];
        NSMutableArray *matches = [result[@"matches"] mutableCopy];
        [matches sortUsingComparator:^NSComparisonResult(GASubstitutionMatch *a,
                                                         GASubstitutionMatch *b) {
          if (a.base != b.base)
              return a.base ? NSOrderedAscending : NSOrderedDescending;
          if (!a.base && a.sourceRange.length != b.sourceRange.length)
              return a.sourceRange.length < b.sourceRange.length ? NSOrderedAscending
                                                                 : NSOrderedDescending;
          if (a.sourceRange.location != b.sourceRange.location)
              return a.sourceRange.location < b.sourceRange.location ? NSOrderedAscending
                                                                     : NSOrderedDescending;
          return NSOrderedSame;
        }];
        return matches;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (NSArray<GAGlyphLayoutRun *> *)layoutRunsForText:(NSString *)text
                                       contextual:(BOOL)contextual
                                        ligatures:(BOOL)ligatures
                                         vertical:(BOOL)vertical {
    NSMutableArray *result = [NSMutableArray array];
    try {
        const auto &r = *self.program->resource;
        std::map<Tag,double> coordinates;
        for (NSNumber *axis in self.coordinates) coordinates[axis.unsignedIntValue] = [self.coordinates[axis] doubleValue];
        size_t branch = r.gsub.variationBranch(normalizeCoordinates(r.fvar,r.avar,coordinates));
        for (auto run : prepareText(text,r.cmap)) {
            Settings settings; settings.script = run.script;
            settings.rtl = run.level & 1; settings.vertical = vertical;
            settings.features[tag('c','a','l','t')] = contextual;
            settings.features[tag('l','i','g','a')] = ligatures;
            settings.features[tag('c','l','i','g')] = ligatures;
            bool vrt2 = false;
            for (const auto &feature : r.gsub.features(branch)) vrt2 |= feature.name == tag('v','r','t','2');
            settings.features[tag('v','r','t','2')] = vertical && vrt2;
            settings.features[tag('v','e','r','t')] = vertical && !vrt2;
            Buffer items = run.glyphs;
            if (!r.aat.empty()) {
                std::vector<AATSelector> options{{36,contextual ? 0u:1u},{1,ligatures ? 2u:3u},{4,vertical ? 0u:1u}};
                r.aat.applyFeatures(items,options,settings.rtl,vertical);
            } else r.gsub.substitute(items,r.gdef,settings,branch);
            if (settings.rtl) std::reverse(items.begin(),items.end());
            for (const auto &cluster : clusters(items)) {
                GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
                hit.range = NSMakeRange(cluster.source.start,cluster.source.end-cluster.source.start);
                hit.glyphIDs = glyphArray(cluster.glyphs); [result addObject:hit];
            }
        }
    } catch (const std::exception &error) { [self recordError:error]; }
    return result;
}
- (Metrics)metrics {
    const auto &r = *self.program->resource;
    CTFontRef font = _font;
    double scale = r.unitsPerEm / CTFontGetSize(font);
    Metrics metrics;
    metrics.horizontalAdvance = [font, scale](Glyph glyph) {
        CGSize advance = {};
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &g, &advance, 1);
        return advance.width * scale;
    };
    metrics.verticalAdvance = [font, scale](Glyph glyph) {
        CGSize advance = {};
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationVertical, &g, &advance, 1);
        double value = std::max(std::abs(advance.width), std::abs(advance.height));
        return value ? value * scale : (CTFontGetAscent(font) + CTFontGetDescent(font)) * scale;
    };
    std::map<Tag, double> coordinates;
    for (NSNumber *axis in self.coordinates)
        coordinates[axis.unsignedIntValue] = [self.coordinates[axis] doubleValue];
    metrics.normalized = normalizeCoordinates(r.fvar, r.avar, coordinates);
    return metrics;
}
- (void)position:(Buffer &)buffer settings:(const Settings &)settings {
    const auto &r = *self.program->resource;
    Metrics metrics = [self metrics];
    Buffer nominal = buffer;
    bool hasKerning = false;
    try {
        size_t branch = r.gpos.variationBranch(metrics.normalized);
        r.gpos.position(buffer, r.gdef, settings, metrics, branch);
        for (auto step : r.gpos.plan(settings, branch))
            if (step.feature == tag('k', 'e', 'r', 'n'))
                hasKerning = true;
    } catch (const InvalidTable &error) {
        [self recordError:error];
        buffer = std::move(nominal);
        for (auto &item : buffer) {
            item.xAdvance = settings.vertical ? 0 : metrics.horizontalAdvance(item.glyph);
            item.yAdvance = settings.vertical ? -metrics.verticalAdvance(item.glyph) : 0;
            item.xOffset = item.yOffset = 0;
        }
    }
    if (!hasKerning) {
        Buffer before = buffer;
        try {
            r.kerning.position(buffer, settings, r.gdef);
        } catch (const InvalidTable &error) {
            [self recordError:error];
            buffer = std::move(before);
        }
    }
    for (auto &item : buffer)
        if (item.ignorable)
            item.xAdvance = item.yAdvance = 0;
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    return [self positionsForGlyphIDs:glyphIDs content:@""];
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content {
    try {
        const auto &r = *self.program->resource;
        auto runs = prepareText(content, r.cmap);
        Settings settings;
        if (!runs.empty()) {
            settings.script = runs.front().script;
            settings.rtl = runs.front().level & 1;
        }
        Buffer items = literalBuffer(glyphVector(glyphIDs));
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        [self position:items settings:settings];
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        double scale = 200.0 / r.unitsPerEm;
        ga::layout::Point pen;
        NSMutableArray *positions = [NSMutableArray array];
        for (const auto &item : items) {
            [positions
                addObject:[NSValue valueWithPoint:NSMakePoint((pen.x + item.xOffset) * scale,
                                                              (pen.y + item.yOffset) * scale)]];
            pen.x += item.xAdvance;
            pen.y += item.yAdvance;
        }
        return positions;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSArray *key = @[ @"glyphs", [glyphIDs copy] ];
    NSDictionary *cached = [self.program.cache objectForKey:key];
    if (cached)
        return cached[@"matches"];
    try {
        const auto &r = *self.program->resource;
        auto original = glyphVector(glyphIDs);
        Span whole{0, uint32_t(original.size())};
        NSMutableArray *matches = [NSMutableArray array];
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];
        merge(seen, matches, whole, original, nil, YES);
        for (const auto &domain : r.domains) {
            std::vector<Tag> scripts;
            if (domain.apple)
                scripts = {tag('D', 'F', 'L', 'T')};
            else
                for (const auto &script : r.gsub.scripts())
                    scripts.push_back(script.name);
            for (Tag script : scripts)
                for (Tag language : domain.apple ? std::vector<Tag>{0} : r.gsub.languages(script))
                    for (auto plan : plans(r, domain)) {
                        Settings settings;
                        settings.script = script;
                        settings.language = language;
                        if (plan.first)
                            settings.features[plan.first] = plan.second;
                        Buffer items = literalBuffer(original);
                        Trace trace;
                        trace.inventory = true;
                        r.substitute(items, domain, settings, &trace);
                        merge(seen, matches, whole, identifiers(items), nil, NO);
                        for (const auto &change : trace.changes)
                            merge(seen, matches, whole, identifiers(items),
                                  @(change.feature.c_str()), NO);
                        for (const auto &change : trace.changes) {
                            if (change.source.end > original.size())
                                continue;
                            auto sequence = original;
                            sequence.erase(sequence.begin() + change.source.start,
                                           sequence.begin() + change.source.end);
                            sequence.insert(sequence.begin() + change.source.start,
                                            change.glyphs.begin(), change.glyphs.end());
                            merge(seen, matches, whole, sequence, @(change.feature.c_str()), NO);
                        }
                    }
        }
        for (size_t i = 0; i < original.size(); i++)
            for (NSDictionary *output in [self relatedOutputs:original[i]]) {
                auto sequence = original;
                auto replacement = glyphVector(output[@"glyphs"]);
                sequence.erase(sequence.begin() + i);
                sequence.insert(sequence.begin() + i, replacement.begin(), replacement.end());
                merge(seen, matches, whole, sequence, output[@"source"], NO);
            }
        [self.program.cache setObject:@{@"matches" : matches}
                               forKey:key
                                 cost:glyphIDs.count * 2 + matches.count * 128];
        return matches;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (NSNumber *)verticalGlyph:(uint16_t)glyph {
    try {
        const auto &r = *self.program->resource;
        for (const auto &domain : r.domains) {
            if (domain.apple) {
                if (domain.selector && domain.selector->type != 4)
                    continue;
                Buffer items = literalBuffer({glyph});
                r.aat.substitute(items, domain.selector, false, true, nullptr, true);
                if (items.size() == 1 && items.front().glyph != glyph)
                    return @(items.front().glyph);
            } else
                for (Tag name : {tag('v', 'r', 't', '2'), tag('v', 'e', 'r', 't')})
                    for (const auto &feature : r.gsub.features(domain.branch)) {
                        if (feature.name != name)
                            continue;
                        std::vector<LookupStep> steps;
                        for (unsigned lookup : feature.lookups)
                            steps.push_back({lookup, 1, name, true});
                        Buffer items = literalBuffer({glyph});
                        r.gsub.substituteLookups(items, r.gdef, steps);
                        if (items.size() == 1 && items.front().glyph != glyph)
                            return @(items.front().glyph);
                    }
        }
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return nil;
}
#if GA_FONT_LAYOUT_TESTING
- (NSDictionary *)shapeText:(NSString *)text
                   features:(NSDictionary *)features
                     script:(NSString *)script
                   language:(NSString *)language
                     branch:(NSUInteger)branch {
    try {
        const auto &r = *self.program->resource;
        auto runs = prepareText(text, r.cmap);
        std::vector<Buffer> output;
        const auto &domain = r.domains[branch < r.domains.size() ? branch : 0];
        for (auto run : runs) {
            Settings settings;
            settings.script = script.length ? scriptTag(script) : run.script;
            settings.language = languageTag(language);
            settings.rtl = run.level & 1;
            for (NSString *name in features)
                settings.features[tag(name.UTF8String ?: "")] = [features[name] unsignedIntValue];
            Buffer items = run.glyphs;
            r.substitute(items, domain, settings);
            [self position:items settings:settings];
            if (settings.rtl)
                std::reverse(items.begin(), items.end());
            output.push_back(std::move(items));
        }
        NSMutableArray *glyphs = [NSMutableArray array], *clusters = [NSMutableArray array],
                       *positions = [NSMutableArray array];
        for (size_t index : visualRunOrder(runs))
            for (const auto &item : output[index]) {
                [glyphs addObject:@(item.glyph)];
                [clusters addObject:@(item.source.start)];
                [positions addObject:@[
                    @(item.xAdvance), @(item.yAdvance), @(item.xOffset), @(item.yOffset)
                ]];
            }
        return
            @{@"ok" : @YES, @"glyphs" : glyphs, @"clusters" : clusters, @"positions" : positions};
    } catch (const std::exception &error) {
        return @{
            @"ok" : @NO,
            @"error" : @(error.what()),
            @"glyphs" : @[],
            @"clusters" : @[],
            @"positions" : @[]
        };
    }
}
#endif
@end
