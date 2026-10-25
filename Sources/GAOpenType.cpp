#include "GAOpenType.h"

namespace ga::layout {
Predicate Predicate::exact(Glyph g) {
    Predicate p;
    p.value = g;
    return p;
}
Predicate Predicate::covered(View table) {
    Predicate p;
    p.kind = Kind::Coverage;
    p.coverage = Coverage(table);
    return p;
}
Predicate Predicate::classified(View table, unsigned value) {
    Predicate p;
    p.kind = Kind::Class;
    p.classes = ClassDef(table);
    p.value = value;
    return p;
}
bool Predicate::matches(Glyph glyph) const {
    switch (kind) {
    case Kind::Exact:
        return glyph == value;
    case Kind::Coverage:
        return coverage.contains(glyph);
    case Kind::Class:
        return classes.get(glyph) == value;
    }
    return false;
}
static std::vector<LookupRecord> records(View table, size_t at, unsigned count) {
    table.array(at, count, 4);
    std::vector<LookupRecord> result;
    for (unsigned i = 0; i < count; i++)
        result.push_back({table.u16(at + i * 4), table.u16(at + i * 4 + 2)});
    return result;
}
static void predicates(std::vector<Predicate> &result, View table, size_t at, unsigned count,
                       unsigned format, View classes = {}) {
    table.array(at, count, 2);
    for (unsigned i = 0; i < count; i++) {
        if (format == 1)
            result.push_back(Predicate::exact(table.u16(at + i * 2)));
        else if (format == 2)
            result.push_back(Predicate::classified(classes, table.u16(at + i * 2)));
        else
            result.push_back(Predicate::covered(table.offset16(at + i * 2)));
    }
}
std::vector<Pattern> readContexts(View sub, unsigned type) {
    const bool chained = type == 6;
    unsigned format = sub.u16(0);
    std::vector<Pattern> result;
    if (format == 3) {
        Pattern p;
        size_t cursor = 2;
        if (chained) {
            unsigned back = sub.u16(cursor);
            cursor += 2;
            predicates(p.backtrack, sub, cursor, back, 3);
            cursor += back * 2;
        }
        unsigned input = sub.u16(cursor);
        cursor += 2;
        if (!input)
            throw InvalidTable("empty context input");
        unsigned actionCount = 0;
        if (!chained) {
            actionCount = sub.u16(cursor);
            cursor += 2;
        }
        predicates(p.input, sub, cursor, input, 3);
        cursor += input * 2;
        if (chained) {
            unsigned look = sub.u16(cursor);
            cursor += 2;
            predicates(p.lookahead, sub, cursor, look, 3);
            cursor += look * 2;
            actionCount = sub.u16(cursor);
            cursor += 2;
        }
        p.actions = records(sub, cursor, actionCount);
        result.push_back(std::move(p));
        return result;
    }
    if (format != 1 && format != 2)
        throw InvalidTable("unknown contextual lookup format");
    Coverage coverage(sub.offset16(2));
    auto firstGlyphs = format == 1 ? coverage.glyphs() : std::vector<Glyph>{};
    View backClasses, inputClasses, lookClasses;
    size_t countAt = 4;
    if (format == 2) {
        if (chained) {
            backClasses = sub.offset16(4);
            inputClasses = sub.offset16(6);
            lookClasses = sub.offset16(8);
            countAt = 10;
        } else {
            inputClasses = sub.offset16(4);
            countAt = 6;
        }
    }
    unsigned sets = sub.u16(countAt);
    sub.array(countAt + 2, sets, 2);
    if (format == 1)
        sets = std::min(sets, unsigned(firstGlyphs.size()));
    for (unsigned si = 0; si < sets; si++) {
        View set = sub.offset16(countAt + 2 + si * 2);
        if (!set)
            continue;
        unsigned count = set.u16(0);
        set.array(2, count, 2);
        for (unsigned ri = 0; ri < count; ri++) {
            if (result.size() >= 1000000)
                throw InvalidTable("too many contextual rules");
            View rule = set.offset16(2 + ri * 2);
            if (!rule)
                throw InvalidTable("null contextual rule");
            Pattern p;
            p.firstCoverage = coverage;
            size_t cursor = 0;
            if (chained) {
                unsigned back = rule.u16(cursor);
                cursor += 2;
                predicates(p.backtrack, rule, cursor, back, format, backClasses);
                cursor += back * 2;
            }
            unsigned input = rule.u16(cursor);
            cursor += 2;
            if (!input)
                throw InvalidTable("empty context input");
            unsigned actionCount = 0;
            if (!chained) {
                actionCount = rule.u16(cursor);
                cursor += 2;
            }
            p.input.push_back(format == 1 ? Predicate::exact(firstGlyphs[si])
                                          : Predicate::classified(inputClasses, si));
            predicates(p.input, rule, cursor, input - 1, format, inputClasses);
            cursor += (input - 1) * 2;
            if (chained) {
                unsigned look = rule.u16(cursor);
                cursor += 2;
                predicates(p.lookahead, rule, cursor, look, format, lookClasses);
                cursor += look * 2;
                actionCount = rule.u16(cursor);
                cursor += 2;
            }
            p.actions = records(rule, cursor, actionCount);
            result.push_back(std::move(p));
        }
    }
    return result;
}
std::optional<std::vector<size_t>> match(const Pattern &pattern, const Buffer &buffer, size_t start,
                                         const GDEF &gdef, LookupFlags flags, Span *scope) {
    if (start >= buffer.size() || pattern.input.empty() || !accepts(gdef, flags, buffer[start]))
        return {};
    if (pattern.firstCoverage && !pattern.firstCoverage.contains(buffer[start].glyph))
        return {};
    if (!pattern.input.front().matches(buffer[start].glyph))
        return {};
    Span range = buffer[start].source;
    std::vector<size_t> input{start};
    size_t cursor = start;
    for (const auto &predicate : pattern.backtrack) {
        bool found = false;
        while (cursor > 0) {
            --cursor;
            if (accepts(gdef, flags, buffer[cursor])) {
                found = true;
                break;
            }
        }
        if (!found || !predicate.matches(buffer[cursor].glyph))
            return {};
        range = unite(range, buffer[cursor].source);
    }
    cursor = start;
    auto advance = [&](const Predicate &predicate) {
        do {
            ++cursor;
        } while (cursor < buffer.size() && !accepts(gdef, flags, buffer[cursor]));
        if (cursor >= buffer.size() || !predicate.matches(buffer[cursor].glyph))
            return false;
        range = unite(range, buffer[cursor].source);
        return true;
    };
    for (size_t i = 1; i < pattern.input.size(); i++) {
        if (!advance(pattern.input[i]))
            return {};
        input.push_back(cursor);
    }
    for (const auto &predicate : pattern.lookahead)
        if (!advance(predicate))
            return {};
    if (scope)
        *scope = range;
    return input;
}

static std::vector<Feature> readFeatures(View list) {
    if (!list)
        return {};
    unsigned count = list.u16(0);
    list.array(2, count, 6);
    std::vector<Feature> result;
    for (unsigned i = 0; i < count; i++) {
        Feature f;
        f.name = list.u32(2 + i * 6);
        View table = list.offset16(6 + i * 6);
        unsigned n = table.u16(2);
        table.array(4, n, 2);
        for (unsigned j = 0; j < n; j++)
            f.lookups.push_back(table.u16(4 + j * 2));
        result.push_back(std::move(f));
    }
    return result;
}
static Language readLanguage(Tag name, View table) {
    Language lang;
    lang.name = name;
    lang.required = table.u16(2);
    unsigned count = table.u16(4);
    table.array(6, count, 2);
    for (unsigned i = 0; i < count; i++)
        lang.features.push_back(table.u16(6 + i * 2));
    return lang;
}
static std::vector<Script> readScripts(View list) {
    if (!list)
        return {};
    unsigned count = list.u16(0);
    list.array(2, count, 6);
    std::vector<Script> result;
    for (unsigned i = 0; i < count; i++) {
        Script script;
        script.name = list.u32(2 + i * 6);
        View table = list.offset16(6 + i * 6);
        if (View def = table.offset16(0))
            script.languages.push_back(readLanguage(0, def));
        unsigned n = table.u16(2);
        table.array(4, n, 6);
        for (unsigned j = 0; j < n; j++)
            script.languages.push_back(
                readLanguage(table.u32(4 + j * 6), table.offset16(8 + j * 6)));
        result.push_back(std::move(script));
    }
    return result;
}
static void indexPatterns(Subtable &s) {
    for (unsigned i = 0; i < s.patterns.size(); i++) {
        const auto &p = s.patterns[i];
        if (p.input.empty())
            continue;
        const auto &first = p.input.front();
        auto glyphs = first.kind == Predicate::Kind::Exact ? std::vector<Glyph>{Glyph(first.value)}
                      : first.kind == Predicate::Kind::Coverage ? first.coverage.glyphs()
                                                                : p.firstCoverage.glyphs();
        for (Glyph g : glyphs)
            if (first.matches(g) && (!p.firstCoverage || p.firstCoverage.contains(g)))
                s.starts[g].push_back(i);
    }
}
static Subtable readSubtable(View data, unsigned type, bool positioning, unsigned depth = 0) {
    if (depth > 0 && (type == (positioning ? 9 : 7)))
        throw InvalidTable("nested extension lookup");
    if (type == (positioning ? 9 : 7)) {
        if (data.u16(0) != 1)
            throw InvalidTable("unknown extension format");
        return readSubtable(data.offset32(4), data.u16(2), positioning, depth + 1);
    }
    Subtable s;
    s.type = type;
    s.data = data;
    if (positioning) {
        if (type == 7 || type == 8)
            s.patterns = readContexts(data, type == 7 ? 5 : 6);
        else if (type >= 1 && type <= 6)
            s.coverage = Coverage(data.offset16(2));
        else
            throw InvalidTable("unknown positioning lookup");
        indexPatterns(s);
        return s;
    }
    if (type == 5 || type == 6)
        s.patterns = readContexts(data, type);
    else if ((type >= 1 && type <= 4) || type == 8)
        s.coverage = Coverage(data.offset16(2));
    else
        throw InvalidTable("unknown substitution lookup");
    if (type == 4) {
        if (data.u16(0) != 1)
            throw InvalidTable("unknown ligature format");
        auto glyphs = s.coverage.glyphs();
        unsigned count = data.u16(4);
        data.array(6, count, 2);
        if (count > glyphs.size())
            throw InvalidTable("ligature set exceeds coverage");
        for (unsigned i = 0; i < count; i++) {
            View set = data.offset16(6 + i * 2);
            if (!set)
                continue;
            unsigned n = set.u16(0);
            set.array(2, n, 2);
            for (unsigned j = 0; j < n; j++) {
                View lig = set.offset16(2 + j * 2);
                Pattern p;
                p.input.push_back(Predicate::exact(glyphs[i]));
                unsigned length = lig.u16(2);
                if (!length)
                    throw InvalidTable("empty ligature");
                predicates(p.input, lig, 4, length - 1, 1);
                p.replacement = {lig.u16(0)};
                s.patterns.push_back(std::move(p));
            }
        }
    }
    if (type == 8) {
        if (data.u16(0) != 1)
            throw InvalidTable("unknown reverse chaining format");
        Pattern p;
        p.input.push_back(Predicate::covered(data.offset16(2)));
        size_t at = 4;
        unsigned back = data.u16(at);
        at += 2;
        predicates(p.backtrack, data, at, back, 3);
        at += back * 2;
        unsigned look = data.u16(at);
        at += 2;
        predicates(p.lookahead, data, at, look, 3);
        s.patterns.push_back(std::move(p));
    }
    indexPatterns(s);
    return s;
}
OpenType::OpenType(View table, bool positioning) : positioning_(positioning), data_(table) {
    branches_.push_back({});
    if (!table)
        return;
    table.require(0, 10);
    scripts_ = readScripts(table.offset16(4));
    branches_[0] = readFeatures(table.offset16(6));
    View list = table.offset16(8);
    unsigned count = list.u16(0);
    list.array(2, count, 2);
    size_t familyEntries = 0;
    for (unsigned i = 0; i < count; i++) {
        View data = list.offset16(2 + i * 2);
        Lookup lookup;
        unsigned type = data.u16(0);
        lookup.flags = data.u16(2);
        unsigned n = data.u16(4);
        data.array(6, n, 2);
        if (lookup.flags & 16)
            lookup.markSet = data.u16(6 + n * 2);
        for (unsigned j = 0; j < n; j++) {
            auto sub = readSubtable(data.offset16(6 + j * 2), type, positioning);
            for (const auto &pattern : sub.patterns)
                for (auto action : pattern.actions)
                    lookup.references.insert(action.lookup);
            if (!positioning && sub.type == 3) {
                unsigned sets = sub.data.u16(4);
                sub.data.array(6, sets, 2);
                for (unsigned k = 0; k < sets; k++) {
                    View alternate = sub.data.offset16(6 + k * 2);
                    unsigned size = alternate.u16(0);
                    alternate.array(2, size, 2);
                    lookup.alternateCount = std::max(lookup.alternateCount, size);
                }
                // Build the inverse family index once. A query for an unencoded
                // alternate must not scan every alternate set in a CJK font.
                for (Glyph input : sub.coverage.glyphs())
                    for (Glyph output : substitutionOutputs(sub, input)) {
                        if (sub.coverage.contains(output))
                            continue;
                        auto &inputs = sub.alternateInputs[output];
                        if (inputs.empty() || inputs.back() != input) {
                            if (++familyEntries > 2000000)
                                throw InvalidTable(
                                    "alternate family index exceeds resource budget");
                            inputs.push_back(input);
                        }
                    }
            }
            lookup.reverse |= !positioning && sub.type == 8;
            lookup.subtables.push_back(std::move(sub));
        }
        lookups_.push_back(std::move(lookup));
    }
    if (table.u32(0) == 0x10001) {
        View variations = table.offset32(10);
        if (variations) {
            unsigned n = variations.u32(4);
            variations.array(8, n, 8);
            for (unsigned i = 0; i < n; i++) {
                auto features = branches_.front();
                View replacement = variations.offset32(12 + i * 8);
                unsigned replacements = replacement.u16(4);
                replacement.array(6, replacements, 6);
                for (unsigned j = 0; j < replacements; j++) {
                    unsigned fi = replacement.u16(6 + j * 6);
                    if (fi >= features.size())
                        throw InvalidTable("variation feature index outside list");
                    View alt = replacement.offset32(8 + j * 6);
                    unsigned k = alt.u16(2);
                    alt.array(4, k, 2);
                    features[fi].lookups.clear();
                    for (unsigned q = 0; q < k; q++)
                        features[fi].lookups.push_back(alt.u16(4 + q * 2));
                }
                branches_.push_back(std::move(features));
            }
        }
    }
    for (auto &branch : branches_)
        for (auto &feature : branch) {
            std::vector<unsigned> queue = feature.lookups;
            std::set<unsigned> seen;
            for (size_t i = 0; i < queue.size(); i++) {
                unsigned li = queue[i];
                if (li >= lookups_.size() || !seen.insert(li).second)
                    continue;
                const auto &l = lookups_[li];
                feature.maximum = std::max(feature.maximum, l.alternateCount);
                queue.insert(queue.end(), l.references.begin(), l.references.end());
            }
        }
}
const std::vector<Feature> &OpenType::features(size_t branch) const {
    return branches_[branch < branches_.size() ? branch : 0];
}
static const Script *selectScript(const std::vector<Script> &scripts, Tag wanted) {
    for (Tag name : {wanted, tag('D', 'F', 'L', 'T'), tag('l', 'a', 't', 'n')})
        for (const auto &s : scripts)
            if (s.name == name)
                return &s;
    return nullptr;
}
std::vector<Tag> OpenType::languages(Tag script) const {
    std::vector<Tag> result{0};
    if (auto selected = selectScript(scripts_, script))
        for (const auto &l : selected->languages)
            if (l.name)
                result.push_back(l.name);
    return result;
}
static bool defaultFeature(Tag value, bool positioning) {
    if (positioning)
        return value == tag('k', 'e', 'r', 'n') || value == tag('m', 'a', 'r', 'k') ||
               value == tag('m', 'k', 'm', 'k') || value == tag('c', 'u', 'r', 's') ||
               value == tag('d', 'i', 's', 't') || value == tag('a', 'b', 'v', 'm') ||
               value == tag('b', 'l', 'w', 'm');
    static const std::set<Tag> names = {
        tag('c', 'c', 'm', 'p'), tag('l', 'o', 'c', 'l'), tag('r', 'l', 'i', 'g'),
        tag('l', 'i', 'g', 'a'), tag('c', 'l', 'i', 'g'), tag('c', 'a', 'l', 't'),
        tag('r', 'c', 'l', 't'), tag('l', 'j', 'm', 'o'), tag('v', 'j', 'm', 'o'),
        tag('t', 'j', 'm', 'o'), tag('i', 's', 'o', 'l'), tag('i', 'n', 'i', 't'),
        tag('m', 'e', 'd', 'i'), tag('f', 'i', 'n', 'a')};
    return names.count(value);
}
std::vector<LookupStep> OpenType::plan(const Settings &settings, size_t branch) const {
    std::vector<LookupStep> result;
    auto script = selectScript(scripts_, settings.script);
    if (!script)
        return result;
    const Language *language = nullptr;
    for (Tag wanted : {settings.language, Tag(0)}) {
        for (const auto &l : script->languages)
            if (l.name == wanted) {
                language = &l;
                break;
            }
        if (language)
            break;
    }
    if (!language)
        return result;
    const auto &all = features(branch);
    std::vector<unsigned> indices = language->features;
    if (language->required != 0xffff)
        indices.push_back(language->required);
    std::map<unsigned, LookupStep> enabled;
    for (unsigned fi : indices) {
        if (fi >= all.size())
            throw InvalidTable("language feature index outside list");
        const auto &f = all[fi];
        auto explicitValue = settings.features.find(f.name);
        unsigned value = explicitValue == settings.features.end()
                             ? (defaultFeature(f.name, positioning_) ? 1 : 0)
                             : explicitValue->second;
        if (fi == language->required)
            value = std::max(value, 1u);
        if (!value)
            continue;
        for (unsigned li : f.lookups) {
            if (li >= lookups_.size())
                throw InvalidTable("feature lookup index outside list");
            auto item = enabled.find(li);
            LookupStep step{li, value, f.name, explicitValue != settings.features.end()};
            if (item == enabled.end() || step.explicitValue)
                enabled[li] = step;
        }
    }
    // Composition and localization establish the input for the remaining features.
    for (Tag stage : {tag('c', 'c', 'm', 'p'), tag('l', 'o', 'c', 'l')})
        for (auto it = enabled.begin(); it != enabled.end();) {
            if (it->second.feature == stage) {
                result.push_back(it->second);
                it = enabled.erase(it);
            } else
                ++it;
        }
    for (const auto &entry : enabled)
        result.push_back(entry.second);
    return result;
}
size_t OpenType::variationBranch(const std::vector<double> &normalized) const {
    if (!data_ || data_.u32(0) != 0x10001)
        return 0;
    View variations = data_.offset32(10);
    if (!variations)
        return 0;
    unsigned count = variations.u32(4);
    for (unsigned i = 0; i < count; i++) {
        View set = variations.offset32(8 + i * 8);
        bool matches = true;
        if (set) {
            unsigned n = set.u16(0);
            set.array(2, n, 4);
            for (unsigned j = 0; j < n; j++) {
                View condition = set.offset32(2 + j * 4);
                if (!condition)
                    continue;
                if (condition.u16(0) != 1)
                    throw InvalidTable("unknown feature variation condition");
                unsigned axis = condition.u16(2);
                double value = axis < normalized.size() ? normalized[axis] : 0;
                if (value < condition.f2dot14(4) || value > condition.f2dot14(6)) {
                    matches = false;
                    break;
                }
            }
        }
        if (matches)
            return i + 1;
    }
    return 0;
}
std::vector<Glyph> substitutionOutputs(const Subtable &s, Glyph glyph) {
    int index = s.coverage.index(glyph);
    if (index < 0)
        return {};
    View d = s.data;
    if (s.type == 1) {
        unsigned format = d.u16(0);
        if (format == 1)
            return {Glyph(glyph + d.s16(4))};
        if (format == 2) {
            if (unsigned(index) >= d.u16(4))
                throw InvalidTable("single substitute exceeds coverage");
            return {d.u16(6 + index * 2)};
        }
    }
    if (s.type == 2 || s.type == 3) {
        if (d.u16(0) != 1)
            throw InvalidTable("unknown sequence format");
        if (unsigned(index) >= d.u16(4))
            throw InvalidTable("sequence exceeds coverage");
        View seq = d.offset16(6 + index * 2);
        unsigned n = seq.u16(0);
        seq.array(2, n, 2);
        std::vector<Glyph> result;
        for (unsigned i = 0; i < n; i++)
            result.push_back(seq.u16(2 + i * 2));
        return result;
    }
    return {};
}
} // namespace ga::layout
