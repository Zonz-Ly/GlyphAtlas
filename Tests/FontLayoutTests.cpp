#include "FontLayout/GAAAT.h"
#include "FontLayout/GACmap.h"
#include "FontLayout/GAKerning.h"
#include "FontLayout/GAOpenType.h"
#include "FontLayout/GAVariation.h"
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <random>

using namespace ga::layout;
namespace {
size_t checks = 0, mutations = 0;
using Bytes = std::vector<uint8_t>;
void check(bool value, const char *message) {
    ++checks;
    if (!value)
        throw std::runtime_error(message);
}
void u16(Bytes &bytes, unsigned value) {
    bytes.push_back(uint8_t(value >> 8));
    bytes.push_back(uint8_t(value));
}
void u32(Bytes &bytes, uint32_t value) {
    u16(bytes, value >> 16);
    u16(bytes, value);
}
Bytes words(std::initializer_list<unsigned> values) {
    Bytes bytes;
    for (unsigned value : values)
        u16(bytes, value);
    return bytes;
}
void append(Bytes &a, const Bytes &b) {
    a.insert(a.end(), b.begin(), b.end());
}
void invalid(const std::function<void()> &operation) {
    bool rejected = false;
    try {
        operation();
    } catch (const InvalidTable &) {
        rejected = true;
    }
    check(rejected, "malformed data accepted");
}
View cmap(Bytes sub, unsigned platform = 0, unsigned encoding = 4) {
    Bytes bytes = words({0, 1, platform, encoding});
    u32(bytes, 12);
    append(bytes, sub);
    return View(std::move(bytes));
}
void binaryTests() {
    View data(words({0x1234, 0xfffe, 0xabcd}));
    check(data.u16(0) == 0x1234 && data.s16(2) == -2, "big endian signed reads");
    invalid([&] { data.u32(4); });
    invalid([&] { data.slice(SIZE_MAX, 2); });
    invalid([&] { data.array(0, SIZE_MAX, 8); });
    Coverage c1(View(words({1, 3, 2, 5, 7})));
    check(c1.index(5) == 1 && c1.index(4) == -1, "coverage 1 search");
    Coverage c2(View(words({2, 2, 2, 4, 0, 7, 8, 3})));
    check(c2.index(8) == 4 && c2.glyphs().size() == 5, "coverage 2 ranges");
    invalid([] { Coverage x(View(words({2, 1, 9, 3, 0}))); });
    invalid([] { Coverage x(View(words({1, 2, 5, 5}))); });
    ClassDef d1(View(words({1, 2, 3, 1, 2, 3})));
    check(d1.get(3) == 2 && d1.get(1) == 0, "class definition 1");
    ClassDef d2(View(words({2, 1, 2, 5, 7})));
    check(d2.get(4) == 7 && d2.get(6) == 0, "class definition 2");
    invalid([] { ClassDef x(View(words({2, 2, 2, 5, 1, 4, 6, 2}))); });
}
void traceTests() {
    Item prefix, ligature;
    prefix.glyph = 2;
    prefix.source = {0, 1};
    ligature.glyph = 22;
    ligature.source = {0, 2};
    auto result = clusters({prefix, ligature});
    check(result.size() == 1 && result[0].source == Span{0, 2} &&
              result[0].glyphs == std::vector<Glyph>{2, 22},
          "partial seed ligature preserves surviving prefix");
}
void appleLookupTests() {
    check(aatLookup(View(words({0, 0, 0, 7})), 2) == 7, "Apple lookup 0");
    check(aatLookup(View(words({2, 6, 2, 12, 1, 0, 5, 2, 7, 65535, 65535, 0})), 3) == 7,
          "Apple lookup 2");
    check(aatLookup(View(words({4, 6, 2, 12, 1, 0, 5, 2, 24, 65535, 65535, 0, 7, 8, 9, 10})), 3) ==
              8,
          "Apple lookup 4");
    check(aatLookup(View(words({6, 4, 2, 8, 1, 0, 3, 7, 65535, 0})), 3) == 7, "Apple lookup 6");
    check(aatLookup(View(words({8, 3, 2, 7, 8})), 4) == 8, "Apple lookup 8");
    Bytes ten = words({10, 4, 3, 1});
    u32(ten, 70000);
    check(aatLookup(View(ten), 3) == 70000, "Apple lookup 10 wide values");
    check(!aatLookup(View(words({4, 6, 1, 6, 0, 0, 65535, 65535, 18})), 65535),
          "deleted GID does not read sentinel data");
}
void cmapTests() {
    Bytes zero = words({0, 262, 0});
    zero.resize(262);
    zero[6 + 65] = 7;
    check(Cmap(cmap(zero)).nominal(65) == 7, "cmap 0");
    Bytes two = words({2, 528, 0});
    two.resize(518);
    append(two, words({65, 1, 0, 2, 7}));
    check(Cmap(cmap(two)).nominal(65) == 7, "cmap 2");
    Bytes four = words({4, 32, 0, 4, 4, 1, 0, 65, 65535, 0, 65, 65535, 65536 - 58, 1, 0, 0});
    check(Cmap(cmap(four)).nominal(65) == 7, "cmap 4 delta");
    Bytes six = words({6, 12, 0, 65, 1, 7});
    check(Cmap(cmap(six)).nominal(65) == 7, "cmap 6");
    Bytes eight = words({8, 0});
    u32(eight, 8220);
    u32(eight, 0);
    eight.resize(8204);
    u32(eight, 1);
    u32(eight, 0xd83dde00);
    u32(eight, 0xd83dde00);
    u32(eight, 7);
    check(Cmap(cmap(eight)).nominal(0x1f600) == 7, "cmap 8 supplementary UTF-16");
    Bytes ten = words({10, 0});
    u32(ten, 22);
    u32(ten, 0);
    u32(ten, 0x1f600);
    u32(ten, 1);
    u16(ten, 7);
    check(Cmap(cmap(ten)).nominal(0x1f600) == 7, "cmap 10");
    for (unsigned format : {12, 13}) {
        Bytes sub = words({format, 0});
        u32(sub, 28);
        u32(sub, 0);
        u32(sub, 1);
        u32(sub, 65);
        u32(sub, 66);
        u32(sub, 7);
        Cmap map(cmap(sub));
        check(map.nominal(66) == (format == 12 ? 8 : 7), "cmap 12/13");
    }
    Bytes symbol = words({6, 12, 0, 0xf041, 1, 7});
    check(Cmap(cmap(symbol, 3, 0)).nominal(65) == 7, "symbol cmap fallback");
    zero[6 + 128] = 8;
    check(Cmap(cmap(zero, 1, 0)).nominal(0xc4) == 8, "MacRoman fallback");
    Bytes uv = words({14});
    u32(uv, 30);
    u32(uv, 1);
    uv.insert(uv.end(), {0, 0xfe, 0x0f});
    u32(uv, 0);
    u32(uv, 21);
    u32(uv, 1);
    uv.insert(uv.end(), {0, 0, 65});
    u16(uv, 9);
    check(Cmap(cmap(uv)).variation(65, 0xfe0f) == 9, "nondefault cmap 14");
}
View variationStore(bool longWords = false) {
    Bytes store = words({1});
    u32(store, 12);
    u16(store, 1);
    u32(store, 22);
    append(store, words({1, 1, 0, 16384, 16384}));
    append(store, words({1, longWords ? 0x8001u : 1u, 1, 0}));
    if (longWords)
        u32(store, 100000);
    else
        u16(store, 200);
    return View(std::move(store));
}
void variationTests() {
    auto store = variationStore();
    check(variationDelta(store, 0, 0, {0}) == 0, "variation default origin");
    check(variationDelta(store, 0, 0, {0.5}) == 100, "variation interpolation");
    check(variationDelta(store, 0, 0, {1}) == 200, "variation peak");
    check(variationDelta(variationStore(true), 0, 0, {0.5}) == 50000, "long variation words");
    check(deviceDelta(View(words({0, 0, 0x8000})), store, {0.5}) == 100, "VariationIndex device");
    check(deviceDelta(View(words({10, 12, 1})), store, {1}) == 0, "unhinted pixel devices");
    Bytes fvar = words({1, 0, 16, 2, 1, 20, 0, 0});
    u32(fvar, tag('w', 'g', 'h', 't'));
    u32(fvar, 100 * 65536);
    u32(fvar, 400 * 65536);
    u32(fvar, 900 * 65536);
    u16(fvar, 0);
    u16(fvar, 256);
    auto normalized = normalizeCoordinates(View(fvar), {}, {{tag('w', 'g', 'h', 't'), 650}});
    check(normalized == std::vector<double>{0.5}, "fvar normalization");
    Bytes avar = words({1, 0, 0, 1, 4, 0xc000, 0xc000, 0, 0, 0x2000, 0x3000, 0x4000, 0x4000});
    check(normalizeCoordinates(View(fvar), View(avar), {{tag('w', 'g', 'h', 't'), 650}}) ==
              std::vector<double>{0.75},
          "avar segment mapping");
}
Buffer seed() {
    Buffer items;
    for (Glyph glyph : {2, 3, 7, 8, 14}) {
        Item item;
        item.glyph = glyph;
        item.source = {uint32_t(items.size()), uint32_t(items.size() + 1)};
        items.push_back(item);
    }
    return items;
}
void exercise(Tag name, const Bytes &bytes) {
    View table(bytes);
    Buffer buffer = seed();
    Settings settings;
    settings.features[tag('t', 'e', 's', 't')] = 1;
    Trace trace;
    Metrics metrics;
    metrics.horizontalAdvance = [](Glyph) { return 600; };
    metrics.verticalAdvance = [](Glyph) { return 1000; };

    if (name == tag('G', 'S', 'U', 'B')) {
        OpenType program(table);
        program.substitute(buffer, GDEF{}, settings, 0, &trace);
    } else if (name == tag('G', 'P', 'O', 'S')) {
        OpenType program(table, true);
        program.position(buffer, GDEF{}, settings, metrics);
    } else if (name == tag('m', 'o', 'r', 'x') || name == tag('m', 'o', 'r', 't'))
        AAT(table, name == tag('m', 'o', 'r', 'x')).substitute(buffer, {}, false, false, &trace);
    else if (name == tag('G', 'D', 'E', 'F')) {
        GDEF gdef(table);
        for (const auto &item : buffer)
            gdef.included(item.glyph, 0x10, 0);
    } else if (name == tag('c', 'm', 'a', 'p')) {
        Cmap map(table);
        for (uint32_t scalar : {32, 65, 0x301, 0x1f600}) {
            map.nominal(scalar);
            map.variation(scalar, 0xfe0f);
        }
    } else if (name == tag('k', 'e', 'r', 'n') || name == tag('k', 'e', 'r', 'x'))
        Kerning(name == tag('k', 'e', 'r', 'n') ? table : View{},
                name == tag('k', 'e', 'r', 'x') ? table : View{})
            .position(buffer, settings, GDEF{});
    for (const auto &item : buffer)
        check(item.source.start < item.source.end, "source span lost");
}
void mutationsTest(const std::filesystem::path &directory) {
    std::mt19937 random(1729);
    for (const auto &entry : std::filesystem::directory_iterator(directory)) {
        if (entry.path().extension() != ".ttf")
            continue;
        std::ifstream file(entry.path(), std::ios::binary);
        Bytes bytes((std::istreambuf_iterator<char>(file)), {});
        View sfnt(bytes);
        for (unsigned i = 0; i < sfnt.u16(4); i++) {
            size_t p = 12 + i * 16;
            Tag name = sfnt.u32(p);
            bool relevant = false;
            for (Tag supported :
                 {tag('G', 'S', 'U', 'B'), tag('G', 'P', 'O', 'S'), tag('m', 'o', 'r', 'x'),
                  tag('m', 'o', 'r', 't'), tag('G', 'D', 'E', 'F'), tag('c', 'm', 'a', 'p'),
                  tag('k', 'e', 'r', 'n'), tag('k', 'e', 'r', 'x')})
                relevant |= name == supported;
            if (!relevant)
                continue;
            size_t offset = sfnt.u32(p + 8), size = sfnt.u32(p + 12);
            Bytes original(bytes.begin() + offset, bytes.begin() + offset + size);
            for (size_t m = 0; m < std::min<size_t>(size, 80) + 40; m++) {
                Bytes changed = original;
                if (m < std::min<size_t>(size, 80))
                    changed.resize(m);
                else if (!changed.empty())
                    changed[random() % changed.size()] ^= uint8_t(1u << (random() % 8));
                try {
                    exercise(name, changed);
                } catch (const InvalidTable &) {
                }
                ++mutations;
            }
        }
    }
}
} // namespace
int main(int argc, char **argv) {
    try {
        binaryTests();
        traceTests();
        appleLookupTests();
        cmapTests();
        variationTests();
        if (argc == 2)
            mutationsTest(argv[1]);
        std::cout << "OK: " << checks << " core assertions; " << mutations
                  << " deterministic truncated/mutated table executions\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << "\n";
        return 1;
    }
}
