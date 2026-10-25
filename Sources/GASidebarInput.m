#import "GASidebarInput.h"
#import "GAGlyphSelection.h"

/// YES when the shortcut modifiers in `modifiers` are exactly `expected`.
/// Caps Lock, the function key, the numeric keypad, Help, and device-dependent
/// bits do not count.
BOOL GAModifiersAre(NSEventModifierFlags modifiers,
                    NSEventModifierFlags expected) {
  NSEventModifierFlags mask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift |
      NSEventModifierFlagOption | NSEventModifierFlagControl;
  return (modifiers & mask) == expected;
}

#pragma mark - Line-break marker

/// The input field keeps a line break as U+23CE RETURN SYMBOL carrying this
/// attribute. A literal U+23CE typed by the user has no attribute and stays a
/// normal character. The model text handed to the window uses U+000A instead;
/// the conversion is one UTF-16 unit for one, so ranges never move.
NSString *const GALineBreakAttributeName = @"com.zonz.GlyphAtlas.lineBreak";
static NSString *const GALineBreakCharacter = @"\u23CE";

/// Marks one visible line-break character and gives it the secondary text
/// colour used by AppKit for auxiliary inline content.
static void GASetLineBreakMarker(NSMutableAttributedString *text,
                                 NSRange range) {
  [text addAttribute:GALineBreakAttributeName value:@YES range:range];
  [text addAttribute:NSForegroundColorAttributeName
               value:[NSColor secondaryLabelColor]
               range:range];
}

/// Replaces line breaks with markers and attaches the line-break attribute.
static NSAttributedString *GAMarkerTextFromString(NSString *string,
                                                  NSDictionary *attributes) {
  NSMutableString *converted =
      [NSMutableString stringWithCapacity:string.length];
  NSMutableIndexSet *markers = [NSMutableIndexSet indexSet];
  for (NSUInteger index = 0; index < string.length; index++) {
    unichar character = [string characterAtIndex:index];
    if (character == '\r') {
      if (index + 1 < string.length &&
          [string characterAtIndex:index + 1] == '\n') {
        index++;
      }
      [markers addIndex:converted.length];
      [converted appendString:GALineBreakCharacter];
    } else if (character == '\n') {
      [markers addIndex:converted.length];
      [converted appendString:GALineBreakCharacter];
    } else {
      [converted
          appendString:[string substringWithRange:NSMakeRange(index, 1)]];
    }
  }
  NSMutableAttributedString *text =
      [[NSMutableAttributedString alloc] initWithString:converted
                                             attributes:attributes];
  [markers enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
    (void)stop;
    GASetLineBreakMarker(text, NSMakeRange(index, 1));
  }];
  return text;
}

/// Replaces the marker attribute with real line breaks for the model text.
NSAttributedString *GAModelTextFromFieldText(NSAttributedString *fieldText) {
  if (fieldText.length == 0) {
    return [[NSAttributedString alloc] init];
  }
  NSRange all = NSMakeRange(0, fieldText.length);
  NSMutableArray<NSValue *> *markerRanges = [NSMutableArray array];
  [fieldText
      enumerateAttribute:GALineBreakAttributeName
                 inRange:all
                 options:0
              usingBlock:^(id value, NSRange range, BOOL *stop) {
                (void)stop;
                if (value != nil) {
                  [markerRanges addObject:[NSValue valueWithRange:range]];
                }
              }];
  NSMutableString *string = [fieldText.string mutableCopy];
  for (NSValue *value in markerRanges) {
    NSRange range = value.rangeValue;
    for (NSUInteger index = range.location; index < NSMaxRange(range);
         index++) {
      [string replaceCharactersInRange:NSMakeRange(index, 1) withString:@"\n"];
    }
  }
  NSMutableAttributedString *model =
      [[NSMutableAttributedString alloc] initWithString:string];
  [fieldText
      enumerateAttributesInRange:all
                         options:0
                      usingBlock:^(
                          NSDictionary<NSAttributedStringKey, id> *attrs,
                          NSRange range, BOOL *stop) {
                        (void)stop;
                        NSMutableDictionary *clean = [attrs mutableCopy];
                        [clean removeObjectForKey:GALineBreakAttributeName];
                        [model setAttributes:clean range:range];
                      }];
  return model;
}

/// Replaces model line breaks with the visible marked character for the field.
NSAttributedString *GAFieldTextFromModelText(NSAttributedString *modelText) {
  if (modelText.length == 0) {
    return [[NSAttributedString alloc] init];
  }
  NSRange all = NSMakeRange(0, modelText.length);
  NSMutableString *string = [modelText.string mutableCopy];
  NSMutableIndexSet *markers = [NSMutableIndexSet indexSet];
  for (NSUInteger index = 0; index < string.length; index++) {
    if ([string characterAtIndex:index] == '\n') {
      [string replaceCharactersInRange:NSMakeRange(index, 1)
                            withString:GALineBreakCharacter];
      [markers addIndex:index];
    }
  }
  NSMutableAttributedString *field =
      [[NSMutableAttributedString alloc] initWithString:string];
  [modelText
      enumerateAttributesInRange:all
                         options:0
                      usingBlock:^(
                          NSDictionary<NSAttributedStringKey, id> *attrs,
                          NSRange range, BOOL *stop) {
                        (void)stop;
                        NSMutableDictionary *clean = [attrs mutableCopy];
                        [clean removeObjectForKey:GALineBreakAttributeName];
                        [field setAttributes:clean range:range];
                      }];
  [markers enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
    (void)stop;
    GASetLineBreakMarker(field, NSMakeRange(index, 1));
  }];
  return field;
}

/// Converts newlines before the single-line field editor can turn them into
/// spaces. A newline is inserted as a marked U+23CE, so the field stays one
/// line tall and the character can be told apart from a literal U+23CE.
@implementation GASearchFieldEditor

/// AppKit's single-line field editor does not map all four Command-arrow
/// variants to the document start/end (Command-Down is a no-op). Handle them
/// explicitly so the whole field behaves as one document.
- (void)keyDown:(NSEvent *)event {
  BOOL commandOnly =
      GAModifiersAre(event.modifierFlags, NSEventModifierFlagCommand);
  if (commandOnly) {
    if (event.keyCode == 123 || event.keyCode == 126) { // Left, Up
      [self moveToBeginningOfDocument:nil];
      return;
    }
    if (event.keyCode == 124 || event.keyCode == 125) { // Right, Down
      [self moveToEndOfDocument:nil];
      return;
    }
  }
  [super keyDown:event];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *inserted = nil;
  if ([string isKindOfClass:[NSAttributedString class]]) {
    inserted = [(NSAttributedString *)string string];
  } else if ([string isKindOfClass:[NSString class]]) {
    inserted = string;
  }
  if (inserted.length == 0) {
    [super insertText:string replacementRange:replacementRange];
    return;
  }
  if ([inserted rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]]
          .location == NSNotFound) {
    [super insertText:string replacementRange:replacementRange];
    return;
  }
  NSRange range = replacementRange;
  if (range.location == NSNotFound) {
    range = self.selectedRange;
  }
  NSMutableDictionary *attributes = [self.typingAttributes mutableCopy];
  [attributes removeObjectForKey:GALineBreakAttributeName];
  NSAttributedString *text = GAMarkerTextFromString(inserted, attributes);
  if ([self shouldChangeTextInRange:range replacementString:text.string]) {
    [self.textStorage replaceCharactersInRange:range withAttributedString:text];
    [self didChangeText];
    [self setSelectedRange:NSMakeRange(range.location + text.length, 0)];
    self.typingAttributes = attributes;
  }
}

- (void)paste:(id)sender {
  NSString *string =
      [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  if (string != nil &&
      [string rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]]
              .location != NSNotFound) {
    [self insertText:string replacementRange:self.selectedRange];
    return;
  }
  [super paste:sender];
}

/// Copy the selection as plain text, turning marked line breaks back into
/// U+000A. A literal U+23CE has no marker attribute and is copied as is.
- (void)copy:(id)sender {
  NSRange range = self.selectedRange;
  if (range.length == 0) {
    [super copy:sender];
    return;
  }
  NSAttributedString *selected =
      [self.textStorage attributedSubstringFromRange:range];
  NSString *model = GAModelTextFromFieldText(selected).string;
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setString:model forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender {
  NSRange range = self.selectedRange;
  if (range.length == 0) {
    [super cut:sender];
    return;
  }
  [self copy:sender];
  if ([self shouldChangeTextInRange:range replacementString:@""]) {
    [self.textStorage replaceCharactersInRange:range withString:@""];
    [self didChangeText];
    [self setSelectedRange:NSMakeRange(range.location, 0)];
  }
}

/// Dragging out of the field also carries real line breaks. The superclass
/// writes the selection for every requested type; the plain-text entries are
/// then replaced with the model text.
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
                             types:(NSArray<NSPasteboardType> *)types {
  BOOL result = [super writeSelectionToPasteboard:pboard types:types];
  NSRange range = self.selectedRange;
  if (range.length == 0) {
    return result;
  }
  NSAttributedString *selected =
      [self.textStorage attributedSubstringFromRange:range];
  NSString *model = GAModelTextFromFieldText(selected).string;
  [pboard setString:model forType:NSPasteboardTypeString];
  // Older pasteboard readers ask for the legacy name instead.
  [pboard setString:model forType:@"NSStringPboardType"];
  return YES;
}

@end

/// macOS 26+ search fields drop the leading text inset when the search button
/// cell is removed; the text then starts at the bezel edge. Use a fixed 9 pt
/// text inset on both edges without changing the field's frame, font or text.
static const CGFloat GASearchFieldTextInset = 9.0;

@interface GASearchFieldCell : NSSearchFieldCell
@end

@implementation GASearchFieldCell

- (NSRect)rectByInsettingTextEdges:(NSRect)rect bounds:(NSRect)bounds {
  rect.origin.x = NSMinX(bounds) + GASearchFieldTextInset;
  rect.size.width =
      MAX(0, NSMaxX(bounds) - GASearchFieldTextInset - NSMinX(rect));
  return rect;
}

- (NSRect)searchTextRectForBounds:(NSRect)bounds {
  return [self rectByInsettingTextEdges:[super searchTextRectForBounds:bounds]
                                 bounds:bounds];
}

- (NSRect)titleRectForBounds:(NSRect)bounds {
  return [self rectByInsettingTextEdges:[super titleRectForBounds:bounds]
                                 bounds:bounds];
}

- (NSRect)drawingRectForBounds:(NSRect)bounds {
  return [self rectByInsettingTextEdges:[super drawingRectForBounds:bounds]
                                 bounds:bounds];
}

@end

@implementation GASearchField

+ (Class)cellClass {
  return [GASearchFieldCell class];
}

@end

/// Drops every attribute except the app font, the app foreground color,
/// selection runs, and line-break markers. Shared by the plain copy and the
/// field editor normalization path.
NSAttributedString *GANormalizedSidebarInput(NSAttributedString *source,
                                             NSFont *font, NSColor *color) {
  NSMutableAttributedString *storage =
      [[NSMutableAttributedString alloc] initWithString:source.string];
  NSRange all = NSMakeRange(0, storage.length);
  NSMutableArray<NSValue *> *runRanges = [NSMutableArray array];
  NSMutableArray<GAGlyphSelection *> *runValues = [NSMutableArray array];
  [source enumerateAttribute:GAGlyphSelectionAttributeName
                     inRange:NSMakeRange(0, source.length)
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                    (void)stop;
                    if ([value isKindOfClass:GAGlyphSelection.class]) {
                      [runRanges addObject:[NSValue valueWithRange:range]];
                      [runValues addObject:value];
                    }
                  }];
  NSMutableArray<NSValue *> *markerRanges = [NSMutableArray array];
  [source enumerateAttribute:GALineBreakAttributeName
                     inRange:all
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
                    (void)stop;
                    if (value != nil) {
                      [markerRanges addObject:[NSValue valueWithRange:range]];
                    }
                  }];

  [storage beginEditing];
  [storage setAttributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
  }
                   range:all];
  for (NSUInteger index = 0; index < runRanges.count; index++) {
    [storage addAttribute:GAGlyphSelectionAttributeName
                    value:runValues[index]
                    range:runRanges[index].rangeValue];
  }
  for (NSValue *value in markerRanges) {
    GASetLineBreakMarker(storage, value.rangeValue);
  }
  [storage endEditing];
  return storage;
}
