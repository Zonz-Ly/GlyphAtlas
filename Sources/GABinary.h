#import <Foundation/Foundation.h>

typedef uint16_t GAGlyph;
typedef uint32_t GATag;
NS_INLINE GATag GATagMake(char a, char b, char c, char d) {
    return ((uint32_t)(uint8_t)a << 24) | ((uint32_t)(uint8_t)b << 16) |
           ((uint32_t)(uint8_t)c << 8) | (uint8_t)d;
}
FOUNDATION_EXPORT GATag GATagFromString(NSString *text);
FOUNDATION_EXPORT NSString *GATagName(GATag tag);
FOUNDATION_EXPORT void GAInvalidTable(NSString *message) __attribute__((noreturn));

/// Immutable, bounded view retaining its table owner. Zero offsets are empty
/// views.
@interface GATableView : NSObject
@property(nonatomic, readonly) NSUInteger length;
@property(nonatomic, readonly) BOOL present;
+ (instancetype)data:(NSData *)data;
- (void)require:(NSUInteger)offset count:(NSUInteger)count;
- (void)array:(NSUInteger)offset count:(NSUInteger)count stride:(NSUInteger)stride;
- (uint8_t)u8:(NSUInteger)offset;
- (uint16_t)u16:(NSUInteger)offset;
- (int16_t)s16:(NSUInteger)offset;
- (uint32_t)u24:(NSUInteger)offset;
- (uint32_t)u32:(NSUInteger)offset;
- (int32_t)s32:(NSUInteger)offset;
- (double)fixed:(NSUInteger)offset;
- (double)f2dot14:(NSUInteger)offset;
- (GATableView *)at:(NSUInteger)offset;
- (GATableView *)slice:(NSUInteger)offset length:(NSUInteger)length;
- (GATableView *)offset16:(NSUInteger)field;
- (GATableView *)offset32:(NSUInteger)field;
@end

@interface GACoverage : NSObject
- (instancetype)initWithView:(GATableView *)view;
@property(nonatomic, readonly) BOOL present;
- (NSInteger)index:(GAGlyph)glyph;
- (BOOL)contains:(GAGlyph)glyph;
- (NSArray<NSNumber *> *)glyphs;
@end
@interface GAClassDef : NSObject
- (instancetype)initWithView:(GATableView *)view;
- (unsigned)value:(GAGlyph)glyph;
@end
