#include "GAVariation.h"
#include <cmath>
namespace ga::layout {
std::vector<double> normalizeCoordinates(View fvar, View avar,
                                         const std::map<Tag, double> &coordinates) {
    std::vector<double> result;
    if (!fvar)
        return result;
    unsigned at = fvar.u16(4), count = fvar.u16(8), stride = fvar.u16(10);
    if (stride < 20)
        throw InvalidTable("short variation axis");
    fvar.array(at, count, stride);
    for (unsigned i = 0; i < count; i++) {
        size_t p = at + i * stride;
        double minimum = fvar.fixed(p + 4), def = fvar.fixed(p + 8), maximum = fvar.fixed(p + 12);
        auto found = coordinates.find(fvar.u32(p));
        double value = found == coordinates.end() ? def : found->second;
        if (minimum > def || def > maximum || !std::isfinite(value))
            throw InvalidTable("invalid variation axis coordinates");
        value = std::clamp(value, minimum, maximum);
        double norm = value < def ? (def == minimum ? 0 : (value - def) / (def - minimum))
                                  : (maximum == def ? 0 : (value - def) / (maximum - def));
        result.push_back(norm);
    }
    if (avar) {
        size_t p = 8;
        unsigned axes = avar.u16(6);
        if (axes != result.size())
            throw InvalidTable("avar axis count mismatch");
        for (unsigned i = 0; i < axes; i++) {
            unsigned count = avar.u16(p);
            p += 2;
            avar.array(p, count, 4);
            double value = result[i];
            for (unsigned j = 1; j < count; j++) {
                double x0 = avar.f2dot14(p + (j - 1) * 4), x1 = avar.f2dot14(p + j * 4);
                if (value >= x0 && value <= x1) {
                    double y0 = avar.f2dot14(p + (j - 1) * 4 + 2), y1 = avar.f2dot14(p + j * 4 + 2);
                    result[i] = x1 == x0 ? y0 : y0 + (value - x0) * (y1 - y0) / (x1 - x0);
                    break;
                }
            }
            p += count * 4;
        }
    }
    return result;
}
double variationDelta(View store, unsigned outer, unsigned inner,
                      const std::vector<double> &normalized) {
    if (!store)
        return 0;
    if (store.u16(0) != 1)
        throw InvalidTable("unknown variation store format");
    unsigned count = store.u16(6);
    if (outer >= count)
        return 0;
    store.array(8, count, 4);
    View data = store.offset32(8 + outer * 4);
    unsigned items = data.u16(0), wordCount = data.u16(2), regions = data.u16(4);
    if (inner >= items)
        return 0;
    bool longWords = wordCount & 0x8000;
    wordCount &= 0x7fff;
    if (wordCount > regions)
        throw InvalidTable("variation word count exceeds regions");
    data.array(6, regions, 2);
    size_t stride = longWords ? size_t(wordCount) * 4 + (regions - wordCount) * 2
                              : size_t(wordCount) * 2 + regions - wordCount;
    size_t row = 6 + size_t(regions) * 2 + size_t(inner) * stride;
    data.require(row, stride);
    View list = store.offset32(2);
    unsigned axes = list.u16(0), regionCount = list.u16(2);
    list.array(4, size_t(axes) * regionCount, 6);
    double result = 0;
    for (unsigned i = 0; i < regions; i++) {
        unsigned region = data.u16(6 + i * 2);
        if (region >= regionCount)
            throw InvalidTable("variation region index outside list");
        double scalar = 1;
        for (unsigned axis = 0; axis < axes; axis++) {
            size_t p = 4 + (size_t(region) * axes + axis) * 6;
            double start = list.f2dot14(p), peak = list.f2dot14(p + 2), end = list.f2dot14(p + 4),
                   value = axis < normalized.size() ? normalized[axis] : 0;
            if (!peak || start > peak || peak > end || (start < 0 && end > 0))
                continue;
            if (value < start || value > end) {
                scalar = 0;
                break;
            }
            if (value == peak)
                continue;
            if (value < peak)
                scalar *= peak == start ? 1 : (value - start) / (peak - start);
            else
                scalar *= end == peak ? 1 : (end - value) / (end - peak);
        }
        int32_t delta;
        if (longWords) {
            if (i < wordCount) {
                delta = data.s32(row);
                row += 4;
            } else {
                delta = data.s16(row);
                row += 2;
            }
        } else if (i < wordCount) {
            delta = data.s16(row);
            row += 2;
        } else
            delta = int8_t(data.u8(row++));
        result += scalar * delta;
    }
    return result;
}
double deviceDelta(View device, View store, const std::vector<double> &normalized) {
    if (!device)
        return 0;
    if (device.u16(4) == 0x8000)
        return variationDelta(store, device.u16(0), device.u16(2), normalized);
    // Layout uses design units, with no pixel grid fitting. Pixel-device deltas
    // intentionally do not apply; VariationIndex deltas always do.
    return 0;
}
} // namespace ga::layout
