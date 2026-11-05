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
    size_t subtableIndex = 0;
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
            chain.subtables.push_back({type, coverage, sub.u32(extended ? 8 : 4), sub.at(sh), {}, subtableIndex++});
            pos += size;
        }
        chains_.push_back(std::move(chain));
        at += length;
    }
}
namespace {
void addOutput(std::vector<bool> &outputs, uint64_t glyph) {
    if (glyph && glyph != 0xffff && glyph < outputs.size())
        outputs[size_t(glyph)] = true;
}

void collectLookupOutputs(View lookup, std::vector<bool> &outputs, Budget &budget) {
    if (!lookup) return;
    auto collectRange = [&](size_t first, size_t end) {
        end = std::min(end, outputs.size());
        for (size_t glyph = first; glyph < end; ++glyph) {
            budget.step();
            auto replacement = aatLookup(lookup, Glyph(glyph));
            if (replacement && *replacement != glyph)
                addOutput(outputs, *replacement);
        }
    };
    const unsigned format = lookup.u16(0);
    if (format == 0) {
        collectRange(0, (lookup.size() - 2) / 2);
    } else if (format == 8 || format == 10) {
        const size_t at = format == 8 ? 2 : 4;
        const size_t first = lookup.u16(at);
        collectRange(first, first + lookup.u16(at + 2));
    } else if (format == 2 || format == 4 || format == 6) {
        const unsigned stride = lookup.u16(2), count = lookup.u16(4);
        lookup.array(12, count, stride);
        for (unsigned i = 0; i < count; ++i) {
            budget.step();
            const size_t at = 12 + size_t(i) * stride;
            const size_t last = lookup.u16(at);
            const size_t first = format == 6 ? last : lookup.u16(at + 2);
            collectRange(first, last + 1);
        }
    } else {
        throw InvalidTable("unknown Apple lookup format");
    }
}
} // namespace

class AATMachine {
  public:
    struct Entry {
        unsigned state, flags, first = 0xffff, second = 0xffff;
    };

  private:
    View data_;
    bool extended_;
    unsigned type_, classes_;
    size_t classOffset_, stateOffset_, entryOffset_;
    struct Cache {
        std::array<std::pair<unsigned, unsigned>, 256> glyphs{};
        std::array<std::pair<size_t, Entry>, 256> entries{};
    };
    mutable std::unique_ptr<Cache> cache_;
    // A zero page contains only the default class. Dense maps use one flat array.
    static constexpr size_t glyphsPerPage = 64;
    std::vector<uint16_t> glyphs_, pages_, rows_;
    size_t glyphCount_ = 0;
    std::vector<Entry> entries_;

  public:
    AATMachine(View data, bool extended, unsigned type)
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
    size_t compile(size_t glyphs) {
        if (classes_ > 65536 || entryOffset_ <= stateOffset_)
            return 0;
        size_t cells = (entryOffset_ - stateOffset_) / (extended_ ? 2 : 1);
        if (cells < classes_ || cells > 131072)
            return 0;
        glyphCount_ = glyphs;
        std::vector<uint16_t> flat;
        flat.reserve(glyphs);
        for (size_t i = 0; i < glyphs; ++i)
            flat.push_back(readGlyphClass(Glyph(i)));
        size_t pageCount = (glyphs + glyphsPerPage - 1) / glyphsPerPage;
        size_t stored = 0;
        pages_.resize(pageCount);
        for (size_t i = 0; i < pageCount; ++i) {
            auto first = flat.begin() + i * glyphsPerPage;
            auto last = flat.begin() + std::min(glyphs, (i + 1) * glyphsPerPage);
            if (std::any_of(first, last, [](unsigned c) { return c != 1; }))
                pages_[i] = ++stored;
        }
        if (pageCount + stored * glyphsPerPage < glyphs) {
            glyphs_.resize(stored * glyphsPerPage, 1);
            for (size_t i = 0; i < pageCount; ++i)
                if (pages_[i])
                    std::copy(flat.begin() + i * glyphsPerPage,
                              flat.begin() + std::min(glyphs, (i + 1) * glyphsPerPage),
                              glyphs_.begin() + (pages_[i] - 1) * glyphsPerPage);
        } else {
            std::vector<uint16_t>().swap(pages_);
            glyphs_ = std::move(flat);
        }
        rows_.reserve(cells);
        std::vector<bool> decoded;
        for (size_t i = 0; i < cells; ++i) {
            unsigned slot = readIndex(i);
            rows_.push_back(slot);
            if (decoded.size() <= slot) {
                decoded.resize(slot + 1);
                entries_.resize(slot + 1);
            }
            if (!decoded[slot]) {
                entries_[slot] = readEntryRecord(slot);
                decoded[slot] = true;
            }
        }
        return (glyphs_.capacity() + pages_.capacity() + rows_.capacity()) * sizeof(uint16_t) +
               entries_.capacity() * sizeof(Entry);
    }
    void cacheTransitions() { cache_ = std::make_unique<Cache>(); }
    unsigned glyphClass(Glyph glyph) const {
        if (glyph < glyphCount_) {
            if (pages_.empty()) return glyphs_[glyph];
            auto page = pages_[glyph / glyphsPerPage];
            return page ? glyphs_[(page - 1) * glyphsPerPage + glyph % glyphsPerPage] : 1;
        }
        if (!cache_) return readGlyphClass(glyph);
        auto &slot = cache_->glyphs[glyph % cache_->glyphs.size()];
        if (slot.first != unsigned(glyph) + 1)
            slot = {unsigned(glyph) + 1, readGlyphClass(glyph)};
        return slot.second;
    }
    unsigned readGlyphClass(Glyph glyph) const {
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
    bool hasCompiledState(unsigned state) const {
        return state < rows_.size() / classes_;
    }
    Entry entry(unsigned state, unsigned cls) const {
        size_t index = size_t(state) * classes_ + cls;
        if (index < rows_.size()) return entries_[rows_[index]];
        if (!cache_) return readEntry(index);
        auto &slot = cache_->entries[index % cache_->entries.size()];
        if (slot.first != index + 1)
            slot = {index + 1, readEntry(index)};
        return slot.second;
    }
    unsigned readIndex(size_t index) const {
        size_t at = stateOffset_ + index * (extended_ ? 2 : 1);
        return extended_ ? data_.u16(at) : data_.u8(at);
    }
    Entry readEntry(size_t index) const { return readEntryRecord(readIndex(index)); }
    Entry readEntryRecord(unsigned ei) const {
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
        int64_t at = 2 * (int64_t(int16_t(index)) + int64_t(glyph));
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

    void collectOutputs(std::vector<bool> &outputs, Budget &budget) const {
        const unsigned offsets = type_ == 2 ? 7 : (type_ == 5 && !extended_ ? 4 : 5);
        auto sectionEnd = [&](size_t start) {
            size_t end = data_.size();
            for (unsigned field = 1; field < offsets; ++field) {
                const size_t offset = word(field);
                if (offset > start) end = std::min(end, offset);
            }
            data_.require(start, end - start);
            return end;
        };
        if (type_ == 2) {
            // The ligature list is the font's declared output catalogue.
            // Bound it by the next section, since the offsets can be unordered.
            const size_t start = word(6), end = sectionEnd(start);
            if (!start) return;
            for (size_t at = start; at + 2 <= end; at += 2) {
                budget.step();
                addOutput(outputs, data_.u16(at));
            }
            return;
        }

        const size_t stateCount = (sectionEnd(stateOffset_) - stateOffset_) /
                                  (size_t(classes_) * (extended_ ? 2 : 1));
        if (!stateCount)
            throw InvalidTable("empty AAT feature state table");
        const size_t entryCount = (sectionEnd(entryOffset_) - entryOffset_) / 8;
        std::set<unsigned> states, entries, contextualIndices;
        std::vector<unsigned> pending{0};
        if (stateCount > 1) pending.push_back(1);
        for (size_t i = 0; i < pending.size(); ++i) {
            unsigned state = pending[i];
            if (state >= stateCount || !states.insert(state).second) continue;
            for (unsigned cls = 0; cls < classes_; ++cls) {
                budget.step();
                const auto index = readIndex(size_t(state) * classes_ + cls);
                if (index >= entryCount || !entries.insert(index).second) continue;
                const auto e = readEntryRecord(index);
                pending.push_back(e.state);
                if (type_ == 1) {
                    contextualIndices.insert(e.first);
                    contextualIndices.insert(e.second);
                } else if (type_ == 5) {
                    for (Glyph g : insertion(e.first, (e.flags >> 5) & 31))
                        addOutput(outputs, g);
                    for (Glyph g : insertion(e.second, e.flags & 31))
                        addOutput(outputs, g);
                }
            }
        }
        for (unsigned index : contextualIndices) {
            if (extended_) {
                if (index == 0xffff) continue;
                const size_t start = word(4);
                View lookups = data_.slice(start, sectionEnd(start) - start);
                collectLookupOutputs(lookups.offset32(size_t(index) * 4), outputs, budget);
            } else if (index) {
                const size_t start = word(4), end = sectionEnd(start);
                for (size_t glyph = 0; glyph < outputs.size(); ++glyph) {
                    budget.step();
                    int64_t at = 2 * (int64_t(int16_t(index)) + int64_t(glyph));
                    if (at < int64_t(start) || uint64_t(at) + 2 > end) continue;
                    Glyph replacement = data_.u16(size_t(at));
                    if (replacement != glyph) addOutput(outputs, replacement);
                }
            }
        }
    }

};
namespace {
using Entry = AATMachine::Entry;
// Type 2 changes GIDs and source ranges within a stable set of glyph slots.
struct LigatureWindow {
    Buffer before;
    size_t first = 0, last = 0;
    void capture(const Buffer &buffer, size_t low, size_t high) {
        if (!before.empty()) {
            low = std::min(low, first);
            high = std::max(high, last - 1);
        }
        auto overlaps = [](Span a, Span b) {
            return a.start < b.end && b.start < a.end;
        };
        while (low > 0 && overlaps(buffer[low - 1].source, buffer[low].source))
            --low;
        while (high + 1 < buffer.size() && overlaps(buffer[high + 1].source, buffer[high].source))
            ++high;
        if (before.empty())
            before.assign(buffer.begin() + low, buffer.begin() + high + 1);
        else {
            before.insert(before.begin(), buffer.begin() + low, buffer.begin() + first);
            before.insert(before.end(), buffer.begin() + last, buffer.begin() + high + 1);
        }
        first = low;
        last = high + 1;
    }
};

bool orderedSources(const Buffer &buffer) {
    bool ascending = true, descending = true;
    for (size_t i = 0; i < buffer.size(); ++i) {
        Span b = buffer[i].source;
        if (b.empty()) return false;
        if (!i) continue;
        Span a = buffer[i - 1].source;
        ascending &= a.start <= b.start && a.end <= b.end;
        descending &= a.start >= b.start && a.end >= b.end;
    }
    return ascending || descending;
}

// Type 2 never changes a slot ahead of its cursor. Reuse the next active
// transition in that untouched suffix when a state only advances through it.
class LigatureSkips {
    const AATMachine &machine_;
    std::vector<unsigned> classes_;
    std::map<unsigned, std::vector<size_t>> next_;
    size_t available_ = 2 * 1024 * 1024;

  public:
    LigatureSkips(const AATMachine &machine, const Buffer &input, Budget &budget)
        : machine_(machine) {
        if (input.size() < 64 || input.size() > available_ / sizeof(unsigned) ||
            !machine.hasCompiledState(0))
            return;
        classes_.reserve(input.size());
        for (const auto &item : input) {
            budget.step();
            classes_.push_back(machine.glyphClass(item.glyph));
        }
        available_ -= classes_.capacity() * sizeof(unsigned);
    }
    size_t next(unsigned state, size_t cursor, Budget &budget) {
        if (classes_.empty() || cursor >= classes_.size() || !machine_.hasCompiledState(state))
            return cursor;
        auto found = next_.find(state);
        if (found == next_.end()) {
            if (classes_.size() > available_ / sizeof(size_t) || machine_.actionable(machine_.entry(state, 0)))
                return cursor;
            std::vector<size_t> positions(classes_.size());
            size_t active = positions.size();
            for (size_t i = positions.size(); i-- > 0;) {
                budget.step();
                Entry entry = machine_.entry(state, classes_[i]);
                if (entry.state != state || entry.flags)
                    active = i;
                positions[i] = active;
            }
            available_ -= positions.capacity() * sizeof(size_t);
            found = next_.emplace(state, std::move(positions)).first;
        }
        return found->second[cursor];
    }
};

struct LigatureFootprint {
    size_t first = SIZE_MAX, end = 0;
    void include(size_t low, size_t high) {
        first = std::min(first, low);
        end = std::max(end, high + 1);
    }
    void restore(const Buffer &input, Buffer &candidate) const {
        if (first < end)
            std::copy(input.begin() + first, input.begin() + end, candidate.begin() + first);
    }
};

class Runner {
    Buffer &buffer_;
    Trace *trace_;
    Budget ownedBudget_;
    Budget &budget_;
    uint64_t nextIdentity_ = 1;
    size_t mark_ = 0, first_ = 0, last_ = 0;
    bool marked_ = false;
    std::vector<size_t> stack_;
    LigatureWindow *window_ = nullptr;
    LigatureFootprint *footprint_ = nullptr;
    size_t locate(uint64_t identity) const {
        for (size_t i = 0; i < buffer_.size(); i++)
            if (buffer_[i].identity == identity)
                return i;
        return buffer_.size();
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
        Span span = buffer_[first_].source;
        for (size_t i = first_ + 1; i < last_; i++)
            span = unite(span, buffer_[i].source);
        for (size_t i = first_; i < last_; i++)
            buffer_[i].source = span;
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
    void contextual(const AATMachine &machine, const Entry &entry, size_t cursor) {
        if (buffer_.empty() || (cursor == buffer_.size() && !marked_))
            return;
        if (marked_ && mark_ < buffer_.size())
            if (auto g = machine.contextual(entry.first, buffer_[mark_].glyph)) {
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
    void ligate(const AATMachine &machine, const Entry &entry, size_t cursor, bool extended) {
        if ((entry.flags & 0x8000) && cursor < buffer_.size()) {
            if (stack_.empty() || stack_.back() != cursor)
                stack_.push_back(cursor);
        }
        bool action = extended ? (entry.flags & 0x2000) : (entry.flags & 0x3fff);
        if (!action)
            return;
        size_t actionAt = extended ? entry.first : (entry.flags & 0x3fff);
        unsigned accumulated = 0;
        std::vector<size_t> pending;
        while (!stack_.empty()) {
            budget_.step();
            size_t pos = stack_.back();
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
                }
                if (window_)
                    window_->capture(buffer_, low, high);
                if (footprint_)
                    footprint_->include(low, high);
                for (size_t p : pending)
                    if (p != pos)
                        buffer_[p].glyph = 0xffff;
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
                pending = {pos};
            }
            if (value & 0x80000000) {
                stack_.push_back(pending.back());
                break;
            }
        }
    }
    size_t insert(const AATMachine &machine, unsigned index, unsigned count, size_t position,
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
    size_t insertion(const AATMachine &machine, const Entry &entry, size_t cursor) {
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
    Runner(Buffer &buffer, Trace *trace, Budget *budget = nullptr,
           const Cancellation *cancellation = nullptr)
        : buffer_(buffer), trace_(trace), ownedBudget_(buffer.size(), cancellation),
          budget_(budget ? *budget : ownedBudget_) {
        for (auto &item : buffer_) {
            if (!item.identity)
                item.identity = nextIdentity_++;
            else
                nextIdentity_ = std::max(nextIdentity_, item.identity + 1);
        }
    }
    void action(const AATMachine &machine, const Entry &entry, size_t &cursor, unsigned type,
                bool extended) {
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
    }
    // A prefix end is a transition of this parsed automaton, not a separate
    // text query. Snapshot only when EOT has an action; never cut an atomic seed.
    void terminal(const AATMachine &machine, unsigned state, size_t cursor, unsigned type,
                  bool extended, const std::string &label) {
        if (!cursor || cursor >= buffer_.size() ||
            buffer_[cursor - 1].source.end > buffer_[cursor].source.start)
            return;
        Entry ending = machine.entry(state, 0);
        if (!machine.actionable(ending))
            return;
        budget_.step();
        Buffer prefix(buffer_.begin(), buffer_.begin() + cursor), before = prefix;
        Runner trial(prefix, nullptr, &budget_);
        trial.mark_ = mark_;
        trial.first_ = first_;
        trial.last_ = last_;
        trial.marked_ = marked_;
        trial.stack_ = stack_;
        trial.nextIdentity_ = nextIdentity_;
        trial.action(machine, ending, cursor, type, extended);
        trace_->changed(before, prefix, label);
    }
    void runMachine(const AATMachine &machine, unsigned type, bool extended, size_t start = 0,
                    const std::string *label = nullptr, bool windowed = false,
                    LigatureSkips *skips = nullptr, std::vector<bool> *visitedRoots = nullptr,
                    LigatureFootprint *footprint = nullptr) {
        unsigned state = 0;
        size_t cursor = start;
        mark_ = first_ = last_ = start;
        footprint_ = footprint;
        marked_ = false;
        stack_.clear();
        while (cursor <= buffer_.size()) {
            budget_.step();
            bool end = cursor == buffer_.size();
            if (visitedRoots && !end && state == 0 && stack_.empty()) {
                // With an empty stack, no action can read the old prefix.
                // Source clusters must also be disjoint across the boundary.
                if (!cursor || buffer_[cursor - 1].source.end <= buffer_[cursor].source.start ||
                    buffer_[cursor].source.end <= buffer_[cursor - 1].source.start) {
                    if ((*visitedRoots)[cursor]) break;
                    (*visitedRoots)[cursor] = true;
                }
            }
            if (label && !end)
                terminal(machine, state, cursor, type, extended, *label);
            unsigned cls = end ? 0 : machine.glyphClass(buffer_[cursor].glyph);
            Entry entry = machine.entry(state, cls);
            if (!end && skips && entry.state == state && !entry.flags) {
                cursor = skips->next(state, cursor + 1, budget_);
                continue;
            }
            Buffer before = label && !windowed && machine.actionable(entry) ? buffer_ : Buffer{};
            LigatureWindow window;
            window_ = windowed ? &window : nullptr;
            action(machine, entry, cursor, type, extended);
            window_ = nullptr;
            if (!before.empty())
                trace_->changed(before, buffer_, *label);
            if (!window.before.empty()) {
                Buffer after(buffer_.begin() + window.first, buffer_.begin() + window.last);
                trace_->changed(window.before, after, *label);
            }
            state = entry.state;
            if (end)
                break;
            if (!(entry.flags & 0x4000))
                cursor++;
        }
    }
    void run(View data, unsigned type, bool extended, const AATMachine *compiled = nullptr) {
        if (type == 4) {
            for (auto &item : buffer_) {
                if (budget_.cancellation)
                    budget_.poll();
                if (auto value = aatLookup(data, item.glyph))
                    item.glyph = Glyph(*value);
            }
        } else if (compiled)
            runMachine(*compiled, type, extended);
        else {
            AATMachine machine(data, extended, type);
            runMachine(machine, type, extended);
        }
    }
    // Match the automaton from productive input origins. Other glyphs remain
    // in the buffer so a partial seed's surviving GIDs stay in its output.
    void discover(View data, unsigned type, bool extended, const std::string &label,
                  const AATMachine *compiled) {
        if (type == 4)
            return;
        std::optional<AATMachine> local;
        if (!compiled) {
            local.emplace(data, extended, type);
            if (buffer_.size() >= 64)
                local->cacheTransitions();
            compiled = &*local;
        }
        const AATMachine &machine = *compiled;
        bool windowed = type == 2 && !trace_->provenance && orderedSources(buffer_);
        std::optional<LigatureSkips> skips;
        if (type == 2) skips.emplace(machine, buffer_, budget_);
        std::vector<bool> visitedRoots(windowed ? buffer_.size() : 0);
        Buffer ligatureCandidate;
        std::optional<Runner> ligatureRunner;
        if (type == 2) {
            ligatureCandidate = buffer_;
            ligatureRunner.emplace(ligatureCandidate, trace_, &budget_);
        }
        for (size_t start = 0; start < buffer_.size(); start++) {
            budget_.step();
            Entry root = machine.entry(0, machine.glyphClass(buffer_[start].glyph));
            if ((!root.state && !machine.actionable(root) && !root.flags) ||
                (!visitedRoots.empty() && visitedRoots[start]))
                continue;
            if (ligatureRunner) {
                LigatureFootprint footprint;
                ligatureRunner->runMachine(machine, type, extended, start, &label, windowed,
                                           &*skips, visitedRoots.empty() ? nullptr : &visitedRoots,
                                           &footprint);
                footprint.restore(buffer_, ligatureCandidate);
            } else {
                Buffer candidate = buffer_;
                Runner(candidate, trace_, &budget_).runMachine(machine, type, extended, start, &label);
            }
        }
    }
};
} // namespace
void AAT::compileMachines(size_t glyphs) {
    // Bound both eager work and retained data for unusually large tables.
    size_t glyphReads = 2 * 1024 * 1024;
    size_t available = 4 * 1024 * 1024;
    if (!glyphs || glyphs > UINT16_MAX + size_t(1))
        return;
    for (auto &chain : chains_)
        for (auto &sub : chain.subtables) {
            if (sub.type == 4)
                continue;
            if (glyphs > glyphReads || !available)
                return;
            glyphReads -= glyphs;
            try {
                auto program = std::make_shared<AATMachine>(sub.data, extended_, sub.type);
                size_t bytes = program->compile(glyphs);
                if (bytes && bytes <= available) {
                    available -= bytes;
                    sub.program = std::move(program);
                }
            } catch (const InvalidTable &) {
                // Keep the checked byte reader for tables that cannot be compiled eagerly.
            }
        }
}
bool AAT::hasVerticalSubstitutions() const {
    for (const auto &chain : chains_) {
        for (const auto &feature : chain.features)
            if (feature.selector.type == 4)
                return true;
        for (const auto &sub : chain.subtables)
            if (!(sub.coverage & 0x20000000) && (sub.coverage & 0x80000000))
                return true;
    }
    return false;
}
std::vector<const AAT::Subtable *> AAT::schedule(
    std::optional<AATSelector> selector, bool vertical, bool verticalSubstitutionsOnly,
    const std::vector<AATSelector> &overrides) const {
    std::vector<const Subtable *> result;
    for (const auto &chain : chains_) {
        uint32_t flags = chain.defaults;
        for (const auto &feature : chain.features)
            if (selector && feature.selector == *selector)
                flags = feature.apply(flags);
        for (auto override : overrides)
            for (const auto &feature : chain.features)
                if (feature.selector == override)
                    flags = feature.apply(flags);
        for (const auto &sub : chain.subtables) {
            if (!(sub.flags & flags))
                continue;
            if (verticalSubstitutionsOnly) {
                bool directional = !(sub.coverage & 0x20000000) && (sub.coverage & 0x80000000);
                bool selected =
                    (sub.flags & flags & ~chain.defaults) && selector && selector->type == 4;
                if (!directional && !selected)
                    continue;
            }
            if (!(sub.coverage & 0x20000000) && bool(sub.coverage & 0x80000000) != vertical)
                continue;
            result.push_back(&sub);
        }
    }
    return result;
}

std::vector<AATSelector> AAT::outputSelectors() const {
    std::set<std::pair<unsigned, unsigned>> selected;
    for (const auto &chain : chains_) {
        uint32_t produces = 0;
        for (const auto &sub : chain.subtables)
            if (sub.type != 0)
                produces |= sub.flags;
        if (!produces) continue;
        std::map<std::pair<unsigned, unsigned>, uint32_t> masks;
        for (const auto &feature : chain.features) {
            if (!feature.selector.type) continue;
            auto &mask = masks[{feature.selector.type, feature.selector.setting}];
            mask = feature.apply(mask);
        }
        for (const auto &[selector, mask] : masks)
            if (mask & produces)
                selected.insert(selector);
    }
    std::vector<AATSelector> result;
    result.reserve(selected.size());
    for (auto [type, setting] : selected)
        result.push_back({type, setting});
    return result;
}

void AAT::collectFeatureOutputs(AATSelector selector, std::vector<bool> &outputs,
                                const Cancellation *cancellation) const {
    if (!selector.type) return;
    Budget budget(std::min<size_t>(outputs.size(), 1000), cancellation);
    for (const auto &chain : chains_) {
        checkCancellation(cancellation);
        uint32_t owned = 0;
        for (const auto &feature : chain.features)
            if (feature.selector == selector)
                owned = feature.apply(owned);
        if (!owned) continue;
        for (const auto &sub : chain.subtables) {
            if (sub.type == 0 || !(sub.flags & owned)) continue;
            checkCancellation(cancellation);
            if (sub.type == 4)
                collectLookupOutputs(sub.data, outputs, budget);
            else if (sub.program)
                sub.program->collectOutputs(outputs, budget);
            else
                AATMachine(sub.data, extended_, sub.type).collectOutputs(outputs, budget);
        }
    }
}

bool AAT::canIndexHorizontalSchedules() const {
    // Every selector scans the same chains, features and subtables. Bound the
    // total visits before allocating any keys, even if every schedule differs.
    constexpr size_t maxVisits = 512 * 1024;
    const size_t visitsPerSchedule = maxVisits / (selectors_.size() + 1);
    size_t visits = 1;
    for (const auto &chain : chains_) {
        visits += 1 + chain.features.size() + chain.subtables.size();
        if (visits > visitsPerSchedule)
            return false;
    }
    return true;
}

std::vector<size_t> AAT::horizontalSchedule(std::optional<AATSelector> selector) const {
    const auto subtables = schedule(selector, false, false, {});
    std::vector<size_t> result;
    result.reserve(subtables.size() + 1);
    result.push_back(size_t(selector && selector->type == 4));
    for (const auto *sub : subtables)
        result.push_back(sub->index);
    return result;
}
std::string AAT::featureLabel(std::optional<AATSelector> selector) const {
    auto label = name();
    if (selector)
        label += ":" + std::to_string(selector->type) + ":" + std::to_string(selector->setting);
    return label;
}

void AAT::substitute(Buffer &buffer, std::optional<AATSelector> selector, bool rtl, bool vertical,
                     Trace *trace, bool verticalSubstitutionsOnly,
                     const std::vector<AATSelector> &overrides,
                     const Cancellation *cancellation) const {
    checkCancellation(cancellation);
    const std::string label = featureLabel(selector);
    const Buffer original = trace && trace->inventory ? buffer : Buffer{};
    const auto originalClusters = clusters(original);
    const bool inventory = trace && trace->inventory;
    Budget discoveryBudget(buffer.size(), cancellation, inventory);
    // Inventory explores overlapping origins, unlike the deterministic run.
    // Leave room for those origins before reporting an incomplete inventory.
    if (inventory) discoveryBudget.remaining *= 2;
    std::set<std::tuple<Span, std::vector<Glyph>, std::string, std::vector<uint64_t>, bool>> recorded;
    for (const auto *selected : schedule(selector, vertical, verticalSubstitutionsOnly, overrides)) {
        checkCancellation(cancellation);
        const auto &sub = *selected;
        bool reverse =
            bool(sub.coverage & 0x40000000) ^ ((sub.coverage & 0x10000000) ? false : rtl);
        Buffer before = trace ? buffer : Buffer{};
        if (reverse)
            std::reverse(buffer.begin(), buffer.end());
        try {
            if (inventory && !trace->incomplete) {
                // Match this parsed rule against the supplied input and
                // preceding candidate outputs. A default ffi must not hide
                // the stylistic mappings of f, ff, or fi in later tables.
                size_t prior = trace->changes.size();
                auto append = [&](Change change) {
                    change.vertical |= (!(sub.coverage & 0x20000000) &&
                                        (sub.coverage & 0x80000000)) ||
                                       (selector && selector->type == 4);
                    if (recorded.emplace(change.source, change.glyphs, change.feature,
                                         change.inputKey(), change.vertical).second)
                        trace->changes.push_back(std::move(change));
                };
                auto mapped = [&](Span source, const std::vector<Glyph> &glyphs) {
                    auto output = glyphs;
                    for (auto &glyph : output) {
                        if (cancellation)
                            discoveryBudget.poll();
                        if (auto value = aatLookup(sub.data, glyph))
                            glyph = Glyph(*value);
                    }
                    if (output != glyphs)
                        append({source, std::move(output), label, {{source, glyphs}}});
                };
                auto explore = [&](Buffer candidate) {
                    Buffer input = candidate;
                    Trace found;
                    auto publish = [&] {
                        for (auto &change : found.changes) {
                            if (reverse) {
                                std::reverse(change.glyphs.begin(), change.glyphs.end());
                                for (auto &input : change.inputs)
                                    std::reverse(input.glyphs.begin(), input.glyphs.end());
                            }
                            append(std::move(change));
                        }
                    };
                    try {
                        Runner(candidate, &found, &discoveryBudget)
                            .discover(sub.data, sub.type, extended_, label, sub.program.get());
                        Runner(candidate, nullptr, &discoveryBudget)
                            .run(sub.data, sub.type, extended_, sub.program.get());
                        found.changed(input, candidate, label);
                    } catch (const DiscoveryLimit &) {
                        publish();
                        throw;
                    }
                    publish();
                };
                if (sub.type == 4) {
                    for (const auto &cluster : originalClusters)
                        mapped(cluster.source, cluster.glyphs);
                    for (auto cluster : clusters(buffer)) {
                        if (reverse)
                            std::reverse(cluster.glyphs.begin(), cluster.glyphs.end());
                        mapped(cluster.source, cluster.glyphs);
                    }
                } else
                    explore(buffer);
                Buffer input = original;
                if (reverse)
                    std::reverse(input.begin(), input.end());
                bool same = input.size() == buffer.size() &&
                            std::equal(input.begin(), input.end(), buffer.begin(),
                                       [](const Item &a, const Item &b) {
                                           return a.glyph == b.glyph && a.source == b.source;
                                       });
                if (!same && sub.type != 4)
                    explore(std::move(input));
                std::set<std::pair<Span, std::vector<Glyph>>> visited;
                for (size_t i = 0; i < prior; i++) {
                    if (cancellation)
                        discoveryBudget.poll();
                    const Change previous = trace->changes[i];
                    if (previous.glyphs.empty() ||
                        !visited.emplace(previous.source, previous.glyphs).second)
                        continue;
                    if (sub.type == 4) {
                        mapped(previous.source, previous.glyphs);
                        continue;
                    }
                    Buffer candidate;
                    for (Glyph glyph : previous.glyphs) {
                        Item item;
                        item.glyph = glyph;
                        item.source = previous.source;
                        candidate.push_back(item);
                    }
                    if (reverse)
                        std::reverse(candidate.begin(), candidate.end());
                    explore(std::move(candidate));
                }
            }
        } catch (const DiscoveryLimit &) {
            trace->incomplete = true;
        } catch (const InvalidTable &error) {
            throw InvalidTable(name() + " type " + std::to_string(sub.type) + ": " + error.what());
        }
        try {
            Budget executionBudget(buffer.size(), cancellation, inventory);
            Runner(buffer, trace, &executionBudget).run(sub.data, sub.type, extended_, sub.program.get());
        } catch (const DiscoveryLimit &) {
            trace->incomplete = true;
            if (reverse) std::reverse(buffer.begin(), buffer.end());
            return;
        } catch (const InvalidTable &error) {
            throw InvalidTable(name() + " type " + std::to_string(sub.type) + ": " +
                               error.what());
        }
        if (reverse)
            std::reverse(buffer.begin(), buffer.end());
        if (trace)
            trace->changed(before, buffer, label);
    }
    buffer.erase(std::remove_if(buffer.begin(), buffer.end(),
                                [](const Item &i) { return i.glyph == 0xffff; }),
                 buffer.end());
}
} // namespace ga::layout
