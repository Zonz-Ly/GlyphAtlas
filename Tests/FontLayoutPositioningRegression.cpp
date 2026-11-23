#include "GAOpenType.h"
#include "FontLayoutPositioningFixtures.h"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace ga::layout;
using Bytes = std::vector<uint8_t>;

static void word(Bytes &b, unsigned n) { b.push_back(uint8_t(n >> 8)); b.push_back(uint8_t(n)); }
static Bytes words(std::initializer_list<unsigned> v) { Bytes b; for (auto n : v) word(b,n); return b; }
static void put16(Bytes &b, size_t at, unsigned n) { b.at(at)=uint8_t(n >> 8); b.at(at+1)=uint8_t(n); }
static void put32(Bytes &b, size_t at, uint32_t n) { put16(b,at,n >> 16); put16(b,at+2,n); }
static size_t append(Bytes &b, const Bytes &v) { size_t at=b.size(); b.insert(b.end(),v.begin(),v.end()); return at; }
static Buffer items(const std::vector<Glyph> &glyphs) {
    Buffer b;
    for (auto g : glyphs) {
        Item i; i.glyph=g; i.identity=b.size()+1;
        i.source={uint32_t(b.size()),uint32_t(b.size()+1)}; b.push_back(i);
    }
    return b;
}
static Metrics metrics() {
    Metrics m;
    m.horizontalAdvance=[](Glyph g) { return g==1 || g==2 ? 600.0 : 0.0; };
    m.verticalAdvance=[](Glyph) { return 1000.0; };
    return m;
}
static Bytes lookup(unsigned type, const Bytes &sub) {
    Bytes b=words({type,0,1,8}); append(b,sub); return b;
}
static Bytes positioningTable(const std::vector<Bytes> &lookups) {
    Bytes b=words({1,0,10,0,0});
    append(b,words({1,0x6c61,0x746e,8,4,0,0,0xffff,1,0}));
    put16(b,6,b.size()); append(b,words({1,0x6d61,0x726b,8,0,unsigned(lookups.size())}));
    for (unsigned i=0;i<lookups.size();++i) word(b,i);
    size_t list=b.size(); put16(b,8,list);
    word(b,lookups.size()); b.resize(b.size()+2*lookups.size());
    for (unsigned i=0;i<lookups.size();++i) put16(b,list+2+2*i,append(b,lookups[i])-list);
    return b;
}
static Bytes markLookup(unsigned type, Glyph mark, Glyph target, const std::vector<unsigned> &heights) {
    Bytes b(12); put16(b,0,1); put16(b,6,1);
    put16(b,2,append(b,words({1,1,mark})));
    put16(b,4,append(b,words({1,1,target})));
    put16(b,8,append(b,words({1,0,6,1,0,0})));
    size_t array=b.size(); put16(b,10,array);
    if (type==5) {
        append(b,words({1,4}));
        size_t lig=b.size(); word(b,heights.size()); b.resize(b.size()+2*heights.size());
        for (unsigned i=0;i<heights.size();++i)
            put16(b,lig+2+2*i,append(b,words({1,0,heights[i]}))-lig);
    } else
        append(b,words({1,4,1,0,heights.front()}));
    return lookup(type,b);
}
static void checkMarkFilters() {
    for (auto test : reviewCases()) {
        if (test.name=="mkmk_filtering_set") {
            size_t at=View(test.gpos).offset16(8).offset16(2).tableOffset();
            put16(test.gpos,at+2,0x110); // Both filters: filtering set wins.
            put16(test.gdef,10,test.gdef.size());
            append(test.gdef,words({1,2,3,0,1,0})); // Attachment type alone excludes A/C.
            OpenType ot{View(test.gpos),true}; Buffer b=items(test.glyphs);
            ot.position(b,GDEF{View(test.gdef)},Settings{},metrics());
            assert(b.back().yOffset==500);
        }
        if (test.name=="mkmk_base_barrier") {
            size_t at=View(test.gpos).offset16(8).offset16(2).tableOffset();
            put16(test.gpos,at+2,4); // IgnoreLigatures cannot cross a ligature boundary.
            size_t classes=View(test.gdef).offset16(4).tableOffset();
            put16(test.gdef,classes+6,2);
            OpenType ot{View(test.gpos),true}; Buffer b=items(test.glyphs);
            ot.position(b,GDEF{View(test.gdef)},Settings{},metrics());
            assert(b.back().yOffset==0);
        }
    }
    // Type 5 retains its independent component selection and anchor lookup.
    GDEF gdef; gdef.glyphClasses=ClassDef(View(words({1,1,4,0,2,0,3})));
    OpenType lig{View(positioningTable({markLookup(5,4,2,{500,900})})),true};
    for (int component : {-1,0,1,9}) {
        Buffer b=items({2,4}); b.back().component=component;
        lig.position(b,gdef,Settings{},metrics());
        assert(b.back().yOffset==(component==0 ? 500 : 900));
    }
    std::cout << "Mark filters, boundaries and type 5 controls PASS\n";
}
static Bytes singlePosition(Glyph glyph, int x, int y) {
    return lookup(1,words({1,10,3,unsigned(x),unsigned(y),1,1,glyph}));
}
static Bytes pairPosition(bool placement) {
    Bytes sub=words({1,0,placement ? 0u : 4u,placement ? 3u : 0u,1,0});
    put16(sub,2,append(sub,words({1,1,1})));
    put16(sub,10,sub.size());
    append(sub,placement ? words({1,4,10,40}) : words({1,4,unsigned(-50)}));
    return lookup(2,sub);
}
static void checkPlacementOrder() {
    GDEF gdef; gdef.glyphClasses=ClassDef(View(words({1,1,4,1,3,3,3})));
    auto run=[&](const std::vector<Bytes> &lookups) {
        OpenType ot{View(positioningTable(lookups)),true}; Buffer b=items({1,4});
        ot.position(b,gdef,Settings{},metrics()); return b;
    };
    Bytes mark=markLookup(4,4,1,{500}), shift=singlePosition(4,10,40);
    auto after=run({mark,shift});
    assert(after[1].xOffset==-590 && after[1].yOffset==540);
    auto before=run({shift,mark});
    assert(before[1].xOffset==-600 && before[1].yOffset==500);
    auto multiple=run({mark,shift,singlePosition(4,-3,5)});
    assert(multiple[1].xOffset==-593 && multiple[1].yOffset==545);
    auto replaced=run({mark,shift,markLookup(4,4,1,{700}),singlePosition(4,0,20)});
    assert(replaced[1].xOffset==-600 && replaced[1].yOffset==720);
    auto pairAfter=run({mark,pairPosition(true)});
    assert(pairAfter[1].xOffset==-590 && pairAfter[1].yOffset==540);
    auto pairBefore=run({pairPosition(true),mark});
    assert(pairBefore[1].xOffset==-600 && pairBefore[1].yOffset==500);
    auto advance=run({mark,pairPosition(false)});
    assert(advance[0].xAdvance==550 && advance[1].xOffset==-550 && advance[1].yOffset==500);
    {
        GDEF ligdef; ligdef.glyphClasses=ClassDef(View(words({1,1,4,0,2,0,3})));
        OpenType ot{View(positioningTable({markLookup(5,4,2,{500,900}),shift})),true};
        Buffer b=items({2,4}); ot.position(b,ligdef,Settings{},metrics());
        assert(b[1].xOffset==-590 && b[1].yOffset==940);
    }
    {
        OpenType ot{View(positioningTable({markLookup(4,2,1,{500}),markLookup(6,4,2,{100}),
                    singlePosition(2,0,20),singlePosition(4,0,30)})),true};
        Buffer b=items({1,2,4}); ot.position(b,gdef,Settings{},metrics());
        assert(b[1].yOffset==520 && b[2].yOffset==650);
    }
    std::cout << "Placement order, replacement, pair, ligature and parent-chain controls PASS\n";
}
static Bytes variationTable(bool positioning, bool universalFirst) {
    Bytes b(14); put32(b,0,0x10001); put16(b,4,14);
    append(b,words({1,0x6c61,0x746e,8,4,0,0,0xffff,1,0}));
    put16(b,6,b.size());
    append(b,positioning ? words({1,0x6d61,0x726b,8,0,1,0})
                         : words({1,0x6c69,0x6761,8,0,1,0}));
    size_t list=b.size(); put16(b,8,list); append(b,words({2,6,28}));
    for (unsigned value : {positioning ? 40u : 10u, positioning ? 80u : 20u}) {
        append(b,words({1,0,1,8}));
        append(b,positioning ? words({1,8,2,value}) : words({2,8,1,value}));
        append(b,words({1,1,4}));
    }
    size_t fv=b.size(); put32(b,10,fv); b.resize(fv+24);
    put32(b,fv,0x10000); put32(b,fv+4,2);
    if (!universalFirst) {
        put32(b,fv+8,b.size()-fv);
        append(b,words({1,0,6,1,0,0xe000,0x2000})); // axis 0, [-0.5,0.5]
    }
    // First substitution is NULL. The second record is an unconditional +80
    // (GPOS) or GID 20 (GSUB), so dropping/skipping the first record is visible.
    put32(b,fv+20,b.size()-fv);
    append(b,words({1,0,1,0,0,12,0,1,1}));
    return b;
}
static void checkVariations() {
    for (bool positioning : {false,true}) for (bool universal : {false,true}) {
        Bytes bytes=variationTable(positioning,universal);
        OpenType ot{View(bytes),positioning};
        assert(ot.branchCount()==3);
        assert(ot.features(0).front().lookups==ot.features(1).front().lookups);
        assert((ot.features(2).front().lookups==std::vector<unsigned>{1}));
        for (double coordinate : {0.0,1.0}) {
            size_t branch=ot.variationBranch({coordinate});
            assert(branch==(universal || coordinate==0 ? 1u : 2u));
            Buffer b=items({4});
            if (positioning) {
                ot.position(b,GDEF{},Settings{},metrics(),branch);
                assert(b[0].yOffset==(branch==1 ? 40 : 80));
            } else {
                ot.substitute(b,GDEF{},Settings{},branch);
                assert(b[0].glyph==(branch==1 ? 10 : 20));
            }
        }
        // A nonzero offset that points to EOF is malformed, not a NULL record.
        uint32_t fv=View(bytes).u32(10);
        put32(bytes,fv+12,bytes.size()-fv);
        bool rejected=false;
        try { OpenType bad{View(bytes),positioning}; }
        catch (const InvalidTable &) { rejected=true; }
        assert(rejected);
        std::cout << "FV " << positioning << '/' << universal << " PASS\n";
    }
}
int main() {
    unsigned failures=0;
    // Add confirmed regressions with each separately committed correction.
    const std::set<std::string> covered={"null_feature_substitution", "mkmk_direct",
        "mkmk_base_barrier", "single_then_attachment", "mkmk_uncovered_adjacent",
        "mkmk_filtering_set", "mkmk_attachment_type", "attachment_then_single"};
    for (const auto &test : reviewCases()) {
        if (!covered.count(test.name)) continue;
        std::cout << test.name << ": ";
        bool good=false;
        try {
            OpenType ot{View(test.gpos),true};
            Buffer b=items(test.glyphs);
            Settings settings; settings.script=tag('l','a','t','n');
            bool kern=ot.position(b,GDEF{View(test.gdef)},settings,metrics(),ot.variationBranch({0}));
            good=!b.empty() && b.back().yOffset==test.y;
            if (test.kern>=0) good=good && kern==bool(test.kern) && b.front().xAdvance==550;
            std::cout << "y=" << b.back().yOffset;
        } catch (const std::exception &e) { std::cout << e.what(); }
        std::cout << (good ? " PASS\n" : " FAIL\n"); failures+=!good;
    }
    try { checkVariations(); }
    catch (const std::exception &e) { std::cout << "FV ERROR: " << e.what() << '\n'; ++failures; }
    checkMarkFilters();
    checkPlacementOrder();
    return failures ? 1 : 0;
}
