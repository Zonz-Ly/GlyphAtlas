#include "GAGlyphBuffer.h"
namespace ga::layout {
std::vector<Cluster> clusters(const Buffer &buffer) {
    std::vector<Span> spans;
    for (const auto &item : buffer)
        spans.push_back(item.source);
    std::sort(spans.begin(), spans.end());
    std::vector<Cluster> result;
    for (Span span : spans) {
        if (!result.empty() && span.start < result.back().source.end)
            result.back().source = unite(result.back().source, span);
        else
            result.push_back({span, {}});
    }
    // Overlapping sources form one atomic replacement. In particular, when
    // only the final GID of a multi-GID seed ligates with its neighbor, the
    // seed's surviving prefix must accompany the new ligature in the result.
    for (const auto &item : buffer) {
        auto found = std::upper_bound(
            result.begin(), result.end(), item.source.start,
            [](uint32_t start, const Cluster &cluster) { return start < cluster.source.start; });
        if (item.glyph != 0xffff)
            (found - 1)->glyphs.push_back(item.glyph);
    }
    return result;
}
std::vector<uint64_t> Change::inputKey() const {
    std::vector<uint64_t> key;
    for (const auto &input : inputs) {
        key.insert(key.end(), {input.source.start, input.source.end, input.glyphs.size()});
        key.insert(key.end(), input.glyphs.begin(), input.glyphs.end());
    }
    return key;
}
void Trace::changed(const Buffer &before, const Buffer &after, const std::string &feature) {
    auto same = [](const Item &a, const Item &b) {
        return a.glyph == b.glyph && a.source == b.source;
    };
    auto [firstOld, firstNew] =
        std::mismatch(before.begin(), before.end(), after.begin(), after.end(), same);
    bool sameBuffer = firstOld == before.end() && firstNew == after.end();
    if (sameBuffer && std::none_of(before.begin(), before.end(),
                                  [](const Item &item) { return item.source.empty(); }))
        return;
    Buffer oldWindow, newWindow;
    if (!provenance && !sameBuffer) {
        auto [lastOldReversed, lastNewReversed] = std::mismatch(
            before.rbegin(), std::make_reverse_iterator(firstOld),
            after.rbegin(), std::make_reverse_iterator(firstNew), same);
        auto lastOld = lastOldReversed.base(), lastNew = lastNewReversed.base();
        Span scope{UINT32_MAX, 0};
        bool positive = true;
        auto include = [&](const Item &item) {
            scope = unite(scope, item.source);
            positive &= !item.source.empty();
        };
        std::for_each(firstOld, lastOld, include);
        std::for_each(firstNew, lastNew, include);
        auto intersects = [&](const Item &item) {
            if (item.source.empty()) return true;
            return item.source.start < scope.end && scope.start < item.source.end;
        };
        // Include unchanged glyphs in an affected atomic source cluster.
        for (;;) {
            Span prior = scope;
            while (firstOld != before.begin() && intersects(firstOld[-1])) {
                --firstNew;
                include(*--firstOld);
            }
            while (lastOld != before.end() && intersects(*lastOld)) {
                ++lastNew;
                include(*lastOld++);
            }
            if (prior == scope) break;
        }
        if (positive && std::none_of(before.begin(), firstOld, intersects) &&
            std::none_of(lastOld, before.end(), intersects)) {
            oldWindow.assign(firstOld, lastOld);
            newWindow.assign(firstNew, lastNew);
        }
    }
    bool window = !oldWindow.empty() || !newWindow.empty();
    auto old = clusters(window ? oldWindow : before), next = clusters(window ? newWindow : after);
    size_t firstChange = changes.size();
    auto append = [&](Span source, const std::vector<Glyph> &glyphs) {
        Change change{source, glyphs, feature, {}};
        auto first = std::lower_bound(old.begin(), old.end(), source.start,
            [](const Cluster &input, uint32_t start) { return input.source.end <= start; });
        for (auto input = first; input != old.end() && input->source.start < source.end; ++input)
            change.inputs.push_back(*input);
        changes.push_back(std::move(change));
    };
    // clusters preserves Span ordering; lower_bound also keeps the first equal span.
    for (const auto &cluster : next) {
        auto found = std::lower_bound(
            old.begin(), old.end(), cluster.source,
            [](const Cluster &item, Span source) { return item.source < source; });
        if (found == old.end() || !(found->source == cluster.source) || found->glyphs != cluster.glyphs)
            append(cluster.source, cluster.glyphs);
    }
    // Prefix maxima allow each old interval to be tested independently, even
    // when source scopes overlap or nest after a rearrangement or insertion.
    std::vector<uint32_t> ends;
    uint32_t maximum = 0;
    for (const auto &cluster : next) {
        maximum = std::max(maximum, cluster.source.end);
        ends.push_back(maximum);
    }
    for (const auto &cluster : old) {
        auto limit = std::lower_bound(
            next.begin(), next.end(), cluster.source.end,
            [](const Cluster &item, uint32_t end) { return item.source.start < end; });
        size_t count = size_t(limit - next.begin());
        if (!count || ends[count - 1] <= cluster.source.start)
            append(cluster.source, {});
    }
    if (provenance && changes.size() != firstChange)
        steps.push_back({before, after, feature});
}
GDEF::GDEF(View table) {
    if (!table)
        return;
    table.require(0, 12);
    glyphClasses = ClassDef(table.offset16(4));
    markAttachmentClasses = ClassDef(table.offset16(10));
    auto version = table.u32(0);
    if (version >= 0x10002) {
        View sets = table.offset16(12);
        if (sets) {
            unsigned count = sets.u16(2);
            sets.array(4, count, 4);
            for (unsigned i = 0; i < count; i++)
                markSets.emplace_back(sets.offset32(4 + i * 4));
        }
    }
    if (version >= 0x10003)
        variations = table.offset32(14);
}
bool GDEF::included(Glyph glyph, unsigned flags, unsigned markSet) const {
    unsigned cls = glyphClasses.get(glyph);
    if ((cls == 1 && (flags & 2)) || (cls == 2 && (flags & 4)) || (cls == 3 && (flags & 8)))
        return false;
    if (cls == 3) {
        if (flags & 16)
            return markSet < markSets.size() && markSets[markSet].contains(glyph);
        if (flags & 0xff00)
            return markAttachmentClasses.get(glyph) == (flags >> 8);
    }
    return true;
}
} // namespace ga::layout
