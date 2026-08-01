//
//  KFOverlay.m
//  自动启动 kfun 隐藏的雷达服务器
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static IMP original_viewDidAppear = NULL;

static void hooked_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (original_viewDidAppear) {
        ((void(*)(id, SEL, BOOL))original_viewDidAppear)(self, _cmd, animated);
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[KFOverlay] Auto-starting radar...");
        
        if ([self respondsToSelector:@selector(radarTapped:)]) {
            NSLog(@"[KFOverlay] Found radarTapped: calling it");
            UIButton *fakeButton = [UIButton buttonWithType:UIButtonTypeSystem];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:@selector(radarTapped:) withObject:fakeButton];
            #pragma clang diagnostic pop
            NSLog(@"[KFOverlay] radarTapped: called successfully");
        } else {
            NSLog(@"[KFOverlay] radarTapped: not found on %@", [self class]);
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList([self class], &methodCount);
            for (unsigned int i = 0; i < methodCount; i++) {
                SEL selector = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(selector);
                if ([name containsString:@"radar"] || [name containsString:@"Radar"]) {
                    NSLog(@"[KFOverlay] Found method: %@", name);
                    [self performSelector:selector withObject:nil];
                }
            }
            free(methods);
        }
    });
}

__attribute__((constructor)) static void KFOverlayEntry(void) {
    NSLog(@"[KFOverlay] Dylib loaded, setting up hooks...");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class rootVC = objc_getClass("RootViewController");
        
        if (!rootVC) {
            NSLog(@"[KFOverlay] RootViewController not found, trying alternatives...");
            const char *classNames[] = {
                "RootViewController", "ViewController",
                "MainViewController", "HomeViewController", NULL
            };
            for (int i = 0; classNames[i]; i++) {
                rootVC = objc_getClass(classNames[i]);
                if (rootVC) {
                    NSLog(@"[KFOverlay] Found class: %s", classNames[i]);
                    break;
                }
            }
        }
        
        if (!rootVC) {
            NSLog(@"[KFOverlay] ERROR: No view controller class found");
            return;
        }
        
        SEL viewDidAppearSel = @selector(viewDidAppear:);
        Method viewDidAppearMethod = class_getInstanceMethod(rootVC, viewDidAppearSel);
        
        if (viewDidAppearMethod) {
            original_viewDidAppear = method_getImplementation(viewDidAppearMethod);
            method_setImplementation(viewDidAppearMethod, (IMP)hooked_viewDidAppear);
            NSLog(@"[KFOverlay] Hooked viewDidAppear: on %s", class_getName(rootVC));
        }
        
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(rootVC, &methodCount);
        NSLog(@"[KFOverlay] Methods on %s (%d total):", class_getName(rootVC), methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL selector = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(selector);
            if ([name containsString:@"radar"] || [name containsString:@"Radar"] ||
                [name containsString:@"tapped"] || [name containsString:@"Tapped"] ||
                [name containsString:@"start"] || [name containsString:@"Start"]) {
                NSLog(@"[KFOverlay]   >>> %@", name);
            }
        }
        free(methods);
        
        NSLog(@"[KFOverlay] Hooks installed. Radar will auto-start on viewDidAppear.");
    });
}
