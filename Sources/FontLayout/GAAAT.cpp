#include "GAAAT.h"
#include <array>

namespace ga::layout {
static uint64_t unsignedValue(View data, size_t at, unsigned size) {
    if (size != 1 && size != 2 && size != 4 && size != 8)
        throw InvalidTable("unsupported Apple lookup value size");
    data.require(at, size);
    uint64_t result = 0;
    for (unsigned i = 0; i < size; i++)
        result = (result << 8) | data.u8(at + i);
    return result;
}
std::optional<uint64_t> aatLookup(View table, Glyph glyph, unsigned valueSize) {
    if (!table || glyph == 0xffff)
        return {};
    unsigned format = table.u16(0);
    if (format == 0) {
        size_t at = 2 + size_t(glyph) * valueSize;
        if (!table.contains(at, valueSize))
            return {};
        return unsignedValue(table, at, valueSize);
    }
    if (format == 8 || format == 10) {
        unsigned size = format == 8 ? 2 : table.u16(2);
        size_t firstAt = format == 8 ? 2 : 4;
        unsigned first = table.u16(firstAt), count = table.u16(firstAt + 2);
        if (glyph < first || unsigned(glyph) - first >= count)
            return {};
        return unsignedValue(table, firstAt + 4 + size_t(glyph - first) * size, size);
    }
    if (format != 2 && format != 4 && format != 6)
        throw InvalidTable("unknown Apple lookup format");
    unsigned stride = table.u16(2), count = table.u16(4);
    unsigned required = format == 6 ? 2 + valueSize : format == 4 ? 6 : 4 + valueSize;
    if (stride < required)
        throw InvalidTable("short Apple lookup record");
    table.array(12, count, stride);
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2, p = 12 + mid * stride;
        unsigned last = table.u16(p), first = format == 6 ? last : table.u16(p + 2);
        if (glyph < first)
            hi = mid;
        else if (glyph > last)
            lo = mid + 1;
        else if (format == 4)
            return unsignedValue(table, table.u16(p + 4) + size_t(glyph - first) * valueSize,
                                 valueSize);
        else
            return unsignedValue(table, p + (format == 6 ? 2 : 4), valueSize);
    }
    return {};
}
AAT::AAT(View table, bool extended) : extended_(extended) {
    if (!table)
        return;
    unsigned version = table.u32(0) >> 16;
    if ((extended && version != 2 && version != 3) || (!extended && version != 1))
        throw InvalidTable("unknown metamorphosis version");
    size_t at = 8;
    unsigned count = table.u32(4);
    for (unsigned ci = 0; ci < count; ci++) {
        View tail = table.at(at);
        unsigned header = extended ? 16 : 12;
        unsigned length = tail.u32(4);
        if (length < header)
            throw InvalidTable("short metamorphosis chain");
        View body = tail.slice(0, length);
        Chain chain;
        chain.defaults = body.u32(0);
        unsigned features = extended ? body.u32(8) : body.u16(8),
                 subtables = extended ? body.u32(12) : body.u16(10);
        body.array(header, features, 12);
        size_t pos = header;
        for (unsigned fi = 0; fi < features; fi++, pos += 12) {
            Feature f{{body.u16(pos), body.u16(pos + 2)}, body.u32(pos + 4), body.u32(pos + 8)};
            chain.features.push_back(f);
            if (std::find(selectors_.begin(), selectors_.end(), f.selector) == selectors_.end())
                selectors_.push_back(f.selector);
        }
        for (unsigned si = 0; si < subtables; si++) {
            unsigned sh = extended ? 12 : 8;
            body.require(pos, sh);
            unsigned size = extended ? body.u32(pos) : body.u16(pos);
            if (size < sh)
                throw InvalidTable("short metamorphosis subtable");
            View sub = body.slice(pos, size);
            uint32_t coverage = extended ? sub.u32(4) : uint32_t(sub.u16(2)) << 16;
            unsigned type = extended ? (coverage & 255) : (sub.u16(2) & 7);
            coverage &= 0xffff0000;
            if (type != 0 && type != 1 && type != 2 && type != 4 && type != 5)
                throw InvalidTable("unknown metamorphosis subtable type");
            chain.subtables.push_back({type, coverage, sub.u32(extended ? 8 : 4), sub.at(sh)});
            pos += size;
        }
        chains_.push_back(std::move(chain));
        at += length;
    }
}
namespace {
struct Entry {
    unsigned state = 0, flags = 0, first = 0xffff, second = 0xffff;
    friend bool operator==(const Entry &a, const Entry &b) {
        return a.state == b.state && a.flags == b.flags && a.first == b.first &&
               a.second == b.second;
    }
};
class Machine {
    View data_;
    bool extended_;
    unsigned type_, classes_;
    size_t classOffset_, stateOffset_, entryOffset_;

  public:
    Machine(View data, bool extended, unsigned type)
        : data_(data), extended_(extended), type_(type) {
        classes_ = word(0);
        classOffset_ = word(1);
        stateOffset_ = word(2);
        entryOffset_ = word(3);
        if (classes_ < 4)
            throw InvalidTable("state machine omits predefined classes");
        data_.require(classOffset_, extended ? 2 : 4);
        data_.require(stateOffset_, 0);
        data_.require(entryOffset_, 0);
    }
    unsigned word(unsigned field) const {
        return extended_ ? data_.u32(field * 4) : data_.u16(field * 2);
    }
    unsigned glyphClass(Glyph glyph) const {
        if (glyph == 0xffff)
            return 2;
        unsigned result = 1;
        if (extended_) {
            auto value = aatLookup(data_.at(classOffset_), glyph);
            if (value)
                result = unsigned(*value);
        } else {
            unsigned first = data_.u16(classOffset_), count = data_.u16(classOffset_ + 2);
            if (glyph >= first && glyph - first < count)
                result = data_.u8(classOffset_ + 4 + glyph - first);
        }
        return result < classes_ ? result : 1;
    }
    Entry entry(unsigned state, unsigned cls) const {
        size_t index = size_t(state) * classes_ + cls,
               at = stateOffset_ + index * (extended_ ? 2 : 1);
        unsigned ei = extended_ ? data_.u16(at) : data_.u8(at);
        unsigned stride = type_ == 0 ? 4 : type_ == 2 ? (extended_ ? 6 : 4) : 8;
        View record = data_.slice(entryOffset_ + size_t(ei) * stride, stride);
        Entry e;
        unsigned raw = record.u16(0);
        e.flags = record.u16(2);
        if (extended_)
            e.state = raw;
        else {
            if (raw < stateOffset_ || (raw - stateOffset_) % classes_)
                throw InvalidTable("unaligned legacy state row");
            e.state = unsigned((raw - stateOffset_) / classes_);
        }
        if (stride >= 6)
            e.first = record.u16(4);
        if (stride >= 8)
            e.second = record.u16(6);
        return e;
    }
    bool actionable(const Entry &e) const {
        if (type_ == 0)
            return e.flags & 15;
        if (type_ == 1)
            return extended_ ? (e.first != 0xffff || e.second != 0xffff)
                             : (e.first != 0 || e.second != 0);
        if (type_ == 2)
            return extended_ ? (e.flags & 0x2000) : (e.flags & 0x3fff);
        return (e.flags & 0x3ff) != 0;
    }
    std::optional<Glyph> contextual(unsigned index, Glyph glyph) const {
        if (extended_) {
            if (index == 0xffff)
                return {};
            View lookupList = data_.at(word(4));
            auto value = aatLookup(lookupList.offset32(size_t(index) * 4), glyph);
            return value ? std::optional<Glyph>(Glyph(*value)) : std::nullopt;
        }
        if (!index)
            return {};
        int64_t at = 2 * (int64_t(int16_t(index)) + glyph);
        if (at < 0)
            throw InvalidTable("negative legacy substitution offset");
        Glyph g = data_.u16(size_t(at));
        return g ? std::optional<Glyph>(g) : std::nullopt;
    }
    uint32_t ligatureAction(size_t index) const {
        return data_.u32(extended_ ? word(4) + index * 4 : index);
    }
    unsigned component(int64_t glyphPlusOffset) const {
        int64_t at = extended_ ? int64_t(word(5)) + 2 * glyphPlusOffset : 2 * glyphPlusOffset;
        if (at < 0)
            throw InvalidTable("negative ligature component offset");
        return data_.u16(size_t(at));
    }
    Glyph ligature(size_t index) const {
        return data_.u16(extended_ ? word(6) + index * 2 : index);
    }
    std::vector<Glyph> insertion(unsigned index, unsigned count) const {
        if (!count || (extended_ ? index == 0xffff : index == 0))
            return {};
        size_t at = extended_ ? word(4) + size_t(index) * 2 : index;
        data_.array(at, count, 2);
        std::vector<Glyph> result;
        for (unsigned i = 0; i < count; i++)
            result.push_back(data_.u16(at + i * 2));
        return result;
    }
};
class Runner {
    Buffer &buffer_;
    Trace *trace_;
    Budget budget_;
    uint64_t nextIdentity_ = 1;
    size_t mark_ = 0, first_ = 0, last_ = 0;
    bool marked_ = false;
    std::vector<uint64_t> stack_;
    std::optional<Span> dependency_;
    void window(Span span) {
        if (trace_ && !span.empty())
            trace_->windows.insert(span);
    }
    size_t locate(uint64_t identity) const {
        for (size_t i = 0; i < buffer_.size(); i++)
            if (buffer_[i].identity == identity)
                return i;
        return buffer_.size();
    }
    void merge(size_t first, size_t last) {
        if (first >= last || last > buffer_.size())
            return;
        Span span = buffer_[first].source;
        for (size_t i = first + 1; i < last; i++)
            span = unite(span, buffer_[i].source);
        for (size_t i = first; i < last; i++)
            buffer_[i].source = span;
        window(span);
    }
    void rearrange(unsigned verb) {
        if (first_ >= last_ || last_ > buffer_.size())
            return;
        static constexpr std::array<unsigned, 16> heads = {0, 1, 0, 1, 2, 2, 0, 0,
                                                           1, 1, 2, 2, 2, 2, 2, 2};
        static constexpr std::array<unsigned, 16> tails = {0, 0, 1, 1, 0, 0, 2, 2,
                                                           2, 2, 1, 1, 2, 2, 2, 2};
        unsigned h = heads[verb], t = tails[verb];
        if (last_ - first_ < h + t)
            return;
        merge(first_, last_);
        Buffer head(buffer_.begin() + first_, buffer_.begin() + first_ + h),
            tail(buffer_.begin() + last_ - t, buffer_.begin() + last_);
        bool flipHead = verb == 5 || verb == 11 || verb == 13 || verb == 15,
             flipTail = verb == 7 || verb == 9 || verb == 14 || verb == 15;
        if (flipHead)
            std::reverse(head.begin(), head.end());
        if (flipTail)
            std::reverse(tail.begin(), tail.end());
        Buffer result = tail;
        result.insert(result.end(), buffer_.begin() + first_ + h, buffer_.begin() + last_ - t);
        result.insert(result.end(), head.begin(), head.end());
        std::copy(result.begin(), result.end(), buffer_.begin() + first_);
    }
    void contextual(const Machine &machine, const Entry &entry, size_t cursor) {
        if (buffer_.empty() || (cursor == buffer_.size() && !marked_))
            return;
        size_t current = std::min(cursor, buffer_.size() - 1);
        if (marked_ && mark_ < buffer_.size())
            if (auto g = machine.contextual(entry.first, buffer_[mark_].glyph)) {
                window(unite(buffer_[mark_].source, buffer_[current].source));
                buffer_[mark_].glyph = *g;
            }
        if (cursor < buffer_.size())
            if (auto g = machine.contextual(entry.second, buffer_[cursor].glyph))
                buffer_[cursor].glyph = *g;
        if (entry.flags & 0x8000) {
            mark_ = cursor;
            marked_ = true;
        }
    }
    void ligate(const Machine &machine, const Entry &entry, size_t cursor, bool extended) {
        if ((entry.flags & 0x8000) && cursor < buffer_.size()) {
            auto id = buffer_[cursor].identity;
            if (stack_.empty() || stack_.back() != id)
                stack_.push_back(id);
        }
        bool action = extended ? (entry.flags & 0x2000) : (entry.flags & 0x3fff);
        if (!action)
            return;
        size_t actionAt = extended ? entry.first : (entry.flags & 0x3fff);
        unsigned accumulated = 0;
        std::vector<size_t> pending;
        while (!stack_.empty()) {
            budget_.step();
            size_t pos = locate(stack_.back());
            stack_.pop_back();
            if (pos >= buffer_.size())
                continue;
            uint32_t value = machine.ligatureAction(actionAt);
            actionAt += extended ? 1 : 4;
            int32_t offset = int32_t(value & 0x3fffffff);
            if (offset & 0x20000000)
                offset |= int32_t(0xc0000000);
            accumulated += machine.component(int64_t(buffer_[pos].glyph) + offset);
            pending.push_back(pos);
            if (value & 0xc0000000) {
                Glyph glyph = machine.ligature(accumulated);
                Span source = buffer_[pos].source;
                size_t low = pos, high = pos;
                for (size_t p : pending) {
                    source = unite(source, buffer_[p].source);
                    low = std::min(low, p);
                    high = std::max(high, p);
                    if (p != pos)
                        buffer_[p].glyph = 0xffff;
                }
                std::vector<Span> components;
                for (auto it = pending.rbegin(); it != pending.rend(); ++it) {
                    const auto &item = buffer_[*it];
                    if (item.components.empty())
                        components.push_back(item.source);
                    else
                        components.insert(components.end(), item.components.begin(),
                                          item.components.end());
                }
                buffer_[pos].glyph = glyph;
                buffer_[pos].source = source;
                buffer_[pos].components = std::move(components);
                for (size_t p = low; p <= high; p++)
                    buffer_[p].source = source;
                window(source);
                pending = {pos};
            }
            if (value & 0x80000000) {
                if (!pending.empty())
                    stack_.push_back(buffer_[pending.back()].identity);
                break;
            }
        }
    }
    size_t insert(const Machine &machine, unsigned index, unsigned count, size_t position,
                  bool before, Span owner) {
        if (position >= buffer_.size())
            return 0;
        auto glyphs = machine.insertion(index, count);
        if (glyphs.empty())
            return 0;
        Item basis = buffer_[position];
        basis.source = owner;
        Buffer added;
        for (Glyph glyph : glyphs) {
            Item item = basis;
            item.glyph = glyph;
            item.identity = nextIdentity_++;
            added.push_back(std::move(item));
        }
        budget_.growth(buffer_.size() + added.size());
        size_t at = position + (before ? 0 : 1);
        buffer_.insert(buffer_.begin() + at, added.begin(), added.end());
        if (mark_ >= at)
            mark_ += added.size();
        return added.size();
    }
    size_t insertion(const Machine &machine, const Entry &entry, size_t cursor) {
        if (cursor >= buffer_.size()) {
            if (marked_ && mark_ < buffer_.size())
                insert(machine, entry.second, entry.flags & 31, mark_, entry.flags & 0x400,
                       buffer_[mark_].source);
            return buffer_.size();
        }
        auto currentIdentity = buffer_[cursor].identity;
        Span currentSource = buffer_[cursor].source;
        size_t originalMark = mark_;
        bool setMark = entry.flags & 0x8000;
        unsigned markedCount = entry.flags & 31, currentCount = (entry.flags >> 5) & 31;
        if (markedCount && originalMark < buffer_.size()) {
            Span source = (entry.flags & 0x1000) ? buffer_[originalMark].source : currentSource;
            window(unite(buffer_[originalMark].source, currentSource));
            insert(machine, entry.second, markedCount, originalMark, entry.flags & 0x400, source);
        }
        cursor = locate(currentIdentity);
        if (cursor >= buffer_.size())
            return cursor;
        if (setMark) {
            mark_ = cursor;
            marked_ = true;
        }
        if (currentCount) {
            Span source = currentSource;
            if (!(entry.flags & 0x2000) && marked_ && mark_ < buffer_.size())
                source = buffer_[mark_].source;
            bool before = entry.flags & 0x800;
            size_t count = insert(machine, entry.first, currentCount, cursor, before, source);
            if (count) {
                size_t now = locate(currentIdentity);
                return (entry.flags & 0x4000) ? (before ? cursor : now + 1)
                                              : (before ? now : now + count);
            }
        }
        return locate(currentIdentity);
    }

  public:
    Runner(Buffer &buffer, Trace *trace) : buffer_(buffer), trace_(trace), budget_(buffer.size()) {
        for (auto &item : buffer_) {
            if (!item.identity)
                item.identity = nextIdentity_++;
            else
                nextIdentity_ = std::max(nextIdentity_, item.identity + 1);
        }
    }
    void run(View data, unsigned type, bool extended) {
        if (type == 4) {
            for (auto &item : buffer_)
                if (auto value = aatLookup(data, item.glyph))
                    item.glyph = Glyph(*value);
            return;
        }
        Machine machine(data, extended, type);
        unsigned state = 0;
        size_t cursor = 0;
        mark_ = first_ = last_ = 0;
        marked_ = false;
        stack_.clear();
        dependency_.reset();
        while (cursor <= buffer_.size()) {
            budget_.step();
            bool end = cursor == buffer_.size();
            unsigned cls = end ? 0 : machine.glyphClass(buffer_[cursor].glyph);
            Entry entry = machine.entry(state, cls), root = machine.entry(0, cls),
                  ending = machine.entry(state, 0);
            if (!end) {
                // A transition independent of prior state starts a new dependency
                // island. Actual mark/stack actions add their full source scope.
                bool boundary = (state == 0 || entry == root) && !machine.actionable(ending);
                dependency_ = !dependency_ || boundary
                                  ? buffer_[cursor].source
                                  : unite(*dependency_, buffer_[cursor].source);
                if (!boundary)
                    window(*dependency_);
            } else if (dependency_ && machine.actionable(entry))
                window(*dependency_);
            if (type == 0) {
                if (entry.flags & 0x8000)
                    first_ = cursor;
                if (entry.flags & 0x2000)
                    last_ = std::min(cursor + 1, buffer_.size());
                if (entry.flags & 15)
                    rearrange(entry.flags & 15);
            } else if (type == 1)
                contextual(machine, entry, cursor);
            else if (type == 2)
                ligate(machine, entry, cursor, extended);
            else if (type == 5)
                cursor = insertion(machine, entry, cursor);
            state = entry.state;
            if (end)
                break;
            if (!(entry.flags & 0x4000))
                cursor++;
        }
    }
};
} // namespace
void AAT::substitute(Buffer &buffer, std::optional<AATSelector> selector, bool rtl, bool vertical,
                     Trace *trace, bool verticalSubstitutionsOnly) const {
    std::string label = name();
    if (selector)
        label += ":" + std::to_string(selector->type) + ":" + std::to_string(selector->setting);
    for (const auto &chain : chains_) {
        uint32_t flags = chain.defaults;
        if (selector)
            for (const auto &feature : chain.features)
                if (feature.selector == *selector)
                    flags = (flags & feature.disable) | feature.enable;
        for (const auto &sub : chain.subtables) {
            if (!(sub.flags & flags))
                continue;
            if (verticalSubstitutionsOnly) {
                bool directional = !(sub.coverage & 0x20000000) && (sub.coverage & 0x80000000);
                bool selected =
                    selector && selector->type == 4 && (sub.flags & flags & ~chain.defaults);
                if (!directional && !selected)
                    continue;
            }
            if (!(sub.coverage & 0x20000000) && bool(sub.coverage & 0x80000000) != vertical)
                continue;
            bool reverse =
                bool(sub.coverage & 0x40000000) ^ ((sub.coverage & 0x10000000) ? false : rtl);
            Buffer before = trace ? buffer : Buffer{};
            if (reverse)
                std::reverse(buffer.begin(), buffer.end());
            try {
                Runner(buffer, trace).run(sub.data, sub.type, extended_);
            } catch (const InvalidTable &error) {
                throw InvalidTable(name() + " type " + std::to_string(sub.type) + ": " +
                                   error.what());
            }
            if (reverse)
                std::reverse(buffer.begin(), buffer.end());
            if (trace)
                trace->changed(before, buffer, label);
        }
    }
    buffer.erase(std::remove_if(buffer.begin(), buffer.end(),
                                [](const Item &i) { return i.glyph == 0xffff; }),
                 buffer.end());
}
} // namespace ga::layout
