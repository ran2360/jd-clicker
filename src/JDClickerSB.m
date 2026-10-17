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
- (void)tapAtPoint:(CGPoint)point;
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

- (void)tapAtPoint:(CGPoint)point
{
    if (!self.ready) return;

    _dispatchCount++;

    @try {
        // 按下 -> 移动 -> 抬起, 各隔 50ms。
        // 直接把按下/抬起背靠背派发, 会被系统在 UIKit 处理之前合并掉 (ios-mcp 的结论)。
        IOHIDEventRef began = ACCreateHIDEvent(point, UITouchPhaseBegan, YES);
        if (began) { pSystemClientDispatch(_client, began); CFRelease(began); }
        usleep(50 * 1000);

        IOHIDEventRef moved = ACCreateHIDEvent(point, UITouchPhaseMoved, YES);
        if (moved) { pSystemClientDispatch(_client, moved); CFRelease(moved); }
        usleep(50 * 1000);

        IOHIDEventRef ended = ACCreateHIDEvent(point, UITouchPhaseEnded, YES);
        if (ended) { pSystemClientDispatch(_client, ended); CFRelease(ended); }

        if (_dispatchCount <= 4) {
            CGSize sz = ACScreenFixedSize();
            AC_LOG(@"派发 #%ld: 点=(%.0f, %.0f) 归一化=(%.4f, %.4f) 屏=%.0fx%.0f began/moved/ended=%@/%@/%@ client=%@",
                   (long)_dispatchCount, point.x, point.y,
                   sz.width > 0 ? point.x / sz.width : 0.0,
                   sz.height > 0 ? point.y / sz.height : 0.0,
                   sz.width, sz.height,
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

static id ACCallObj(id obj, NSString *sel)
{
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
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

#pragma mark - 权限自检

// ★ 这一步是关键怀疑的定性手段 ★
//
// 系统级 HID 触摸派发需要进程有 com.apple.private.hid.client.event-dispatch
// 这个 entitlement。backboardd 肯定有 (它本身就是 HID 事件系统), 但
// **SpringBoard 有没有, 我并不确定** —— 而实测"桌面图标也点不动"说明派发完全没生效,
// 权限不足是最可能的原因之一。
//
// SecTaskCreateFromSelf 能直接读出本进程代码签名里的 entitlements, 所以不用猜。
static void ACProbeOwnEntitlements(void)
{
    typedef struct __SecTask *ACSecTaskRef;
    typedef ACSecTaskRef (*ACSecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*ACSecTaskCopyValueFn)(ACSecTaskRef, CFStringRef, CFErrorRef *);

    // 用 dlsym 取, 免得为了这两个私有 API 去链接 Security.framework
    ACSecTaskCreateFromSelfFn create =
        (ACSecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    ACSecTaskCopyValueFn copy =
        (ACSecTaskCopyValueFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) {
        AC_LOG(@"权限自检: 拿不到 SecTask API, 跳过");
        return;
    }
    ACSecTaskRef task = create(kCFAllocatorDefault);
    if (!task) { AC_LOG(@"权限自检: SecTaskCreateFromSelf 返回空"); return; }

    static const char *keys[] = {
        "com.apple.private.hid.client.event-dispatch",
        "com.apple.private.hid.client.event-filter",
        "com.apple.private.hid.client.event-monitor",
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "com.apple.private.security.storage.AppDataContainers",
        NULL
    };

    AC_LOG(@"---------- 本进程权限自检 (当前进程 = SpringBoard) ----------");
    for (int i = 0; keys[i] != NULL; i++) {
        CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, keys[i],
                                                  kCFStringEncodingUTF8);
        CFTypeRef v = copy(task, k, NULL);
        AC_LOG(@"  %-52s : %@", keys[i], v ? @"有" : @"无");
        if (v) CFRelease(v);
        CFRelease(k);
    }
    AC_LOG(@"  ↑ 如果 hid.client.event-dispatch 是「无」, 那就是派发不生效的根因:");
    AC_LOG(@"    SpringBoard 沙箱不允许, 需要把派发放到 backboardd 侧去做。");
    AC_LOG(@"--------------------------------------------------------------");
    CFRelease(task);
}

#pragma mark - 诊断: 把能找到的东西全打出来

// 列出某个类上所有名字包含 needle 的方法 —— 这是找对 selector 名最直接的办法。
static void ACDumpSelectorsMatching(Class c, const char *needle)
{
    if (!c) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        const char *sn = sel_getName(method_getName(ms[i]));
        if (sn && strcasestr(sn, needle)) {
            [hits addObject:[NSString stringWithUTF8String:sn]];
        }
    }
    if (ms) free(ms);
    [hits sortUsingSelector:@selector(compare:)];
    AC_LOG(@"    [%@ 中名含 \"%s\"] %@", NSStringFromClass(c), needle,
           hits.count ? [hits componentsJoinedByString:@", "] : @"(无)");
}

static NSArray *ACAllSBApplications(id ctrl)
{
    id all = ACKVC(ctrl, @"allApplications");
    if (![all isKindOfClass:[NSArray class]]) all = ACKVC(ctrl, @"_applications");
    if (![all isKindOfClass:[NSArray class]]) all = nil;
    return all;
}

// 读一个 SBApplication 的两个进程状态字段。
//
// 为什么两个都读: 实测 processState 返回的是 10773618432 这种大数 (见日志里的
// com.apple.PosterBoard), 根本不是小枚举 —— 所以 "processState == 4" 这条判定
// 从一开始就不可能对。而 SBApplication 上还有一个 _internalProcessState,
// 那个更可能是干净的小枚举。两个都记, 才不用再猜一轮。
static void ACReadAppStates(id app, NSInteger *pub, BOOL *pubOK,
                            NSInteger *inn, BOOL *innOK)
{
    if (pub)   *pub = ACCallInt(app, @"processState", pubOK);
    if (inn)   *inn = ACCallInt(app, @"_internalProcessState", innOK);
}

static void ACDumpRunningApps(void)
{
    id ctrl = ACSharedInstanceOf(@"SBApplicationController");
    if (!ctrl) return;
    NSArray *all = ACAllSBApplications(ctrl);
    if (!all) return;

    NSMutableArray *lines = [NSMutableArray array];
    for (id a in all) {
        BOOL ok1 = NO, ok2 = NO;
        NSInteger pub = 0, inn = 0;
        ACReadAppStates(a, &pub, &ok1, &inn, &ok2);
        if (!ok1 && !ok2) continue;
        if ((!ok1 || pub == 0) && (!ok2 || inn == 0)) continue;   // 两个都是 0 视为没运行
        id bid = ACCallObj(a, @"bundleIdentifier");
        [lines addObject:[NSString stringWithFormat:@"%@(pub=%ld,inn=%ld)",
                          bid ?: @"?", (long)pub, (long)inn]];
    }
    if (lines.count == 0) {
        AC_LOG(@"当前没有运行中的应用");
    } else {
        AC_LOG(@"正在运行的应用 (bundleId(pub=processState,inn=_internalProcessState)):");
        for (NSString *l in lines) AC_LOG(@"    %@", l);
    }
}

static id ACTargetSBApplication(void);   // 前置声明: 定义在后面, 诊断里要用

static void ACDumpForegroundDiagnostics(void)
{

    ACProbeOwnEntitlements();          // ★ 先查权限, 这是"派发不生效"的头号嫌疑
    AC_LOG(@"========== 前台检测诊断 (开始) ==========");

    Class ctrlC = NSClassFromString(@"SBApplicationController");
    AC_LOG(@"SBApplicationController: %@", ctrlC ? @"存在" : @"不存在");
    if (ctrlC) ACDumpSelectorsMatching(ctrlC, "application");

    id ctrl = ACSharedInstanceOf(@"SBApplicationController");
    AC_LOG(@"  sharedInstance: %@", ctrl ? @"拿到" : @"拿不到");

    if (ctrl) {
        SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        AC_LOG(@"  响应 applicationWithBundleIdentifier: %@",
               [ctrl respondsToSelector:appSel] ? @"是" : @"否");

        id app = ACCallObj1(ctrl, @"applicationWithBundleIdentifier:", kJDTargetBundle);
        AC_LOG(@"  查询 %@ -> %@", kJDTargetBundle,
               app ? NSStringFromClass([app class]) : @"nil");

        if (app) {
            Class ac = object_getClass(app);
            ACDumpSelectorsMatching(ac, "front");
            ACDumpSelectorsMatching(ac, "state");
            ACDumpSelectorsMatching(ac, "active");

            BOOL ok = NO;
            NSInteger st = ACCallInt(app, @"processState", &ok);
            AC_LOG(@"    processState = %ld (%@)", (long)st, ok ? @"可读" : @"不存在");
            BOOL f = ACCallBool(app, @"isFrontmost", &ok);
            AC_LOG(@"    isFrontmost = %@ (%@)", f ? @"YES" : @"NO", ok ? @"可读" : @"不存在");
            id bid = ACCallObj(app, @"bundleIdentifier");
            AC_LOG(@"    bundleIdentifier = %@", bid ?: @"(nil)");
        }

        // ★ 最关键的一条: 把 SpringBoard 当前认识的所有 bundle id 列出来。
        //   如果京东的 id 不在里面, 说明我们的 bundle id 写错了。
        NSArray *all = ACAllSBApplications(ctrl);
        if (all) {
            NSMutableArray *ids = [NSMutableArray array];
            for (id a in all) {
                id bid = ACCallObj(a, @"bundleIdentifier");
                if (bid) [ids addObject:bid];
            }
            [ids sortUsingSelector:@selector(compare:)];
            AC_LOG(@"  SpringBoard 已知应用 %lu 个:", (unsigned long)ids.count);
            AC_LOG(@"    %@", [ids componentsJoinedByString:@", "]);
        } else {
            AC_LOG(@"  拿不到 allApplications / _applications");
        }
    }

    for (NSString *cn in @[@"SBSceneManagerCoordinator", @"SBMainWorkspace",
                           @"FBSceneManager", @"SBUIController", @"SBSceneManager",
                           @"SBApplicationSceneHandle"]) {
        Class c = NSClassFromString(cn);
        AC_LOG(@"%@: %@", cn, c ? @"存在" : @"不存在");
        if (!c) continue;
        id inst = ACSharedInstanceOf(cn);
        ACDumpSelectorsMatching(c, "front");
        ACDumpSelectorsMatching(c, "fore");
        ACDumpSelectorsMatching(c, "active");
        ACDumpSelectorsMatching(c, "current");
        if (inst) {
            ACDumpSelectorsMatching(object_getClass(inst), "front");
            ACDumpSelectorsMatching(object_getClass(inst), "fore");
        }
    }

    // SBApplication 上我还没搜过的关键词 (之前只搜了 front/state/active)
    id probeApp = ACTargetSBApplication();
    if (probeApp) {
        Class ac = object_getClass(probeApp);
        ACDumpSelectorsMatching(ac, "fore");
        ACDumpSelectorsMatching(ac, "ground");
        ACDumpSelectorsMatching(ac, "running");
        ACDumpSelectorsMatching(ac, "visible");
    }

    // 直接试几个 KVC key, 看哪个能拿到"前台应用"
    id ws = ACSharedInstanceOf(@"SBMainWorkspace");
    if (ws) {
        for (NSString *key in @[@"frontmostApplication", @"currentApplication",
                                @"_frontmostApplication", @"_currentApplication"]) {
            id v = ACKVC(ws, key);
            AC_LOG(@"SBMainWorkspace '%@' -> %@", key,
                   v ? NSStringFromClass([v class]) : @"nil");
        }
    }

    AC_LOG(@"========== 前台检测诊断 (结束) ==========");
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
static NSSet *ACForegroundBundleIDsViaScenes(BOOL verbose)
{
    id coord = ACSharedInstanceOf(@"SBSceneManagerCoordinator");
    if (!coord) { if (verbose) AC_LOG(@"检测: 没有 SBSceneManagerCoordinator"); return nil; }

    id mgr = nil;
    for (NSString *key in @[@"mainDisplaySceneManager", @"mainSceneManager"]) {
        mgr = ACKVC(coord, key);
        if (mgr) break;
    }
    if (!mgr) { if (verbose) AC_LOG(@"检测: 拿不到主屏 SBSceneManager"); return nil; }

    id handles = ACKVC(mgr, @"externalForegroundApplicationSceneHandles");
    if (verbose) AC_LOG(@"检测: externalForegroundApplicationSceneHandles = %@",
                        handles ? NSStringFromClass([handles class]) : @"nil");
    if (!handles) return nil;

    NSArray *array = handles;
    if ([handles respondsToSelector:@selector(allObjects)]) {
        array = [handles performSelector:@selector(allObjects)];
    }
    if (![array isKindOfClass:[NSArray class]]) return nil;

    NSMutableSet *bids = [NSMutableSet set];
    for (id handle in array) {
        if (verbose) AC_LOG(@"检测:   前台句柄 = %@", NSStringFromClass([handle class]));
        id app = ACKVC(handle, @"application");
        if (!app) app = ACKVC(handle, @"_application");
        if (!app) {
            id scene = ACKVC(handle, @"sceneIfExists");
            if (!scene) scene = ACKVC(handle, @"scene");
            if (scene) app = ACKVC(scene, @"application");
        }
        id bid = ACKVC(app, @"bundleIdentifier");
        if (!bid) {
            id ident = ACKVC(handle, @"processIdentity");
            if (!ident) ident = ACKVC(app, @"processIdentity");
            bid = ACKVC(ident, @"bundleIdentifier");
        }
        if (bid && [bid isKindOfClass:[NSString class]]) {
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
    UIButton            *_confirmBtn;      // 瞄准时替代菜单的「确认」小按钮
    UILabel             *_statusLabel;
    ACCrosshairView     *_crosshair;

    BOOL                 _aiming;
    CGPoint              _point;
    BOOL                 _hasPoint;
    NSInteger            _freqIndex;
    BOOL                 _targetFront;
    NSTimer             *_visTimer;
    NSInteger            _installRetry;
    NSInteger            _tickCount;
    NSInteger            _lastTargetState; // 京东 processState 的上一个值 (用来发现变化)
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

    _lastTargetState = NSIntegerMin;    // 保证第一次读到就记一条变化
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
    _tickCount++;

    // 装好 5 秒后打一次完整诊断 (不管当前是什么显示模式, 都要拿到这些数据)
    if (_tickCount == 17) {     // 0.3s * 17 ≈ 5s
        @try { ACDumpForegroundDiagnostics(); }
        @catch (NSException *e) { AC_LOG(@"诊断异常: %@ - %@", e.name, e.reason); }
    }

    ACFrontProbe probe = ACProbeTargetFrontmost(NO);
    BOOL front = (probe == ACFrontProbeYes);

    // 「仅京东显示」: 只有**确认**京东在前台时才显示;
    // 检测手段不可用(未知)时**也显示**, 免得球藏起来后用户点不到它 (1.0.10 的教训)。
    BOOL shouldShow = (probe != ACFrontProbeNo);

    // 记录京东 processState 的变化 (旧检测方式的数据; 场景句柄不可用时还能用来兜底)
    {
        id app = ACTargetSBApplication();
        if (app) {
            BOOL ok = NO;
            NSInteger st = ACCallInt(app, @"processState", &ok);
            if (ok && st != _lastTargetState) {
                AC_LOG(@"★ %@ 的 processState 变化: %ld -> %ld",
                       kJDTargetName, (long)_lastTargetState, (long)st);
                _lastTargetState = st;
                ACDumpRunningApps();
            }
        }
    }

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

    _freqCtrl = [[UISegmentedControl alloc] initWithItems:@[@"10/s", @"20/s", @"30/s", @"50/s"]];
    _freqCtrl.frame = CGRectMake(10, 102, w - 20, 32);
    _freqCtrl.selectedSegmentIndex = _freqIndex;
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
        ? [UIColor colorWithRed:0.88 green:0.16 blue:0.16 alpha:0.95]
        : [UIColor colorWithWhite:0.20 alpha:0.92];
    _ball.layer.borderColor = (running
        ? [UIColor colorWithRed:1.0 green:0.55 blue:0.5 alpha:0.95]
        : [UIColor colorWithWhite:1.0 alpha:0.75]).CGColor;
    _ballLabel.text = running ? @"停" : @"连点";

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
