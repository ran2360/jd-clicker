//
//  BBProbe.m — backboardd 侧探针
//
//  ---------------------------------------------------------------------------
//  为什么需要它
//  ---------------------------------------------------------------------------
//  实测结论 (见 README §6.11):
//    * 我们的插件注入 SpringBoard 完全正常 (悬浮窗、悬浮球、准星、菜单都能跑);
//    * SpringBoard **确实有** com.apple.private.hid.client.event-dispatch 权限;
//    * IOHIDEvent 的五个符号全都在, client 五种创建方式都能建出来, 事件也构造成功;
//    * **但派发的触摸完全不出现** —— 连点桌面 App 图标都没反应。
//    * SpringBoard 的 platform-application / no-sandbox **都没有** —— 它是有沙箱的。
//
//  结论: 很可能是 SpringBoard 的沙箱挡住了 HID 事件的真正投递。
//  那就只能把"派发"搬到 backboardd —— 它本身就是 HID 事件系统, 不受应用沙箱限制。
//
//  ---------------------------------------------------------------------------
//  这个探针只做三件事, 都很安全
//  ---------------------------------------------------------------------------
//    1. 证明 ElleKit 到底会不会把 dylib 注入 backboardd (这是整个方案的前提);
//    2. 把 backboardd 自己的权限、IOKit 符号可用性打进日志;
//    3. 15 秒后在**屏幕中心**派发一次点击 —— 用来验证 HID 派发在 backboardd 里通不通。
//
//  只点 1 次、只点屏幕中心, 是为了把风险降到最低: 万一 backboardd 出问题,
//  最坏结果是注销一次, 不会把系统搞坏。
//
//  日志: /tmp/BBProbe.log
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
static NSString *BBLogPath(void)
{
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *c in @[@"/tmp/BBProbe.log",
                             @"/var/mobile/Library/Caches/BBProbe.log"]) {
            @try {
                if (![fm fileExistsAtPath:c]) [fm createFileAtPath:c contents:nil attributes:nil];
                if ([fm isWritableFileAtPath:c]) { path = c; break; }
            } @catch (NSException *e) { }
        }
    });
    return path;
}

static void BBLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [@"[BBProbe] " stringByAppendingString:s];
    NSLog(@"%@", line);
    NSString *p = BBLogPath();
    if (!p) return;
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) { }
}

// ---------------------------------------------------------------------------
// IOHID
// ---------------------------------------------------------------------------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef struct { uint32_t lo; uint32_t hi; } BBAbsoluteTime;

typedef IOHIDEventRef (*BBCreateDigitizerEventFn)(CFAllocatorRef, BBAbsoluteTime, uint32_t,
                                                  uint32_t, uint32_t, uint32_t, uint32_t,
                                                  IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                                  IOHIDFloat, IOHIDFloat,
                                                  Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*BBCreateFingerEventFn)(CFAllocatorRef, BBAbsoluteTime,
                                               uint32_t, uint32_t, uint32_t,
                                               IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                               IOHIDFloat, IOHIDFloat,
                                               IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                               IOHIDFloat, IOHIDFloat,
                                               Boolean, Boolean, uint32_t);
typedef void (*BBAppendEventFn)(IOHIDEventRef, IOHIDEventRef);
typedef void (*BBSetIntFn)(IOHIDEventRef, int32_t, int);
typedef IOHIDEventSystemClientRef (*BBClientCreateWithTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);
typedef IOHIDEventSystemClientRef (*BBClientCreateFn)(CFAllocatorRef);
typedef void (*BBDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static BBCreateDigitizerEventFn pDigitizer = NULL;
static BBCreateFingerEventFn    pFinger    = NULL;
static BBAppendEventFn          pAppend    = NULL;
static BBSetIntFn               pSetInt    = NULL;
static BBClientCreateWithTypeFn pCreateT   = NULL;
static BBClientCreateFn         pCreate    = NULL;
static BBDispatchFn             pDispatch  = NULL;

#define BB_FIELD_IS_DISPLAY_INTEGRATED (int32_t)((11 << 16) + 25)

static void BBLoadSymbols(void)
{
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    #define BB_BIND(v, n) do { void *h = iokit ? dlsym(iokit, n) : NULL; \
        if (!h) h = dlsym(RTLD_DEFAULT, n); v = (__typeof__(v))h; } while (0)
    BB_BIND(pDigitizer, "IOHIDEventCreateDigitizerEvent");
    BB_BIND(pFinger,    "IOHIDEventCreateDigitizerFingerEventWithQuality");
    BB_BIND(pAppend,    "IOHIDEventAppendEvent");
    BB_BIND(pSetInt,    "IOHIDEventSetIntegerValue");
    BB_BIND(pCreateT,   "IOHIDEventSystemClientCreateWithType");
    BB_BIND(pCreate,    "IOHIDEventSystemClientCreate");
    BB_BIND(pDispatch,  "IOHIDEventSystemClientDispatchEvent");
    #undef BB_BIND
    BBLog(@"IOKit 符号: digitizer=%@ finger=%@ append=%@ setInt=%@ CreateWithType=%@ Create=%@ dispatch=%@",
          pDigitizer ? @"有" : @"无", pFinger ? @"有" : @"无", pAppend ? @"有" : @"无",
          pSetInt ? @"有" : @"无", pCreateT ? @"有" : @"无", pCreate ? @"有" : @"无",
          pDispatch ? @"有" : @"无");
}

static IOHIDEventRef BBCreateEvent(CGPoint pt, BOOL ending)
{
    if (!pDigitizer || !pFinger) return NULL;
    uint64_t ab = mach_absolute_time();
    BBAbsoluteTime ts; ts.lo = (uint32_t)ab; ts.hi = (uint32_t)(ab >> 32);

    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, ts, 3 /* Hand */,
                                    0, 0, 2 /* Touch */, 0,
                                    0, 0, 0, 0, 0, 0, true, 0);
    if (!hand) return NULL;
    if (pSetInt) pSetInt(hand, BB_FIELD_IS_DISPLAY_INTEGRATED, 1);

    uint32_t mask = 3;                     // Range | Touch
    uint32_t touching = ending ? 0 : 1;
    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, 2, mask,
                                   (IOHIDFloat)pt.x, (IOHIDFloat)pt.y, 0.0,
                                   0, 0, 5.0, 5.0, 1.0, 1.0, 1.0,
                                   (Boolean)touching, (Boolean)touching, 0);
    if (!finger) { CFRelease(hand); return NULL; }
    if (pSetInt) pSetInt(finger, BB_FIELD_IS_DISPLAY_INTEGRATED, 1);
    if (pAppend) pAppend(hand, finger);
    CFRelease(finger);
    return hand;
}

// 滑动过程中的"移动"事件: eventMask 只用 Position(4), 不碰 Range/Touch
static IOHIDEventRef BBCreateMoveEvent(CGPoint pt)
{
    if (!pDigitizer || !pFinger) return NULL;
    uint64_t ab = mach_absolute_time();
    BBAbsoluteTime ts; ts.lo = (uint32_t)ab; ts.hi = (uint32_t)(ab >> 32);

    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, ts, 3,
                                    0, 0, 2, 0,
                                    0, 0, 0, 0, 0, 0, true, 0);
    if (!hand) return NULL;
    if (pSetInt) pSetInt(hand, BB_FIELD_IS_DISPLAY_INTEGRATED, 1);

    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, 2, 4 /* Position */,
                                   (IOHIDFloat)pt.x, (IOHIDFloat)pt.y, 0.0,
                                   0, 0, 5.0, 5.0, 1.0, 1.0, 1.0,
                                   (Boolean)1, (Boolean)1, 0);
    if (!finger) { CFRelease(hand); return NULL; }
    if (pSetInt) pSetInt(finger, BB_FIELD_IS_DISPLAY_INTEGRATED, 1);
    if (pAppend) pAppend(hand, finger);
    CFRelease(finger);
    return hand;
}

// ---------------------------------------------------------------------------
// 权限自检
// ---------------------------------------------------------------------------
static void BBProbeEntitlements(void)
{
    typedef struct __SecTask *BBSecTaskRef;
    typedef BBSecTaskRef (*BBCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*BBCopyValueFn)(BBSecTaskRef, CFStringRef, CFErrorRef *);

    BBCreateFromSelfFn create = (BBCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    BBCopyValueFn copy = (BBCopyValueFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) { BBLog(@"权限自检: 拿不到 SecTask, 跳过"); return; }
    BBSecTaskRef task = create(kCFAllocatorDefault);
    if (!task) return;

    static const char *keys[] = {
        "com.apple.private.hid.client.event-dispatch",
        "com.apple.private.hid.client.event-monitor",
        "platform-application",
        "com.apple.private.security.no-sandbox",
        NULL
    };
    BBLog(@"---------- backboardd 权限自检 ----------");
    for (int i = 0; keys[i]; i++) {
        CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, keys[i], kCFStringEncodingUTF8);
        CFTypeRef v = copy(task, k, NULL);
        BBLog(@"  %-52s : %@", keys[i], v ? @"有" : @"无");
        if (v) CFRelease(v);
        CFRelease(k);
    }
    BBLog(@"------------------------------------------");
    CFRelease(task);
}

// ---------------------------------------------------------------------------
// 坐标单位 —— 这是本轮要验证的核心
// ---------------------------------------------------------------------------
// 之前所有测试都传"点" (430x932)。但 IOHID 的 digitizer 也有可能期望的是
// **物理像素** (1290x2796)。两种解释和"什么都没发生"都完全吻合:
//
//   * 点 Dock 图标 (55, 850)
//       按点   -> 就是 Dock 第一个图标 -> 应该打开 App
//       按像素 -> 实际落在 (18, 283) 点 = 屏幕左侧中上部空白 -> 什么都没有
//   * 顶部下滑 (215,3)->(215,620)
//       按点   -> 一整段下滑 -> 应该拉出通知中心
//       按像素 -> 只有左上角一小段 (72,1)->(72,207) -> 什么都不会发生
//
// 所以这一轮把两种单位各测一遍, 一次性定性。
static CGFloat BBScreenScale(void)
{
    @try {
        CGFloat s = [UIScreen mainScreen].scale;
        if (s > 0) return s;
    } @catch (NSException *e) { }
    return 3.0;                      // iPhone 14 Pro Max
}

static CGPoint BBScaled(CGPoint p, BOOL pixels, CGFloat scale)
{
    return pixels ? CGPointMake(p.x * scale, p.y * scale) : p;
}

// ---------------------------------------------------------------------------
// 派发动作
// ---------------------------------------------------------------------------
static IOHIDEventSystemClientRef BBMakeClient(int kind)
{
    if (kind == 1 && pCreateT) return pCreateT(kCFAllocatorDefault, 1, NULL);   // Admin
    if (kind == 2 && pCreateT) return pCreateT(kCFAllocatorDefault, 5, NULL);   // System
    if (pCreate)               return pCreate(kCFAllocatorDefault);             // Create
    return NULL;
}

// 在同一个点连点 times 次
static void BBTap(IOHIDEventSystemClientRef c, CGPoint p, int times)
{
    for (int i = 0; i < times; i++) {
        IOHIDEventRef down = BBCreateEvent(p, NO);
        IOHIDEventRef up   = BBCreateEvent(p, YES);
        if (down) { pDispatch(c, down); CFRelease(down); }
        if (up)   { pDispatch(c, up);   CFRelease(up); }
        usleep(120 * 1000);            // 每次之间隔 120ms, 免得被当成连击
    }
}

// 从 from 滑到 to, steps 个中间点。
// ★ 这个动作用来选择"必然可见"的验证目标: 从屏幕顶部下滑 = 拉出通知中心,
//   结果会一直留在屏幕上, 用户事后也能看到, 不像"点屏幕中心"那样毫无反应。
static void BBSwipe(IOHIDEventSystemClientRef c, CGPoint from, CGPoint to, int steps)
{
    IOHIDEventRef down = BBCreateEvent(from, NO);
    if (down) { pDispatch(c, down); CFRelease(down); }
    usleep(30 * 1000);

    for (int i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                from.y + (to.y - from.y) * t);
        IOHIDEventRef mv = BBCreateMoveEvent(p);
        if (mv) { pDispatch(c, mv); CFRelease(mv); }
        usleep(16 * 1000);
    }

    usleep(30 * 1000);
    IOHIDEventRef up = BBCreateEvent(to, YES);
    if (up) { pDispatch(c, up); CFRelease(up); }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void BBProbeInit(void)
{
    BBLog(@"==================================================");
    BBLog(@"constructor 执行了 —— ElleKit 确实把 dylib 注入了 backboardd");
    BBLog(@"进程名: %@   bundleId: %@",
          [[NSProcessInfo processInfo] processName] ?: @"?",
          [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
    BBLog(@"日志文件: %@", BBLogPath() ?: @"(写不进去)");
    BBLog(@"==================================================");

    BBLoadSymbols();
    BBProbeEntitlements();

    if (!pDispatch) { BBLog(@"没有 dispatch 符号, 放弃"); return; }

    CGFloat scale = BBScreenScale();
    BBLog(@"屏幕缩放 = %.1f  (点是 430x932, 像素是 %.0fx%.0f)",
          scale, 430 * scale, 932 * scale);

    // 四轮, 每轮都用**必然可见**的动作 + 换坐标单位:
    //   第 1 轮 点 Dock 图标 · 单位=点
    //   第 2 轮 点 Dock 图标 · 单位=像素   <- 如果只有这轮有反应, 说明坐标要用像素
    //   第 3 轮 顶部下滑   · 单位=点
    //   第 4 轮 顶部下滑   · 单位=像素
    //
    // 用"点 Dock 图标"(会开 App) 和"顶部下滑"(会拉通知中心) 当作判据, 是因为
    // 它们的结果肉眼必然可见、而且事后还能查。上一版用"点屏幕中心"完全无效 ——
    // 桌面中心本来就是空白, 点一下就什么都不会发生, 那个结论毫无意义。
    for (int round = 0; round < 4; round++) {
        BOOL pixels = (round % 2) == 1;         // 1、3 轮用像素
        BOOL dockTap = (round < 2);             // 前两轮点 Dock, 后两轮下滑

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((20 + round * 20) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                IOHIDEventSystemClientRef c = BBMakeClient(2);      // System(5)
                BBLog(@"---------- 第 %d 轮  坐标单位=%@ ----------",
                      round + 1, pixels ? @"像素" : @"点");
                BBLog(@"client = %@", c ? @"建好" : @"失败");
                if (!c) return;

                if (dockTap) {
                    CGPoint p = BBScaled(CGPointMake(55, 850), pixels, scale);
                    BBLog(@"动作: 点 (%.0f, %.0f) 三次 —— 成功的话应该会打开 Dock 第一个 App",
                          p.x, p.y);
                    BBTap(c, p, 3);
                    BBLog(@"已派发。★ 有 App 自己打开吗?");
                } else {
                    CGPoint from = BBScaled(CGPointMake(215, 3), pixels, scale);
                    CGPoint to   = BBScaled(CGPointMake(215, 620), pixels, scale);
                    BBLog(@"动作: 从 (%.0f, %.0f) 滑到 (%.0f, %.0f) —— 成功的话应该拉出通知中心",
                          from.x, from.y, to.x, to.y);
                    BBSwipe(c, from, to, 30);
                    BBLog(@"已派发。★ 通知中心被拉出来了吗? (它会一直留着)");
                }
            }
        });
    }
}
