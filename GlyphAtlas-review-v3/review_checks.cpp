/*
 * Focused review checks for GlyphAtlas f4acc1c92366b4210f2aaecdcd1cd2a2ad9368e1.
 * These are isolated loop reproductions and synthetic models, NOT production-
 * linked tests and NOT a complete macOS/CoreText run. Font table parsing is not
 * exercised. The original parent-search loop below is transcribed from
 * Sources/FontLayout/GAPositioning.cpp:187-201; stand-in types supply classes
 * and coverage. Other loops model the indicated source paths.
 * Upstream excerpts: GlyphAtlas, GPL-3.0. No font files are included.
 */
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <optional>
#include <random>
#include <set>
#include <utility>
#include <vector>
using Glyph = uint16_t;
struct Item { Glyph glyph; };
struct ClassDef {
    std::map<Glyph, unsigned> values;
    unsigned get(Glyph g) const {
        auto it = values.find(g); return it == values.end() ? 0 : it->second;
    }
};
struct GDEF { ClassDef glyphClasses; };
struct Coverage {
    std::set<Glyph> values;
    bool contains(Glyph g) const { return values.count(g) != 0; }
};
struct Subtable { unsigned type; };

static std::optional<size_t> currentParent(const std::vector<Item> &buffer_,
                                          const GDEF &gdef_, const Coverage &targets,
                                          const Subtable &sub, size_t at) {
    // Unmodified target-search loop. The real mark() receives no Lookup argument.
    std::optional<size_t> parent;
    for (size_t p = at; p > 0;) {
        p--;
        unsigned glyphClass = gdef_.glyphClasses.get(buffer_[p].glyph);
        if (sub.type != 6 && glyphClass == 3)
            continue;
        if (sub.type == 6 && glyphClass != 3)
            break;
        if (targets.contains(buffer_[p].glyph)) {
            parent = p;
            break;
        }
        if (sub.type != 6)
            break;
    }
    return parent;
}
static std::optional<size_t> expectedMarkParent(const std::vector<Item> &buffer,
                                               const GDEF &gdef, const Coverage &targets,
                                               size_t at, const std::set<Glyph> &ignored = {}) {
    // OpenType GPOS: preceding glyph after LookupFlags skipping, then coverage.
    while (at > 0) {
        --at;
        if (ignored.count(buffer[at].glyph)) continue;
        if (gdef.glyphClasses.get(buffer[at].glyph) != 3 ||
            !targets.contains(buffer[at].glyph)) return {};
        return at;
    }
    return {};
}
static void printParent(std::optional<size_t> value, const std::vector<Item> &b) {
    if (value) std::cout << b[*value].glyph; else std::cout << "none";
}
static void checkParents() {
    const std::vector<Item> b{{1}, {10}, {11}, {12}};
    const GDEF gdef{{{{1, 1}, {10, 3}, {11, 3}, {12, 3}}}};
    const Subtable sub{6};
    // No flags: an un-covered adjacent mark blocks this lookup.
    Coverage targetA{{10}};
    auto actual = currentParent(b, gdef, targetA, sub, 3);
    auto expected = expectedMarkParent(b, gdef, targetA, 3);
    assert(actual == std::optional<size_t>{1} && !expected);
    std::cout << "mkmk, adjacent mark not covered: current="; printParent(actual,b);
    std::cout << ", expected="; printParent(expected,b); std::cout << '\n';
    // A mark filtering set excludes glyph 11, even though coverage contains it.
    Coverage targetBoth{{10,11}};
    actual = currentParent(b, gdef, targetBoth, sub, 3);
    expected = expectedMarkParent(b, gdef, targetBoth, 3, {11});
    assert(actual == std::optional<size_t>{2} && expected == std::optional<size_t>{1});
    std::cout << "mkmk, adjacent mark filtered out: current="; printParent(actual,b);
    std::cout << ", expected="; printParent(expected,b); std::cout << '\n';
}

static std::vector<size_t> oldSkipped(const std::vector<size_t> &positions, uint64_t &comparisons) {
    std::vector<size_t> skipped;
    for (size_t pos = positions.front(); pos <= positions.back(); ++pos) {
        // Instrumented equivalent of std::find in Substitution::ligate().
        bool present = false;
        for (auto candidate : positions) {
            ++comparisons;
            if (candidate == pos) { present = true; break; }
        }
        if (!present) skipped.push_back(pos);
    }
    return skipped;
}
static std::vector<size_t> cursorSkipped(const std::vector<size_t> &positions, uint64_t &comparisons) {
    std::vector<size_t> skipped;
    size_t cursor = 0;
    for (size_t pos = positions.front(); pos <= positions.back(); ++pos) {
        ++comparisons;
        if (positions[cursor] == pos) ++cursor;
        else skipped.push_back(pos);
    }
    return skipped;
}
static void checkLigatureMembership() {
    std::mt19937 rng(24601);
    for (unsigned trial = 0; trial < 1000; ++trial) {
        std::vector<size_t> p{rng() % 20};
        unsigned count = 1 + rng() % 128;
        for (unsigned i = 1; i < count; ++i) p.push_back(p.back() + 1 + rng() % 6);
        uint64_t oldCount = 0, newCount = 0;
        assert(oldSkipped(p, oldCount) == cursorSkipped(p, newCount));
    }
    std::vector<size_t> p(8192);
    for (size_t i = 0; i < p.size(); ++i) p[i] = i;
    uint64_t oldCount=0, newCount=0;
    assert(oldSkipped(p,oldCount) == cursorSkipped(p,newCount));
    std::cout << "ligature membership: 1000 randomized ordered-index cases match\n"
              << "8192 components, equality comparisons: current=" << oldCount
              << ", cursor=" << newCount << '\n';
}
using Plan = std::pair<uint32_t,unsigned>;
template <typename F> static void visitPlans(const std::vector<Plan>& specs, F visit) {
    visit(Plan{0,0});
    for (const auto &[tag, maximum] : specs)
        for (unsigned value=1; value<=maximum; ++value) visit(Plan{tag,value});
}
static void checkPlans() {
    std::mt19937 rng(727);
    for (unsigned trial=0; trial<200; ++trial) {
        std::vector<Plan> specs, materialized{{0,0}}, visited;
        for (unsigned i=0, count=rng()%50; i<count; ++i) specs.emplace_back(i+1,rng()%128);
        for (const auto &[tag, maximum]: specs)
            for (unsigned value=1; value<=maximum; ++value) materialized.emplace_back(tag,value);
        visitPlans(specs,[&](Plan p){visited.push_back(p);});
        assert(materialized == visited);
    }
    // Synthetic metadata, not a loaded font. Measure the new expansion alone.
    std::vector<Plan> specs;
    for (unsigned i=0; i<256; ++i) specs.emplace_back(0x61303030+i,32768);
    std::vector<Plan> expanded{{0,0}};
    visitPlans(specs,[&](Plan p){ if (p.first) expanded.push_back(p); });
    std::cout << "plan enumeration: 200 synthetic cases preserve values and order\n"
              << "256 features x 32768 values: entries=" << expanded.size()
              << ", element_bytes=" << expanded.size()*sizeof(Plan)
              << ", vector_capacity_bytes=" << expanded.capacity()*sizeof(Plan)
              << ", compact_spec_bytes=" << specs.size()*sizeof(Plan) << '\n';
}
struct Advance { double xAdvance, yAdvance; };
static double currentRTLPen(const std::vector<Advance> &buffer, size_t index, uint64_t &visits) {
    double x = 0;
    for (size_t i=index+1; i<buffer.size(); ++i) { ++visits; x+=buffer[i].xAdvance; }
    return x;
}
static void checkRTLWork() {
    constexpr size_t n=4096;
    std::vector<Advance> b(n);
    for (size_t i=0;i<n;++i) b[i]={i%2?0.0:600.0,0};
    uint64_t visits=0;
    for (size_t mark=1;mark<n;mark+=2) {
        const double markPen=currentRTLPen(b,mark,visits);
        const double basePen=currentRTLPen(b,mark-1,visits);
        assert(markPen==basePen);
    }
    assert(visits==n*(n-1)/2);
    std::cout << "RTL pen model, 4096 glyphs / 2048 attachments: suffix visits=" << visits << '\n';
    std::vector<double> values{0.1,0.2,0.3};
    double forward=0,backward=0;
    for (auto v:values) forward+=v;
    for (auto it=values.rbegin();it!=values.rend();++it) backward+=*it;
    std::cout.precision(17);
    std::cout << "floating sum order example: forward=" << forward << ", reverse=" << backward << '\n';
}
int main() {
    checkParents(); checkLigatureMembership(); checkPlans(); checkRTLWork();
    std::cout << "Focused checks passed. No macOS app or production-linked suite was executed.\n";
}
