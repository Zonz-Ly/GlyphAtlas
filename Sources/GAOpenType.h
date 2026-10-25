#import "GAGlyphBuffer.h"
typedef NS_ENUM(NSUInteger, GAPredicateKind) {
    GAPredicateExact,
    GAPredicateCoverage,
    GAPredicateClass
};
@interface GAOTPredicate : NSObject
@property(nonatomic) GAPredicateKind kind;
@property(nonatomic) unsigned value;
@property(nonatomic, strong) GACoverage *coverage;
@property(nonatomic, strong) GAClassDef *classes;
+ (instancetype)exact:(GAGlyph)glyph;
+ (instancetype)covered:(GATableView *)view;
+ (instancetype)classified:(GATableView *)view value:(unsigned)value;
- (BOOL)matches:(GAGlyph)glyph;
@end
@interface GAOTAction : NSObject
@property(nonatomic) unsigned sequence, lookup;
@end
@interface GAOTPattern : NSObject
@property(nonatomic, strong) GACoverage *firstCoverage;
@property(nonatomic, strong) NSMutableArray<GAOTPredicate *> *backtrack, *input, *lookahead;
@property(nonatomic, copy) NSArray<GAOTAction *> *actions;
@property(nonatomic, copy) NSArray<NSNumber *> *replacement;
@end
@interface GAOTSubtable : NSObject
@property(nonatomic) unsigned type;
@property(nonatomic, strong) GATableView *data;
@property(nonatomic, strong) GACoverage *coverage;
@property(nonatomic, copy) NSArray<GAOTPattern *> *patterns;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *starts,
    *alternateInputs;
@end
@interface GAOTLookup : NSObject
@property(nonatomic) unsigned flags, markSet, alternateCount;
@property(nonatomic) BOOL reverse;
@property(nonatomic, copy) NSArray<GAOTSubtable *> *subtables;
@property(nonatomic, strong) NSMutableIndexSet *references;
@end
@interface GAOTFeature : NSObject <NSCopying>
@property(nonatomic) GATag name;
@property(nonatomic, copy) NSArray<NSNumber *> *lookups;
@property(nonatomic) unsigned maximum;
@end
@interface GAOTLanguage : NSObject
@property(nonatomic) GATag name;
@property(nonatomic) unsigned required;
@property(nonatomic, copy) NSArray<NSNumber *> *features;
@end
@interface GAOTScript : NSObject
@property(nonatomic) GATag name;
@property(nonatomic, copy) NSArray<GAOTLanguage *> *languages;
@end
@interface GALayoutSettings : NSObject
@property(nonatomic) GATag script, language;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *features;
@property(nonatomic) BOOL vertical, rtl;
@end
@interface GARelatedSubstitution : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *glyphs;
@property(nonatomic) GATag feature;
@property(nonatomic) unsigned value;
@property(nonatomic) BOOL directFamily;
@end
@interface GAOTLookupStep : NSObject
@property(nonatomic) unsigned lookup, value;
@property(nonatomic) GATag feature;
@property(nonatomic) BOOL explicitValue;
@end
@interface GAOpenType : NSObject
@property(nonatomic, readonly) NSArray<GAOTLookup *> *lookups;
@property(nonatomic, readonly) NSArray<GAOTScript *> *scripts;
@property(nonatomic, readonly) NSUInteger branchCount;
@property(nonatomic, readonly) BOOL positioning;
- (instancetype)initWithView:(GATableView *)table positioning:(BOOL)positioning;
- (NSArray<GAOTFeature *> *)features:(NSUInteger)branch;
- (NSUInteger)variationBranch:(NSArray<NSNumber *> *)normalized;
- (NSArray<NSNumber *> *)languages:(GATag)script;
- (NSArray<GAOTLookupStep *> *)plan:(GALayoutSettings *)settings branch:(NSUInteger)branch;
@end
@interface GAOpenType (Candidates)
- (NSArray<GARelatedSubstitution *> *)relatedSubstitutions:(GAGlyph)glyph gdef:(GAGDEF *)gdef;
@end
@interface GAOpenType (Substitution)
- (void)substituteBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                    gdef:(GAGDEF *)gdef
                settings:(GALayoutSettings *)settings
                  branch:(NSUInteger)branch
                   trace:(GALayoutTrace *)trace;
- (void)substituteLookups:(NSMutableArray<GALayoutItem *> *)buffer
                     gdef:(GAGDEF *)gdef
                    steps:(NSArray<GAOTLookupStep *> *)steps
                    trace:(GALayoutTrace *)trace;
@end
@interface GAOpenType (Positioning)
- (void)positionBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                  gdef:(GAGDEF *)gdef
              settings:(GALayoutSettings *)settings
               metrics:(GALayoutMetrics *)metrics
                branch:(NSUInteger)branch;
@end
/// nil means no match; the returned indices refer to the unmodified buffer.
FOUNDATION_EXPORT NSArray<NSNumber *> *
GAMatchPattern(GAOTPattern *pattern, NSArray<GALayoutItem *> *buffer, NSUInteger start,
               GAGDEF *gdef, unsigned flags, unsigned markSet, GASpan *scope);
FOUNDATION_EXPORT NSArray<NSNumber *> *GASubstitutionOutputs(GAOTSubtable *subtable, GAGlyph glyph);
