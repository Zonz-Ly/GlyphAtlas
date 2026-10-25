#pragma once
#import <Foundation/Foundation.h>
#import "GAGlyphSelection.h"
#include "GACmap.h"
#include "GAOpenType.h"
namespace ga::layout {
struct TextRun {
    Buffer glyphs;
    Span source;
    Tag script = 0;
    uint8_t level = 0;
};
std::vector<TextRun> prepareText(NSString *text, const Cmap &cmap,
                                 NSArray<GAGlyphSelectionRun *> *selections = nil);
Tag scriptTag(NSString *script);
Tag languageTag(NSString *language);
std::vector<size_t> visualRunOrder(const std::vector<TextRun> &runs);
} // namespace ga::layout
