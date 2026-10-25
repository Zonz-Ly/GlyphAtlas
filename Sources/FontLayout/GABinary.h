#pragma once
#include <algorithm>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace ga::layout {
using Glyph = uint16_t;
using Tag = uint32_t;
constexpr Tag tag(char a, char b, char c, char d) {
    return (uint32_t(uint8_t(a)) << 24) | (uint32_t(uint8_t(b)) << 16) |
           (uint32_t(uint8_t(c)) << 8) | uint8_t(d);
}
inline Tag tag(const std::string &text) {
    return text.size() == 4 ? tag(text[0], text[1], text[2], text[3]) : 0;
}
inline std::string tagName(Tag value) {
    return {char(value >> 24), char(value >> 16), char(value >> 8), char(value)};
}

class InvalidTable final : public std::runtime_error {
  public:
    explicit InvalidTable(const std::string &message) : std::runtime_error(message) {}
};

// A relative, immutable table view. Every offset stays inside this view's owner;
// arithmetic is checked before indexing. A zero relative offset is explicitly null.
class View {
    std::shared_ptr<const std::vector<uint8_t>> owner_;
    size_t begin_ = 0, length_ = 0;

  public:
    View() = default;
    explicit View(std::vector<uint8_t> bytes)
        : owner_(std::make_shared<const std::vector<uint8_t>>(std::move(bytes))),
          length_(owner_->size()) {}
    size_t size() const {
        return length_;
    }
    explicit operator bool() const {
        return length_ != 0;
    }
    bool contains(size_t at, size_t count = 1) const {
        return at <= length_ && count <= length_ - at;
    }
    void require(size_t at, size_t count) const {
        if (!contains(at, count))
            throw InvalidTable("offset " + std::to_string(at) + " + " + std::to_string(count) +
                               " outside table size " + std::to_string(length_));
    }
    uint8_t u8(size_t at) const {
        require(at, 1);
        return (*owner_)[begin_ + at];
    }
    uint16_t u16(size_t at) const {
        require(at, 2);
        return uint16_t((u8(at) << 8) | u8(at + 1));
    }
    int16_t s16(size_t at) const {
        return int16_t(u16(at));
    }
    uint32_t u24(size_t at) const {
        require(at, 3);
        return (uint32_t(u16(at)) << 8) | u8(at + 2);
    }
    uint32_t u32(size_t at) const {
        require(at, 4);
        return (uint32_t(u16(at)) << 16) | u16(at + 2);
    }
    int32_t s32(size_t at) const {
        return int32_t(u32(at));
    }
    double fixed(size_t at) const {
        return s32(at) / 65536.0;
    }
    double f2dot14(size_t at) const {
        return s16(at) / 16384.0;
    }
    View at(size_t offset) const {
        require(offset, 0);
        View v = *this;
        v.begin_ += offset;
        v.length_ -= offset;
        return v;
    }
    View slice(size_t offset, size_t count) const {
        require(offset, count);
        View v = at(offset);
        v.length_ = count;
        return v;
    }
    View offset16(size_t field) const {
        auto n = u16(field);
        return n ? at(n) : View{};
    }
    View offset32(size_t field) const {
        auto n = u32(field);
        return n ? at(n) : View{};
    }
    void array(size_t at, size_t count, size_t stride) const {
        if (!stride || at > length_ || count > (length_ - at) / stride)
            throw InvalidTable("array outside font table");
    }
};

class Coverage {
    View data_;

  public:
    Coverage() = default;
    explicit Coverage(View data) : data_(data) {
        if (!data_)
            return;
        auto format = data_.u16(0), count = data_.u16(2);
        if (format != 1 && format != 2)
            throw InvalidTable("unknown coverage format");
        data_.array(4, count, format == 1 ? 2 : 6);
        unsigned previous = 0, index = 0;
        for (unsigned i = 0; i < count; i++) {
            size_t p = 4 + size_t(i) * (format == 1 ? 2 : 6);
            unsigned first = data_.u16(p), last = format == 1 ? first : data_.u16(p + 2);
            if (first > last || (i && first <= previous))
                throw InvalidTable("unordered coverage ranges");
            if (format == 2 && data_.u16(p + 4) != index)
                throw InvalidTable("noncontiguous coverage indices");
            previous = last;
            index += last - first + 1;
        }
    }
    explicit operator bool() const {
        return bool(data_);
    }
    int index(Glyph glyph) const {
        if (!data_)
            return -1;
        size_t lo = 0, hi = data_.u16(2);
        auto format = data_.u16(0);
        while (lo < hi) {
            size_t mid = (lo + hi) / 2;
            size_t p = 4 + mid * (format == 1 ? 2 : 6);
            unsigned first = data_.u16(p), last = format == 1 ? first : data_.u16(p + 2);
            if (glyph < first)
                hi = mid;
            else if (glyph > last)
                lo = mid + 1;
            else
                return format == 1 ? int(mid) : data_.u16(p + 4) + glyph - first;
        }
        return -1;
    }
    bool contains(Glyph glyph) const {
        return index(glyph) >= 0;
    }
    std::vector<Glyph> glyphs() const {
        std::vector<Glyph> result;
        if (!data_)
            return result;
        for (unsigned i = 0, n = data_.u16(2); i < n; i++) {
            if (data_.u16(0) == 1)
                result.push_back(data_.u16(4 + i * 2));
            else {
                size_t p = 4 + i * 6;
                unsigned first = data_.u16(p), last = data_.u16(p + 2);
                if (first > last)
                    throw InvalidTable("reversed coverage range");
                for (unsigned g = first; g <= last; g++)
                    result.push_back(Glyph(g));
            }
        }
        return result;
    }
};
class ClassDef {
    View data_;

  public:
    ClassDef() = default;
    explicit ClassDef(View data) : data_(data) {
        if (!data_)
            return;
        if (data_.u16(0) == 1)
            data_.array(6, data_.u16(4), 2);
        else if (data_.u16(0) == 2) {
            unsigned count = data_.u16(2);
            data_.array(4, count, 6);
            unsigned previous = 0;
            for (unsigned i = 0; i < count; i++) {
                size_t p = 4 + size_t(i) * 6;
                unsigned first = data_.u16(p), last = data_.u16(p + 2);
                if (first > last || (i && first <= previous))
                    throw InvalidTable("unordered class ranges");
                previous = last;
            }
        } else
            throw InvalidTable("unknown class definition format");
    }
    unsigned get(Glyph glyph) const {
        if (!data_)
            return 0;
        if (data_.u16(0) == 1) {
            unsigned first = data_.u16(2), count = data_.u16(4);
            return glyph >= first && glyph - first < count ? data_.u16(6 + (glyph - first) * 2) : 0;
        }
        size_t lo = 0, hi = data_.u16(2);
        while (lo < hi) {
            size_t m = (lo + hi) / 2, p = 4 + m * 6;
            if (glyph < data_.u16(p))
                hi = m;
            else if (glyph > data_.u16(p + 2))
                lo = m + 1;
            else
                return data_.u16(p + 4);
        }
        return 0;
    }
};
} // namespace ga::layout
