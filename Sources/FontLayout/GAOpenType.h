#pragma once
#include "GAGlyphBuffer.h"
#include <optional>
#include <unordered_map>

namespace ga::layout {
struct Predicate {
    enum class Kind { Exact, Coverage, Class };
    Kind kind = Kind::Exact;
    unsigned value = 0;
    Coverage coverage;
    ClassDef classes;
    static Predicate exact(Glyph value);
    static Predicate covered(View table);
    static Predicate classified(View table, unsigned value);
    bool matches(Glyph glyph) const;
};
struct LookupRecord {
    unsigned sequence = 0, lookup = 0;
};
struct Pattern {
    Coverage firstCoverage;
    std::vector<Predicate> backtrack, input, lookahead;
    std::vector<LookupRecord> actions;
    std::vector<Glyph> replacement;
};
struct Subtable {
    unsigned type = 0;
    View data;
    Coverage coverage;
    std::vector<Pattern> patterns;
    std::unordered_map<Glyph, std::vector<unsigned>> starts;
    std::unordered_map<Glyph, std::vector<Glyph>> alternateInputs;
};
struct Lookup : LookupFlags {
    std::vector<Subtable> subtables;
    std::set<unsigned> references;
    unsigned alternateCount = 1;
    bool reverse = false;
};
struct Feature {
    Tag name = 0;
    std::vector<unsigned> lookups;
    unsigned maximum = 1;
};
struct Language {
    Tag name = 0;
    std::vector<unsigned> features;
    unsigned required = 0xffff;
};
struct Script {
    Tag name = 0;
    std::vector<Language> languages;
};
struct Settings {
    Tag script = tag('D', 'F', 'L', 'T'), language = 0;
    std::map<Tag, unsigned> features;
    bool vertical = false, rtl = false;
};
struct RelatedSubstitution {
    std::vector<Glyph> glyphs;
    Tag feature = 0;
    unsigned value = 1;
    // Direct single/alternate outputs, including reverse alternate siblings.
    bool directFamily = false;
};
struct LookupStep {
    unsigned lookup = 0, value = 1;
    Tag feature = 0;
    bool explicitValue = false;
};
class OpenType {
    bool positioning_ = false;
    View data_;
    std::vector<Lookup> lookups_;
    std::vector<std::vector<Feature>> branches_;
    std::vector<Script> scripts_;

  public:
    explicit OpenType(View table = {}, bool positioning = false);
    const std::vector<Lookup> &lookups() const {
        return lookups_;
    }
    const std::vector<Feature> &features(size_t branch = 0) const;
    const std::vector<Script> &scripts() const {
        return scripts_;
    }
    size_t branchCount() const {
        return branches_.size();
    }
    size_t variationBranch(const std::vector<double> &normalized) const;
    std::vector<Tag> languages(Tag script) const;
    std::vector<LookupStep> plan(const Settings &settings, size_t branch = 0) const;
    std::vector<RelatedSubstitution> relatedSubstitutions(Glyph seed, const GDEF &gdef) const;
    void substitute(Buffer &buffer, const GDEF &gdef, const Settings &settings, size_t branch,
                    Trace *trace = nullptr) const;
    void substituteLookups(Buffer &buffer, const GDEF &gdef, const std::vector<LookupStep> &steps,
                           Trace *trace = nullptr) const;
    void position(Buffer &buffer, const GDEF &gdef, const Settings &settings,
                  const Metrics &metrics, size_t branch = 0) const;
};
// Shared context matching for substitution and positioning lookup formats.
std::optional<std::vector<size_t>> match(const Pattern &pattern, const Buffer &buffer, size_t start,
                                         const GDEF &gdef, LookupFlags flags,
                                         Span *scope = nullptr);
std::vector<Glyph> substitutionOutputs(const Subtable &subtable, Glyph glyph);
std::vector<Pattern> readContexts(View subtable, unsigned type);
} // namespace ga::layout
