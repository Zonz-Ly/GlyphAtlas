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
        if (found != result.begin() && item.glyph != 0xffff)
            (found - 1)->glyphs.push_back(item.glyph);
    }
    return result;
}
void Trace::changed(const Buffer &before, const Buffer &after, const std::string &feature) {
    auto old = clusters(before), next = clusters(after);
    std::map<Span, std::vector<Glyph>> prior;
    for (const auto &cluster : old)
        prior.emplace(cluster.source, cluster.glyphs);
    for (const auto &cluster : next) {
        auto found = prior.find(cluster.source);
        if (found == prior.end() || found->second != cluster.glyphs)
            changes.push_back({cluster.source, cluster.glyphs, feature});
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
            changes.push_back({cluster.source, {}, feature});
    }
}
GDEF::GDEF(View table) {
    if (!table)
        return;
    table.require(0, 12);
    glyphClasses = ClassDef(table.offset16(4));
    markAttachmentClasses = ClassDef(table.offset16(10));
    if (table.u32(0) >= 0x10002) {
        View sets = table.offset16(12);
        if (sets) {
            sets.array(4, sets.u16(2), 4);
            for (unsigned i = 0; i < sets.u16(2); i++)
                markSets.emplace_back(sets.offset32(4 + i * 4));
        }
    }
    if (table.u32(0) >= 0x10003)
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
