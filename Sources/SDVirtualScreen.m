//
//  SDVirtualScreen.m
//

#import "SDVirtualScreen.h"
#import "SDDisplayInfo.h"
#import "CGVirtualDisplayPrivate.h"

#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>

static NSString * const SDVDErrorDomain = @"SimpleDisplay";

/// 本工具创建的虚拟屏使用该 vendorID（'SD'），重扫时据此排除。
static const unsigned int kSDVendorID = 0x5344;

#pragma mark - 自身可执行路径 / 子进程

static const char *SDExecutablePath(void) {
    static char *resolved = NULL;
    if (resolved) return resolved;
    NSString *p = [NSBundle mainBundle].executablePath;
    if (p.length == 0) {
        NSArray<NSString *> *args = [NSProcessInfo processInfo].arguments;
        if (args.count > 0) p = args.firstObject;
    }
    if (p.length == 0) return NULL;
    resolved = realpath(p.fileSystemRepresentation, NULL);
    return resolved;
}

/// fork + exec 本进程，执行只读子命令并收取全部 stdout。
///
/// 读取真实模式的调用一律走子进程。创建虚拟屏的进程内，
/// CGDisplayCopyAllDisplayModes / CGDisplayCopyDisplayMode 返回 NULL 或陈旧值，
/// CGDisplayPixelsWide 首帧返回点宽、重建时返回 0，均不可作为判断依据。
static NSData *SDRunSelf(NSString *a1, NSString *a2) {
    const char *exe = SDExecutablePath();
    if (!exe) return nil;

    int fds[2];
    if (pipe(fds) != 0) return nil;

    pid_t pid = fork();
    if (pid == 0) {                      // 子进程
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        execl(exe, exe, a1.UTF8String, a2.UTF8String, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) { close(fds[0]); close(fds[1]); return nil; }

    close(fds[1]);
    NSMutableData *buf = [NSMutableData data];
    char tmp[8192];
    ssize_t n;
    while ((n = read(fds[0], tmp, sizeof tmp)) > 0) [buf appendBytes:tmp length:(NSUInteger)n];
    close(fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    return buf.length ? buf : nil;
}

/// 读某块屏「当前模式」的点宽 / 像素宽。自检 2× 背板用。
static BOOL SDProbeCurrentMode(CGDirectDisplayID vid, size_t *pointW, size_t *pixelW) {
    NSData *d = SDRunSelf(@"--probe", [NSString stringWithFormat:@"%u", vid]);
    if (!d) return NO;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return NO;

    size_t mw = 0, pw = 0;
    if (sscanf(s.UTF8String, "%zu %zu", &mw, &pw) != 2) return NO;
    if (mw == 0) return NO;
    if (pointW) *pointW = mw;
    if (pixelW) *pixelW = pw;
    return YES;
}

#pragma mark - 物理屏模式对齐

/// 在物理屏的模式表里找与目标刷新率最接近、且像素尺寸为面板原生的模式。
/// 硬件镜像不同步 slave 的刷新率，需先手动对齐，否则 master 与 slave 按不同频率刷新。
///
/// 比对使用像素尺寸，原生像素由 SDDisplayInfo 推断。
/// 以 CGDisplayPixelsWide 作为原生值会在两种情况下失配：
///   1. 系统缩放或其它 HiDPI 工具生效时，该值等于当前模式的像素宽，非面板原生；
///   2. HiDPI 生效时，该值为背板宽（2×），无法匹配任何 1× 模式。
/// 失配导致 master 与 slave 刷新率不一致，画面周期性抖动。
static CGDisplayModeRef SDCopyAlignedMode(CGDirectDisplayID did, double wantHz) {
    NSDictionary *opts = @{ (__bridge NSString *)CFSTR("kCGDisplayShowDuplicateLowResolutionModes"): @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);
    if (!modes) return NULL;

    CGSize native = [SDDisplayInfo nativePixelSizeForDisplay:did];
    size_t nativeW = (size_t)llround(native.width);
    size_t nativeH = (size_t)llround(native.height);
    if (nativeW == 0 || nativeH == 0) { CFRelease(modes); return NULL; }

    CGDisplayModeRef best = NULL;
    double bestDiff = 1e9;
    CFIndex n = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pw = CGDisplayModeGetPixelWidth(m);
        size_t ph = CGDisplayModeGetPixelHeight(m);
        if (pw == 0 || ph == 0) { pw = CGDisplayModeGetWidth(m); ph = CGDisplayModeGetHeight(m); }
        if (pw != nativeW || ph != nativeH) continue;
        double r = CGDisplayModeGetRefreshRate(m);
        if (r <= 1.0) continue;
        double diff = fabs(r - wantHz);
        if (diff < bestDiff) { bestDiff = diff; best = m; }
    }
    CFRelease(modes);
    if (!best) return NULL;
    return (CGDisplayModeRef)CFRetain(best);
}

#pragma mark - 建屏 / 等待

/// 建一块虚拟屏并申请一组点尺寸（统一 hiDPI）。
///
/// 像素上限按候选中的最大尺寸计算：5K 屏点宽 5120 需要 10240 背板，
/// 6K 点宽 6016 需要 12032。
static CGVirtualDisplay *SDMakeVirtualDisplay(CGDirectDisplayID physID,
                                              NSArray<NSValue *> *pointSizes,
                                              double hz,
                                              NSError **error) {
    unsigned maxPtW = 0, maxPtH = 0;
    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];

    for (NSValue *v in pointSizes) {
        CGSize s = v.sizeValue;
        unsigned w = (unsigned)llround(s.width);
        unsigned h = (unsigned)llround(s.height);
        if (w < 320 || h < 200) continue;
        if (w > maxPtW) maxPtW = w;
        if (h > maxPtH) maxPtH = h;
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:hz]];
    }
    if (modes.count == 0) return nil;

    CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
    d.name = [NSString stringWithFormat:@"SimpleDisplay %u", physID];

    unsigned needW = (unsigned)MAX((double)maxPtW * 2.0 + 64.0, 1024.0);
    unsigned needH = (unsigned)MAX((double)maxPtH * 2.0 + 64.0, 768.0);
    // 环境变量 SD_MIN_MAXPIXELS 可抬高 maxPixels 下限，用于核对降级与像素上限的关系
    const char *env = getenv("SD_MIN_MAXPIXELS");
    if (env) {
        unsigned floorPx = (unsigned)atoi(env);
        needW = MAX(needW, floorPx);
        needH = MAX(needH, floorPx);
    }
    d.maxPixelsWide = needW;
    d.maxPixelsHigh = needH;
    d.sizeInMillimeters = CGDisplayScreenSize(physID);
    d.vendorID = kSDVendorID;             // 'SD'：标识本工具创建的屏
    d.productID = physID;                 // 每块屏唯一，避免多屏时冲突
    d.serialNum = physID;
    d.queue = dispatch_get_main_queue();

    CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    if (!vd) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:2
                                            userInfo:@{NSLocalizedDescriptionKey:
                          @"虚拟屏初始化返回 nil。可能是 maxPixels 超出本机渲染能力。"}];
        return nil;
    }

    CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
    st.hiDPI = 1;
    st.modes = modes;
    if (![vd applySettings:st]) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                          @"applySettings 返回 NO。系统拒绝了这组模式。"}];
        return nil;
    }
    return vd;
}

static void SDWaitVirtualOnline(CGDirectDisplayID vid, int tries) {
    for (int i = 0; i < tries; i++) {
        uint32_t n = 0;
        CGDirectDisplayID ids[32];
        CGGetOnlineDisplayList(32, ids, &n);
        BOOL found = NO;
        for (uint32_t k = 0; k < n; k++) if (ids[k] == vid) { found = YES; break; }
        if (found && CGDisplayIsActive(vid)) return;
        usleep(50 * 1000);
    }
}

#pragma mark -

@implementation SDVirtualScreen {
    CGVirtualDisplay *_vd;
    CGDirectDisplayID _virtualDisplayID;
    BOOL _active;
    CGSize _pointSize;
    double _refreshRate;
    CGSize _originalNative;            // 被镜像前的原生像素尺寸
    CGDisplayModeRef _savedPhysMode;   // 对齐刷新率前的物理屏模式，还原时恢复
}

- (instancetype)initWithPhysicalDisplay:(CGDirectDisplayID)did {
    if ((self = [super init])) {
        _physicalDisplayID = did;
        _virtualDisplayID = 0;
        _active = NO;
        _pointSize = CGSizeZero;
        _refreshRate = 0;
    }
    return self;
}

- (CGDirectDisplayID)virtualDisplayID { return _virtualDisplayID; }
- (BOOL)active { return _active; }
- (CGSize)pointSize { return _pointSize; }
- (double)refreshRate { return _refreshRate; }
- (CGSize)originalNativePixelSize { return _originalNative; }

#pragma mark - 能力检测

+ (BOOL)isPrivateAPIAvailable {
    static int cached = -1;
    if (cached >= 0) return cached == 1;

    // CGVirtualDisplay 是私有类。系统移除或版本不支持时，alloc/init 会抛出
    // unrecognized selector 导致崩溃，因此先检查类与方法是否存在。
    Class desc = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class vd   = NSClassFromString(@"CGVirtualDisplay");
    Class st   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class md   = NSClassFromString(@"CGVirtualDisplayMode");

    BOOL ok = (desc && vd && st && md)
           && [vd instancesRespondToSelector:@selector(initWithDescriptor:)]
           && [vd instancesRespondToSelector:@selector(applySettings:)]
           && [st instancesRespondToSelector:@selector(setHiDPI:)]
           && [md instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)];

    cached = ok ? 1 : 0;
    return ok;
}

+ (BOOL)isOurVirtualDisplay:(CGDirectDisplayID)did {
    if (did == kCGNullDirectDisplay) return NO;
    return CGDisplayVendorNumber(did) == kSDVendorID;
}

#pragma mark - 探测可用尺寸

+ (int)probeSizeIsHiDPI:(CGSize)size
     forPhysicalDisplay:(CGDirectDisplayID)physID
            refreshRate:(double)hz {
    unsigned w = (unsigned)llround(size.width);
    unsigned h = (unsigned)llround(size.height);
    if (![self isPrivateAPIAvailable] || w < 320 || h < 200) return -1;

    // 探测屏不镜像，短暂存在后即销毁，不改变当前画面。
    CGVirtualDisplay *vd = SDMakeVirtualDisplay(physID,
                                               @[[NSValue valueWithSize:CGSizeMake(w, h)]],
                                               hz, NULL);
    if (!vd) return -1;

    CGDirectDisplayID vid = vd.displayID;
    SDWaitVirtualOnline(vid, 40);

    int result = -1;
    for (int i = 0; i < 12; i++) {
        size_t pointW = 0, pixelW = 0;
        if (SDProbeCurrentMode(vid, &pointW, &pixelW)) {
            result = (pointW == (size_t)w && pixelW == (size_t)w * 2) ? 1 : 0;
            break;
        }
        usleep(120 * 1000);
    }

    (void)vd;              // 出作用域即释放，虚拟屏随之销毁
    usleep(200 * 1000);    // 留出销毁间隔，避免下次建屏处于过渡态
    return result;
}

+ (NSArray<NSValue *> *)probeHiDPISizesForPhysicalDisplay:(CGDirectDisplayID)physID
                                              pointSizes:(NSArray<NSValue *> *)candidates
                                             refreshRate:(double)hz {
    if (![self isPrivateAPIAvailable] || candidates.count == 0) return @[];

    // 逐个尺寸建屏探测：虚拟屏的模式表无法枚举（CGDisplayCopyAllDisplayModes 返回空），
    // 只能读取「当前模式」判断该尺寸是否获得 2× 背板。
    // 单档耗时约 1~2 秒，仅在主动检测时全量执行，其余情况读取缓存。
    NSMutableArray<NSValue *> *ok = [NSMutableArray array];
    for (NSValue *v in candidates) {
        if ([self probeSizeIsHiDPI:v.sizeValue forPhysicalDisplay:physID refreshRate:hz] == 1) {
            [ok addObject:v];
        }
    }
    return ok;
}

#pragma mark - 应用

- (BOOL)applyPointSize:(CGSize)size refreshRate:(double)hz error:(NSError **)error {
    unsigned wantW = (unsigned)llround(size.width);
    unsigned wantH = (unsigned)llround(size.height);

    if (![SDVirtualScreen isPrivateAPIAvailable]) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:6
                                            userInfo:@{NSLocalizedDescriptionKey:
                          @"当前系统缺少 CGVirtualDisplay 私有 API（需要 macOS 11 及以上）。"}];
        return NO;
    }

    if (wantW < 320 || wantH < 200) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"请求的尺寸过小。"}];
        return NO;
    }

    [self teardown];
    usleep(300 * 1000);

    // 等物理屏从上次镜像里真正恢复（过渡态里立刻再镜像会返回 kCGErrorFailure / 1001）
    for (int i = 0; i < 30; i++) {
        if (CGDisplayIsActive(_physicalDisplayID) &&
            CGDisplayMirrorsDisplay(_physicalDisplayID) == kCGNullDirectDisplay) break;
        usleep(100 * 1000);
    }
    usleep(400 * 1000);

    // 记录被镜像前的原生像素尺寸。
    // 成为 mirror slave 后模式表不再代表该屏自身，重扫时读取会得到虚拟屏的尺寸。
    // 首次应用时记录，后续沿用。
    if (_originalNative.width <= 0 || _originalNative.height <= 0) {
        _originalNative = [SDDisplayInfo nativePixelSizeForDisplay:_physicalDisplayID];
    }

    // 记下物理屏此刻的原生模式（首次应用时）。对齐刷新率会改它，还原时要换回来。
    if (!_savedPhysMode) {
        _savedPhysMode = CGDisplayCopyDisplayMode(_physicalDisplayID);
    }

    // 先将物理屏切换到目标刷新率。硬件镜像不同步 slave 的刷新率，
    // 未对齐时 master 与 slave 各自刷新，画面周期性抖动。
    CGDisplayModeRef aligned = SDCopyAlignedMode(_physicalDisplayID, hz);
    if (aligned) {
        double exact = CGDisplayModeGetRefreshRate(aligned);
        if (exact > 1.0) hz = exact;      // 沿用面板的精确刷新率，避免 99.86 与 100.00 之间的累积偏差
        CGDisplayConfigRef cfg = NULL;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGError me = CGConfigureDisplayWithDisplayMode(cfg, _physicalDisplayID, aligned, NULL);
            if (me == kCGErrorSuccess) {
                CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            } else {
                CGCancelDisplayConfiguration(cfg);
            }
        }
        CGDisplayModeRelease(aligned);
        usleep(350 * 1000);
    }

    CGVirtualDisplay *vd = SDMakeVirtualDisplay(_physicalDisplayID,
                                               @[[NSValue valueWithSize:CGSizeMake(wantW, wantH)]],
                                               hz, error);
    if (!vd) return NO;

    _vd = vd;
    _virtualDisplayID = vd.displayID;

    SDWaitVirtualOnline(_virtualDisplayID, 60);
    usleep(500 * 1000);

    // 自检：2× 背板是否存在
    if (![self verifyHiDPIExpectWidth:wantW]) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:4
                                            userInfo:@{NSLocalizedDescriptionKey:
                          [NSString stringWithFormat:@"%u × %u 没能生成 2× 背板，系统会把它当成 1× 铺满屏幕。",
                           wantW, wantH]}];
        [self teardown];
        return NO;
    }

    // 镜像（带重试）
    CGError e = kCGErrorFailure;
    for (int attempt = 0; attempt < 5; attempt++) {
        CGDisplayConfigRef cfg = NULL;
        e = CGBeginDisplayConfiguration(&cfg);
        if (e != kCGErrorSuccess) { usleep(500 * 1000); continue; }
        e = CGConfigureDisplayMirrorOfDisplay(cfg, _physicalDisplayID, _virtualDisplayID);
        if (e == kCGErrorSuccess) {
            e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        } else {
            CGCancelDisplayConfiguration(cfg);
        }
        if (e == kCGErrorSuccess) break;
        usleep(700 * 1000);
    }

    if (e != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:SDVDErrorDomain code:5
                                            userInfo:@{NSLocalizedDescriptionKey:
                          [NSString stringWithFormat:@"镜像失败（错误码 %d）。", e]}];
        [self teardown];
        return NO;
    }

    _active = YES;
    _pointSize = CGSizeMake(wantW, wantH);
    _refreshRate = hz;
    return YES;
}

- (BOOL)verifyHiDPIExpectWidth:(unsigned)wantW {
    for (int i = 0; i < 25; i++) {
        size_t pointW = 0, pixelW = 0;
        if (SDProbeCurrentMode(_virtualDisplayID, &pointW, &pixelW)) {
            return (pointW == (size_t)wantW) && (pixelW == (size_t)wantW * 2);
        }
        usleep(250 * 1000);
    }
    return NO;
}

#pragma mark - 还原

- (void)teardown {
    if (_active) {
        // 必须使用物理屏 ID：虚拟屏为主屏时 CGMainDisplayID() 返回虚拟屏，导致解除镜像的对象错误
        CGDisplayConfigRef cfg = NULL;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(cfg, _physicalDisplayID, kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        _active = NO;
    }
    if (_vd) {
        _vd = nil;          // 释放即销毁虚拟屏
        _virtualDisplayID = 0;
    }

    // 恢复对齐前的物理屏刷新率
    if (_savedPhysMode) {
        usleep(200 * 1000);
        CGDisplayConfigRef cfg = NULL;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            if (CGConfigureDisplayWithDisplayMode(cfg, _physicalDisplayID, _savedPhysMode, NULL) == kCGErrorSuccess) {
                CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            } else {
                CGCancelDisplayConfiguration(cfg);
            }
        }
    }

    _pointSize = CGSizeZero;
    _refreshRate = 0;
}

- (void)dealloc {
    [self teardown];
    if (_savedPhysMode) {
        CGDisplayModeRelease(_savedPhysMode);
        _savedPhysMode = NULL;
    }
}

@end
