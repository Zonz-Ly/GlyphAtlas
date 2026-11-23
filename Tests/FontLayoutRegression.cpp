#include "GAOpenType.h"
#include <cassert>
#include <iostream>

using namespace ga::layout;
using Bytes = std::vector<uint8_t>;

static void word(Bytes &b, unsigned n) {
    b.push_back(uint8_t(n >> 8));
    b.push_back(uint8_t(n));
}
static void put(Bytes &b, size_t at, unsigned n) {
    b.at(at) = uint8_t(n >> 8);
    b.at(at + 1) = uint8_t(n);
}
static Bytes words(std::initializer_list<unsigned> values) {
    Bytes b;
    for (unsigned value : values) word(b, value);
    return b;
}
static size_t append(Bytes &b, const Bytes &tail) {
    size_t at = b.size();
    b.insert(b.end(), tail.begin(), tail.end());
    return at;
}
static Bytes coverage(unsigned first, unsigned last) {
    return words({2, 1, first, last, 0});
}
static Bytes sequence(unsigned count, bool multiple = false) {
    Bytes b(8);
    put(b, 0, 1); put(b, 4, 1);
    put(b, 2, append(b, coverage(10, 10)));
    put(b, 6, b.size()); word(b, count);
    for (unsigned i = 0; i < count; ++i) word(b, multiple ? 20 + i : 100 + i);
    return b;
}
static Bytes ligatures() {
    Bytes b(8);
    put(b, 0, 1); put(b, 4, 1);
    put(b, 2, append(b, coverage(10, 10)));
    size_t set = b.size(); put(b, 6, set);
    word(b, 3); b.resize(b.size() + 6);
    for (unsigned i = 0; i < 3; ++i) {
        put(b, set + 2 + i * 2, b.size() - set);
        append(b, words({50 + i, 2, 11}));
    }
    return b;
}
static Bytes context(bool chained, unsigned classFormat) {
    // Both class 0 and class 1 start rules are present; class 0 includes
    // covered glyphs outside the explicit ClassDef ranges.
    size_t countAt = chained ? 10 : 6;
    Bytes b(countAt + 6);
    put(b, 0, 2); put(b, countAt, 2);
    put(b, 2, append(b, coverage(5, 12)));
    size_t classes = b.size();
    append(b, classFormat == 1 ? words({1, 10, 3, 1, 2, 0})
                              : words({2, 2, 10, 10, 1, 11, 11, 2}));
    if (chained) { put(b, 4, classes); put(b, 6, classes); put(b, 8, classes); }
    else put(b, 4, classes);
    for (unsigned c = 0; c < 2; ++c) {
        size_t set = b.size(); put(b, countAt + 2 + c * 2, set);
        word(b, 3); b.resize(b.size() + 6);
        for (unsigned i = 0; i < 3; ++i) {
            put(b, set + 2 + i * 2, b.size() - set);
            if (chained) append(b, words({1, 0}));
            word(b, 2);
            if (!chained) word(b, 1);
            word(b, 2);
            if (chained) append(b, words({1, 0, 1}));
            append(b, words({0, 1}));
        }
    }
    return b;
}
static Bytes reverse() {
    Bytes b = words({1, 0, 1, 0, 1, 0, 1, 55});
    put(b, 2, append(b, coverage(10, 10)));
    put(b, 6, append(b, coverage(5, 5)));
    put(b, 10, append(b, coverage(11, 11)));
    return b;
}
struct LookupBytes { unsigned type; Bytes subtable; unsigned flags = 0; };
static Bytes table(const std::vector<LookupBytes> &lookups) {
    // One DFLT default language and one liga feature. Nested lookup 1 is
    // reached by contextual actions rather than independently in the plan.
    Bytes b = words({1, 0, 10, 0, 0});
    append(b, words({1, 0x4446, 0x4c54, 8, 4, 0, 0, 0xffff, 1, 0}));
    put(b, 6, b.size());
    append(b, words({1, 0x6c69, 0x6761, 8, 0, 1, 0}));
    size_t list = b.size(); put(b, 8, list);
    word(b, unsigned(lookups.size())); b.resize(b.size() + lookups.size() * 2);
    for (size_t i = 0; i < lookups.size(); ++i) {
        put(b, list + 2 + i * 2, b.size() - list);
        append(b, words({lookups[i].type, lookups[i].flags, 1, 8}));
        append(b, lookups[i].subtable);
    }
    return b;
}
static Bytes extension(unsigned type, const Bytes &sub) {
    Bytes b = words({1, type, 0, 8});
    append(b, sub);
    return b;
}
static Buffer buffer(const std::vector<Glyph> &glyphs) {
    Buffer b;
    for (size_t i = 0; i < glyphs.size(); ++i) {
        Item item;
        item.glyph = glyphs[i]; item.source = {uint32_t(i), uint32_t(i + 1)};
        item.identity = i + 1; item.scalar = 65 + uint32_t(i);
        item.ignorable = i == 3; item.form = tag('i','s','o','l');
        b.push_back(item);
    }
    return b;
}
static void print(const Buffer &b) {
    std::cout << '[';
    for (const auto &i : b) {
        std::cout << i.glyph << '@' << i.source.start << ':' << i.source.end << '#'
                  << i.identity << '/' << i.component << '/' << i.scalar << '/' << i.form
                  << '/' << i.ignorable << '(';
        for (auto c : i.components) std::cout << c.start << ':' << c.end << ',';
        std::cout << ");";
    }
    std::cout << ']';
}
static void print(const Trace &trace) {
    std::cout << " incomplete=" << trace.incomplete << " changes=";
    for (const auto &c : trace.changes) {
        std::cout << c.source.start << ':' << c.source.end << '/' << c.feature << '/'
                  << c.vertical << '/' << c.inherited << '[';
        for (auto g : c.glyphs) std::cout << g << ',';
        std::cout << "]inputs[";
        for (const auto &input : c.inputs) {
            std::cout << input.source.start << ':' << input.source.end << '(';
            for (auto g : input.glyphs) std::cout << g << ',';
            std::cout << ')';
        }
        std::cout << "];";
    }
    for (const auto &s : trace.steps) {
        std::cout << " replay=" << s.feature;
        print(s.before); print(s.after);
    }
}
static void run(const std::string &label, const Bytes &bytes,
                const std::vector<Glyph> &glyphs, unsigned value, unsigned mode,
                unsigned cancelAt = 0, const GDEF &gdef = GDEF{}) {
    std::cout << label << '/' << value << '/' << mode << '/' << cancelAt;
    unsigned polls = 0;
    Trace trace;
    Buffer items = buffer(glyphs);
    try {
        OpenType ot{View(bytes)};
        std::cout << " parsed";
        trace.inventory = mode == 1;
        trace.provenance = mode == 2;
        Cancellation cancel{[&] { return ++polls >= cancelAt; }};
        ot.substituteLookups(items, gdef, {{0, value, tag('l','i','g','a'), true}},
                             &trace, cancelAt ? &cancel : nullptr);
        std::cout << " OK";
    } catch (const InvalidTable &e) { std::cout << " ERROR " << e.what(); }
      catch (const QueryCancelled &) { std::cout << " CANCELLED"; }
    print(items); print(trace);
    std::cout << " polls=" << polls << '\n';
}
int main() {
    // Direct public-entry assertions: no copied parser/executor functions.
    for (unsigned count : {0u, 1u, 3u, 1024u}) {
        OpenType ot{View(table({{3, sequence(count)}}))};
        for (unsigned value : {0u, 1u, count, count + 1}) {
            Buffer items = buffer({10});
            ot.substituteLookups(items, GDEF{}, {{0, value, tag('s','a','l','t'), true}});
            assert(items.size() == 1);
            assert(items[0].glyph == (value && value <= count ? 100 + value - 1 : 10));
        }
        Bytes truncated = table({{3, sequence(count + 1)}});
        truncated.pop_back();
        Buffer items = buffer({10}); bool rejected = false;
        try {
            OpenType invalid{View(truncated)};
            invalid.substituteLookups(items, GDEF{}, {{0, 1, tag('s','a','l','t'), true}});
        }
        catch (const InvalidTable &) { rejected = true; }
        assert(rejected); // An accessible first alternate cannot hide truncation.
    }
    for (bool chained : {false, true}) for (unsigned format : {1u, 2u}) {
        Bytes single = words({1, 6, 100});
        append(single, coverage(5, 12));
        OpenType ot{View(table({{chained ? 6u : 5u, context(chained, format)}, {1, single}}))};
        for (Glyph first : {Glyph(5), Glyph(10)}) {
            // Class 0 outside the explicit ClassDef ranges is an actual rule,
            // not an absent class. Its nested substitution must still run.
            Buffer items = buffer({5, first, 11, 12});
            ot.substituteLookups(items, GDEF{}, {{0, 1, tag('l','i','g','a'), true}});
            assert(items.size() == 4 && items[1].glyph == first + 100);
            assert((items[1].source == Span{1,2}));
        }
        OpenType nested{View(table({{chained ? 6u : 5u, context(chained, format)}, {4, ligatures()}}))};
        Trace trace; trace.inventory = true;
        Buffer items = buffer({5,10,11,12});
        nested.substituteLookups(items, GDEF{}, {{0, 1, tag('l','i','g','a'), true}}, &trace);
        assert(!trace.incomplete && trace.changes.size() == 3);
        // This is the existing nested-choice traversal order, not a sorted set.
        assert((trace.changes[0].glyphs == std::vector<Glyph>{50}));
        assert((trace.changes[1].glyphs == std::vector<Glyph>{52}));
        assert((trace.changes[2].glyphs == std::vector<Glyph>{51}));
        for (const auto &change : trace.changes) {
            assert(change.feature == "liga" && !change.inherited);
            assert((change.source == Span{1,3}));
            assert(change.inputs.size() == 2);
        }
    }
    {
        OpenType ot{View(table({{4, ligatures()}}))};
        Buffer items = buffer({10,11});
        Trace trace; trace.inventory = true;
        Cancellation cancel{[] { return true; }};
        bool cancelled = false;
        try { ot.substituteLookups(items, GDEF{}, {{0, 1, tag('l','i','g','a'), true}}, &trace, &cancel); }
        catch (const QueryCancelled &) { cancelled = true; }
        assert(cancelled && !trace.incomplete && trace.changes.empty());
    }
    uint32_t state = 0x175ba912;
    for (unsigned test = 0; test < 120; ++test) {
        state = state * 1664525u + 1013904223u;
        unsigned count = 1 + state % 32;
        Bytes sub(8);
        put(sub, 0, 1); put(sub, 4, 1);
        put(sub, 2, append(sub, coverage(100, 100)));
        put(sub, 6, sub.size());
        append(sub, words({1, 4, 500, count}));
        for (unsigned c = 1; c < count; ++c) word(sub, 100 + c);
        Bytes bytes = table({{4, sub, 8}}); // IgnoreMarks.
        GDEF gdef;
        gdef.glyphClasses = ClassDef(View(words({1, 65000, 1, 3})));
        std::vector<Glyph> glyphs;
        std::vector<unsigned> markOwners;
        for (unsigned c = 0; c < count; ++c) {
            glyphs.push_back(Glyph(100 + c));
            state = state * 1664525u + 1013904223u;
            if (c + 1 < count)
                for (unsigned m = 0; m < state % 4; ++m) {
                    glyphs.push_back(65000); markOwners.push_back(c);
                }
        }
        Buffer items = buffer(glyphs);
        OpenType ot{View(bytes)};
        ot.substituteLookups(items, gdef, {{0, 1, tag('l','i','g','a'), true}});
        assert(items.size() == 1 + markOwners.size() && items[0].glyph == 500);
        assert(items[0].components.size() == count);
        for (size_t m = 0; m < markOwners.size(); ++m) {
            assert(items[m + 1].glyph == 65000 && items[m + 1].component == int(markOwners[m]));
            assert((items[m + 1].source == Span{0, uint32_t(glyphs.size())}));
        }
        for (unsigned mode = 0; mode < 3; ++mode)
            for (unsigned limit : {0u, 1u, 5u})
                run("gapped-ligature-" + std::to_string(test), bytes, glyphs, 1, mode, limit, gdef);
    }
    struct Case { std::string label; std::vector<LookupBytes> lookups; };
    std::vector<Case> cases{
        {"alternate-empty", {{3, sequence(0)}}},
        {"alternate", {{3, sequence(4)}}},
        {"multiple-empty", {{2, sequence(0, true)}}},
        {"multiple", {{2, sequence(3, true)}}},
        {"ligature", {{4, ligatures()}}},
        {"reverse", {{8, reverse()}}},
        {"extension-alternate", {{7, extension(3, sequence(4))}}},
    };
    for (bool chained : {false, true}) for (unsigned format : {1u, 2u}) {
        cases.push_back({"context-" + std::to_string(chained) + '-' + std::to_string(format),
                         {{chained ? 6u : 5u, context(chained, format)}, {3, sequence(3)}}});
        cases.push_back({"nested-ligature-" + std::to_string(chained) + '-' + std::to_string(format),
                         {{chained ? 6u : 5u, context(chained, format)}, {4, ligatures()}}});
    }
    for (const auto &test : cases) {
        auto bytes = table(test.lookups);
        for (const auto &glyphs : std::vector<std::vector<Glyph>>{
                 {}, {10}, {10,11}, {5,10,11,12}, {5,5,11,12}, {10,11,10,11}})
            for (unsigned value : {0u, 1u, 2u, 3u, 4u, 5u, 65535u})
                for (unsigned mode = 0; mode < 3; ++mode)
                    for (unsigned cancelAt : {0u, 1u, 2u, 5u})
                        run(test.label, bytes, glyphs, value, mode, cancelAt);
        // Error phase and message, as well as successful partial tables, are
        // included in the transcript used for before/after comparisons.
        for (size_t length = 0; length < bytes.size(); ++length)
            for (unsigned mode = 0; mode < 3; ++mode)
                run(test.label + "-truncated-" + std::to_string(length),
                    Bytes(bytes.begin(), bytes.begin() + length), {5,10,11,12}, 1, mode);
    }
}
