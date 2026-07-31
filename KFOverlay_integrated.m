//
//  KFOverlay.m
//  KFOverlay
//
//  集成版: 直接放入 kfun.app/Frameworks/
//  通过 install_name_tool 添加 LC_LOAD_DYLIB 到 kfun
//  kfun 启动时自动加载此 dylib
//
//  优势:
//  - 不需要单独注入 (作为 kfun 依赖自动加载)
//  - hook 时机早 (kfun 类已加载完成)
//  - 可直接访问 kfun 内部数据
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - 配置

#define RED_SQUARE_SIZE 10
#define OVERLAY_TAG 99999

// MARK: - 全局状态

static UIWindow *g_overlayWindow = nil;
static UIView *g_overlayView = nil;
static NSMutableArray *g_filteredPlayers = nil;
static NSString *g_currentMap = @"";

// MARK: - 数据模型

@interface KFPlayer : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) double x;
@property (nonatomic, assign) double y;
@property (nonatomic, assign) BOOL isAi;
@property (nonatomic, assign) double direction;
@property (nonatomic, assign) double dist;
@end
@implementation KFPlayer
@end

// MARK: - 坐标转换

static const double kOffsetX = 357353.3;
static const double kOffsetY = -769882.0;
static const double kScaleX = 0.02482745;
static const double kScaleY = 0.0253012;
static const double kImgOffsetX = -6847.523;
static const double kImgOffsetY = 21028.91;
static const double kImgW = 2000.0;
static const double kImgH = 2000.0;

static CGPoint worldToScreen(double wx, double wy, double sw, double sh) {
    double imgX = kScaleX * (wx + kOffsetX) + kImgOffsetX;
    double imgY = kScaleY * (wy + kOffsetY) + kImgOffsetY;
    return CGPointMake(imgX * (sw / kImgW), imgY * (sh / kImgH));
}

// MARK: - JSON 解析

static void parseJSONData(NSData *data) {
    if (!data || data.length == 0) return;
    
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:nil];
    if (!json) return;
    
    NSString *type = json[@"type"];
    
    // map 类型
    if ([type isEqualToString:@"map"]) {
        g_currentMap = json[@"map"] ?: @"";
        return;
    }
    
    // update 类型
    if ([type isEqualToString:@"update"]) {
        NSArray *playerArray = json[@"players"];
        if (!playerArray || ![playerArray isKindOfClass:[NSArray class]]) return;
        
        if (!g_filteredPlayers) {
            g_filteredPlayers = [NSMutableArray array];
        }
        [g_filteredPlayers removeAllObjects];
        
        for (NSDictionary *pDict in playerArray) {
            BOOL isAi = [pDict[@"isAi"] boolValue];
            
            // ★ 只保留 isAi=false 真人玩家
            if (isAi) continue;
            
            KFPlayer *player = [[KFPlayer alloc] init];
            player.name = pDict[@"name"] ?: @"";
            player.x = [pDict[@"x"] doubleValue];
            player.y = [pDict[@"y"] doubleValue];
            player.isAi = isAi;
            player.direction = [pDict[@"direction"] doubleValue];
            player.dist = [pDict[@"dist"] doubleValue];
            
            [g_filteredPlayers addObject:player];
        }
        
        // 刷新叠加层
        if (g_overlayView) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [g_overlayView setNeedsDisplay];
            });
        }
    }
}

// MARK: - Hook 实现

static IMP g_orig_sendMessage = NULL;
static IMP g_orig_broadcastMessage = NULL;

static void hooked_sendMessage(id self, SEL _cmd, id message) {
    NSData *data = nil;
    if ([message isKindOfClass:[NSString class]]) {
        data = [(NSString *)message dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([message isKindOfClass:[NSData class]]) {
        data = (NSData *)message;
    }
    if (data) parseJSONData(data);
    
    if (g_orig_sendMessage) {
        ((void (*)(id, SEL, id))g_orig_sendMessage)(self, _cmd, message);
    }
}

static void hooked_broadcastMessage(id self, SEL _cmd, id message) {
    NSData *data = nil;
    if ([message isKindOfClass:[NSString class]]) {
        data = [(NSString *)message dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([message isKindOfClass:[NSData class]]) {
        data = (NSData *)message;
    }
    if (data) parseJSONData(data);
    
    if (g_orig_broadcastMessage) {
        ((void (*)(id, SEL, id))g_orig_broadcastMessage)(self, _cmd, message);
    }
}

static void setupHooks() {
    // kfun 类可能使用的 WebSocket 类名
    NSArray *classNames = @[
        @"MBWebSocketServer",
        @"MBWebSocket",
        @"WebSocketServer",
        @"SRWebSocket",
        @"WebSocketServerProtocol",
        @"WebSocketClient",
    ];
    
    Class wsClass = nil;
    for (NSString *name in classNames) {
        wsClass = NSClassFromString(name);
        if (wsClass) {
            NSLog(@"[KFOverlay] Found: %@", name);
            break;
        }
    }
    
    if (!wsClass) {
        NSLog(@"[KFOverlay] No WebSocket class found");
        return;
    }
    
    // Hook 所有可能的发送方法
    struct { const char *name; IMP *orig; IMP hooked; } methods[] = {
        {"sendMessage:", &g_orig_sendMessage, (IMP)hooked_sendMessage},
        {"broadcastMessage:", &g_orig_broadcastMessage, (IMP)hooked_broadcastMessage},
        {"sendString:", &g_orig_sendMessage, (IMP)hooked_sendMessage},
        {"broadcastString:", &g_orig_broadcastMessage, (IMP)hooked_broadcastMessage},
        {"sendData:", &g_orig_sendMessage, (IMP)hooked_sendMessage},
        {"writeFrame:", &g_orig_sendMessage, (IMP)hooked_sendMessage},
        {"sendFrame:", &g_orig_broadcastMessage, (IMP)hooked_broadcastMessage},
        {"sendMessageTo:", &g_orig_sendMessage, (IMP)hooked_sendMessage},
    };
    
    for (int i = 0; i < sizeof(methods)/sizeof(methods[0]); i++) {
        if (*(methods[i].orig)) continue;  // 已 hook
        
        SEL sel = sel_registerName(methods[i].name);
        Method method = class_getInstanceMethod(wsClass, sel);
        if (method) {
            *(methods[i].orig) = method_getImplementation(method);
            method_setImplementation(method, methods[i].hooked);
            NSLog(@"[KFOverlay] Hooked: %s", methods[i].name);
        }
    }
}

// MARK: - 叠加层视图

@interface KFOverlayView : UIView
@end

@implementation KFOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.tag = OVERLAY_TAG;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    
    // 清除
    [[UIColor clearColor] setFill];
    UIRectFill(rect);
    
    CGSize sz = rect.size;
    
    // 绘制玩家 (仅 isAi=false)
    if (g_filteredPlayers.count > 0) {
        for (KFPlayer *p in g_filteredPlayers) {
            if (p.isAi) continue;  // 双保险
            
            CGPoint pt = worldToScreen(p.x, p.y, sz.width, sz.height);
            CGRect r = CGRectMake(pt.x - 5, pt.y - 5, 10, 10);
            
            if (CGRectIntersectsRect(r, rect)) {
                [[UIColor redColor] setFill];
                UIRectFill(r);
                [[UIColor whiteColor] setStroke];
                CGContextSetLineWidth(ctx, 1.0);
                UIRectFrame(r);
            }
        }
    }
    
    // 状态 (左下角, 避免遮挡游戏 HUD)
    NSString *status = [NSString stringWithFormat:@"KFOverlay | %lu | %@",
                        (unsigned long)g_filteredPlayers.count,
                        g_currentMap.length > 0 ? g_currentMap : @"--"];
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    CGSize ts = [status sizeWithAttributes:attrs];
    CGRect sr = CGRectMake(10, sz.height - ts.height - 15, ts.width + 10, ts.height + 4);
    [[[UIColor blackColor] colorWithAlphaComponent:0.6] setFill];
    UIRectFill(sr);
    [status drawAtPoint:CGPointMake(sr.origin.x + 5, sr.origin.y + 2) withAttributes:attrs];
}

@end

// MARK: - Window 管理

static void createOverlayWindow() {
    if (g_overlayWindow) return;
    
    CGRect bounds = [UIScreen mainScreen].bounds;
    
    g_overlayWindow = [[UIWindow alloc] initWithFrame:bounds];
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar + 100;  // 最高层
    g_overlayWindow.backgroundColor = [UIColor clearColor];
    g_overlayWindow.opaque = NO;
    g_overlayWindow.userInteractionEnabled = NO;
    
    g_overlayView = [[KFOverlayView alloc] initWithFrame:bounds];
    [g_overlayWindow addSubview:g_overlayView];
    [g_overlayWindow makeKeyAndVisible];
    
    NSLog(@"[KFOverlay] Window created (level: %.0f)", g_overlayWindow.windowLevel);
}

// MARK: - 初始化入口

__attribute__((constructor))
static void kf_overlay_init() {
    NSLog(@"[KFOverlay] === KFOverlay dylib loaded ===");
    
    // 作为 kfun 的依赖库，constructor 在 kfun 启动时立即执行
    // kfun 的 ObjC 类此时已可用
    
    // 1. 创建叠加层窗口 (立即创建，不需要等待)
    createOverlayWindow();
    
    // 2. Hook kfun 的 WebSocket 发送方法
    //    因为是 kfun 的依赖库，kfun 类已加载，直接 hook
    setupHooks();
    
    // 3. 设置持续刷新定时器 (每 100ms)
    [NSTimer scheduledTimerWithTimeInterval:0.1
                                    repeats:YES
                                      block:^(NSTimer *timer) {
        if (g_overlayView) {
            [g_overlayView setNeedsDisplay];
        }
    }];
    
    NSLog(@"[KFOverlay] Ready - filtering isAi=false players");
}
