//
//  main.m
//  BetterLite VD — 用 CGVirtualDisplay 做真 2× HiDPI，并硬件镜像到物理屏。
//
//  用法：
//    BetterLiteVD                        菜单栏常驻
//    BetterLiteVD --apply W H [Hz] [ID]  启动即对某块屏应用（ID 缺省为主屏）
//    BetterLiteVD --selftest             执行建屏/拆除/重建自检
//    BetterLiteVD --diagnose             打印环境报告（提 issue 用）
//    BetterLiteVD --probe <displayID>    内部用：打印 "<点宽> <背板宽>"
//    BetterLiteVD --modes <displayID>    内部用：逐行打印 "<点宽> <点高> <像素宽> <像素高>"
//

#import <Cocoa/Cocoa.h>
#import "BLAppDelegate.h"
#import "BLDisplayInfo.h"
#import "BLVirtualScreen.h"
#import "BLProbeCache.h"

#include <stdlib.h>
#include <string.h>

BOOL gBLRequestSelfTest = NO;

#pragma mark - 诊断

static NSString *BLDisplayName(CGDirectDisplayID did) {
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        if (num && num.unsignedIntValue == did && s.localizedName.length) return s.localizedName;
    }
    return [NSString stringWithFormat:@"Display %u", did];
}

/// 打印单块屏的完整信息，用于问题报告。
static void BLReportDisplay(CGDirectDisplayID did, BOOL withProbe) {
    CGSize native = [BLDisplayInfo nativePixelSizeForDisplay:did];

    size_t cw = 0, ch = 0, cpw = 0, cph = 0, oneX = 0, twoX = 0, other = 0;
    double chz = 0;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    if (cur) {
        cw = CGDisplayModeGetWidth(cur); ch = CGDisplayModeGetHeight(cur);
        cpw = CGDisplayModeGetPixelWidth(cur); cph = CGDisplayModeGetPixelHeight(cur);
        if (cpw == 0 || cph == 0) { cpw = cw; cph = ch; }
        chz = CGDisplayModeGetRefreshRate(cur);
        CGDisplayModeRelease(cur);
    }

    NSDictionary *o = @{ (__bridge NSString *)CFSTR("kCGDisplayShowDuplicateLowResolutionModes"): @YES };
    CFArrayRef ms = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)o);
    if (ms) {
        CFIndex n = CFArrayGetCount(ms);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(ms, i);
            size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
            size_t pw = CGDisplayModeGetPixelWidth(m), ph = CGDisplayModeGetPixelHeight(m);
            if (pw == 0 || ph == 0) { pw = w; ph = h; }
            if (pw == w && ph == h) oneX++;
            else if (pw == w * 2 && ph == h * 2) twoX++;
            else other++;
        }
        CFRelease(ms);
    }

    printf("\n[%u] %s%s%s%s\n", did,
           BLDisplayName(did).UTF8String,
           CGDisplayIsMain(did) ? "  (main)" : "",
           CGDisplayIsBuiltin(did) ? "  (builtin)" : "",
           CGDisplayMirrorsDisplay(did) != kCGNullDirectDisplay ? "  (mirror-slave)" : "");
    printf("  native pixels : %zu x %zu\n", (size_t)llround(native.width), (size_t)llround(native.height));
    printf("  current mode  : %zu x %zu point, %zu x %zu px, %.2f Hz\n", cw, ch, cpw, cph, chz);
    printf("  modes         : %zu total (%zu 1x, %zu 2x, %zu other)\n",
           oneX + twoX + other, oneX, twoX, other);

    BLDisplayInfo *info = [BLDisplayInfo infoWithDisplayID:did];
    if (info) {
        printf("  refresh rates : ");
        for (NSNumber *n in info.refreshRates) printf("%.2f ", n.doubleValue);
        printf("\n  candidates(%lu) : ", (unsigned long)info.pointSizes.count);
        for (NSValue *v in info.pointSizes) {
            printf("%ux%u ", (unsigned)v.sizeValue.width, (unsigned)v.sizeValue.height);
        }
        printf("\n");

        if (withProbe) {
            double hz = info.refreshRates.count ? info.refreshRates.lastObject.doubleValue : 60.0;
            printf("  probing       : %lu sizes @ %.2fHz（每档约 1-2 秒）\n",
                   (unsigned long)info.pointSizes.count, hz);
            fflush(stdout);

            NSMutableArray<NSValue *> *ok = [NSMutableArray array];
            NSMutableArray<NSValue *> *bad = [NSMutableArray array];
            for (NSValue *v in info.pointSizes) {
                int r = [BLVirtualScreen probeSizeIsHiDPI:v.sizeValue
                                       forPhysicalDisplay:did
                                              refreshRate:hz];
                if (r == 1) [ok addObject:v]; else [bad addObject:v];
                fprintf(stderr, "\r    %ux%u -> %s        ",
                        (unsigned)v.sizeValue.width, (unsigned)v.sizeValue.height,
                        r == 1 ? "2x" : (r == 0 ? "1x (降级)" : "建屏失败"));
                fflush(stderr);
            }
            fprintf(stderr, "\n");

            printf("  result        : %lu/%lu 可用\n",
                   (unsigned long)ok.count, (unsigned long)info.pointSizes.count);
            printf("    2x ok : ");
            for (NSValue *v in ok) printf("%ux%u ", (unsigned)v.sizeValue.width, (unsigned)v.sizeValue.height);
            printf("\n    1x/fail: ");
            for (NSValue *v in bad) printf("%ux%u ", (unsigned)v.sizeValue.width, (unsigned)v.sizeValue.height);
            printf("\n");
        }
    }
}

static int BLRunDiagnose(BOOL withProbe) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSOperatingSystemVersion v = pi.operatingSystemVersion;

    printf("BetterLite VD diagnose\n");
    printf("  macOS         : %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
    printf("  host          : %s\n", pi.hostName.UTF8String);
    printf("  CGVirtualDisplay API : %s\n",
           [BLVirtualScreen isPrivateAPIAvailable] ? "available" : "MISSING");

    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    CGGetOnlineDisplayList(32, ids, &n);
    printf("  online displays      : %u\n", n);

    for (uint32_t i = 0; i < n; i++) {
        if ([BLVirtualScreen isOurVirtualDisplay:ids[i]]) {
            printf("\n[%u] <BetterLite virtual display>\n", ids[i]);
            continue;
        }
        BLReportDisplay(ids[i], withProbe);
    }

    fflush(stdout);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);   // 自检/日志要即时可见
        // 子进程探针，需在任何 UI 初始化之前返回。
        // 创建虚拟屏的进程内，CGDisplayCopyDisplayMode 返回 NULL，
        // CGDisplayPixelsWide 首帧返回点宽、重建时返回 0，无法判断 2× 背板是否存在。
        if (argc >= 3 && strcmp(argv[1], "--probe") == 0) {
            CGDirectDisplayID did = (CGDirectDisplayID)atoi(argv[2]);
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
            if (m) {
                printf("%zu %zu\n", CGDisplayModeGetWidth(m), CGDisplayModeGetPixelWidth(m));
                CGDisplayModeRelease(m);
            } else {
                printf("0 0\n");
            }
            fflush(stdout);
            return 0;
        }

        if (argc >= 3 && strcmp(argv[1], "--modes") == 0) {
            CGDirectDisplayID did = (CGDirectDisplayID)atoi(argv[2]);
            NSDictionary *o = @{ (__bridge NSString *)CFSTR("kCGDisplayShowDuplicateLowResolutionModes"): @YES };
            CFArrayRef ms = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)o);
            if (ms) {
                CFIndex n = CFArrayGetCount(ms);
                for (CFIndex i = 0; i < n; i++) {
                    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(ms, i);
                    size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
                    size_t pw = CGDisplayModeGetPixelWidth(m), ph = CGDisplayModeGetPixelHeight(m);
                    if (pw == 0 || ph == 0) { pw = w; ph = h; }
                    printf("%zu %zu %zu %zu\n", w, h, pw, ph);
                }
                CFRelease(ms);
            }
            fflush(stdout);
            return 0;
        }

        if (argc >= 4 && strcmp(argv[1], "--probe-size") == 0) {
            CGSize s = CGSizeMake(atof(argv[2]), atof(argv[3]));
            CGDirectDisplayID did = argc >= 5 ? (CGDirectDisplayID)atoi(argv[4]) : CGMainDisplayID();
            int r = [BLVirtualScreen probeSizeIsHiDPI:s forPhysicalDisplay:did refreshRate:100.0];
            printf("%s\n", r == 1 ? "2x" : (r == 0 ? "1x" : "fail"));
            fflush(stdout);
            return r == 1 ? 0 : 1;
        }

        if (argc >= 3 && strcmp(argv[1], "--probe-all") == 0) {
            CGDirectDisplayID did = (CGDirectDisplayID)atoi(argv[2]);
            BLDisplayInfo *info = [BLDisplayInfo infoWithDisplayID:did];
            if (!info) return 1;

            // 作为子进程调用时由父进程统一写入，避免并发写同一 plist
            BOOL noCache = NO;
            for (int i = 3; i < argc; i++) {
                if (strcmp(argv[i], "--no-cache") == 0) noCache = YES;
            }

            double hz = info.refreshRates.count ? info.refreshRates.lastObject.doubleValue : 60.0;
            for (NSValue *v in info.pointSizes) {
                CGSize s = v.sizeValue;
                int r = [BLVirtualScreen probeSizeIsHiDPI:s forPhysicalDisplay:did refreshRate:hz];
                printf("%u %u %d\n",
                       (unsigned)llround(s.width), (unsigned)llround(s.height), r);
                fflush(stdout);   // 父进程是流式读的，必须逐行刷
                if (r != -1 && !noCache) {
                    [[BLProbeCache shared] setResult:(BLProbeResult)r forDisplay:did size:s];
                }
            }
            if (!noCache) [[BLProbeCache shared] flushSync];
            return 0;
        }

        if (argc >= 2 && strcmp(argv[1], "--diagnose") == 0) {
            return BLRunDiagnose(argc >= 3 && strcmp(argv[2], "--probe") == 0);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        BLAppDelegate *delegate = [[BLAppDelegate alloc] init];

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--selftest") == 0) {
                gBLRequestSelfTest = YES;
            } else if (strcmp(argv[i], "--apply") == 0 && i + 2 < argc) {
                delegate.hasStartupRequest = YES;
                delegate.startupSize = CGSizeMake(atof(argv[i + 1]), atof(argv[i + 2]));
                if (i + 3 < argc) delegate.startupHz = atof(argv[i + 3]);
                if (i + 4 < argc) delegate.startupDisplayID = (CGDirectDisplayID)atoi(argv[i + 4]);
            }
        }

        app.delegate = delegate;
        [app run];
    }
    return 0;
}
