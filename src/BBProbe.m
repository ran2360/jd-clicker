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

    // 15 秒后再点, 给用户留时间回到桌面方便观察
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (!pDispatch || (!pCreateT && !pCreate)) {
                BBLog(@"派发测试: 符号不全, 放弃");
                return;
            }
            // 用 System(5) 类型 —— 在 backboardd 里这个应该最合适
            IOHIDEventSystemClientRef client = pCreateT
                ? pCreateT(kCFAllocatorDefault, 5, NULL)
                : pCreate(kCFAllocatorDefault);
            BBLog(@"派发测试: client = %@", client ? @"建好" : @"失败");
            if (!client) return;

            CGPoint pt = CGPointMake(215, 466);      // 屏幕中心 (430x932)
            BBLog(@"派发测试: 在 (%.0f, %.0f) 派发一次点击 —— 请留意屏幕有没有反应", pt.x, pt.y);

            IOHIDEventRef down = BBCreateEvent(pt, NO);
            IOHIDEventRef up   = BBCreateEvent(pt, YES);
            BBLog(@"派发测试: down=%@ up=%@", down ? @"建好" : @"失败", up ? @"建好" : @"失败");
            if (down) { pDispatch(client, down); CFRelease(down); }
            if (up)   { pDispatch(client, up);   CFRelease(up); }
            BBLog(@"派发测试: 已经调用 dispatch 完毕 (如果屏幕没反应, 说明这条路也不通)");
        }
    });
}
