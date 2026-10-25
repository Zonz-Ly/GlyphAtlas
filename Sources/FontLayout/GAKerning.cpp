#include "GAKerning.h"
namespace ga::layout {
namespace {
std::optional<double> pair(View body, Glyph first, Glyph second, bool extended) {
    unsigned count = extended ? body.u32(0) : body.u16(0);
    size_t start = extended ? 16 : 8;
    body.array(start, count, 6);
    uint32_t key = (uint32_t(first) << 16) | second;
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2, p = start + mid * 6;
        uint32_t found = body.u32(p);
        if (found < key)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < count && body.u32(start + lo * 6) == key
               ? std::optional<double>(body.s16(start + lo * 6 + 4))
               : std::nullopt;
}
unsigned classicClass(View table, size_t offset, Glyph glyph, unsigned fallback = 0) {
    unsigned first = table.u16(offset), count = table.u16(offset + 2);
    return glyph >= first && glyph - first < count
               ? table.u16(offset + 4 + size_t(glyph - first) * 2)
               : fallback;
}
void adjust(Buffer &buffer, size_t first, size_t second, double value, bool vertical, bool cross,
            bool overrideValue) {
    auto &a = buffer[first];
    auto &b = buffer[second];
    double &target =
        cross ? (vertical ? b.xOffset : b.yOffset) : (vertical ? a.yAdvance : a.xAdvance);
    if (cross && value == -32768) {
        target = 0;
        return;
    }
    if (vertical && !cross)
        value = -value;
    if (overrideValue)
        target = value;
    else
        target += value;
}
void table(View table, bool extended, Buffer &buffer, const Settings &settings, const GDEF &gdef) {
    if (!table)
        return;
    bool apple = extended || table.u16(0) != 0;
    unsigned count = apple ? table.u32(4) : table.u16(2);
    size_t at = apple ? 8 : 4;
    for (unsigned si = 0; si < count; si++) {
        View rest = table.at(at);
        unsigned header = extended ? 12 : apple ? 8 : 6;
        size_t size = extended || apple ? rest.u32(0) : rest.u16(2);
        if (size < header)
            throw InvalidTable("short kerning subtable");
        View sub = rest.slice(0, size), body = sub.at(header);
        at += size;
        uint32_t coverage = extended ? sub.u32(4) : sub.u16(4);
        unsigned format = extended || apple ? coverage & 255 : coverage >> 8;
        bool vertical = extended ? coverage & 0x80000000
                        : apple  ? coverage & 0x8000
                                 : !(coverage & 1),
             cross = extended ? coverage & 0x40000000
                     : apple  ? coverage & 0x4000
                              : coverage & 4;
        if (vertical != settings.vertical)
            continue;
        if (!apple && (coverage & 2))
            continue;
        bool overrideValue = !apple && (coverage & 8);
        if ((extended && (coverage & 0x20000000)) || (apple && !extended && (coverage & 0x2000)))
            throw InvalidTable("variation kerning requires tuple data");
        for (size_t i = 0; i < buffer.size(); i++) {
            if (gdef.glyphClasses.get(buffer[i].glyph) == 3)
                continue;
            size_t j = i + 1;
            while (j < buffer.size() && gdef.glyphClasses.get(buffer[j].glyph) == 3)
                j++;
            if (j >= buffer.size())
                break;
            std::optional<double> value;
            if (format == 0)
                value = pair(body, buffer[i].glyph, buffer[j].glyph, extended);
            else if (format == 2) {
                unsigned row = extended ? body.u32(0) : body.u16(0),
                         left = extended ? body.u32(4) : body.u16(2),
                         right = extended ? body.u32(8) : body.u16(4),
                         array = extended ? body.u32(12) : body.u16(6);
                if (!row)
                    throw InvalidTable("zero kerning row width");
                unsigned a = extended
                                 ? unsigned(aatLookup(sub.at(left), buffer[i].glyph).value_or(0))
                                 : classicClass(sub, left, buffer[i].glyph, array);
                unsigned b = extended
                                 ? unsigned(aatLookup(sub.at(right), buffer[j].glyph).value_or(0))
                                 : classicClass(sub, right, buffer[j].glyph);
                value = sub.s16(extended ? array + size_t(a) + b : size_t(a) + b);
            } else if (format == 3 && !extended) {
                unsigned glyphs = body.u16(0), values = body.u8(2), left = body.u8(3),
                         right = body.u8(4);
                size_t leftAt = 6 + values * 2, rightAt = leftAt + glyphs,
                       indexAt = rightAt + glyphs;
                if (buffer[i].glyph >= glyphs || buffer[j].glyph >= glyphs)
                    continue;
                unsigned a = body.u8(leftAt + buffer[i].glyph),
                         b = body.u8(rightAt + buffer[j].glyph);
                if (a >= left || b >= right)
                    throw InvalidTable("kerning class exceeds matrix");
                unsigned index = body.u8(indexAt + size_t(a) * right + b);
                if (index >= values)
                    throw InvalidTable("kerning value outside list");
                value = body.s16(6 + index * 2);
            } else
                throw InvalidTable("unsupported kerning subtable format");
            if (value)
                adjust(buffer, i, j, *value, vertical, cross, overrideValue);
        }
    }
}
} // namespace
void Kerning::position(Buffer &buffer, const Settings &settings, const GDEF &gdef) const {
    auto kern = settings.features.find(tag('k', 'e', 'r', 'n'));
    if (kern != settings.features.end() && !kern->second)
        return;
    if (kerx_)
        table(kerx_, true, buffer, settings, gdef);
    else
        table(kern_, false, buffer, settings, gdef);
}
} // namespace ga::layout
