#import "GASubstitutionEngine.h"
#import "GAGlyphSelection.h"
#import "GAAAT.h"
#import "GACmap.h"
#import "GAOpenType.h"
#import "GATextPreparation.h"
#import "GAVariation.h"
#include <cmath>
#include <map>
#include <deque>

using namespace ga::layout;
@implementation GASubstitutionMatch
@end
@implementation GASubstitutionOrigin
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
    bool apple;
    size_t branch;
    std::optional<AATSelector> selector;
};
struct Resource {
    Cmap cmap;
    GDEF gdef;
    OpenType gsub, gpos{{}, true};
    AAT aat;
    Kerning kerning;
    View fvar, avar;
    View os2, variationStore, head;
    struct VariationIndex {
        bool present = false;
        unsigned outer = 0, inner = 0;
    } ascenderVariation, descenderVariation;
    bool verticalAAT;
    unsigned glyphCount;
    double unitsPerEm;
    std::vector<Domain> domains;
    std::vector<Feature> featureSpecs;
    Resource(CTFontRef font)
        : glyphCount(unsigned(CTFontGetGlyphCount(font))), unitsPerEm(CTFontGetUnitsPerEm(font)) {
        auto read = [&](Tag name, auto &&assign) {
            try {
                assign(tableBytes(font, name));
            } catch (const InvalidTable &) {
                // Keep the default program when a table is invalid.
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
        read(tag('O', 'S', '/', '2'), [&](View data) { os2 = data; });
        read(tag('h', 'e', 'a', 'd'), [&](View data) { head = data; });
        read(tag('M', 'V', 'A', 'R'), [&](View data) { readVariationMetrics(data); });
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
    void readVariationMetrics(View mvar) {
        if (!mvar)
            return;
        if (mvar.u16(0) != 1)
            throw InvalidTable("unknown MVAR version");
        unsigned size = mvar.u16(6), count = mvar.u16(8);
        if (size < 8)
            throw InvalidTable("short MVAR value record");
        mvar.array(12, count, size);
        VariationIndex ascender, descender;
        for (unsigned i = 0; i < count; i++) {
            size_t at = 12 + size_t(i) * size;
            Tag name = mvar.u32(at);
            if (name == tag('h', 'a', 's', 'c')) {
                ascender.present = true;
                ascender.outer = mvar.u16(at + 4);
                ascender.inner = mvar.u16(at + 6);
            } else if (name == tag('h', 'd', 's', 'c')) {
                descender.present = true;
                descender.outer = mvar.u16(at + 4);
                descender.inner = mvar.u16(at + 6);
            }
        }
        // The store is shared by both records; keep it only when one applies.
        if (!ascender.present && !descender.present)
            return;
        View store = mvar.offset16(10);
        if (!store)
            return;
        variationStore = store;
        ascenderVariation = ascender;
        descenderVariation = descender;
    }
    Tag verticalFeature(size_t branch) const {
        // Select by feature presence, never by whether this glyph is covered.
        for (const auto &feature : gsub.features(branch))
            if (feature.name == tag('v', 'r', 't', '2'))
                return feature.name;
        return tag('v', 'e', 'r', 't');
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
std::vector<Glyph> replacingGlyph(const std::vector<Glyph> &glyphs, size_t index,
                                 NSDictionary *output) {
    auto sequence = glyphs;
    auto replacement = glyphVector(output[@"glyphs"]);
    sequence.erase(sequence.begin() + index);
    sequence.insert(sequence.begin() + index, replacement.begin(), replacement.end());
    return sequence;
}
void merge(NSMutableDictionary *seen, NSMutableArray<GASubstitutionMatch *> *matches, Span span,
           const std::vector<Glyph> &glyphs, NSString *source, BOOL base) {
    if (span.empty())
        return;
    NSArray *ids = glyphArray(glyphs);
    NSString *key = [NSString stringWithFormat:@"%u:%u:%@", span.start, span.end, ids];
    GASubstitutionMatch *match = seen[key];
    if (!match) {
        match = [[GASubstitutionMatch alloc] init];
        match.glyphIDs = ids;
        match.sourceRange = NSMakeRange(span.start, span.end - span.start);
        match.sources = @[];
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
std::optional<std::vector<Glyph>> sequenceAt(const Buffer &buffer, Span span, bool rtl) {
    std::vector<Glyph> result;
    Span covered{span.end, span.start};
    for (const auto &item : buffer) {
        if (item.source.start >= span.end || item.source.end <= span.start)
            continue;
        if (item.source.start < span.start || item.source.end > span.end)
            return {};
        covered = unite(covered, item.source);
        if (item.glyph != 0xffff)
            result.push_back(item.glyph);
    }
    if (!(covered == span))
        return {};
    if (rtl)
        std::reverse(result.begin(), result.end());
    return result;
}
bool verticalSource(const std::string &source) {
    auto feature = source.substr(0, source.find(' '));
    return feature == "vert" || feature == "vrt2" ||
           source.rfind("morx:4:", 0) == 0 || source.rfind("mort:4:", 0) == 0;
}
struct OriginEdge {
    std::vector<Glyph> glyphs;
    std::string feature;
    bool vertical;
};
GASubstitutionOrigin *origin(NSUInteger index, const std::vector<std::string> &features) {
    GASubstitutionOrigin *result = [[GASubstitutionOrigin alloc] init];
    result.sourceIndex = index;
    NSMutableArray *labels = [NSMutableArray array];
    for (const auto &feature : features) {
        NSString *label = @(feature.c_str());
        if (label.length && ![labels containsObject:label])
            [labels addObject:label];
    }
    result.sources = labels;
    return result;
}
bool primaryChange(const Change &change, const std::vector<Cluster> &roots) {
    auto first = std::lower_bound(roots.begin(), roots.end(), change.source.start,
        [](const Cluster &input, uint32_t start) { return input.source.end <= start; });
    auto last = first;
    while (last != roots.end() && last->source.start < change.source.end) ++last;
    if (size_t(last - first) == change.inputs.size() &&
        std::equal(first, last, change.inputs.begin(),
                   [](const Cluster &a, const Cluster &b) {
                       return a.source == b.source && a.glyphs == b.glyphs;
                   }))
        return true;
    // A ligature can be formed from already localized/joined input glyphs.
    return change.inputs.size() > 1;
}
std::vector<std::pair<Tag, unsigned>> plans(const Resource &resource, const Domain &domain) {
    std::vector<std::pair<Tag, unsigned>> result{{0, 0}};
    if (!domain.apple)
        for (const auto &feature : resource.featureSpecs)
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
@property(nonatomic, strong, readonly) NSCache<id, NSArray<GASubstitutionMatch *> *> *cache;
@property(nonatomic, strong, readonly) NSCache<NSNumber *, NSArray<NSDictionary *> *> *relatedCache;
@end
@implementation GAFontProgram
- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (self) {
        resource = std::make_shared<Resource>(font);
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
@property(nonatomic, strong, readonly) GAFontProgram *program;
@property(nonatomic, copy, readonly) NSDictionary<NSNumber *, NSNumber *> *coordinates;
- (std::vector<double>)normalizedCoordinates;
- (NSArray<NSDictionary *> *)relatedOutputs:(Glyph)glyph;
- (NSArray<GASubstitutionMatch *> *)discoverContent:(NSString *)text
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
                @"source" : @(label.c_str())
            }];
        }
        if (r.verticalAAT)
            for (const auto &domain : r.domains) {
                if (!domain.apple || (domain.selector && domain.selector->type != 4)) continue;
                Buffer input = literalBuffer({glyph});
                r.aat.substitute(input,domain.selector,false,true,nullptr,true);
                auto ids = identifiers(input);
                if (ids == std::vector<Glyph>{glyph}) continue;
                std::string source = r.aat.name();
                if (domain.selector) source += ":" + std::to_string(domain.selector->type) + ":" + std::to_string(domain.selector->setting);
                [outputs addObject:@{@"glyphs":glyphArray(ids),@"source":@(source.c_str()),@"vertical":@YES}];
            }
    } catch (const InvalidTable &) {
        // Keep any catalogue entries already collected.
    }
    [self.program.relatedCache setObject:outputs forKey:@(glyph) cost:outputs.count * 128];
    return outputs;
}
- (NSArray<GASubstitutionMatch *> *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    GAGlyphQueryIdentity *queryKey = GAGlyphQueryKey(text, selections);
    NSArray<GASubstitutionMatch *> *cached = [self.program.cache objectForKey:queryKey];
    if (cached)
        return cached;
    const auto &r = *self.program->resource;
    auto runs = prepareText(text, r.cmap, selections);
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    std::set<Span> inputSpans;
    // The root is the prepared cmap/UVS input (or the user's literal seed).
    // Shaping results are discoveries, never replacements for this row.
    for (const auto &run : runs)
        for (const auto &cluster : clusters(run.glyphs)) {
            merge(seen, matches, cluster.source, cluster.glyphs, nil, YES);
            inputSpans.insert(cluster.source);
        }
    // Catalogue order comes first; text matches below merge into these rows.
    // Preserve other GIDs belonging to the same atomic input cluster.
    for (const auto &run : runs)
        for (const auto &cluster : clusters(run.glyphs))
            for (size_t i = 0; i < cluster.glyphs.size(); i++)
                for (NSDictionary *output in [self relatedOutputs:cluster.glyphs[i]]) {
                    auto sequence = replacingGlyph(cluster.glyphs, i, output);
                    merge(seen, matches, cluster.source, sequence, output[@"source"], NO);
                }
    for (const auto &domain : r.domains) {
        for (const auto &run : runs) {
            const auto roots = clusters(run.glyphs);
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
                        } catch (const InvalidTable &) {
                            items = run.glyphs;
                            trace = {};
                        }
                        for (auto change : trace.changes) {
                            // Keep direct changes of the original input and
                            // newly formed combinations. Later changes of a
                            // variant are resolved lazily when clicked.
                            if (!primaryChange(change, roots))
                                continue;
                            if (settings.rtl)
                                std::reverse(change.glyphs.begin(), change.glyphs.end());
                            merge(seen, matches, change.source, change.glyphs,
                                  @(change.feature.c_str()), NO);
                        }
                    }
            }
        }
    }
    // A first-formed composition is a browsing root in its own right.
    // List its direct catalogue outputs, without closing over their outputs.
    NSArray *firstLevel = [matches copy];
    std::set<Span> compositionRoots;
    for (GASubstitutionMatch *match in firstLevel) {
        Span span{uint32_t(match.sourceRange.location), uint32_t(NSMaxRange(match.sourceRange))};
        if (inputSpans.count(span) || !compositionRoots.insert(span).second)
            continue;
        auto original = glyphVector(match.glyphIDs);
        for (size_t i = 0; i < original.size(); i++)
            for (NSDictionary *output in [self relatedOutputs:original[i]])
                merge(seen, matches,
                      {uint32_t(match.sourceRange.location), uint32_t(NSMaxRange(match.sourceRange))},
                      replacingGlyph(original, i, output), output[@"source"], NO);
    }
    [self.program.cache setObject:matches
                           forKey:queryKey
                             cost:text.length * 2 + matches.count * 128];
    return matches;
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                      selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    if (!text.length)
        return @[];
    try {
        NSMutableArray *matches = [[self discoverContent:text selections:selections] mutableCopy];
        [matches sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(GASubstitutionMatch *a,
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
    } catch (const std::exception &) {
        // Failed discovery yields no candidates.
    }
    return @[];
}
- (GASubstitutionOrigin *)originForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                sourceRange:(NSRange)sourceRange
                                       text:(NSString *)text
                                 selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                 candidates:(NSArray<NSArray<NSNumber *> *> *)candidates
                                   vertical:(BOOL)vertical
                       contextualAlternates:(BOOL)contextualAlternates
                                  ligatures:(BOOL)ligatures
                                  cancelled:(BOOL (^)(void))cancelled {
    if (!sourceRange.length || NSMaxRange(sourceRange) > text.length || !candidates.count)
        return nil;
    const auto &r = *self.program->resource;
    Span span{uint32_t(sourceRange.location), uint32_t(NSMaxRange(sourceRange))};
    auto target = glyphVector(glyphIDs);
    std::vector<std::vector<Glyph>> sources;
    for (NSArray *candidate in candidates)
        sources.push_back(glyphVector(candidate));
    try {
        size_t branch = r.gsub.variationBranch([self normalizedCoordinates]);
        // This is our executor's replay, not a trace of TextKit internals.
        // Accept it only when its final sequence and complete source agree.
        for (const auto &run : prepareText(text, r.cmap, selections)) {
            if (cancelled()) return nil;
            if (run.source.start > span.start || run.source.end < span.end) continue;
            Settings settings;
            settings.script = run.script;
            settings.rtl = run.level & 1;
            settings.vertical = vertical;
            if (vertical) settings.features[r.verticalFeature(branch)] = 1;
            if (!contextualAlternates)
                for (const char *name : {"calt", "cswh", "rclt"})
                    settings.features[tag(name)] = 0;
            if (!ligatures)
                for (const char *name : {"liga", "clig", "dlig", "hlig", "rlig"})
                    settings.features[tag(name)] = 0;
            Buffer items = run.glyphs;
            Trace trace;
            trace.provenance = true;
            if (!r.aat.empty()) {
                std::vector<AATSelector> overrides;
                if (!contextualAlternates)
                    for (unsigned selector : {1u, 3u, 5u}) overrides.push_back({36, selector});
                if (!ligatures)
                    for (unsigned selector = 1; selector <= 21; selector += 2)
                        overrides.push_back({1, selector});
                r.aat.substitute(items, {}, settings.rtl, vertical, &trace, false, overrides);
            } else
                r.gsub.substitute(items, r.gdef, settings, branch, &trace);
            auto final = sequenceAt(items, span, settings.rtl);
            if (!final || *final != target) continue;
            auto current = target;
            std::vector<std::string> labels;
            for (auto step = trace.steps.rbegin(); step != trace.steps.rend(); ++step) {
                auto after = sequenceAt(step->after, span, settings.rtl);
                auto before = sequenceAt(step->before, span, settings.rtl);
                if (!after || *after != current || !before) break;
                if (*before == current) continue;
                labels.insert(labels.begin(), step->feature);
                for (size_t i = 0; i < sources.size(); i++)
                    if (*before == sources[i]) return origin(i, labels);
                current = std::move(*before);
            }
        }
    } catch (const InvalidTable &) {
        // An unavailable replay proceeds to independent source discovery.
    }

    // Multi-source breadth-first traversal. Two visits per sequence retain
    // paths with/without a vertical feature separately. Mode preference wins
    // over distance; BFS then resolves shortest path and sidebar order.
    struct State {
        std::vector<Glyph> glyphs;
        size_t source;
        bool vertical;
        std::vector<std::string> labels;
    };
    std::deque<State> pending;
    std::set<std::pair<std::vector<Glyph>, bool>> visited;
    std::map<std::vector<Glyph>, std::vector<OriginEdge>> edges;
    GASubstitutionOrigin *otherMode = nil;
    Budget budget(text.length);
    size_t queuedGlyphs = 0;
    try {
        for (size_t i = 0; i < sources.size(); i++)
            if (visited.emplace(sources[i], false).second) {
                pending.push_back({sources[i], i, false, {}});
                queuedGlyphs += sources[i].size();
            }
        while (!pending.empty()) {
            if (cancelled()) return nil;
            budget.step();
            State state = std::move(pending.front());
            pending.pop_front();
            queuedGlyphs -= state.glyphs.size();
            if (state.glyphs == target) {
                if (state.vertical == bool(vertical)) return origin(state.source, state.labels);
                if (!otherMode) otherMode = origin(state.source, state.labels);
                continue;
            }
            if (otherMode && !vertical && state.vertical) continue;
            auto [entry, inserted] = edges.emplace(state.glyphs, std::vector<OriginEdge>{});
            auto &outputs = entry->second;
            if (inserted) {
                // Static single-GID catalogue plus actual full-context matches
                // cover contextual and multi-GID/composition sources alike.
                for (size_t i = 0; i < state.glyphs.size(); i++)
                    for (NSDictionary *output in [self relatedOutputs:state.glyphs[i]]) {
                        std::string label = [output[@"source"] UTF8String];
                        outputs.push_back({replacingGlyph(state.glyphs, i, output), label,
                                           verticalSource(label) || [output[@"vertical"] boolValue]});
                    }
                NSMutableArray *seedRuns = [NSMutableArray array];
                for (GAGlyphSelectionRun *selection in selections)
                    if (!NSIntersectionRange(selection.range, sourceRange).length)
                        [seedRuns addObject:selection];
                GAGlyphSelectionRun *seed = [[GAGlyphSelectionRun alloc] init];
                seed.range = sourceRange;
                seed.selection = [[GAGlyphSelection alloc]
                    initWithSourceText:[text substringWithRange:sourceRange]
                    glyphIDs:glyphArray(state.glyphs) featureSources:@[] ligature:NO];
                [seedRuns addObject:seed];
                [seedRuns sortUsingComparator:^NSComparisonResult(GAGlyphSelectionRun *a,
                                                                   GAGlyphSelectionRun *b) {
                    return a.range.location < b.range.location ? NSOrderedAscending
                         : a.range.location > b.range.location ? NSOrderedDescending : NSOrderedSame;
                }];
                for (const auto &run : prepareText(text, r.cmap, seedRuns)) {
                    if (run.source.start > span.start || run.source.end < span.end) continue;
                    for (const auto &domain : r.domains)
                        for (Tag language : domain.apple ? std::vector<Tag>{0}
                                                       : r.gsub.languages(run.script))
                            for (auto plan : plans(r, domain))
                                for (bool orientation : domain.apple && r.verticalAAT
                                                            ? std::vector<bool>{false, true}
                                                            : std::vector<bool>{false}) {
                                    if (cancelled()) return nil;
                                    budget.step();
                                    Settings settings;
                                    settings.script = run.script;
                                    settings.language = language;
                                    settings.rtl = run.level & 1;
                                    settings.vertical = orientation;
                                    if (plan.first) settings.features[plan.first] = plan.second;
                                    Buffer items = run.glyphs;
                                    Trace found;
                                    found.inventory = true;
                                    try {
                                        r.substitute(items, domain, settings, &found);
                                    } catch (const InvalidTable &) {
                                        continue;
                                    }
                                    for (const auto &change : found.changes) {
                                        if (!(change.source == span) || change.inherited) continue;
                                        std::vector<Glyph> input;
                                        for (const auto &cluster : change.inputs)
                                            input.insert(input.end(), cluster.glyphs.begin(), cluster.glyphs.end());
                                        auto output = change.glyphs;
                                        if (settings.rtl) {
                                            std::reverse(input.begin(), input.end());
                                            std::reverse(output.begin(), output.end());
                                        }
                                        if (input == state.glyphs)
                                            outputs.push_back({std::move(output), change.feature,
                                                verticalSource(change.feature) || change.vertical});
                                    }
                                }
                }
            }
            for (const auto &output : outputs) {
                budget.step();
                bool containsVertical = state.vertical || output.vertical;
                if (output.glyphs.empty() || output.glyphs == state.glyphs ||
                    !visited.emplace(output.glyphs, containsVertical).second) continue;
                budget.growth(queuedGlyphs + output.glyphs.size());
                queuedGlyphs += output.glyphs.size();
                State next{output.glyphs, state.source, containsVertical, state.labels};
                next.labels.push_back(output.feature);
                pending.push_back(std::move(next));
            }
        }
    } catch (const InvalidTable &) {
        // Cycles, malformed data and excessive discovery cannot stall a click.
    }
    return otherMode;
}
- (std::vector<double>)normalizedCoordinates {
    const auto &r = *self.program->resource;
    std::map<Tag, double> coordinates;
    for (NSNumber *axis in self.coordinates)
        coordinates[axis.unsignedIntValue] = [self.coordinates[axis] doubleValue];
    return normalizeCoordinates(r.fvar, r.avar, coordinates);
}
- (BOOL)typoMetricsAscender:(CGFloat *)ascender descender:(CGFloat *)descender {
    const auto &r = *self.program->resource;
    // OS/2 typographic values are design units and need the head table's em
    // scale. Bitmap-only fonts (no head) can store pixel metrics there; use
    // CoreText's ascent/descent fallback instead.
    if (r.head.size() < 54 || r.head.u16(18) == 0 || r.os2.size() < 72)
        return NO;
    double top = r.os2.s16(68);
    double bottom = r.os2.s16(70);
    try {
        if (r.variationStore) {
            std::vector<double> normalized = [self normalizedCoordinates];
            if (r.ascenderVariation.present)
                top += variationDelta(r.variationStore, r.ascenderVariation.outer,
                                      r.ascenderVariation.inner, normalized);
            if (r.descenderVariation.present)
                bottom += variationDelta(r.variationStore, r.descenderVariation.outer,
                                         r.descenderVariation.inner, normalized);
        }
    } catch (const InvalidTable &) {
        // Malformed variation data leaves the static OS/2 values in place.
        top = r.os2.s16(68);
        bottom = r.os2.s16(70);
    }
    if (!std::isfinite(top) || !std::isfinite(bottom))
        return NO;
    top = std::round(top);
    bottom = std::round(bottom);
    if (top + std::fabs(bottom) <= 0)
        return NO;
    *ascender = top;
    *descender = bottom;
    return YES;
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
    metrics.normalized = [self normalizedCoordinates];
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
    } catch (const InvalidTable &) {
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
        } catch (const InvalidTable &) {
            buffer = std::move(before);
        }
    }
    for (auto &item : buffer)
        if (item.ignorable)
            item.xAdvance = item.yAdvance = 0;
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
        double scale = CTFontGetSize(_font) / r.unitsPerEm;
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
    } catch (const std::exception &) {
        // Failed positioning yields no explicit origins.
    }
    return @[];
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSArray *key = @[ @"glyphs", [glyphIDs copy] ];
    NSArray<GASubstitutionMatch *> *cached = [self.program.cache objectForKey:key];
    if (cached)
        return cached;
    try {
        const auto &r = *self.program->resource;
        auto original = glyphVector(glyphIDs);
        const auto roots = clusters(literalBuffer(original));
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
                        for (const auto &change : trace.changes) {
                            if (!primaryChange(change, roots) ||
                                change.source.end > original.size())
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
                auto sequence = replacingGlyph(original, i, output);
                merge(seen, matches, whole, sequence, output[@"source"], NO);
            }
        [self.program.cache setObject:matches
                               forKey:key
                                 cost:glyphIDs.count * 2 + matches.count * 128];
        return matches;
    } catch (const std::exception &) {
        // Failed discovery yields no candidates.
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
            } else {
                Tag name = r.verticalFeature(domain.branch);
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
        }
    } catch (const std::exception &) {
        // A failed lookup has no vertical substitute.
    }
    return nil;
}
@end
