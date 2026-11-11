#import "GAGlyphLabels.h"
#include "GABinary.h"
#include "GAGlyphNameTables.h"
#include <iterator>
#include <numeric>
#include <optional>
#include <string_view>

namespace {
using ga::layout::InvalidTable;
using Bytes = std::string_view;

Bytes bytes(NSData *data) {
    return data.length ? Bytes(static_cast<const char *>(data.bytes), data.length) : Bytes{};
}

Bytes slice(Bytes data, size_t offset, size_t length) {
    if (offset > data.size() || length > data.size() - offset)
        throw InvalidTable("glyph label data outside font table");
    return data.substr(offset, length);
}

uint32_t readUInt(Bytes data, size_t offset, unsigned width) {
    uint32_t value = 0;
    for (unsigned char byte : slice(data, offset, width))
        value = (value << 8) | byte;
    return value;
}

NSString *nameFromBytes(Bytes name) {
    if (name.empty())
        return @"";
    return [[NSString alloc] initWithBytes:name.data()
                                    length:name.size()
                                  encoding:NSASCIIStringEncoding] ?: @"";
}

NSArray<NSString *> *readPostNames(Bytes post, size_t count) {
    if (post.size() < 32)
        return nil;
    const size_t standardCount = std::size(GAMacintoshGlyphNames);
    const uint32_t version = readUInt(post, 0, 4);
    if (version == 0x00010000)
        return count == standardCount
            ? [NSArray arrayWithObjects:GAMacintoshGlyphNames count:standardCount] : nil;

    const bool offsets = version == 0x00025000 || version == 0x00028000;
    if (version != 0x00020000 && !offsets)
        return nil;
    if (readUInt(post, 32, 2) != count)
        return nil;
    const Bytes indices = slice(post, 34, count * (offsets ? 1 : 2));
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    if (offsets) {
        for (size_t gid = 0; gid < count; ++gid) {
            const int index = int(gid) + int8_t(indices[gid]);
            [names addObject:index >= 0 && size_t(index) < standardCount
                ? GAMacintoshGlyphNames[index] : @""];
        }
        return [names copy];
    }

    size_t customCount = 0;
    for (size_t gid = 0; gid < count; ++gid) {
        const size_t index = readUInt(indices, gid * 2, 2);
        if (index >= standardCount)
            customCount = std::max(customCount, index - standardCount + 1);
    }
    NSMutableArray<NSString *> *custom = [NSMutableArray array];
    Bytes remaining = post.substr(34 + indices.size());
    while (custom.count < customCount && !remaining.empty()) {
        const size_t length = uint8_t(remaining.front());
        if (length >= remaining.size())
            break;
        [custom addObject:nameFromBytes(remaining.substr(1, length))];
        remaining.remove_prefix(1 + length);
    }
    for (size_t gid = 0; gid < count; ++gid) {
        const size_t index = readUInt(indices, gid * 2, 2);
        NSString *name = @"";
        if (index < standardCount) {
            // For nonzero GIDs, index 0 is the documented unassigned name.
            if (index != 0 || gid == 0)
                name = GAMacintoshGlyphNames[index];
        } else if (index - standardCount < custom.count) {
            name = custom[index - standardCount];
        }
        [names addObject:name];
    }
    return [names copy];
}

struct CFFIndex {
    size_t count;
    size_t next;
    Bytes offsets;
    Bytes data;
    unsigned width = 0;

    CFFIndex(Bytes table, size_t start) : count(readUInt(table, start, 2)), next(start + 2) {
        if (!count)
            return;
        width = readUInt(table, next++, 1);
        if (width < 1 || width > 4)
            throw InvalidTable("invalid CFF INDEX offset size");
        offsets = slice(table, next, (count + 1) * width);
        next += offsets.size();
        const size_t last = readUInt(offsets, count * width, width);
        if (readUInt(offsets, 0, width) != 1 || last < 1)
            throw InvalidTable("invalid CFF INDEX bounds");
        data = slice(table, next, last - 1);
        next += data.size();
    }

    Bytes entry(size_t index) const {
        if (index >= count)
            throw InvalidTable("CFF INDEX entry missing");
        const size_t first = readUInt(offsets, index * width, width);
        const size_t last = readUInt(offsets, (index + 1) * width, width);
        if (first < 1 || last < first)
            throw InvalidTable("invalid CFF INDEX entry");
        return slice(data, first - 1, last - first);
    }
};

struct CFFDict {
    size_t charset = 0; // ISOAdobe when omitted.
    size_t charStrings = 0;
    bool cidKeyed = false;
};

std::optional<int32_t> readDictOperand(uint8_t code, Bytes &dict) {
    auto take = [&](unsigned width) {
        const auto value = readUInt(dict, 0, width);
        dict.remove_prefix(width);
        return value;
    };
    if (code >= 32 && code <= 246)
        return int(code) - 139;
    if (code >= 247 && code <= 250)
        return (int(code) - 247) * 256 + int(take(1)) + 108;
    if (code >= 251 && code <= 254)
        return -(int(code) - 251) * 256 - int(take(1)) - 108;
    if (code == 28)
        return int16_t(take(2));
    if (code == 29)
        return int32_t(take(4));
    if (code == 30) {
        // Skip a real operand by its terminating nibble.
        while (true) {
            const auto value = take(1);
            if ((value & 0xf) == 0xf || (value >> 4) == 0xf)
                return std::nullopt;
        }
    }
    throw InvalidTable("unknown CFF DICT operand");
}

CFFDict readTopDict(Bytes dict) {
    CFFDict result;
    unsigned operands = 0;
    std::optional<int32_t> first;
    while (!dict.empty()) {
        const auto code = uint8_t(dict.front());
        dict.remove_prefix(1);
        if (code > 21) {
            const auto value = readDictOperand(code, dict);
            if (operands == 0)
                first = value;
            if (++operands > 48)
                throw InvalidTable("too many CFF DICT operands");
            continue;
        }
        if (code == 15 || code == 17) { // charset / CharStrings offsets
            if (operands != 1 || !first || *first < 0)
                throw InvalidTable("invalid CFF DICT offset");
            if (code == 15)
                result.charset = size_t(*first);
            else
                result.charStrings = size_t(*first);
        } else if (code == 12) {
            const auto escaped = readUInt(dict, 0, 1);
            dict.remove_prefix(1);
            if (escaped == 30) { // ROS
                if (operands != 3)
                    throw InvalidTable("invalid CFF ROS");
                result.cidKeyed = true;
            }
        }
        operands = 0;
        first.reset();
    }
    if (operands || result.charStrings == 0)
        throw InvalidTable("incomplete CFF Top DICT");
    return result;
}

std::vector<uint16_t> readCharset(Bytes cff, const CFFDict &dict, size_t count) {
    if (dict.charset < 3) {
        if (dict.cidKeyed)
            throw InvalidTable("CID-keyed CFF cannot use a predefined charset");
        if (dict.charset == 0 && count <= 229) {
            std::vector<uint16_t> sids(count);
            std::iota(sids.begin(), sids.end(), 0);
            return sids;
        }
        if (dict.charset == 1 && count <= std::size(GACFFExpertCharset))
            return {GACFFExpertCharset, GACFFExpertCharset + count};
        if (dict.charset == 2 && count <= std::size(GACFFExpertSubsetCharset))
            return {GACFFExpertSubsetCharset, GACFFExpertSubsetCharset + count};
        throw InvalidTable("CFF predefined charset is shorter than the glyph count");
    }
    size_t offset = dict.charset;
    const auto format = readUInt(cff, offset++, 1);
    std::vector<uint16_t> values(count); // GID 0 has implicit SID or CID 0.
    if (format == 0) {
        const Bytes entries = slice(cff, offset, (count - 1) * 2);
        for (size_t gid = 1; gid < count; ++gid)
            values[gid] = readUInt(entries, (gid - 1) * 2, 2);
    } else if (format == 1 || format == 2) {
        for (size_t gid = 1; gid < count;) {
            const auto first = readUInt(cff, offset, 2);
            const auto left = readUInt(cff, offset + 2, format);
            if (left >= count - gid || first + left > UINT16_MAX)
                throw InvalidTable("CFF charset range exceeds glyph count or ID space");
            offset += 2 + format;
            for (uint32_t value = first; value <= first + left; ++value)
                values[gid++] = uint16_t(value);
        }
    } else {
        throw InvalidTable("unknown CFF charset format");
    }
    return values;
}

NSArray<NSString *> *readCFFLabels(Bytes cff, size_t count, std::vector<uint16_t> &cids) {
    const auto headerSize = readUInt(cff, 2, 1);
    if (readUInt(cff, 0, 1) != 1 || headerSize < 4)
        return nil;
    const CFFIndex fontNames(cff, headerSize);
    const CFFIndex dicts(cff, fontNames.next);
    if (fontNames.count != 1 || dicts.count != 1)
        return nil;
    const auto dict = readTopDict(dicts.entry(0));
    if (readUInt(cff, dict.charStrings, 2) != count)
        return nil;
    auto charset = readCharset(cff, dict, count);
    if (dict.cidKeyed) {
        cids = std::move(charset);
        return nil;
    }
    const CFFIndex strings(cff, dicts.next);
    const size_t standardCount = std::size(GACFFStandardStrings);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (const size_t sid : charset) {
        NSString *name = @"";
        if (sid < standardCount)
            name = GACFFStandardStrings[sid];
        else if (sid - standardCount < strings.count)
            name = nameFromBytes(strings.entry(sid - standardCount));
        [names addObject:name];
    }
    return [names copy];
}
}

@implementation GAGlyphLabels {
    NSArray<NSString *> *_names;
    std::vector<uint16_t> _cids;
}

+ (instancetype)labelsForFont:(CTFontRef)font {
    const CFIndex count = CTFontGetGlyphCount(font);
    if (count <= 0 || count > UINT16_MAX)
        return nil;
    NSArray<NSString *> *names = nil;
    std::vector<uint16_t> cids;
    try {
        // The borrowed bytes live through the parser. Keep only decoded labels.
        NSData *cff __attribute__((objc_precise_lifetime)) =
            CFBridgingRelease(CTFontCopyTable(font, kCTFontTableCFF, 0));
        if (cff.length) {
            names = readCFFLabels(bytes(cff), size_t(count), cids);
        } else {
            NSData *post __attribute__((objc_precise_lifetime)) =
                CFBridgingRelease(CTFontCopyTable(font, kCTFontTablePost, 0));
            names = readPostNames(bytes(post), size_t(count));
        }
    } catch (const InvalidTable &) {
        return nil;
    }
    if (!names.count && cids.empty())
        return nil;
    GAGlyphLabels *labels = [self new];
    labels->_names = names;
    labels->_cids = std::move(cids);
    return labels;
}

- (NSString *)labelForGlyph:(NSUInteger)glyph {
    if (glyph < _cids.size())
        return [NSString stringWithFormat:@"CID %u", unsigned(_cids[glyph])];
    NSString *name = glyph < _names.count ? _names[glyph] : nil;
    return name.length ? name : nil;
}

@end
