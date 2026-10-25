#import "GATextQueryModel.h"

@implementation GATextQueryModel {
    GAFontDocument *_document;
    GAGlyphQueryIdentity *_identity;
    GARawScanResult *_result;
}
- (instancetype)initWithFontDocument:(GAFontDocument *)document {
    self = [super init];
    if (self) {
        _document = document;
        _text = @"";
        _groups = @[];
    }
    return self;
}
- (void)projectResult {
    NSArray *groups = GAGroupsForText(_text);
    [_document applyRawResult:_result
                 contentRange:NSMakeRange(0, _text.length)
              startGroupIndex:0
                       groups:groups];
    _groups = groups;
}
- (BOOL)analyzeText:(NSString *)text
         selections:(NSArray<GAGlyphSelectionRun *> *)selections
          cancelled:(BOOL (^)(void))cancelled {
    if (cancelled && cancelled())
        return NO;
    GAGlyphQueryIdentity *identity = GAGlyphQueryKey(text, selections);
    if ([_identity isEqual:identity])
        return YES;
    GARawScanResult *result = [_document rawScanContent:text selections:selections];
    if (cancelled && cancelled())
        return NO;
    _text = [text copy];
    _identity = identity;
    _result = result;
    if (text.length)
        _queryCount++;
    [self projectResult];
    return YES;
}
- (void)updateFontDocument:(GAFontDocument *)document {
    _document = document;
    if (_result) {
        _result = [document rebindResult:_result content:_text];
        [self projectResult];
    }
}
@end
