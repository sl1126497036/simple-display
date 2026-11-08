//
//  BLVirtualScreen.m
//

#import "BLVirtualScreen.h"
#import "CGVirtualDisplayPrivate.h"

#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>

static NSString * const BLVDErrorDomain = @"BetterLiteVD";

#pragma mark - 自身可执行路径

static const char *BLExecutablePath(void) {
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

#pragma mark - 外部探针（唯一可靠的 HiDPI 判据）

/// 起一个子进程读某块屏的真实模式。成功时写入点宽/背板宽。
/// 之所以必须用子进程：在创建虚拟屏的进程内，CGDisplayCopyDisplayMode 返回 NULL，
/// CGDisplayPixelsWide 在建屏首帧返回点宽、重建时返回 0，都不可信。
static BOOL BLProbeDisplay(const char *exe, CGDirectDisplayID vid, size_t *outPointW, size_t *outPixelW) {
    int fds[2];
    if (pipe(fds) != 0) return NO;

    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        char idbuf[24];
        snprintf(idbuf, sizeof idbuf, "%u", vid);
        execl(exe, exe, "--probe", idbuf, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) { close(fds[0]); close(fds[1]); return NO; }

    close(fds[1]);
    char out[64] = {0};
    ssize_t n = read(fds[0], out, sizeof out - 1);
    close(fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (n <= 0) return NO;

    size_t mw = 0, pw = 0;
    if (sscanf(out, "%zu %zu", &mw, &pw) != 2) return NO;
    if (outPointW) *outPointW = mw;
    if (outPixelW) *outPixelW = pw;
    return YES;
}

#pragma mark - 物理屏模式对齐

/// 在物理屏的模式表里找与目标刷新率最接近、且像素尺寸为面板原生的模式。
/// 硬件镜像不会自己把 slave 的刷新率改成 master 的，必须先手动对齐，否则两边各扫各的。
static CGDisplayModeRef BLCopyAlignedMode(CGDirectDisplayID did, double wantHz) {
    NSDictionary *opts = @{ (__bridge NSString *)CFSTR("kCGDisplayShowDuplicateLowResolutionModes"): @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);
    if (!modes) return NULL;

    size_t nativeW = CGDisplayPixelsWide(did);
    size_t nativeH = CGDisplayPixelsHigh(did);

    CGDisplayModeRef best = NULL;
    double bestDiff = 1e9;
    CFIndex n = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(m) != nativeW || CGDisplayModeGetHeight(m) != nativeH) continue;
        double r = CGDisplayModeGetRefreshRate(m);
        if (r <= 1.0) continue;
        double diff = fabs(r - wantHz);
        if (diff < bestDiff) { bestDiff = diff; best = m; }
    }
    CFRelease(modes);
    if (!best) return NULL;
    return (CGDisplayModeRef)CFRetain(best);
}

#pragma mark -

@implementation BLVirtualScreen {
    CGVirtualDisplay *_vd;
    CGDirectDisplayID _virtualDisplayID;
    BOOL _active;
    CGSize _pointSize;
    double _refreshRate;
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

#pragma mark - 应用

- (BOOL)applyPointSize:(CGSize)size refreshRate:(double)hz error:(NSError **)error {
    unsigned wantW = (unsigned)llround(size.width);
    unsigned wantH = (unsigned)llround(size.height);

    if (wantW < 320 || wantH < 200) {
        if (error) *error = [NSError errorWithDomain:BLVDErrorDomain code:1
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

    // 记下物理屏此刻的原生模式（首次应用时）。对齐刷新率会改它，还原时要换回来。
    if (!_savedPhysMode) {
        _savedPhysMode = CGDisplayCopyDisplayMode(_physicalDisplayID);
    }

    // 先把物理屏切到与目标一致的刷新率。硬件镜像不会自动同步 slave 的刷新率，
    // 不对齐就会 master 100Hz / slave 60Hz 各扫各的，表现为画面周期性抖动。
    CGDisplayModeRef aligned = BLCopyAlignedMode(_physicalDisplayID, hz);
    if (aligned) {
        double exact = CGDisplayModeGetRefreshRate(aligned);
        if (exact > 1.0) hz = exact;      // 沿用面板的精确刷新率，避免 99.86 vs 100.00 的节拍差
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

    CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
    d.name = @"HiDPI";
    d.maxPixelsWide = MAX(8192u, wantW * 2 + 64);
    d.maxPixelsHigh = MAX(8192u, wantH * 2 + 64);
    d.sizeInMillimeters = CGDisplayScreenSize(_physicalDisplayID);
    d.vendorID = 0x424C;                                    // 'BL'
    d.productID = 0x0400 + (_physicalDisplayID & 0x00FF);    // 每块屏不同，避免 override 撞车
    d.serialNum = _physicalDisplayID;
    d.queue = dispatch_get_main_queue();

    CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    if (!vd) {
        if (error) *error = [NSError errorWithDomain:BLVDErrorDomain code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"虚拟屏初始化返回 nil。"}];
        return NO;
    }

    CGVirtualDisplaySettings *st = [[CGVirtualDisplaySettings alloc] init];
    st.hiDPI = 1;
    st.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:wantW height:wantH refreshRate:hz]];
    if (![vd applySettings:st]) {
        if (error) *error = [NSError errorWithDomain:BLVDErrorDomain code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"applySettings 返回 NO。"}];
        return NO;
    }

    _vd = vd;
    _virtualDisplayID = vd.displayID;

    // 等它进 online 列表
    for (int i = 0; i < 60; i++) {
        uint32_t n = 0;
        CGDirectDisplayID ids[32];
        CGGetOnlineDisplayList(32, ids, &n);
        BOOL found = NO;
        for (uint32_t k = 0; k < n; k++) if (ids[k] == _virtualDisplayID) { found = YES; break; }
        if (found && CGDisplayIsActive(_virtualDisplayID)) break;
        usleep(50 * 1000);
    }
    usleep(500 * 1000);

    // 自检：2× 背板是否真的存在
    if (![self verifyHiDPIExpectWidth:wantW]) {
        if (error) *error = [NSError errorWithDomain:BLVDErrorDomain code:4
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
        if (error) *error = [NSError errorWithDomain:BLVDErrorDomain code:5
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
    const char *exe = BLExecutablePath();
    if (!exe) return YES;   // 拿不到自身路径就不阻断（极少见）

    for (int i = 0; i < 25; i++) {
        size_t pointW = 0, pixelW = 0;
        if (BLProbeDisplay(exe, _virtualDisplayID, &pointW, &pixelW) && pointW > 0) {
            return (pointW == (size_t)wantW) && (pixelW == (size_t)wantW * 2);
        }
        usleep(250 * 1000);
    }
    return NO;
}

#pragma mark - 还原

- (void)teardown {
    if (_active) {
        // 必须用物理屏 ID：虚拟屏是主屏时 CGMainDisplayID() 会返回虚拟屏，解镜会解错对象
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

    // 把物理屏刷新率换回对齐前的值，否则关掉虚拟屏后会停留在被改过的频率上
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
