#include "GAOpenType.h"
#include "GAVariation.h"
#include <cmath>

namespace ga::layout {
namespace {
size_t valueSize(unsigned format) {
    if (format & 0xff00)
        throw InvalidTable("reserved positioning value bits");
    return size_t(__builtin_popcount(format)) * 2;
}
void valueRecord(Item &item, View parent, size_t at, unsigned format, const GDEF &gdef,
                 const Metrics &metrics) {
    double value[4] = {};
    parent.require(at, valueSize(format));
    for (unsigned bit = 0; bit < 8; bit++)
        if (format & (1u << bit)) {
            if (bit < 4)
                value[bit] += parent.s16(at);
            else
                value[bit - 4] +=
                    deviceDelta(parent.offset16(at), gdef.variations, metrics.normalized);
            at += 2;
        }
    item.xOffset += value[0];
    item.yOffset += value[1];
    item.xAdvance += value[2];
    item.yAdvance += value[3];
}
std::optional<Point> anchor(View table, const GDEF &gdef, const Metrics &metrics) {
    if (!table)
        return {};
    unsigned format = table.u16(0);
    if (format < 1 || format > 3)
        throw InvalidTable("unknown anchor format");
    Point p{double(table.s16(2)), double(table.s16(4))};
    if (format == 2)
        table.require(6, 2); // Contour indices are only needed for grid fitting.
    if (format == 3) {
        p.x += deviceDelta(table.offset16(6), gdef.variations, metrics.normalized);
        p.y += deviceDelta(table.offset16(8), gdef.variations, metrics.normalized);
    }
    return p;
}
struct Attachment {
    size_t parent = 0;
    Point delta;
    bool cursive = false;
};
struct PositionResult {
    bool matched = false;
    size_t next = 0;
};
class Positioning {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    const Metrics &metrics_;
    const Settings &settings_;
    Buffer &buffer_;
    Budget budget_;
    std::map<size_t, Attachment> attachments_;
    std::set<std::pair<unsigned, size_t>> active_;
    std::optional<size_t> next(size_t at, const Lookup &lookup) const {
        for (size_t i = at + 1; i < buffer_.size(); i++)
            if (accepts(gdef_, lookup, buffer_[i]))
                return i;
        return {};
    }
    PositionResult pair(const Subtable &sub, const Lookup &lookup, size_t at) {
        auto second = next(at, lookup);
        if (!second)
            return {};
        View d = sub.data;
        int ci = sub.coverage.index(buffer_[at].glyph);
        if (ci < 0)
            return {};
        unsigned f1 = d.u16(4), f2 = d.u16(6);
        size_t size1 = valueSize(f1), size2 = valueSize(f2);
        if (d.u16(0) == 1) {
            if (unsigned(ci) >= d.u16(8))
                return {};
            View set = d.offset16(10 + ci * 2);
            unsigned count = set.u16(0);
            size_t stride = 2 + size1 + size2;
            set.array(2, count, stride);
            size_t lo = 0, hi = count;
            Glyph wanted = buffer_[*second].glyph;
            while (lo < hi) {
                size_t mid = (lo + hi) / 2, p = 2 + mid * stride;
                Glyph g = set.u16(p);
                if (g < wanted)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            if (lo >= count || set.u16(2 + lo * stride) != wanted)
                return {};
            size_t p = 4 + lo * stride;
            valueRecord(buffer_[at], set, p, f1, gdef_, metrics_);
            valueRecord(buffer_[*second], set, p + size1, f2, gdef_, metrics_);
        } else if (d.u16(0) == 2) {
            unsigned c1 = ClassDef(d.offset16(8)).get(buffer_[at].glyph),
                     c2 = ClassDef(d.offset16(10)).get(buffer_[*second].glyph), n1 = d.u16(12),
                     n2 = d.u16(14);
            if (c1 >= n1 || c2 >= n2)
                return {};
            size_t p = 16 + (size_t(c1) * n2 + c2) * (size1 + size2);
            valueRecord(buffer_[at], d, p, f1, gdef_, metrics_);
            valueRecord(buffer_[*second], d, p + size1, f2, gdef_, metrics_);
        } else
            throw InvalidTable("unknown pair positioning format");
        return {true, f2 ? *second + 1 : at + 1};
    }
    PositionResult cursive(const Subtable &sub, const Lookup &lookup, size_t at) {
        auto second = next(at, lookup);
        if (!second)
            return {};
        View d = sub.data;
        if (d.u16(0) != 1)
            throw InvalidTable("unknown cursive format");
        int a = sub.coverage.index(buffer_[at].glyph),
            b = sub.coverage.index(buffer_[*second].glyph);
        if (a < 0 || b < 0 || unsigned(a) >= d.u16(4) || unsigned(b) >= d.u16(4))
            return {};
        auto exit = anchor(d.offset16(8 + a * 4), gdef_, metrics_),
             entry = anchor(d.offset16(6 + b * 4), gdef_, metrics_);
        if (!exit || !entry)
            return {};
        auto &first = buffer_[at];
        auto &last = buffer_[*second];
        if (settings_.vertical) {
            double firstY = exit->y + first.yOffset, secondY = entry->y + last.yOffset;
            if (!settings_.rtl) {
                first.yAdvance = firstY;
                last.yAdvance -= secondY;
                last.yOffset -= secondY;
            } else {
                first.yAdvance -= firstY;
                first.yOffset -= firstY;
                last.yAdvance = secondY;
            }
        } else if (!settings_.rtl) {
            first.xAdvance = exit->x + first.xOffset;
            double delta = entry->x + last.xOffset;
            last.xAdvance -= delta;
            last.xOffset -= delta;
        } else {
            double delta = exit->x + first.xOffset;
            first.xAdvance -= delta;
            first.xOffset -= delta;
            last.xAdvance = entry->x + last.xOffset;
        }
        if (lookup.flags & 1)
            attachments_[at] = {*second, {entry->x - exit->x, entry->y - exit->y}, true};
        else
            attachments_[*second] = {at, {exit->x - entry->x, exit->y - entry->y}, true};
        return {true, at + 1};
    }
    PositionResult mark(const Subtable &sub, size_t at) {
        View d = sub.data;
        if (d.u16(0) != 1)
            throw InvalidTable("unknown mark positioning format");
        int ci = sub.coverage.index(buffer_[at].glyph);
        if (ci < 0)
            return {};
        Coverage targets(d.offset16(4));
        unsigned classes = d.u16(6);
        View marks = d.offset16(8);
        if (unsigned(ci) >= marks.u16(0))
            return {};
        unsigned markClass = marks.u16(2 + ci * 4);
        if (markClass >= classes)
            return {};
        auto markAnchor = anchor(marks.offset16(4 + ci * 4), gdef_, metrics_);
        if (!markAnchor)
            return {};
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
        if (!parent)
            return {};
        int targetIndex = targets.index(buffer_[*parent].glyph);
        View array = d.offset16(10);
        std::optional<Point> base;
        if (unsigned(targetIndex) >= array.u16(0))
            return {};
        if (sub.type == 5) {
            View ligature = array.offset16(2 + targetIndex * 2);
            unsigned components = ligature.u16(0);
            if (!components)
                return {};
            unsigned component =
                buffer_[at].component >= 0 ? unsigned(buffer_[at].component) : components - 1;
            component = std::min(component, components - 1);
            base = anchor(ligature.offset16(2 + (size_t(component) * classes + markClass) * 2),
                          gdef_, metrics_);
        } else
            base = anchor(array.offset16(2 + (size_t(targetIndex) * classes + markClass) * 2),
                          gdef_, metrics_);
        if (!base)
            return {};
        attachments_[at] = {*parent, {base->x - markAnchor->x, base->y - markAnchor->y}, false};
        return {true, at + 1};
    }
    PositionResult subtable(const Subtable &sub, const Lookup &lookup, size_t at) {
        View d = sub.data;
        if (sub.type == 1) {
            int ci = sub.coverage.index(buffer_[at].glyph);
            if (ci < 0)
                return {};
            unsigned format = d.u16(0), valueFormat = d.u16(4);
            size_t p = 6;
            if (format == 2) {
                if (unsigned(ci) >= d.u16(6))
                    return {};
                p = 8 + size_t(ci) * valueSize(valueFormat);
            } else if (format != 1)
                throw InvalidTable("unknown single positioning format");
            valueRecord(buffer_[at], d, p, valueFormat, gdef_, metrics_);
            return {true, at + 1};
        }
        if (sub.type == 2)
            return pair(sub, lookup, at);
        if (sub.type == 3)
            return cursive(sub, lookup, at);
        if (sub.type >= 4 && sub.type <= 6)
            return mark(sub, at);
        auto candidates = sub.starts.find(buffer_[at].glyph);
        if (candidates == sub.starts.end())
            return {};
        for (unsigned pi : candidates->second) {
            budget_.step();
            const auto &pattern = sub.patterns[pi];
            auto positions = match(pattern, buffer_, at, gdef_, lookup);
            if (!positions)
                continue;
            size_t end = positions->back() + 1;
            for (auto record : pattern.actions)
                if (record.sequence < positions->size()) {
                    auto nested = apply(record.lookup, (*positions)[record.sequence]);
                    if (nested.matched)
                        end = std::max(end, nested.next);
                }
            return {true, end};
        }
        return {};
    }
    PositionResult apply(unsigned index, size_t at) {
        budget_.step();
        if (index >= lookups_.size() || at >= buffer_.size() || active_.size() >= 64 ||
            !active_.insert({index, at}).second)
            return {};
        const auto &lookup = lookups_[index];
        PositionResult result;
        if (accepts(gdef_, lookup, buffer_[at]))
            for (const auto &sub : lookup.subtables) {
                result = subtable(sub, lookup, at);
                if (result.matched)
                    break;
            }
        active_.erase({index, at});
        return result;
    }
    Point pen(size_t index) const {
        Point p;
        if (settings_.rtl)
            for (size_t i = index + 1; i < buffer_.size(); i++) {
                p.x += buffer_[i].xAdvance;
                p.y += buffer_[i].yAdvance;
            }
        else
            for (size_t i = 0; i < index; i++) {
                p.x += buffer_[i].xAdvance;
                p.y += buffer_[i].yAdvance;
            }
        return p;
    }
    void resolve(size_t index, std::set<size_t> &path, std::set<size_t> &done) {
        if (done.count(index))
            return;
        auto found = attachments_.find(index);
        if (found == attachments_.end())
            return;
        if (!path.insert(index).second) {
            attachments_.erase(index);
            return;
        }
        auto attachment = found->second;
        resolve(attachment.parent, path, done);
        auto &item = buffer_[index];
        const auto &parent = buffer_[attachment.parent];
        if (attachment.cursive) {
            if (settings_.vertical)
                item.xOffset += parent.xOffset + attachment.delta.x;
            else
                item.yOffset += parent.yOffset + attachment.delta.y;
        } else {
            auto p = pen(index), base = pen(attachment.parent);
            item.xOffset = base.x + parent.xOffset + attachment.delta.x - p.x;
            item.yOffset = base.y + parent.yOffset + attachment.delta.y - p.y;
        }
        path.erase(index);
        done.insert(index);
    }

  public:
    Positioning(const std::vector<Lookup> &lookups, const GDEF &gdef, const Settings &settings,
                const Metrics &metrics, Buffer &buffer)
        : lookups_(lookups), gdef_(gdef), metrics_(metrics), settings_(settings), buffer_(buffer),
          budget_(buffer.size()) {}
    void run(const std::vector<LookupStep> &plan) {
        for (auto &item : buffer_) {
            item.xOffset = item.yOffset = 0;
            item.xAdvance = settings_.vertical ? 0 : metrics_.horizontalAdvance(item.glyph);
            item.yAdvance = settings_.vertical ? -metrics_.verticalAdvance(item.glyph) : 0;
        }
        for (auto &item : buffer_)
            if (gdef_.glyphClasses.get(item.glyph) == 3) {
                item.xAdvance = 0;
                item.yAdvance = 0;
            }
        for (auto step : plan)
            for (size_t i = 0; i < buffer_.size();) {
                auto result = apply(step.lookup, i);
                i = result.matched ? result.next : i + 1;
            }
        std::set<size_t> done, path;
        std::vector<size_t> keys;
        for (const auto &entry : attachments_)
            keys.push_back(entry.first);
        for (size_t index : keys)
            resolve(index, path, done);
    }
};
} // namespace
void OpenType::position(Buffer &buffer, const GDEF &gdef, const Settings &settings,
                        const Metrics &metrics, size_t branch) const {
    if (!positioning_)
        throw InvalidTable("substitution program used for positioning");
    Positioning(lookups_, gdef, settings, metrics, buffer).run(plan(settings, branch));
}
} // namespace ga::layout
