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
struct CursiveAnchor { Glyph glyph; int entryX, entryY, exitX, exitY; };
static Bytes cursivePosition(unsigned flags, const std::vector<CursiveAnchor> &anchors) {
    Bytes sub(6+4*anchors.size()); put16(sub,0,1); put16(sub,4,anchors.size());
    Bytes coverage=words({1,unsigned(anchors.size())});
    for (auto a:anchors) word(coverage,a.glyph);
    put16(sub,2,append(sub,coverage));
    for (size_t i=0;i<anchors.size();++i) {
        const auto &a=anchors[i];
        put16(sub,6+4*i,append(sub,words({1,unsigned(a.entryX),unsigned(a.entryY)})));
        put16(sub,8+4*i,append(sub,words({1,unsigned(a.exitX),unsigned(a.exitY)})));
    }
    Bytes result=lookup(3,sub); put16(result,2,flags); return result;
}
static void checkCursiveChains() {
    const std::vector<CursiveAnchor> c1={{1,0,0,500,100},{2,10,20,450,80},{3,20,40,400,60}};
    const std::vector<CursiveAnchor> c2={{1,0,0,500,200},{2,10,30,450,160},{3,20,50,400,100}};
    struct Test { std::vector<unsigned> flags; std::vector<double> y; };
    for (const auto &t:std::vector<Test>{{{0},{0,80,120}},{{1},{-120,-40,0}},
            {{0,0},{0,170,280}},{{1,1},{-280,-110,0}},
            {{0,1},{-280,-110,0}},{{1,0},{0,170,280}}}) {
        std::vector<Bytes> lookups;
        for (size_t i=0;i<t.flags.size();++i) lookups.push_back(cursivePosition(t.flags[i],i ? c2:c1));
        OpenType ot{View(positioningTable(lookups)),true};
        Buffer b=items({1,2,3}); Metrics m=metrics(); m.horizontalAdvance=[](Glyph){ return 600.0; };
        ot.position(b,GDEF{},Settings{},m);
        for (size_t i=0;i<b.size();++i) assert(b[i].yOffset==t.y[i]);
        assert(b[0].xAdvance==500 && b[1].xAdvance==440 && b[2].xAdvance==580);
        assert(b[0].xOffset==0 && b[1].xOffset==-10 && b[2].xOffset==-20);
    }
    // Reattach only B/C, retaining the old A/B connection in either direction.
    for (unsigned first:{0u,1u}) {
        std::vector<CursiveAnchor> bc(c2.begin()+1,c2.end());
        OpenType ot{View(positioningTable({cursivePosition(first,c1),cursivePosition(1-first,bc)})),true};
        Buffer b=items({1,2,3}); ot.position(b,GDEF{},Settings{},metrics());
        if (first==0) assert(b[0].yOffset==-190 && b[1].yOffset==-110 && b[2].yOffset==0);
        else assert(b[0].yOffset==-80 && b[1].yOffset==0 && b[2].yOffset==110);
    }
    std::cout << "Cursive chain direction, major-axis and partial reattachment controls PASS\n";
}
static void checkCursivePlacement() {
    const std::vector<CursiveAnchor> c={{1,0,0,500,100},{2,10,20,450,80}};
    for (bool vertical:{false,true}) for (unsigned flags:{0u,1u}) {
        auto anchors=c;
        if (vertical) for (auto &a:anchors) { std::swap(a.entryX,a.entryY); std::swap(a.exitX,a.exitY); }
        Glyph child=flags ? 1:2, parent=flags ? 2:1;
        Bytes cursive=cursivePosition(flags,anchors);
        auto run=[&](std::vector<Bytes> lookups) {
            OpenType ot{View(positioningTable(lookups)),true}; Buffer b=items({1,2});
            Settings settings; settings.vertical=vertical;
            ot.position(b,GDEF{},settings,metrics()); return b;
        };
        auto shift=[&](Glyph glyph) { return singlePosition(glyph,vertical ? 40:0,vertical ? 0:40); };
        auto minor=[&](const Item &i) { return vertical ? i.xOffset:i.yOffset; };
        double delta=flags ? -80:80;
        auto before=run({shift(child),cursive}), after=run({cursive,shift(child)});
        assert(minor(before[child-1])==delta && minor(after[child-1])==delta+40);
        auto parentBefore=run({shift(parent),cursive}), parentAfter=run({cursive,shift(parent)});
        assert(minor(parentBefore[child-1])==delta+40 && minor(parentAfter[child-1])==delta+40);
        auto repeat=run({cursive,shift(child),cursive});
        assert(minor(repeat[child-1])==delta);
        // The major axis keeps the original arithmetic rather than clearing both offsets.
        auto major=run({singlePosition(child,vertical ? 0:27,vertical ? 27:0),cursive});
        assert(minor(major[child-1])==delta);
        if (!vertical && !flags) assert(major[1].xOffset==-10 && major[1].xAdvance==563);
    }
    const std::vector<CursiveAnchor> full={{1,0,0,500,100},{2,10,20,450,80},{3,20,40,400,60}};
    const std::vector<CursiveAnchor> bc={{2,10,30,450,160},{3,20,50,400,100}};
    OpenType ot{View(positioningTable({cursivePosition(0,full),singlePosition(2,0,40),cursivePosition(1,bc)})),true};
    Buffer b=items({1,2,3}); ot.position(b,GDEF{},Settings{},metrics());
    assert(b[0].yOffset==-230 && b[1].yOffset==-110 && b[2].yOffset==0);
    std::cout << "Cursive placement order, parent, reattachment and both axes PASS\n";
}
static void checkMarkComponentBoundaries() {
    GDEF gdef; gdef.glyphClasses=ClassDef(View(words({1,1,4,1,2,3,3})));
    OpenType ot{View(positioningTable({markLookup(5,3,2,{500,900}),markLookup(5,4,2,{500,900}),
                                      markLookup(6,4,3,{200})})),true};
    struct Test { int first,second; uint64_t a,b; double y; };
    for (auto t:std::vector<Test>{{0,0,1,1,700},{0,1,1,1,900},{1,1,1,1,1100},
                                  {0,0,1,2,500},{-1,-1,0,0,1100}}) {
        Buffer b=items({2,3,4}); b[1].component=t.first; b[2].component=t.second;
        b[1].ligatureIdentity=t.a; b[2].ligatureIdentity=t.b;
        ot.position(b,gdef,Settings{},metrics()); assert(b[2].yOffset==t.y);
    }
    std::cout << "Mark component/ligature boundaries and unknown fallback PASS\n";
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
static void checkKernOwnership() {
    ReviewCase shared;
    for (const auto &test : reviewCases()) if (test.name=="shared_kern_owner") shared=test;
    const Tag kern=tag('k','e','r','n'), dist=tag('d','i','s','t');
    auto check=[&](const Bytes &bytes, const Settings &settings, bool owns, Tag label, bool explicitValue) {
        OpenType ot{View(bytes),true};
        auto plan=ot.plan(settings);
        assert(plan.size()==1 && plan.front().lookup==0 && plan.front().feature==label &&
               plan.front().explicitValue==explicitValue);
        Buffer b=items(shared.glyphs);
        GDEF gdef{View(shared.gdef)};
        assert(ot.position(b,gdef,settings,metrics())==owns && b.front().xAdvance==550);
        if (!owns) {
            Kerning legacy{View(words({0,1,0,20,1,1,6,0,0,1,2,unsigned(-50)}))};
            legacy.position(b,settings,gdef);
        }
        bool disabled=settings.features.count(kern) && !settings.features.at(kern);
        assert(b.front().xAdvance==(owns || disabled ? 550 : 500));
    };
    Settings normal;
    check(shared.gpos,normal,true,dist,false);
    Settings off; off.features[kern]=0;
    check(shared.gpos,off,false,dist,false);
    Settings onlyKern; onlyKern.features[dist]=0;
    check(shared.gpos,onlyKern,true,kern,false);
    Settings both; both.features[dist]=1; both.features[kern]=1;
    check(shared.gpos,both,true,kern,true);

    size_t lang=View(shared.gpos).offset16(4).offset16(6).offset16(0).tableOffset();
    Bytes reverse=shared.gpos;
    put16(reverse,lang+6,1); put16(reverse,lang+8,0);
    check(reverse,both,true,dist,true); // Keep the original winning label.
    Bytes noKern=shared.gpos; put16(noKern,lang+4,1);
    check(noKern,normal,false,dist,false); // This language only enables dist.

    Bytes varied=shared.gpos;
    for (size_t field : {4u,6u,8u}) put16(varied,field,View(shared.gpos).u16(field)+4);
    varied.insert(varied.begin()+10,4,0); put32(varied,0,0x10001);
    size_t fv=varied.size(); put32(varied,10,fv);
    append(varied,words({1,0,0,1,0,0,0,16,1,0,1,1,0,12,0,0})); // kern becomes empty.
    OpenType variation{View(varied),true};
    assert(variation.branchCount()==2 && variation.variationBranch({0})==1);
    for (size_t branch : {0u,1u}) {
        Buffer b=items(shared.glyphs);
        assert(variation.position(b,GDEF{View(shared.gdef)},normal,metrics(),branch)==(branch==0));
        assert(b.front().xAdvance==550);
    }
    Bytes invalid=shared.gpos;
    View features=View(invalid).offset16(6);
    size_t feature=features.offset16(6).tableOffset(); // Shared dist/kern feature table.
    put16(invalid,feature+4,0xffff);
    OpenType empty{View(invalid),true}; Buffer b=items(shared.glyphs);
    assert(empty.plan(normal).empty());
    assert(!empty.position(b,GDEF{View(shared.gdef)},normal,metrics()) && b.front().xAdvance==600);

    Bytes truncated=shared.gpos; truncated.pop_back();
    OpenType bad{View(truncated),true}; b=items(shared.glyphs);
    bool returned=false, rejected=false;
    try { returned=bad.position(b,GDEF{View(shared.gdef)},normal,metrics()); }
    catch (const InvalidTable &) { rejected=true; }
    assert(rejected && !returned);
    std::cout << "Kern ownership, labels, disable, language, FV and failure controls PASS\n";
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
    for (const auto &test : reviewCases()) {
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
    checkCursiveChains();
    checkCursivePlacement();
    checkMarkComponentBoundaries();
    checkPlacementOrder();
    checkKernOwnership();
    return failures ? 1 : 0;
}
