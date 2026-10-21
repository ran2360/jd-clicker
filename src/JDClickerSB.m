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
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ===========================================================================
// MARK: - 可调参数
// ===========================================================================

static NSString * const kJDTargetBundle = @"com.360buy.jdmobile";   // 京东
static NSString * const kJDTargetName   = @"京东";

// 62 而不是 56: 满屏撒花/弹幕的背景下小球容易被"吃掉", 稍微放大一点更好找。
static const CGFloat kACBallSize      = 62.0;
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
// 手指事件 —— ★ 必须用 13 参数的 IOHIDEventCreateDigitizerFingerEvent,
//   不是 ...WithQuality。这是我之前(以及 BBProbe)用错的地方之一:
//   参数个数、字段、坐标含义都不同, 导致事件被系统直接丢弃。
typedef IOHIDEventRef (*ACCreateFingerEventFn)(CFAllocatorRef, ACAbsoluteTime,
                                               uint32_t, uint32_t, uint32_t,
                                               IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                               IOHIDFloat, IOHIDFloat,
                                               Boolean, Boolean, uint32_t);
// AppendEvent 其实是 3 参数的 (第三个是 options)。我之前只传 2 个,
// 第三个参数读到的是垃圾值, 可能让附加失败。
typedef void (*ACEventAppendEventFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*ACEventSetIntegerValueFn)(IOHIDEventRef, int32_t, int);
typedef void (*ACEventSetFloatValueFn)(IOHIDEventRef, int32_t, IOHIDFloat);
typedef void (*ACEventSetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemClientRef (*ACSystemClientCreateFn)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*ACSystemClientCreateWithTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);
typedef IOHIDEventSystemClientRef (*ACSystemClientCreateSimpleFn)(CFAllocatorRef);
typedef void (*ACSystemClientDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static ACCreateDigitizerEventFn         pCreateDigitizerEvent = NULL;
static ACCreateFingerEventFn            pCreateFingerEvent    = NULL;
static ACEventAppendEventFn             pEventAppendEvent     = NULL;
static ACEventSetIntegerValueFn         pEventSetIntegerValue = NULL;
static ACEventSetFloatValueFn           pEventSetFloatValue   = NULL;
static ACEventSetSenderIDFn             pEventSetSenderID     = NULL;
static ACSystemClientCreateFn           pSystemClientCreate   = NULL;
static ACSystemClientCreateWithTypeFn   pClientCreateWithType = NULL;
static ACSystemClientCreateSimpleFn     pClientCreateSimple   = NULL;
static ACSystemClientDispatchFn         pSystemClientDispatch = NULL;

// 给合成事件打的 sender id。实测方式1 (IOHIDEventSystemClientCreate + 这个固定
// senderID) 是唯一能真正点中屏幕的组合 —— 其它 client 类型/不带 senderID 都不行,
// 所以现在**只保留这一种**, 不再做可切换的菜单。
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
        AC_BIND(pCreateFingerEvent,    "IOHIDEventCreateDigitizerFingerEvent");
        AC_BIND(pEventAppendEvent,     "IOHIDEventAppendEvent");
        AC_BIND(pEventSetIntegerValue, "IOHIDEventSetIntegerValue");
        AC_BIND(pEventSetFloatValue,   "IOHIDEventSetFloatValue");
        AC_BIND(pEventSetSenderID,     "IOHIDEventSetSenderID");
        AC_BIND(pSystemClientCreate,   "IOHIDEventSystemClientCreate");
        AC_BIND(pClientCreateWithType, "IOHIDEventSystemClientCreateWithType");
        AC_BIND(pClientCreateSimple,   "IOHIDEventSystemClientCreateSimpleClient");
        AC_BIND(pSystemClientDispatch, "IOHIDEventSystemClientDispatchEvent");
        #undef AC_BIND
        AC_LOG(@"IOKit 符号: digitizer=%@ finger=%@ append=%@ setInt=%@ setFloat=%@ setSender=%@",
               pCreateDigitizerEvent ? @"有" : @"无",
               pCreateFingerEvent ? @"有" : @"无",
               pEventAppendEvent ? @"有" : @"无",
               pEventSetIntegerValue ? @"有" : @"无",
               pEventSetFloatValue ? @"有" : @"无",
               pEventSetSenderID ? @"有" : @"无");
        AC_LOG(@"IOKit client: Create=%@ CreateWithType=%@ CreateSimple=%@ dispatch=%@",
               pSystemClientCreate ? @"有" : @"无",
               pClientCreateWithType ? @"有" : @"无",
               pClientCreateSimple ? @"有" : @"无",
               pSystemClientDispatch ? @"有" : @"无");
    });
}

// 屏幕的 fixedCoordinateSpace 尺寸 (点)。手机始终以竖屏 home 为基准,
// 所以 fixed space = 430x932, 与窗口坐标一致, 拿来当归一化的分母最合适。
static CGSize ACScreenFixedSize(void)
{
    @try {
        UIScreen *s = [UIScreen mainScreen];
        if (s) {
            CGSize sz = s.fixedCoordinateSpace.bounds.size;
            if (sz.width > 0 && sz.height > 0) return sz;
        }
    } @catch (NSException *e) { }
    return CGSizeMake(430, 932);
}

// 一个 "手 + 手指" 事件。按 ios-mcp 的**已验证可用**配方构造 (之前那版事件
// 构造错了、坐标也错了, 是"派发毫无反应"的真正原因):
//   1. 坐标**归一化到 0~1** (x/屏宽, y/屏高) —— 之前传点/像素彻底飞出屏幕;
//   2. 手指用 13 参数的 IOHIDEventCreateDigitizerFingerEvent (不是 WithQuality);
//   3. 手事件 index=99, identity=1, eventMask=0;
//   4. 补上 digitizer 字段 0x4 / 0xb0007 / 0xb0008 / 0xb0009 / 0xb0014 / 0xb0015。
static IOHIDEventRef ACCreateHIDEvent(CGPoint point, UITouchPhase phase, BOOL useSenderID)
{
    if (!pCreateDigitizerEvent || !pCreateFingerEvent) return NULL;

    uint64_t abTime = mach_absolute_time();
    ACAbsoluteTime ts;
    ts.lo = (uint32_t)abTime;
    ts.hi = (uint32_t)(abTime >> 32);

    IOHIDEventRef hand = pCreateDigitizerEvent(kCFAllocatorDefault, ts,
                                               kACTransducerTypeHand,
                                               99, 1, 0, 0,
                                               0, 0, 0, 0, 0,
                                               0, 0, 0);
    if (!hand) return NULL;
    if (pEventSetIntegerValue) {
        pEventSetIntegerValue(hand, kACFieldDigitizerIsDisplayIntegrated, 1);   // 0xb0019
        pEventSetIntegerValue(hand, 0x4, 1);
    }

    uint32_t mask = 0; BOOL range = YES, touch = YES;
    switch (phase) {
        case UITouchPhaseBegan:
            mask = kACDigitizerEventRange | kACDigitizerEventTouch; range = YES; touch = YES; break;
        case UITouchPhaseMoved:
            mask = kACDigitizerEventPosition;                         range = YES; touch = YES; break;
        case UITouchPhaseEnded:
            mask = kACDigitizerEventTouch;                            range = NO;  touch = NO;  break;
        default:
            mask = kACDigitizerEventRange | kACDigitizerEventTouch;   range = YES; touch = YES; break;
    }

    CGSize sz = ACScreenFixedSize();
    IOHIDFloat nx = (sz.width  > 0) ? (IOHIDFloat)(point.x / sz.width)  : 0.0;
    IOHIDFloat ny = (sz.height > 0) ? (IOHIDFloat)(point.y / sz.height) : 0.0;

    IOHIDEventRef finger = pCreateFingerEvent(kCFAllocatorDefault, ts,
                                              1, 3, mask,
                                              nx, ny, 0.0,
                                              0.0, 0.0,
                                              range, touch, 0);
    if (!finger) { CFRelease(hand); return NULL; }
    if (pEventSetFloatValue) {
        pEventSetFloatValue(finger, 0xb0014, 0.04);   // 接触半径
        pEventSetFloatValue(finger, 0xb0015, 0.04);
    }

    if (pEventAppendEvent) pEventAppendEvent(hand, finger, 0);
    CFRelease(finger);

    if (pEventSetIntegerValue) {
        pEventSetIntegerValue(hand, 0xb0007, 0x23);
        pEventSetIntegerValue(hand, 0xb0008, 0x1);
        pEventSetIntegerValue(hand, 0xb0009, 0x1);
    }
    if (useSenderID && pEventSetSenderID) {
        pEventSetSenderID(hand, kACSyntheticSenderID);
    }
    return hand;
}

// ===========================================================================
// MARK: - 注入器 (只有 HID 一条路)
// ===========================================================================

@interface ACTouchInjector : NSObject
@property (nonatomic, assign, readonly) BOOL ready;
@property (nonatomic, readonly) NSString *diagnostics;
@property (nonatomic, readonly) NSString *clientKind;
+ (instancetype)shared;
- (void)prepare;
- (void)tapAtPoint:(CGPoint)point phaseDelay:(useconds_t)phaseDelayUs;
@end

@implementation ACTouchInjector
{
    IOHIDEventSystemClientRef _client;
    NSString                 *_clientKind;
    NSInteger                 _dispatchCount;
}

+ (instancetype)shared
{
    static ACTouchInjector *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ACTouchInjector new]; });
    return s;
}

- (NSString *)clientKind { return _clientKind ?: @"(无)"; }

- (NSString *)diagnostics
{
    if (pSystemClientDispatch == NULL) return @"缺少 IOHIDEventSystemClientDispatchEvent";
    if (pCreateDigitizerEvent == NULL || pCreateFingerEvent == NULL) return @"缺少 IOHID 事件构造符号";
    if (_client == NULL) return [NSString stringWithFormat:@"client 创建失败 (%@)", self.clientKind];
    return [NSString stringWithFormat:@"已就绪 / %@", self.clientKind];
}

// 只建一种 client: IOHIDEventSystemClientCreate + 固定 senderID。
// 这是实测唯一能真正点中屏幕的组合, 所以不再做可切换的多种方式。
- (void)buildClient
{
    ACLoadIOHIDSymbols();
    _client = NULL;
    _clientKind = @"IOHIDEventSystemClientCreate + 固定 senderID";

    if (pSystemClientCreate) {
        _client = pSystemClientCreate(kCFAllocatorDefault);
    }
    BOOL ok = self.ready;
    AC_LOG(@"注入器: ready=%@  ->  %@", ok ? @"YES" : @"NO", _clientKind);
}

- (void)prepare
{
    [self buildClient];
    _dispatchCount = 0;
}

- (BOOL)ready
{
    return (_client != NULL && pSystemClientDispatch != NULL &&
            pCreateDigitizerEvent != NULL && pCreateFingerEvent != NULL);
}

- (void)tapAtPoint:(CGPoint)point phaseDelay:(useconds_t)phaseDelayUs
{
    if (!self.ready) return;

    _dispatchCount++;

    @try {
        // 一次点击 = 按下 -> 移动 -> 抬起。
        //
        // ★ 这里的间隔直接决定了**有效频率上限** ★
        //   最初各隔 50ms, 一次点击固定耗时 ~100ms, 于是 10/20/30/50 全都塌缩成
        //   ~10 次/秒 —— 这就是"设什么频率都一样"的根本原因(不是 iOS 的硬性上限)。
        //   现在由调用方按频率算好传进来: 10~50/s 用 6ms, 100/s 自动压到 ~2.5ms,
        //   这样 10/20/30/50/100 五档才都能真正跑到。
        //   仍然保留很短的间隔(不是 0), 是为了让 down/move/up 成为三个可区分的事件,
        //   否则会被系统合并掉 —— 这一点是实测得出的, 不能去掉。
        const useconds_t d = phaseDelayUs ?: (6 * 1000);

        IOHIDEventRef began = ACCreateHIDEvent(point, UITouchPhaseBegan, YES);
        if (began) { pSystemClientDispatch(_client, began); CFRelease(began); }
        usleep(d);

        IOHIDEventRef moved = ACCreateHIDEvent(point, UITouchPhaseMoved, YES);
        if (moved) { pSystemClientDispatch(_client, moved); CFRelease(moved); }
        usleep(d);

        IOHIDEventRef ended = ACCreateHIDEvent(point, UITouchPhaseEnded, YES);
        if (ended) { pSystemClientDispatch(_client, ended); CFRelease(ended); }

        if (_dispatchCount <= 4) {
            CGSize sz = ACScreenFixedSize();
            AC_LOG(@"派发 #%ld: 点=(%.0f, %.0f) 归一化=(%.4f, %.4f) 屏=%.0fx%.0f 相位间隔=%ldus began/moved/ended=%@/%@/%@ client=%@",
                   (long)_dispatchCount, point.x, point.y,
                   sz.width > 0 ? point.x / sz.width : 0.0,
                   sz.height > 0 ? point.y / sz.height : 0.0,
                   sz.width, sz.height, (long)d,
                   began ? @"建好" : @"失败", moved ? @"建好" : @"失败", ended ? @"建好" : @"失败",
                   self.clientKind);
        }
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

// 前台检测的结果。之所以分三态而不是 BOOL:
//   "明确不是前台" 和 "我根本查不出来" 是两回事 ——
//   后者必须走兜底把球显示出来, 否则用户会点不到一个看不见的球而被锁在外面。
typedef NS_ENUM(NSInteger, ACFrontProbe) {
    ACFrontProbeUnknown = -1,
    ACFrontProbeNo      =  0,
    ACFrontProbeYes     =  1,
};

#pragma mark - 安全的私有 API 调用

static id ACSharedInstanceOf(NSString *cls)
{
    Class c = NSClassFromString(cls);
    if (!c) return nil;
    SEL s = NSSelectorFromString(@"sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, s);
}

static id ACCallObj1(id obj, NSString *sel, id arg)
{
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, s, arg);
}

static NSInteger ACCallInt(id obj, NSString *sel, BOOL *ok)
{
    SEL s = NSSelectorFromString(sel);
    if (ok) *ok = NO;
    if (!obj || ![obj respondsToSelector:s]) return 0;
    if (ok) *ok = YES;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, s);
}

static BOOL ACCallBool(id obj, NSString *sel, BOOL *ok)
{
    SEL s = NSSelectorFromString(sel);
    if (ok) *ok = NO;
    if (!obj || ![obj respondsToSelector:s]) return NO;
    if (ok) *ok = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
}

static id ACKVC(id obj, NSString *key)
{
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// 读一个 SBApplication 的两个进程状态字段 (processState / _internalProcessState)。
static void ACReadAppStates(id app, NSInteger *pub, BOOL *pubOK,
                            NSInteger *inn, BOOL *innOK)
{
    if (pub)   *pub = ACCallInt(app, @"processState", pubOK);
    if (inn)   *inn = ACCallInt(app, @"_internalProcessState", innOK);
}

#pragma mark - 前台检测

static id ACTargetSBApplication(void)
{
    return ACCallObj1(ACSharedInstanceOf(@"SBApplicationController"),
                      @"applicationWithBundleIdentifier:", kJDTargetBundle);
}

// 通过 SBSceneManager.externalForegroundApplicationSceneHandles 拿到当前**前台**应用的
// scene handle 集合, 逐个提取 bundle id。
// 这是 iOS 16 上判断"前台应用"的权威来源 —— 实测 SBApplication.processState 返回的是
// 十亿级别的指针/结构体 (不是小枚举), 那个路径根本不能用。
//
// 关键坑 (1.0.2028 修): coordinator 的 `_sceneManager` KVC 返回的是 **FBSceneManager**
// (基类), 它**没有** externalForegroundApplicationSceneHandles 方法 —— 那个方法是
// **SBSceneManager**(子类) 上的。所以必须用 `sceneManagerForDisplayIdentity:` 或枚举
// 才能拿到真正的 SBSceneManager 实例。
static id ACGetSBSceneManager(id coord)
{
    if (!coord) return nil;

    // 单例缓存: SBSceneManager 在 SpringBoard 整个生命周期内不变, 不用每次反射查找。
    static id sCachedManager = nil;
    if (sCachedManager) return sCachedManager;

    SEL fgSel = NSSelectorFromString(@"externalForegroundApplicationSceneHandles");

    // 方法1: _displayIdentityToReferenceMap 的 key 就是 display identity,
    //        用它调 sceneManagerForDisplayIdentity: 拿 SBSceneManager。
    id refMap = ACKVC(coord, @"_displayIdentityToReferenceMap");
    if (refMap && [refMap respondsToSelector:@selector(allKeys)]) {
        NSArray *keys = [refMap performSelector:@selector(allKeys)];
        for (id key in keys) {
            id m = ACCallObj1(coord, @"sceneManagerForDisplayIdentity:", key);
            if (m && [m respondsToSelector:fgSel]) { sCachedManager = m; return m; }
        }
    }

    // 方法2: 枚举 (不依赖 display identity)。用 @try 包住, 防止 block 签名差异导致崩溃。
    SEL enumSel = NSSelectorFromString(@"enumerateSceneManagersWithBlock:");
    if ([coord respondsToSelector:enumSel]) {
        __block id found = nil;
        void (^blk)(id) = ^(id m) {
            if (m && [m respondsToSelector:fgSel] && !found) found = m;
        };
        @try {
            ((void (*)(id, SEL, void *))objc_msgSend)(coord, enumSel, (__bridge void *)blk);
        } @catch (NSException *e) {
            AC_LOG(@"检测: enumerateSceneManagersWithBlock 异常: %@", e.reason);
        }
        if (found) { sCachedManager = found; return found; }
    }

    // 方法3: 老 KVC 键兜底, 只收下"真的响应 externalForegroundApplicationSceneHandles"的那个。
    for (NSString *key in @[@"_sceneManager", @"sceneManager",
                            @"mainDisplaySceneManager", @"mainSceneManager",
                            @"_mainDisplaySceneManager", @"_mainSceneManager"]) {
        id m = ACKVC(coord, key);
        if (m && [m respondsToSelector:fgSel]) { sCachedManager = m; return m; }
    }
    return nil;
}

static NSSet *ACForegroundBundleIDsViaScenes(BOOL verbose)
{
    // coordinator 也是单例, 缓存起来省一次反射查找。
    static id sCachedCoordinator = nil;
    if (!sCachedCoordinator) {
        sCachedCoordinator = ACSharedInstanceOf(@"SBSceneManagerCoordinator");
    }
    id coord = sCachedCoordinator;
    if (!coord) { if (verbose) AC_LOG(@"检测: 没有 SBSceneManagerCoordinator"); return nil; }

    id mgr = ACGetSBSceneManager(coord);
    if (!mgr) {
        if (verbose) AC_LOG(@"检测: 拿不到带 externalForegroundApplicationSceneHandles 的 SBSceneManager");
        return nil;
    }
    if (verbose) AC_LOG(@"检测: 场景管理器 = %@", NSStringFromClass([mgr class]));

    id handles = ACKVC(mgr, @"externalForegroundApplicationSceneHandles");
    if (verbose) AC_LOG(@"检测: externalForegroundApplicationSceneHandles = %@",
                        handles ? NSStringFromClass([handles class]) : @"nil");
    // 1.0.2029 修: 拿到 SBSceneManager 但 handles == nil —— 这表示**当前没有外部应用在前台**
    // (回到了 SpringBoard 桌面 / 锁屏)。桌面不是京东, 所以返回**空集**而不是 nil:
    // 返回 nil 会退回 processState 兜底, 而该设备 processState 是十亿级指针永远判"未知",
    // 未知又按"显示"处理 → 球在桌面不消失。空集让上层判定"不在前台"→ 隐藏。
    if (!handles) return [NSSet set];

    NSArray *array = handles;
    if ([handles respondsToSelector:@selector(allObjects)]) {
        array = [handles performSelector:@selector(allObjects)];
    }
    if (![array isKindOfClass:[NSArray class]]) return nil;

    NSMutableSet *bids = [NSMutableSet set];
    for (id handle in array) {
        if (verbose) AC_LOG(@"检测:   前台句柄 = %@", NSStringFromClass([handle class]));

        // 提取 bundle id 的多条路径, 从最直接到最兜底:
        //   1. handle.application.bundleIdentifier (SBApplicationSceneHandle.application)
        //   2. handle.clientSettings.preferredSceneHostIdentifier (前台 app 场景的权威 host id)
        //   3. handle.applicationProcess / processIdentity 链
        id bid = nil;

        id app = ACKVC(handle, @"application");
        if (!app) app = ACKVC(handle, @"_application");
        if (app) bid = ACKVC(app, @"bundleIdentifier");

        if (!bid || ![bid isKindOfClass:[NSString class]]) {
            id cs = ACKVC(handle, @"clientSettings");
            id host = ACKVC(cs, @"preferredSceneHostIdentifier");
            if ([host isKindOfClass:[NSString class]]) bid = host;
        }

        if (!bid || ![bid isKindOfClass:[NSString class]]) {
            id scene = ACKVC(handle, @"sceneIfExists");
            if (!scene) scene = ACKVC(handle, @"scene");
            id sa = ACKVC(scene, @"application");
            if (sa) bid = ACKVC(sa, @"bundleIdentifier");
        }

        if (!bid || ![bid isKindOfClass:[NSString class]]) {
            id ident = ACKVC(handle, @"processIdentity");
            if (!ident) ident = ACKVC(app, @"processIdentity");
            bid = ACKVC(ident, @"bundleIdentifier");
        }

        if (bid && [bid isKindOfClass:[NSString class]] && [bid length]) {
            [bids addObject:bid];
            if (verbose) AC_LOG(@"检测:   前台 bundle id = %@", bid);
        }
    }
    if (verbose) AC_LOG(@"检测: 前台应用 = %@", [bids allObjects]);
    return bids;
}

static ACFrontProbe ACProbeTargetFrontmost(BOOL verbose)
{
    // 首选: 场景句柄 (权威, 干净的是/否)
    NSSet *fgbids = ACForegroundBundleIDsViaScenes(verbose);
    if (fgbids) {
        return [fgbids containsObject:kJDTargetBundle] ? ACFrontProbeYes : ACFrontProbeNo;
    }

    // 退回: SBApplicationController + processState (这台设备上 processState 是大数, 基本不可用)
    Class ctrlC = NSClassFromString(@"SBApplicationController");
    id ctrl = ACSharedInstanceOf(@"SBApplicationController");
    if (!ctrlC || !ctrl ||
        ![ctrl respondsToSelector:NSSelectorFromString(@"applicationWithBundleIdentifier:")]) {
        if (verbose) AC_LOG(@"检测: SBApplicationController 这条链不可用 -> 未知");
        return ACFrontProbeUnknown;
    }

    id app = ACTargetSBApplication();
    if (!app) {
        if (verbose) AC_LOG(@"检测: 查不到 %@ 的 app 对象 -> 未知", kJDTargetBundle);
        return ACFrontProbeUnknown;   // 关键: 查不到就按"未知"处理, 走兜底显示球
    }

    BOOL ok = NO;
    BOOL front = ACCallBool(app, @"isFrontmost", &ok);
    if (ok) {
        if (verbose) AC_LOG(@"检测: isFrontmost = %@", front ? @"YES" : @"NO");
        return front ? ACFrontProbeYes : ACFrontProbeNo;
    }

    // 两个状态字段都读一遍 (processState 实测是大数, _internalProcessState 才是小枚举)
    BOOL okPub = NO, okInn = NO;
    NSInteger pub = 0, inn = 0;
    ACReadAppStates(app, &pub, &okPub, &inn, &okInn);
    if (verbose) {
        AC_LOG(@"检测: processState=%ld (%@)  _internalProcessState=%ld (%@)",
               (long)pub, okPub ? @"可读" : @"无",
               (long)inn, okInn ? @"可读" : @"无");
    }

    // 用 _internalProcessState 判定 (如果它真的是小枚举)
    if (okInn && inn >= 0 && inn <= 8) {
        return (inn == kSBProcessStateForeground) ? ACFrontProbeYes : ACFrontProbeNo;
    }
    // 退一步: processState 也只有在小范围内才拿来做判定
    if (okPub && pub >= 0 && pub <= 8) {
        return (pub == kSBProcessStateForeground) ? ACFrontProbeYes : ACFrontProbeNo;
    }
    // 拿到的都不是小枚举 -> 说明这套判定方式在这台设备上不适用, 交给兜底
    if (verbose) AC_LOG(@"检测: 两个状态字段都不是小枚举, 无法判定 -> 未知");

    BOOL run = ACCallBool(app, @"isRunning", &ok);
    if (ok) {
        if (verbose) AC_LOG(@"检测: isRunning = %@", run ? @"YES" : @"NO");
        return run ? ACFrontProbeYes : ACFrontProbeNo;
    }
    return ACFrontProbeUnknown;
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

    // 按下/移动/抬起之间的间隔, 必须小于「点击间隔」才跑得满设定频率:
    //   10/20/30/50 次每秒 -> 间隔 100/50/33/20ms, 6ms×2 完全够;
    //   100 次每秒        -> 间隔只有 10ms, 6ms×2 会超时, 必须压到 ~2.5ms。
    double phaseDelay = 0.006;
    if (interval < 0.015) {
        phaseDelay = MAX(0.0015, interval * 0.25);
    }
    const useconds_t phaseDelayUs = (useconds_t)(phaseDelay * 1e6);

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
        [[ACTouchInjector shared] tapAtPoint:p phaseDelay:phaseDelayUs];
        dispatch_semaphore_signal(slot);
    });
    dispatch_resume(_timer);

    AC_LOG(@"开始连点: 位置=(%.0f, %.0f) 频率=%.0f/s 相位间隔=%ldus", p.x, p.y, f, (long)phaseDelayUs);
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
/// 连点运行中: 在球外面套一圈扩散的脉冲光环, 让它在满屏撒花/弹幕里也能一眼找到。
- (void)setPulsing:(BOOL)pulsing;
@end

@implementation ACBallView
{
    CAShapeLayer *_pulse;
    BOOL          _pulsing;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        // 脉冲光环: 一个椭圆描边层, 动画时整体放大 + 淡出。
        // 放在球体的 layer 里而不是外面的容器, 因为 UIView 默认 masksToBounds=NO,
        // 子层可以画到 bounds 之外, 所以光环能扩散到球外一圈。
        _pulse = [CAShapeLayer layer];
        _pulse.frame       = self.bounds;
        _pulse.path        = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 1.5, 1.5)].CGPath;
        _pulse.fillColor   = [UIColor clearColor].CGColor;
        _pulse.strokeColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.35 alpha:1.0].CGColor;
        _pulse.lineWidth   = 3.0;
        _pulse.opacity     = 0.0;
        _pulse.hidden      = YES;
        [self.layer addSublayer:_pulse];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _pulse.frame = self.bounds;
    _pulse.path  = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 1.5, 1.5)].CGPath;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    // 视觉 62pt, 但只有中间 52pt 接手指。
    // 理由: 球是 SpringBoard 的系统窗口, 命中优先级高于京东。如果准星标定的点击
    // 坐标刚好落在球身上, 我们注入的那一下 HID 触摸会被自己的球接住、送不到京东,
    // 等于白点一次。把热区收得比视觉小一圈, "看得见" 和 "不吞自己的点击" 就都有了。
    return CGRectContainsPoint(CGRectInset(self.bounds, 5, 5), point);
}

- (void)setPulsing:(BOOL)pulsing
{
    if (pulsing == _pulsing) return;
    _pulsing = pulsing;

    if (!pulsing) {
        [_pulse removeAnimationForKey:@"pulse"];
        _pulse.hidden  = YES;
        _pulse.opacity = 0.0;
        return;
    }

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @(1.0);
    scale.toValue   = @(1.85);

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(0.95);
    fade.toValue   = @(0.0);

    CAAnimationGroup *g = [CAAnimationGroup animation];
    g.animations  = @[scale, fade];
    g.duration    = 0.9;
    g.repeatCount = HUGE_VALF;
    // 显式给 beginTime, 否则重复加动画时会排队、光环越来越密
    g.beginTime   = CACurrentMediaTime();

    _pulse.hidden = NO;
    _pulse.opacity = 0.95;
    [_pulse addAnimation:g forKey:@"pulse"];
}

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
    UIButton            *_confirmBtn;      // 瞄准时替代菜单的「确认」小按钮
    UILabel             *_statusLabel;
    ACCrosshairView     *_crosshair;

    BOOL                 _aiming;
    CGPoint              _point;
    BOOL                 _hasPoint;
    NSInteger            _freqIndex;
    BOOL                 _targetFront;
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
    [self buildConfirmButton];
    [self buildCrosshair];
    [self refreshUI];

    _window.hidden = YES;                 // 先藏起来, 由可见性调度器决定

    // 可见性: 自适应轮询。球隐藏(京东不在前台)时用 1.5s 低频省电,
    // 球显示时用 0.5s 及时响应切走。用 dispatch_after 链代替固定 NSTimer。
    [self scheduleNextVisTick];
    AC_LOG(@"悬浮窗已安装(SpringBoard): 窗口=%.0fx%.0f 球心=(%.0f, %.0f) level=%.0f",
           _window.bounds.size.width, _window.bounds.size.height,
           _ball.center.x, _ball.center.y, _window.windowLevel);
    AC_LOG(@"默认位置: 屏幕右侧贴边, 距顶部约 1/3 处, 深灰圆 + 白字「连点」");
    return YES;
}

// 自适应轮询调度: 球隐藏(京东不在前台)时用低频 1.5s 省电, 显示时用 0.5s 及时响应。
// 用 dispatch_after 链式调度, 每次 tick 后根据当前显隐状态决定下一次的间隔。
- (void)scheduleNextVisTick
{
    if (!_window) return;
    NSTimeInterval interval = _window.hidden ? 1.5 : 0.5;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf onVisTick];
    });
}

- (void)onVisTick
{
    ACFrontProbe probe = ACProbeTargetFrontmost(NO);
    BOOL front = (probe == ACFrontProbeYes);

    // 「仅京东显示」: 只有**确认**京东在前台时才显示;
    // 检测手段不可用(未知)时**也显示**, 免得球藏起来后用户点不到它 (1.0.10 的教训)。
    BOOL shouldShow = (probe != ACFrontProbeNo);

    if (front != _targetFront) {
        _targetFront = front;
        AC_LOG(@"%@ 前后台状态: %@ (检测结果=%@)", kJDTargetName,
               front ? @"前台" : @"不在前台",
               probe == ACFrontProbeYes ? @"是" :
               (probe == ACFrontProbeNo ? @"否" : @"未知"));
        [self refreshUI];
    }

    BOOL wantHidden = !shouldShow;
    if (_window.hidden != wantHidden) {
        _window.hidden = wantHidden;
        if (!wantHidden) AC_LOG(@"悬浮球已显示");
        else AC_LOG(@"悬浮球已隐藏");
    }

    [self scheduleNextVisTick];
}

#pragma mark 构建 UI

- (void)buildBall
{
    _ball = [[ACBallView alloc] initWithFrame:CGRectMake(0, 0, kACBallSize, kACBallSize)];
    // ★ 不透明 + 白色粗描边 + 四周均匀黑影 ★
    //   球本身就在 SpringBoard 的窗口里, 层级远高于京东的界面, 所以撒花/弹幕
    //   在物理上盖不住它 —— 真正的问题是它太暗太素, 在花哨背景里"看不见"。
    //   白描边负责在暗背景上立住, 黑影晕负责在亮背景上立住, 两边都不会糊。
    _ball.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    _ball.layer.cornerRadius = kACBallSize * 0.5;
    _ball.layer.borderWidth = 3.0;
    _ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:1.0].CGColor;
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOpacity = 0.85;
    _ball.layer.shadowRadius = 7.0;
    _ball.layer.shadowOffset = CGSizeZero;
    // 给阴影一条固定的 path: 球要跟着手指拖、而且在 100/s 下一直有脉冲动画,
    // 不指定 path 的话每帧都要重新算 alpha 遮罩, 白烧 CPU(费电)。
    _ball.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:_ball.bounds cornerRadius:kACBallSize * 0.5].CGPath;
    _ball.userInteractionEnabled = YES;

    _ballLabel = [[UILabel alloc] initWithFrame:_ball.bounds];
    _ballLabel.textAlignment = NSTextAlignmentCenter;
    _ballLabel.textColor = [UIColor whiteColor];
    _ballLabel.font = [UIFont boldSystemFontOfSize:16.0];
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
    // 去掉「派发方式」那一行后, 高度相应减掉 38
    CGFloat h = 10 + 40 + 6 + 40 + 6 + 32 + 6 + 78 + 10;   // 228

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

    _freqCtrl = [[UISegmentedControl alloc] initWithItems:@[@"10/s", @"20/s", @"30/s", @"50/s", @"100/s"]];
    _freqCtrl.frame = CGRectMake(10, 102, w - 20, 32);
    _freqCtrl.selectedSegmentIndex = _freqIndex;
    // ★ 深色面板上必须显式把分段控件的文字设成白色 ★
    //   默认是系统黑色文字, 压在 0.12 的深灰面板上几乎看不见。
    //   5 段挤在 210pt 里, 字号收到 11.5 才不至于把 "100/s" 挤变形。
    NSDictionary *segTextAttrs = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5],
    };
    [_freqCtrl setTitleTextAttributes:segTextAttrs forState:UIControlStateNormal];
    [_freqCtrl setTitleTextAttributes:segTextAttrs forState:UIControlStateSelected];
    _freqCtrl.backgroundColor = [UIColor colorWithWhite:0.26 alpha:1.0];   // 给白字一个可读的底
    if (@available(iOS 13.0, *)) {
        _freqCtrl.selectedSegmentTintColor = [UIColor colorWithRed:0.20 green:0.52 blue:0.96 alpha:1.0];
    }
    [_freqCtrl addTarget:self action:@selector(onFreqChanged:) forControlEvents:UIControlEventValueChanged];
    [_menu addSubview:_freqCtrl];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 140, w - 24, 78)];
    _statusLabel.numberOfLines = 6;
    _statusLabel.font = [UIFont systemFontOfSize:9.5];
    _statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [_menu addSubview:_statusLabel];

    [_window addSubview:_menu];
}

// 瞄准时用的「确认」小按钮: 面板收起后, 这是唯一还能点确认的地方。
// 默认放屏幕底部中间, 并且**可以拖动** —— 免得它正好挡住要瞄准的位置。
- (void)buildConfirmButton
{
    _confirmBtn = [self makeButtonWithTitle:@"确认" action:@selector(onConfirmTapped:)];
    _confirmBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.10 alpha:0.95];
    _confirmBtn.frame = CGRectMake(0, 0, 100, 44);
    CGSize sb = _window.bounds.size;
    _confirmBtn.center = CGPointMake(sb.width * 0.5, sb.height - 80);
    _confirmBtn.hidden = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onConfirmPan:)];
    [_confirmBtn addGestureRecognizer:pan];
    [_window addSubview:_confirmBtn];
}

- (void)onConfirmPan:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:_window];
    _confirmBtn.center = [self clampPoint:CGPointMake(_confirmBtn.center.x + t.x,
                                                       _confirmBtn.center.y + t.y)
                                   forSize:_confirmBtn.bounds.size];
    [g setTranslation:CGPointZero inView:_window];
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

- (NSArray<NSNumber *> *)freqPresets { return @[@10.0, @20.0, @30.0, @50.0, @100.0]; }

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
    if (_aiming) {
        // 瞄准中再点球 = 取消瞄准
        _aiming = NO;
        _crosshair.hidden = YES;
        _confirmBtn.hidden = YES;
        _menu.hidden = NO;
        [self positionMenu];
        AC_LOG(@"已取消瞄准");
    } else {
        _menu.hidden = !_menu.hidden;
        if (!_menu.hidden) [self positionMenu];
    }
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
    if (_aiming) return;

    _aiming = YES;
    _crosshair.hidden = NO;
    _crosshair.center = [self clampPoint:_point forSize:_crosshair.bounds.size];
    _menu.hidden = YES;               // ★ 收起面板, 不挡视野
    _confirmBtn.hidden = NO;          // ★ 用屏幕底部的小「确认」按钮来确认
    AC_LOG(@"进入瞄准模式: 面板已收起, 拖动准星后点底部「确认」(点悬浮球可取消)");
    [self refreshUI];
}

- (void)onConfirmTapped:(UIButton *)b
{
    if (!_aiming) return;
    _point = _crosshair.center;
    [self savePoint];
    [ACClickEngine shared].point = _point;
    _aiming = NO;
    _crosshair.hidden = YES;
    _confirmBtn.hidden = YES;
    AC_LOG(@"已保存点击坐标: (%.0f, %.0f)", _point.x, _point.y);
    _menu.hidden = NO;                // 确认后重新打开菜单, 方便直接点「开始」
    [self positionMenu];
    [self refreshUI];
}

- (void)onStartTapped:(UIButton *)b
{
    ACClickEngine *eng = [ACClickEngine shared];

    if (eng.running) {
        [eng stop];
        _menu.hidden = YES;              // 停止后也把面板收起来, 保持屏幕干净
        [self refreshUI];
        return;
    }

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

    // ★ 关键诊断: 检查点击点是不是被我们自己的悬浮层挡住了。
    //   系统级 HID 事件是按坐标投递的, 而我们的窗口是全屏的、层级 3000。
    //   如果这个坐标被自己的视图命中, 触摸就会被我们吃掉, 打不到京东。
    UIView *hit = [_window hitTest:_point withEvent:nil];
    if (hit) {
        AC_LOG(@"!! 点击点 (%.0f, %.0f) 被自己的悬浮层挡住了: %@",
               _point.x, _point.y, NSStringFromClass([hit class]));
        AC_LOG(@"!! 触摸会打在这个视图上而不是京东 —— 请把准星移到没有被球/菜单覆盖的位置。");
    } else {
        AC_LOG(@"点击点 (%.0f, %.0f) 未被悬浮层命中 (hitTest=nil, 触摸可以穿过)",
               _point.x, _point.y);
    }

    eng.point = _point;
    eng.frequency = [self currentFrequency];
    [eng start];
    _menu.hidden = YES;                  // ★ 开始后收起面板, 不挡连点区域
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
        ? [UIColor colorWithRed:0.90 green:0.13 blue:0.11 alpha:1.0]
        : [UIColor colorWithWhite:0.16 alpha:1.0];
    _ball.layer.borderColor = (running
        ? [UIColor colorWithRed:1.0 green:0.94 blue:0.60 alpha:1.0]
        : [UIColor colorWithWhite:1.0 alpha:1.0]).CGColor;
    _ballLabel.text = running ? @"停" : @"连点";
    // 运行中套一圈黄色脉冲光环 —— 满屏撒花时靠这圈扩散的光最容易定位
    [_ball setPulsing:running];

    // 瞄准按钮始终是「瞄准」; 确认的动作现在由瞄准模式下底部的小按钮完成
    [_aimBtn setTitle:@"瞄准" forState:UIControlStateNormal];
    _aimBtn.backgroundColor = _aiming
        ? [UIColor colorWithRed:0.95 green:0.55 blue:0.10 alpha:1.0]
        : [UIColor colorWithWhite:0.28 alpha:1.0];

    [_startBtn setTitle:(running ? @"停止" : @"开始") forState:UIControlStateNormal];
    _startBtn.backgroundColor = running
        ? [UIColor colorWithRed:0.78 green:0.14 blue:0.14 alpha:1.0]
        : [UIColor colorWithRed:0.16 green:0.46 blue:0.30 alpha:1.0];

    _freqCtrl.selectedSegmentIndex = _freqIndex;

    _statusLabel.text = [NSString stringWithFormat:
        @"坐标 %.0f, %.0f %@ | 频率 %.0f/s\n状态: %@\n%@: %@\n派发: %@\nHID: %@",
        _point.x, _point.y,
        _hasPoint ? @"" : @"(未保存)",
        [self currentFrequency],
        running ? @"连点中" : (_aiming ? @"瞄准中" : @"待机"),
        kJDTargetName, _targetFront ? @"前台" : @"不在前台",
        inj.clientKind,
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
