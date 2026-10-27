#pragma once
#import <Foundation/Foundation.h>
#include "GAGlyphBuffer.h"

@class GAGlyphSelectionRun;

namespace ga::layout {
class Cmap;
struct TextRun {
    Buffer glyphs;
    Span source;
    Tag script = 0;
    uint8_t level = 0;
};
std::vector<TextRun> prepareText(NSString *text, const Cmap &cmap,
                                 NSArray<GAGlyphSelectionRun *> *selections = nil);
} // namespace ga::layout
