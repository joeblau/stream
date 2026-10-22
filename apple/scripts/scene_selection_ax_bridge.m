#import "scene_selection_ax_bridge.h"

// Query only the supplied owned window, using the public in-process informal
// NSAccessibility selectors. SwiftUI proxies need not formally conform to the
// protocol; Objective-C preserves the actual object/NSArray ABI.
static void walk(id object, NSUInteger depth, NSMutableSet *seen,
                 NSMutableArray *report, NSString *press, BOOL *performed) {
    if (!object || depth > 40 || report.count >= 1000) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([seen containsObject:identity]) return;
    [seen addObject:identity];
    id<NSAccessibility> element = (id<NSAccessibility>)object;
    id label = [object respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil;
    id role = [object respondsToSelector:@selector(accessibilityRole)] ? [element accessibilityRole] : nil;
    id value = [object respondsToSelector:@selector(accessibilityValue)] ? [element accessibilityValue] : nil;
    NSString *safeLabel = [label isKindOfClass:NSString.class] ? label : @"";
    NSString *safeRole = [role isKindOfClass:NSString.class] ? role : @"";
    NSString *safeValue = [value isKindOfClass:NSString.class] ? value : @"";
    [report addObject:@{@"label":safeLabel, @"role":safeRole, @"value":safeValue}];
    if (press && !*performed && [safeLabel isEqualToString:press] && [safeRole isEqualToString:NSAccessibilityButtonRole]
        && [object respondsToSelector:@selector(accessibilityPerformPress)]) {
        *performed = [element accessibilityPerformPress];
    }
    if ([object respondsToSelector:@selector(accessibilityChildren)]) {
        id children = [element accessibilityChildren];
        if ([children isKindOfClass:NSArray.class]) for (id child in children) walk(child,depth+1,seen,report,press,performed);
    }
}
NSData *SceneSelectionAXReport(NSWindow *window) {
    NSMutableArray *report = NSMutableArray.array; BOOL performed = NO;
    walk(window,0,NSMutableSet.set,report,nil,&performed);
    return [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
}
BOOL SceneSelectionAXPress(id ownedElement, NSString *label) {
    NSMutableArray *report = NSMutableArray.array; BOOL performed = NO;
    walk(ownedElement,0,NSMutableSet.set,report,label,&performed); return performed;
}
