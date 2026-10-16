//
//  JDClickerSB.m — SpringBoard 侧连点器（京东专用）
//
//  ---------------------------------------------------------------------------
//  为什么不是注入京东
//  ---------------------------------------------------------------------------
//  实测结论（详见 README §6.9）：
//      * 只要京东进程里出现**任何**外来 dylib，京东就主动结束自己 ——
//        连一个只打两条 NSLog 的 NoOp.dylib 都会让它崩；
//      * 同一个 NoOp.dylib 注入「备忘录」则一切正常 —— 所以不是 dylib 的问题；
//      * 把 dyld 的公开镜像枚举 API（_dyld_image_count / _dyld_get_image_name /
//        _dyld_get_image_header / _dyld_get_image_vmaddr_slide）全部接管、
//        对 App 隐藏自己，京东**照样崩** —— 说明它的检测不走公开 API。
//
//  所以本插件**完全不碰京东进程**：它注入 SpringBoard，在那里建悬浮窗，
//  并用系统级 HID 事件把触摸"从外面"打进去。这也正是 SimulateTouch
//  （跑在 backboardd）和 ZXTouch（跑在 SpringBoard）的做法。
//
//  安全属性：本文件带强制守卫，**只允许在 SpringBoard 里安装**。
//  就算有人把它注入到京东，它也什么都不做 —— 不会害京东闪退。
//
//  ---------------------------------------------------------------------------
//  架构
//  ---------------------------------------------------------------------------
//      SpringBoard 进程
//        └─ 悬浮窗（仅当京东位于前台时显示）
//             ├─ 悬浮球 / 菜单 / 准星
//             └─ 连点引擎
//                  └─ IOHIDEventSystemClientDispatchEvent  ← 系统级派发
//                                                            事件按坐标落到
//                                                            当前前台 App（京东）
//
//  编译: 见 build.ps1
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ===========================================================================
// MARK: - 可调参数
// ===========================================================================

static NSString * const kJDTargetBundle = @"com.360buy.jdmobile";   // 京东
static NSString * const kJDTargetName   = @"京东";

static const CGFloat kACBallSize      = 56.0;
static const CGFloat kACMenuWidth     = 230.0;
static const CGFloat kACMenuMargin    = 8.0;
static const CGFloat kACCrosshairSize = 64.0;
static const double  kACDefaultFreq   = 10.0;

// 悬浮窗层级: 必须高于京东的窗口内容。SpringBoard 里给一个足够高的值。
// 注意 UIWindowLevelAlert 是 extern const, 不能用于静态初始化, 所以在函数里算。
static UIWindowLevel ACWindowLevel(void) { return UIWindowLevelAlert + 1000.0; }

static NSString * const kACKeyPointX  = @"jd_point_x";
static NSString * const kACKeyPointY  = @"jd_point_y";
static NSString * const kACKeyFreq    = @"jd_freq";
static NSString * const kACKeyBallX   = @"jd_ball_x";
static NSString * const kACKeyBallY   = @"jd_ball_y";
static NSString * const kACKeyAimed   = @"jd_aimed";
static NSString * const kACKeyAlways  = @"jd_always_show";   // 无视前台 App 一直显示

// ===========================================================================
// MARK: - 日志 (写文件, Filza 直接可看)
// ===========================================================================

static NSString *ACLogFilePath(void)
{
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *cands = @[
            @"/tmp/JDClicker.log",
            @"/var/mobile/Library/Caches/JDClicker.log",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"JDClicker.log"],
        ];
        for (NSString *c in cands) {
            @try {
                if (![fm fileExistsAtPath:c]) {
                    [fm createFileAtPath:c contents:nil attributes:nil];
                }
                if ([fm isWritableFileAtPath:c]) { path = c; break; }
            } @catch (NSException *e) { }
        }
    });
    return path;
}

static void ACLogAppend(NSString *line)
{
    NSString *p = ACLogFilePath();
    if (!p) return;
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) { }
}

#define AC_LOG(fmt, ...)                                                        \
    do {                                                                        \
        NSString *acLine__ = [NSString stringWithFormat:@"[JDClicker] " fmt,    \
                                                       ##__VA_ARGS__];          \
        NSLog(@"%@", acLine__);                                                 \
        ACLogAppend(acLine__);                                                  \
    } while (0)

// ===========================================================================
// MARK: - IOHID 系统级触摸派发
// ===========================================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef struct { uint32_t lo; uint32_t hi; } ACAbsoluteTime;

enum { kACEventTypeDigitizer = 11 };
enum { kACTransducerTypeHand = 3, kACTransducerTypeFinger = 2 };
enum {
    kACDigitizerEventRange    = 0x00000001,
    kACDigitizerEventTouch    = 0x00000002,
    kACDigitizerEventPosition = 0x00000004,
};
#define kACFieldDigitizerIsDisplayIntegrated (int32_t)((kACEventTypeDigitizer << 16) + 25)  // 0xB0019

typedef IOHIDEventRef (*ACCreateDigitizerEventFn)(CFAllocatorRef, ACAbsoluteTime, uint32_t,
                                                  uint32_t, uint32_t, uint32_t, uint32_t,
                                                  IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                                  IOHIDFloat, IOHIDFloat,
                                                  Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*ACCreateFingerEventWithQualityFn)(CFAllocatorRef, ACAbsoluteTime,
                                                          uint32_t, uint32_t, uint32_t,
                                                          IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                                          IOHIDFloat, IOHIDFloat,
                                                          IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                                          IOHIDFloat, IOHIDFloat,
                                                          Boolean, Boolean, uint32_t);
typedef void (*ACEventAppendEventFn)(IOHIDEventRef, IOHIDEventRef);
typedef void (*ACEventSetIntegerValueFn)(IOHIDEventRef, int32_t, int);
typedef void (*ACEventSetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemClientRef (*ACSystemClientCreateFn)(CFAllocatorRef);
typedef void (*ACSystemClientDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static ACCreateDigitizerEventFn         pCreateDigitizerEvent = NULL;
static ACCreateFingerEventWithQualityFn pCreateFingerEvent    = NULL;
static ACEventAppendEventFn             pEventAppendEvent     = NULL;
static ACEventSetIntegerValueFn         pEventSetIntegerValue = NULL;
static ACEventSetSenderIDFn             pEventSetSenderID     = NULL;
static ACSystemClientCreateFn           pSystemClientCreate   = NULL;
static ACSystemClientDispatchFn         pSystemClientDispatch = NULL;

// 给合成事件打一个固定的 sender id, 便于区分"我们发的"和真实触摸
static const uint64_t kACSyntheticSenderID = 0x8000000817319372ULL;

static void ACLoadIOHIDSymbols(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        #define AC_BIND(var, name)                                              \
            do {                                                                \
                void *h = iokit ? dlsym(iokit, name) : NULL;                    \
                if (!h) h = dlsym(RTLD_DEFAULT, name);                          \
                var = (__typeof__(var))h;                                       \
            } while (0)
        AC_BIND(pCreateDigitizerEvent, "IOHIDEventCreateDigitizerEvent");
        AC_BIND(pCreateFingerEvent,    "IOHIDEventCreateDigitizerFingerEventWithQuality");
        AC_BIND(pEventAppendEvent,     "IOHIDEventAppendEvent");
        AC_BIND(pEventSetIntegerValue, "IOHIDEventSetIntegerValue");
        AC_BIND(pEventSetSenderID,     "IOHIDEventSetSenderID");
        AC_BIND(pSystemClientCreate,   "IOHIDEventSystemClientCreate");
        AC_BIND(pSystemClientDispatch, "IOHIDEventSystemClientDispatchEvent");
        #undef AC_BIND
        AC_LOG(@"IOKit: digitizer=%@ finger=%@ append=%@ client=%@ dispatch=%@",
               pCreateDigitizerEvent ? @"有" : @"无",
               pCreateFingerEvent ? @"有" : @"无",
               pEventAppendEvent ? @"有" : @"无",
               pSystemClientCreate ? @"有" : @"无",
               pSystemClientDispatch ? @"有" : @"无");
    });
}

// 一个 "手 + 手指" 事件; x/y 用屏幕坐标(点)
static IOHIDEventRef ACCreateHIDEvent(CGPoint point, UITouchPhase phase)
{
    if (!pCreateDigitizerEvent || !pCreateFingerEvent) return NULL;

    uint64_t abTime = mach_absolute_time();
    ACAbsoluteTime ts;
    ts.lo = (uint32_t)abTime;
    ts.hi = (uint32_t)(abTime >> 32);

    IOHIDEventRef hand = pCreateDigitizerEvent(kCFAllocatorDefault, ts,
                                               kACTransducerTypeHand,
                                               0, 0, kACDigitizerEventTouch, 0,
                                               0, 0, 0, 0, 0,
                                               0, true, 0);
    if (!hand) return NULL;
    if (pEventSetIntegerValue) pEventSetIntegerValue(hand, kACFieldDigitizerIsDisplayIntegrated, 1);

    uint32_t mask = (phase == UITouchPhaseMoved)
        ? kACDigitizerEventPosition
        : (kACDigitizerEventRange | kACDigitizerEventTouch);
    uint32_t touching = (phase == UITouchPhaseEnded) ? 0 : 1;

    IOHIDEventRef finger = pCreateFingerEvent(kCFAllocatorDefault, ts,
                                              1, 2, mask,
                                              (IOHIDFloat)point.x, (IOHIDFloat)point.y, 0.0,
                                              0, 0,
                                              5.0, 5.0, 1.0, 1.0, 1.0,
                                              (Boolean)touching, (Boolean)touching, 0);
    if (!finger) { CFRelease(hand); return NULL; }
    if (pEventSetIntegerValue) pEventSetIntegerValue(finger, kACFieldDigitizerIsDisplayIntegrated, 1);

    if (pEventSetSenderID) {
        pEventSetSenderID(hand, kACSyntheticSenderID);
        pEventSetSenderID(finger, kACSyntheticSenderID);
    }
    if (pEventAppendEvent) pEventAppendEvent(hand, finger);
    CFRelease(finger);
    return hand;
}

// ===========================================================================
// MARK: - 注入器 (只有 HID 一条路)
// ===========================================================================

@interface ACTouchInjector : NSObject
@property (nonatomic, assign, readonly) BOOL ready;
@property (nonatomic, readonly) NSString *diagnostics;
+ (instancetype)shared;
- (void)prepare;
- (void)tapAtPoint:(CGPoint)point;
@end

@implementation ACTouchInjector
{
    IOHIDEventSystemClientRef _client;
}

+ (instancetype)shared
{
    static ACTouchInjector *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ACTouchInjector new]; });
    return s;
}

- (NSString *)diagnostics
{
    if (pSystemClientCreate == NULL)   return @"缺少 IOHIDEventSystemClientCreate";
    if (pSystemClientDispatch == NULL) return @"缺少 IOHIDEventSystemClientDispatchEvent";
    if (pCreateDigitizerEvent == NULL || pCreateFingerEvent == NULL) return @"缺少 IOHID 事件构造符号";
    if (_client == NULL)               return @"IOHIDEventSystemClient 创建失败";
    return @"已就绪";
}

- (void)prepare
{
    ACLoadIOHIDSymbols();
    if (_client == NULL && pSystemClientCreate) {
        _client = pSystemClientCreate(kCFAllocatorDefault);
    }
    BOOL ok = (_client != NULL && pSystemClientDispatch != NULL &&
               pCreateDigitizerEvent != NULL && pCreateFingerEvent != NULL);
    AC_LOG(@"注入器: ready=%@ (%@)", ok ? @"YES" : @"NO", self.diagnostics);
}

- (BOOL)ready
{
    return (_client != NULL && pSystemClientDispatch != NULL &&
            pCreateDigitizerEvent != NULL && pCreateFingerEvent != NULL);
}

- (void)tapAtPoint:(CGPoint)point
{
    if (!self.ready) return;
    @try {
        IOHIDEventRef down = ACCreateHIDEvent(point, UITouchPhaseBegan);
        if (down) { pSystemClientDispatch(_client, down); CFRelease(down); }
        IOHIDEventRef up = ACCreateHIDEvent(point, UITouchPhaseEnded);
        if (up) { pSystemClientDispatch(_client, up); CFRelease(up); }
    } @catch (NSException *ex) {
        AC_LOG(@"派发异常: %@ - %@", ex.name, ex.reason);
    }
}

@end

// ===========================================================================
// MARK: - 进程守卫: 只允许装在 SpringBoard
// ===========================================================================

static BOOL ACIsSpringBoard(void)
{
    static BOOL decided = NO, ok = NO;
    if (decided) return ok;
    decided = YES;

    NSString *pn  = [[NSProcessInfo processInfo] processName] ?: @"";
    NSString *bid = [[[NSBundle mainBundle] bundleIdentifier] lowercaseString] ?: @"";

    ok = [pn isEqualToString:@"SpringBoard"] || [bid isEqualToString:@"com.apple.springboard"];
    if (!ok) {
        AC_LOG(@"当前进程是 %@ (%@), 不是 SpringBoard —— 拒绝安装。", pn, bid);
        AC_LOG(@"这是有意为之: 京东会杀死任何被注入的进程, 所以本插件绝不进京东。");
    }
    return ok;
}

// ===========================================================================
// MARK: - 前台 App 检测 (只在京东位于前台时显示)
// ===========================================================================

// SBApplicationProcessState: 4 = Foreground (按越狱社区广为使用的取值)
static const NSInteger kSBProcessStateForeground = 4;

static BOOL ACIsTargetFrontmost(void)
{
    Class ctrlClass = NSClassFromString(@"SBApplicationController");
    if (ctrlClass == nil) return NO;

    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![ctrlClass respondsToSelector:sharedSel]) return NO;
    id ctrl = ((id (*)(id, SEL))objc_msgSend)(ctrlClass, sharedSel);
    if (ctrl == nil) return NO;

    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![ctrl respondsToSelector:appSel]) return NO;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(ctrl, appSel, kJDTargetBundle);
    if (app == nil) return NO;

    // 依次尝试几种判定方式, 哪种存在用哪种
    SEL frontSel = NSSelectorFromString(@"isFrontmost");
    if ([app respondsToSelector:frontSel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(app, frontSel);
    }
    SEL stateSel = NSSelectorFromString(@"processState");
    if ([app respondsToSelector:stateSel]) {
        NSInteger st = ((NSInteger (*)(id, SEL))objc_msgSend)(app, stateSel);
        return (st == kSBProcessStateForeground);
    }
    SEL runningSel = NSSelectorFromString(@"isRunning");
    if ([app respondsToSelector:runningSel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(app, runningSel);
    }
    return NO;
}

// ===========================================================================
// MARK: - 连点引擎
// ===========================================================================

@interface ACClickEngine : NSObject
@property (nonatomic, assign, readonly) BOOL running;
@property (nonatomic, assign) double frequency;
@property (nonatomic, assign) CGPoint point;
@property (nonatomic, copy) void (^onStateChange)(BOOL running);
+ (instancetype)shared;
- (BOOL)start;
- (void)stop;
@end

@implementation ACClickEngine
{
    dispatch_queue_t     _queue;
    dispatch_source_t    _timer;
    dispatch_semaphore_t _slot;
    int32_t              _inFlight;
}

+ (instancetype)shared
{
    static ACClickEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ACClickEngine new]; });
    return s;
}

- (BOOL)start
{
    if (_timer) return YES;
    ACTouchInjector *inj = [ACTouchInjector shared];
    if (!inj.ready) { AC_LOG(@"无法开始: HID 注入器不可用"); return NO; }

    const CGPoint p = _point;
    const double  f = MAX(1.0, _frequency);
    const double  interval = 1.0 / f;

    _slot  = dispatch_semaphore_create(1);
    _queue = dispatch_queue_create("com.jdclicker.sb", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(interval * (double)NSEC_PER_SEC), 0);

    __weak ACClickEngine *weakSelf = self;
    dispatch_semaphore_t slot = _slot;
    dispatch_source_set_event_handler(_timer, ^{
        ACClickEngine *sself = weakSelf;
        if (!sself || !sself->_timer) return;
        if (dispatch_semaphore_wait(slot, DISPATCH_TIME_NOW) != 0) return;
        // HID 派发不要求主线程, 直接在当前队列做
        [[ACTouchInjector shared] tapAtPoint:p];
        dispatch_semaphore_signal(slot);
    });
    dispatch_resume(_timer);

    AC_LOG(@"开始连点: 位置=(%.0f, %.0f) 频率=%.0f/s", p.x, p.y, f);
    if (self.onStateChange) self.onStateChange(YES);
    return YES;
}

- (void)stop
{
    if (!_timer) return;
    dispatch_source_cancel(_timer);
    _timer = nil; _queue = nil; _slot = nil;
    AC_LOG(@"停止连点");
    if (self.onStateChange) self.onStateChange(NO);
}

- (BOOL)running { return _timer != nil; }
@end

// ===========================================================================
// MARK: - 事件穿透窗口
// ===========================================================================

@interface ACPassThroughWindow : UIWindow
@end

@implementation ACPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;      // 没命中可交互子视图 -> 穿透给京东
}
@end

// ===========================================================================
// MARK: - 悬浮球 / 准星
// ===========================================================================

@interface ACBallView : UIView
@property (nonatomic, copy) void (^onTouchActive)(BOOL active);
@end
@implementation ACBallView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{ if (self.onTouchActive) self.onTouchActive(YES); [super touchesBegan:touches withEvent:event]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{ if (self.onTouchActive) self.onTouchActive(NO); [super touchesEnded:touches withEvent:event]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{ if (self.onTouchActive) self.onTouchActive(NO); [super touchesCancelled:touches withEvent:event]; }
@end

@interface ACCrosshairView : UIView
@end
@implementation ACCrosshairView
- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
    }
    return self;
}
- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat r = MIN(rect.size.width, rect.size.height) * 0.5 - 2.0;
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.18].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectInset(rect, 6, 6));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.35 blue:0.25 alpha:0.95].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    CGContextMoveToPoint(ctx, c.x - r - 6, c.y); CGContextAddLineToPoint(ctx, c.x - 6, c.y);
    CGContextMoveToPoint(ctx, c.x + 6, c.y);     CGContextAddLineToPoint(ctx, c.x + r + 6, c.y);
    CGContextMoveToPoint(ctx, c.x, c.y - r - 6); CGContextAddLineToPoint(ctx, c.x, c.y - 6);
    CGContextMoveToPoint(ctx, c.x, c.y + 6);     CGContextAddLineToPoint(ctx, c.x, c.y + r + 6);
    CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.35 blue:0.25 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 2, c.y - 2, 4, 4));
}
@end

// ===========================================================================
// MARK: - 悬浮层
// ===========================================================================

@interface ACOverlay : NSObject
+ (instancetype)shared;
- (void)bootstrap;
@end

@implementation ACOverlay
{
    ACPassThroughWindow *_window;
    ACBallView          *_ball;
    UILabel             *_ballLabel;
    UIView              *_menu;
    UIButton            *_aimBtn;
    UIButton            *_startBtn;
    UISegmentedControl  *_freqCtrl;
    UISegmentedControl  *_showCtrl;
    UILabel             *_statusLabel;
    ACCrosshairView     *_crosshair;

    BOOL                 _aiming;
    CGPoint              _point;
    BOOL                 _hasPoint;
    NSInteger            _freqIndex;
    BOOL                 _alwaysShow;
    BOOL                 _targetFront;
    NSTimer             *_visTimer;
    NSInteger            _installRetry;
}

+ (instancetype)shared
{
    static ACOverlay *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ACOverlay new]; });
    return s;
}

#pragma mark 生命周期

- (void)bootstrap
{
    if (_window) return;
    if (!ACIsSpringBoard()) return;

    AC_LOG(@"bootstrap: 日志文件 = %@", ACLogFilePath() ?: @"(写不进去)");

    [self loadPrefs];
    [[ACTouchInjector shared] prepare];

    ACClickEngine *eng = [ACClickEngine shared];
    eng.frequency = [self currentFrequency];
    eng.point = _point;
    __weak typeof(self) weakSelf = self;
    eng.onStateChange = ^(BOOL running) {
        (void)running;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshUI]; });
    };

    [self scheduleInstallRetry];
}

- (void)scheduleInstallRetry
{
    if (_window) return;
    if (_installRetry > 600) { AC_LOG(@"放弃安装悬浮窗: 未取得 UIWindowScene"); return; }
    _installRetry++;
    if ([self tryInstall]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf scheduleInstallRetry]; });
}

static UIWindowScene *ACAnyWindowScene(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    UIWindowScene *fallback = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (BOOL)tryInstall
{
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    ACPassThroughWindow *win = nil;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = ACAnyWindowScene();
        if (!scene) return NO;
        win = [[ACPassThroughWindow alloc] initWithWindowScene:scene];
        CGRect sb = scene.coordinateSpace.bounds;
        win.frame = CGRectIsEmpty(sb) ? screenBounds : sb;
    } else {
        win = [[ACPassThroughWindow alloc] initWithFrame:screenBounds];
    }

    win.backgroundColor = [UIColor clearColor];
    win.opaque = NO;
    win.windowLevel = ACWindowLevel();

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = NO;
    win.rootViewController = root;

    _window = win;
    [self buildBall];
    [self buildMenu];
    [self buildCrosshair];
    [self refreshUI];

    _window.hidden = YES;                 // 先藏起来, 由可见性定时器决定

    // 可见性: 每 0.3 秒看一次京东在不在前台
    _visTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                target:self
                                              selector:@selector(onVisTick)
                                              userInfo:nil
                                               repeats:YES];
    AC_LOG(@"悬浮窗已安装(SpringBoard): 窗口=%.0fx%.0f 球心=(%.0f, %.0f) level=%.0f",
           _window.bounds.size.width, _window.bounds.size.height,
           _ball.center.x, _ball.center.y, _window.windowLevel);
    AC_LOG(@"默认位置: 屏幕右侧贴边, 距顶部约 1/3 处, 深灰圆 + 白字「连点」");
    return YES;
}

- (void)onVisTick
{
    BOOL front = ACIsTargetFrontmost();
    BOOL shouldShow = _alwaysShow || front;

    if (front != _targetFront) {
        _targetFront = front;
        AC_LOG(@"%@ 前后台状态: %@", kJDTargetName, front ? @"前台" : @"不在前台");
        [self refreshUI];
    }

    BOOL wantHidden = !shouldShow;
    if (_window.hidden != wantHidden) {
        _window.hidden = wantHidden;
        if (!wantHidden) AC_LOG(@"悬浮球已显示");
    }
}

#pragma mark 构建 UI

- (void)buildBall
{
    _ball = [[ACBallView alloc] initWithFrame:CGRectMake(0, 0, kACBallSize, kACBallSize)];
    _ball.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.92];
    _ball.layer.cornerRadius = kACBallSize * 0.5;
    _ball.layer.borderWidth = 2.0;
    _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.35;
    _ball.layer.shadowRadius = 4.0;
    _ball.layer.shadowOffset = CGSizeMake(0, 2);
    _ball.userInteractionEnabled = YES;

    _ballLabel = [[UILabel alloc] initWithFrame:_ball.bounds];
    _ballLabel.textAlignment = NSTextAlignmentCenter;
    _ballLabel.textColor = [UIColor whiteColor];
    _ballLabel.font = [UIFont boldSystemFontOfSize:15.0];
    _ballLabel.text = @"连点";
    _ballLabel.userInteractionEnabled = NO;
    [_ball addSubview:_ballLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBallPan:)];
    [_ball addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBallTap:)];
    [tap requireGestureRecognizerToFail:pan];
    [_ball addGestureRecognizer:tap];

    [self placeBallFromPrefs];
    [_window addSubview:_ball];
}

- (UIButton *)makeButtonWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    b.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1.0];
    b.layer.cornerRadius = 8.0;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildMenu
{
    CGFloat w = kACMenuWidth;
    CGFloat h = 10 + 40 + 6 + 40 + 6 + 32 + 6 + 32 + 6 + 62 + 10;   // 250

    _menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    _menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    _menu.layer.cornerRadius = 12.0;
    _menu.layer.borderWidth = 1.0;
    _menu.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    _menu.hidden = YES;

    _aimBtn = [self makeButtonWithTitle:@"瞄准" action:@selector(onAimTapped:)];
    _aimBtn.frame = CGRectMake(10, 10, w - 20, 40);
    [_menu addSubview:_aimBtn];

    _startBtn = [self makeButtonWithTitle:@"开始" action:@selector(onStartTapped:)];
    _startBtn.frame = CGRectMake(10, 56, w - 20, 40);
    [_menu addSubview:_startBtn];

    _freqCtrl = [[UISegmentedControl alloc] initWithItems:@[@"10/s", @"20/s", @"30/s", @"50/s"]];
    _freqCtrl.frame = CGRectMake(10, 102, w - 20, 32);
    _freqCtrl.selectedSegmentIndex = _freqIndex;
    if (@available(iOS 13.0, *)) {
        _freqCtrl.selectedSegmentTintColor = [UIColor colorWithRed:0.20 green:0.52 blue:0.96 alpha:1.0];
    }
    [_freqCtrl addTarget:self action:@selector(onFreqChanged:) forControlEvents:UIControlEventValueChanged];
    [_menu addSubview:_freqCtrl];

    _showCtrl = [[UISegmentedControl alloc] initWithItems:@[@"仅京东显示", @"总是显示"]];
    _showCtrl.frame = CGRectMake(10, 140, w - 20, 32);
    _showCtrl.selectedSegmentIndex = _alwaysShow ? 1 : 0;
    if (@available(iOS 13.0, *)) {
        _showCtrl.selectedSegmentTintColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1.0];
    }
    [_showCtrl addTarget:self action:@selector(onShowChanged:) forControlEvents:UIControlEventValueChanged];
    [_menu addSubview:_showCtrl];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 178, w - 24, 62)];
    _statusLabel.numberOfLines = 5;
    _statusLabel.font = [UIFont systemFontOfSize:9.5];
    _statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [_menu addSubview:_statusLabel];

    [_window addSubview:_menu];
}

- (void)buildCrosshair
{
    _crosshair = [[ACCrosshairView alloc] initWithFrame:CGRectMake(0, 0, kACCrosshairSize, kACCrosshairSize)];
    _crosshair.center = _point;
    _crosshair.hidden = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onCrosshairPan:)];
    [_crosshair addGestureRecognizer:pan];
    [_window addSubview:_crosshair];
}

#pragma mark 持久化

- (NSArray<NSNumber *> *)freqPresets { return @[@10.0, @20.0, @30.0, @50.0]; }

- (double)currentFrequency
{
    NSArray<NSNumber *> *p = [self freqPresets];
    NSInteger i = MAX(0, MIN(_freqIndex, (NSInteger)p.count - 1));
    return p[i].doubleValue;
}

- (void)loadPrefs
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    _hasPoint = [d boolForKey:kACKeyAimed];
    CGFloat x = (CGFloat)[d doubleForKey:kACKeyPointX];
    CGFloat y = (CGFloat)[d doubleForKey:kACKeyPointY];
    if (!_hasPoint || (x == 0 && y == 0)) {
        CGSize s = [UIScreen mainScreen].bounds.size;
        _point = CGPointMake(s.width * 0.5, s.height * 0.55);
        _hasPoint = NO;
    } else {
        _point = CGPointMake(x, y);
    }

    double f = [d doubleForKey:kACKeyFreq];
    if (f <= 0) f = kACDefaultFreq;
    NSArray<NSNumber *> *presets = [self freqPresets];
    _freqIndex = 0;
    for (NSInteger i = 0; i < (NSInteger)presets.count; i++) {
        if (fabs(presets[i].doubleValue - f) < 0.01) { _freqIndex = i; break; }
    }

    // 首次运行默认「总是显示」。
    // 原因: 如果前台检测在某个 iOS 版本上不灵, 悬浮球会一直藏起来,
    // 而用户没法点到一个看不见的球去改成「总是显示」—— 死锁。
    // 所以先让它一定能看见, 用户确认检测灵了之后再自己切成「仅京东显示」。
    id alwaysPref = [d objectForKey:kACKeyAlways];
    _alwaysShow = (alwaysPref == nil) ? YES : [d boolForKey:kACKeyAlways];
}

- (void)savePoint
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:_point.x forKey:kACKeyPointX];
    [d setDouble:_point.y forKey:kACKeyPointY];
    [d setBool:YES forKey:kACKeyAimed];
    [d synchronize];
    _hasPoint = YES;
}

- (void)saveFrequency
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:[self currentFrequency] forKey:kACKeyFreq];
    [d synchronize];
}

- (void)saveBallCenter:(CGPoint)c
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:c.x forKey:kACKeyBallX];
    [d setDouble:c.y forKey:kACKeyBallY];
    [d synchronize];
}

- (void)placeBallFromPrefs
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGSize s = _window.bounds.size;
    CGFloat x = (CGFloat)[d doubleForKey:kACKeyBallX];
    CGFloat y = (CGFloat)[d doubleForKey:kACKeyBallY];
    if (x <= 0 || y <= 0) {
        x = s.width - kACBallSize * 0.5 - 12;
        y = s.height * 0.35;
    }
    _ball.center = [self clampPoint:CGPointMake(x, y) forSize:_ball.bounds.size];
}

#pragma mark 工具

- (CGPoint)clampPoint:(CGPoint)p forSize:(CGSize)size
{
    CGSize s = _window.bounds.size;
    CGFloat hw = size.width * 0.5, hh = size.height * 0.5;
    p.x = MAX(hw + kACMenuMargin, MIN(p.x, s.width  - hw - kACMenuMargin));
    p.y = MAX(hh + kACMenuMargin, MIN(p.y, s.height - hh - kACMenuMargin));
    return p;
}

- (BOOL)ballCoversPoint:(CGPoint)p
{
    return CGRectContainsPoint(CGRectInset(_ball.frame, -6, -6), p);
}

- (CGPoint)safeBallCenterAvoiding:(CGPoint)p
{
    CGSize s = _window.bounds.size;
    CGFloat x = (p.x < s.width * 0.5) ? (s.width - kACBallSize * 0.5 - 12)
                                      : (kACBallSize * 0.5 + 12);
    CGFloat y = (p.y < s.height * 0.5) ? (s.height - kACBallSize * 0.5 - 12)
                                       : (kACBallSize * 0.5 + 12);
    return [self clampPoint:CGPointMake(x, y) forSize:_ball.bounds.size];
}

#pragma mark 手势

- (void)onBallPan:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:_window];
    _ball.center = [self clampPoint:CGPointMake(_ball.center.x + t.x, _ball.center.y + t.y)
                            forSize:_ball.bounds.size];
    [g setTranslation:CGPointZero inView:_window];
    if (!_menu.hidden) [self positionMenu];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self saveBallCenter:_ball.center];
    }
}

- (void)onBallTap:(UITapGestureRecognizer *)g
{
    _menu.hidden = !_menu.hidden;
    if (!_menu.hidden) [self positionMenu];
    [self refreshUI];
}

- (void)onCrosshairPan:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:_window];
    _crosshair.center = [self clampPoint:CGPointMake(_crosshair.center.x + t.x,
                                                     _crosshair.center.y + t.y)
                                 forSize:_crosshair.bounds.size];
    [g setTranslation:CGPointZero inView:_window];
}

#pragma mark 菜单动作

- (void)onAimTapped:(UIButton *)b
{
    if ([ACClickEngine shared].running) { AC_LOG(@"请先停止连点再瞄准"); [self refreshUI]; return; }
    if (!_aiming) {
        _aiming = YES;
        _crosshair.hidden = NO;
        _crosshair.center = [self clampPoint:_point forSize:_crosshair.bounds.size];
        AC_LOG(@"进入瞄准模式: 拖动准星到目标位置后点「确认」");
    } else {
        _point = _crosshair.center;
        [self savePoint];
        [ACClickEngine shared].point = _point;
        _aiming = NO;
        _crosshair.hidden = YES;
        AC_LOG(@"已保存点击坐标: (%.0f, %.0f)", _point.x, _point.y);
    }
    [self refreshUI];
}

- (void)onStartTapped:(UIButton *)b
{
    ACClickEngine *eng = [ACClickEngine shared];

    if (eng.running) { [eng stop]; [self refreshUI]; return; }

    if (!_hasPoint) { AC_LOG(@"尚未保存准星坐标, 请先「瞄准」->「确认」"); [self refreshUI]; return; }

    // 关键: 系统级 HID 事件是按坐标投递的, 如果点击点正好被悬浮球盖住,
    // 事件会打到我们自己的球上 (球在 SpringBoard 窗口里, 层级更高)。
    // 所以重叠时自动把球挪到对角。
    if ([self ballCoversPoint:_point]) {
        CGPoint safe = [self safeBallCenterAvoiding:_point];
        _ball.center = safe;
        [self saveBallCenter:safe];
        if (!_menu.hidden) [self positionMenu];
        AC_LOG(@"悬浮球遮挡了点击点, 已自动移动到 (%.0f, %.0f)", safe.x, safe.y);
    }

    eng.point = _point;
    eng.frequency = [self currentFrequency];
    [eng start];
    [self refreshUI];
}

- (void)onFreqChanged:(UISegmentedControl *)c
{
    _freqIndex = c.selectedSegmentIndex;
    [self saveFrequency];
    ACClickEngine *eng = [ACClickEngine shared];
    eng.frequency = [self currentFrequency];
    if (eng.running) { [eng stop]; [eng start]; }
    [self refreshUI];
}

- (void)onShowChanged:(UISegmentedControl *)c
{
    _alwaysShow = (c.selectedSegmentIndex == 1);
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:_alwaysShow forKey:kACKeyAlways];
    [d synchronize];
    AC_LOG(@"显示模式: %@", _alwaysShow ? @"总是显示" : @"仅京东前台时显示");
    [self refreshUI];
}

#pragma mark 布局 / 刷新

- (void)positionMenu
{
    CGRect sb = _window.bounds;
    CGFloat mw = _menu.bounds.size.width, mh = _menu.bounds.size.height;
    CGFloat x = CGRectGetMaxX(_ball.frame) + 10;
    if (x + mw > sb.size.width - kACMenuMargin) x = CGRectGetMinX(_ball.frame) - 10 - mw;
    if (x < kACMenuMargin) x = kACMenuMargin;
    CGFloat y = CGRectGetMidY(_ball.frame) - mh * 0.5;
    y = MAX(kACMenuMargin, MIN(y, sb.size.height - mh - kACMenuMargin));
    _menu.frame = CGRectMake(x, y, mw, mh);
}

- (void)refreshUI
{
    ACClickEngine *eng = [ACClickEngine shared];
    ACTouchInjector *inj = [ACTouchInjector shared];
    BOOL running = eng.running;

    _ball.backgroundColor = running
        ? [UIColor colorWithRed:0.88 green:0.16 blue:0.16 alpha:0.95]
        : [UIColor colorWithWhite:0.20 alpha:0.92];
    _ball.layer.borderColor = (running
        ? [UIColor colorWithRed:1.0 green:0.55 blue:0.5 alpha:0.95]
        : [UIColor colorWithWhite:1.0 alpha:0.75]).CGColor;
    _ballLabel.text = running ? @"停" : @"连点";

    [_aimBtn setTitle:(_aiming ? @"确认" : @"瞄准") forState:UIControlStateNormal];
    _aimBtn.backgroundColor = _aiming
        ? [UIColor colorWithRed:0.95 green:0.55 blue:0.10 alpha:1.0]
        : [UIColor colorWithWhite:0.28 alpha:1.0];

    [_startBtn setTitle:(running ? @"停止" : @"开始") forState:UIControlStateNormal];
    _startBtn.backgroundColor = running
        ? [UIColor colorWithRed:0.78 green:0.14 blue:0.14 alpha:1.0]
        : [UIColor colorWithRed:0.16 green:0.46 blue:0.30 alpha:1.0];

    _freqCtrl.selectedSegmentIndex = _freqIndex;
    _showCtrl.selectedSegmentIndex = _alwaysShow ? 1 : 0;

    _statusLabel.text = [NSString stringWithFormat:
        @"坐标 %.0f, %.0f %@ | 频率 %.0f/s\n状态: %@\n%@: %@\nHID: %@",
        _point.x, _point.y,
        _hasPoint ? @"" : @"(未保存)",
        [self currentFrequency],
        running ? @"连点中" : (_aiming ? @"瞄准中" : @"待机"),
        kJDTargetName, _targetFront ? @"前台" : @"不在前台",
        inj.diagnostics ?: @"?"];
}

@end

// ===========================================================================
// MARK: - 入口
// ===========================================================================

__attribute__((constructor))
static void JDClickerInit(void)
{
    AC_LOG(@"constructor (dyld 初始化阶段)");
    AC_LOG(@"文件日志: %@", ACLogFilePath() ?: @"(写不进去, 只能看 syslog)");

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            AC_LOG(@"main 队列块执行");
            @try {
                [[ACOverlay shared] bootstrap];
            } @catch (NSException *e) {
                AC_LOG(@"bootstrap 异常: %@ - %@", e.name, e.reason);
            }
        }
    });
}
