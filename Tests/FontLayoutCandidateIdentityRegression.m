#import <Foundation/Foundation.h>
#import "Font/GATextQueryModel.h"
#import "Views/GASidebarViewController.h"
#import "App/GAGlyphNavigation.h"
static void require(BOOL value, NSString *message) { NSCAssert(value,@"%@",message); }
@interface GASidebarViewController (IdentityTests)
- (void)notifySelection;
- (void)setGroups:(NSArray *)groups sourceText:(NSString *)text rows:(NSArray *)rows selectedRange:(NSRange)range;
- (NSInteger)rowForPendingSelection;
- (NSInteger)rowForGlyphIDs:(NSArray *)ids textRange:(NSRange)range;
- (void)selectGlyphIdentityAfterNextReload:(id)identity textRange:(NSRange)range scroll:(GAPendingSelectionScroll)scroll;
@end
// Geometry is irrelevant here. All selection, notification, reload and history
// logic is production code; no application, table window or event loop is opened.
@interface GAIdentityTestSidebar : GASidebarViewController @end
@implementation GAIdentityTestSidebar
- (id)captureScrollAnchor { return nil; }
- (void)restoreScrollAnchor:(id)anchor {}
- (void)reloadTableGeometry {}
- (void)scrollGroupContainingRow:(NSInteger)row {}
@end
int main(void) { @autoreleasepool {
    GAIdentityTestSidebar *sidebar=[GAIdentityTestSidebar new];
    GAGlyphVariant *a=[GAGlyphVariant new], *b=[GAGlyphVariant new];
    a.glyphIDs=b.glyphIDs=@[@3,@4]; a.markComponents=@[@-1,@0]; b.markComponents=@[@-1,@1]; a.base=YES;
    a.positions=@[[NSValue valueWithPoint:NSMakePoint(100,500)]];
    b.positions=@[[NSValue valueWithPoint:NSMakePoint(900,500)]];
    __block NSUInteger notifications=0; __block GAGlyphVariant *preview;
    sidebar.onSelectionChanged=^(GAGlyphVariant *v, BOOL quick) { (void)quick; notifications++; preview=v; };
    [sidebar setValue:[NSValue valueWithRange:NSMakeRange(0,3)] forKey:@"selectedVariantTextRange"];
    [sidebar setValue:a forKey:@"selectedVariant"]; [sidebar notifySelection];
    [sidebar setValue:b forKey:@"selectedVariant"]; [sidebar notifySelection];
    require(notifications==2 && preview==b,@"Same-GID component change did not notify preview");
    [sidebar notifySelection]; require(notifications==2,@"Exact repeat notified twice");
    GACharacterGroup *g=[GACharacterGroup new]; g.text=@"abc"; g.textRange=NSMakeRange(0,3); g.variants=@[a,b];
    NSMutableArray *rows=[NSMutableArray array];
    for (id v in @[a,b]) { id row=[NSClassFromString(@"GARowItem") new]; [row setValue:g forKey:@"group"]; [row setValue:v forKey:@"variant"]; [rows addObject:row]; }
    [sidebar setGroups:@[g] sourceText:g.text rows:rows selectedRange:g.textRange];
    require([sidebar valueForKey:@"selectedVariant"]==b,@"Reload restored the first same-GID row");
    id identity=[b valueForKey:@"glyphIdentity"];
    [sidebar selectGlyphIdentityAfterNextReload:identity textRange:g.textRange scroll:GAPendingSelectionScrollGroup];
    require([sidebar rowForPendingSelection]==1,@"Pending exact selection lost components");
    require([sidebar rowForGlyphIDs:b.glyphIDs textRange:g.textRange]==0,@"GID-only fallback changed");
    GAGlyphNavigationStep *first=[GAGlyphNavigationStep new], *second=[GAGlyphNavigationStep new];
    first.mode=second.mode=GAViewModeSingleGlyph; first.glyphIDs=a.glyphIDs; second.glyphIDs=b.glyphIDs;
    first.range=second.range=g.textRange; first.sourceText=second.sourceText=g.text;
    [first setValue:[a valueForKey:@"glyphIdentity"] forKey:@"glyphIdentity"];
    [second setValue:identity forKey:@"glyphIdentity"];
    require(![first matchesLocation:second],@"History merged different component candidates");
    require([[second copy] matchesLocation:second],@"History copy lost identity");
    GAGlyphNavigationHistory *history=[GAGlyphNavigationHistory new];
    [history recordStep:first]; [history recordStep:second]; require(history.backSteps.count==2,@"History lost a visit");
    require([history moveToStep:first leavingStep:second],@"Back failed");
    require([history.restoredStep matchesLocation:first],@"Back restored wrong component");
    GAGlyphNavigationStep *forward=history.forwardSteps.lastObject;
    require([history moveToStep:forward leavingStep:first] && [history.restoredStep matchesLocation:second],@"Forward restored wrong component");
    GAGlyphVariant *ownerA=[GAGlyphVariant new], *ownerB=[GAGlyphVariant new];
    ownerA.glyphIDs=ownerB.glyphIDs=@[@3,@4,@5]; ownerA.markComponents=ownerB.markComponents=@[@-1,@0,@0];
    ownerB.markLigatures=@[@0,@1,@2];
    [sidebar setValue:ownerA forKey:@"selectedVariant"]; [sidebar notifySelection];
    [sidebar setValue:ownerB forKey:@"selectedVariant"]; [sidebar notifySelection];
    require(notifications==4 && preview==ownerB,@"Different ligature owners did not notify");
    GAGlyphNavigationStep *ordinary=[GAGlyphNavigationStep new], *gidOnly=[GAGlyphNavigationStep new];
    ordinary.mode=gidOnly.mode=GAViewModeSingleGlyph; ordinary.glyphIDs=gidOnly.glyphIDs=@[@1];
    ordinary.range=gidOnly.range=g.textRange; ordinary.sourceText=gidOnly.sourceText=g.text;
    GAGlyphVariant *plain=[GAGlyphVariant new]; plain.glyphIDs=@[@1];
    ordinary.glyphIdentity=plain.glyphIdentity;
    require([ordinary matchesLocation:gidOnly],@"Ordinary GID-only history compatibility changed");
    puts("Candidate notification, reload, pending selection, GID fallback and Back/Forward PASS");
} }
