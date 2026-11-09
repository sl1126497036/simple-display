//
//  main.m
//  Simple Display：通过 CGVirtualDisplay 提供 2× 背板 HiDPI，并硬件镜像到物理屏。
//
//  用法：
//    SimpleDisplay                        菜单栏常驻
//    SimpleDisplay --apply W H [Hz] [ID]  启动即对某块屏应用（ID 缺省为主屏）
//    SimpleDisplay --selftest             执行建屏/拆除/重建自检
//    SimpleDisplay --diagnose             打印环境报告，用于问题反馈
//    SimpleDisplay --volume [0-100]       读取或设置显示器音量
//    SimpleDisplay --login on|off         开启/关闭开机启动
//    SimpleDisplay --login-status         打印开机启动状态
//    SimpleDisplay --probe <displayID>    内部用：打印 "<点宽> <背板宽>"
//    SimpleDisplay --modes <displayID>    内部用：逐行打印 "<点宽> <点高> <像素宽> <像素高>"
//    SimpleDisplay --probe-size W H [ID]  内部用：单档检测，打印 2x / 1x / fail
//    SimpleDisplay --probe-all <id>       内部用：逐档检测全部候选尺寸，结果写入缓存
//    SimpleDisplay --dump-menu            内部用：打印菜单结构
//

#import <Cocoa/Cocoa.h>
#import "SDAppDelegate.h"
#import "SDDisplayInfo.h"
#import "SDVirtualScreen.h"
#import "SDProbeCache.h"
#import "SDDisplayDDC.h"

#import <ServiceManagement/ServiceManagement.h>

#include <stdlib.h>
#include <string.h>

BOOL gSDRequestSelfTest = NO;
BOOL gSDRequestDumpMenu = NO;
BOOL gSDRequestVolumeProbe = NO;

#pragma mark - 诊断

static NSString *SDDisplayName(CGDirectDisplayID did) {
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        if (num && num.unsignedIntValue == did && s.localizedName.length) return s.localizedName;
    }
    return [NSString stringWithFormat:@"Display %u", did];
}

/// 打印单块屏的完整信息，用于问题报告。
static void SDReportDisplay(CGDirectDisplayID did, BOOL withProbe) {
    CGSize native = [SDDisplayInfo nativePixelSizeForDisplay:did];

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
           SDDisplayName(did).UTF8String,
           CGDisplayIsMain(did) ? "  (main)" : "",
           CGDisplayIsBuiltin(did) ? "  (builtin)" : "",
           CGDisplayMirrorsDisplay(did) != kCGNullDirectDisplay ? "  (mirror-slave)" : "");
    printf("  native pixels : %zu x %zu\n", (size_t)llround(native.width), (size_t)llround(native.height));
    printf("  current mode  : %zu x %zu point, %zu x %zu px, %.2f Hz\n", cw, ch, cpw, cph, chz);
    printf("  modes         : %zu total (%zu 1x, %zu 2x, %zu other)\n",
           oneX + twoX + other, oneX, twoX, other);

    SDDisplayInfo *info = [SDDisplayInfo infoWithDisplayID:did];
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
                int r = [SDVirtualScreen probeSizeIsHiDPI:v.sizeValue
                                       forPhysicalDisplay:did
                                              refreshRate:hz];
                if (r == 1) [ok addObject:v]; else [bad addObject:v];
                fprintf(stderr, "\r    %ux%u -> %s        ",
                        (unsigned)v.sizeValue.width, (unsigned)v.sizeValue.height,
                        r == 1 ? "2x"
                               : (r == 0 ? "1x (降级)"
                                         : "建屏失败"));
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

static int SDRunDiagnose(BOOL withProbe) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSOperatingSystemVersion v = pi.operatingSystemVersion;

    printf("Simple Display diagnose\n");
    printf("  macOS         : %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
    printf("  host          : %s\n", pi.hostName.UTF8String);
    printf("  CGVirtualDisplay API : %s\n",
           [SDVirtualScreen isPrivateAPIAvailable] ? "available" : "MISSING");

    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    CGGetOnlineDisplayList(32, ids, &n);
    printf("  online displays      : %u\n", n);

    for (uint32_t i = 0; i < n; i++) {
        if ([SDVirtualScreen isOurVirtualDisplay:ids[i]]) {
            printf("\n[%u] <SimpleDisplay virtual display>\n", ids[i]);
            continue;
        }
        SDReportDisplay(ids[i], withProbe);
    }

    fflush(stdout);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);   // 自检/日志要即时可见
        // 子进程探针，需先于任何 UI 初始化返回。
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
            int r = [SDVirtualScreen probeSizeIsHiDPI:s forPhysicalDisplay:did refreshRate:100.0];
            printf("%s\n", r == 1 ? "2x" : (r == 0 ? "1x" : "fail"));
            fflush(stdout);
            return r == 1 ? 0 : 1;
        }

        if (argc >= 3 && strcmp(argv[1], "--probe-all") == 0) {
            CGDirectDisplayID did = (CGDirectDisplayID)atoi(argv[2]);
            SDDisplayInfo *info = [SDDisplayInfo infoWithDisplayID:did];
            if (!info) return 1;

            // 作为子进程调用时由父进程统一写入，避免并发写同一 plist
            BOOL noCache = NO;
            for (int i = 3; i < argc; i++) {
                if (strcmp(argv[i], "--no-cache") == 0) noCache = YES;
            }

            double hz = info.refreshRates.count ? info.refreshRates.lastObject.doubleValue : 60.0;
            for (NSValue *v in info.pointSizes) {
                CGSize s = v.sizeValue;
                int r = [SDVirtualScreen probeSizeIsHiDPI:s forPhysicalDisplay:did refreshRate:hz];
                printf("%u %u %d\n",
                       (unsigned)llround(s.width), (unsigned)llround(s.height), r);
                fflush(stdout);   // 父进程是流式读的，必须逐行刷
                if (r != -1 && !noCache) {
                    [[SDProbeCache shared] setResult:(SDProbeResult)r forDisplay:did size:s];
                }
            }
            if (!noCache) [[SDProbeCache shared] flushSync];
            return 0;
        }

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--dump-menu") == 0) gSDRequestDumpMenu = YES;
            if (strcmp(argv[i], "--volume-probe") == 0) gSDRequestVolumeProbe = YES;
        }

        if (argc >= 2 && strcmp(argv[1], "--volume") == 0) {
            SDDisplayDDC *ddc = [[SDDisplayDDC alloc] init];
            if (!ddc.isAvailable) { printf("unavailable\n"); return 1; }
            NSError *err = nil;
            if (![ddc reloadVolume:&err]) {
                printf("read failed: %s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            if (argc >= 3) {
                unsigned target = (unsigned)strtoul(argv[2], NULL, 10);
                if (![ddc setVolume:target error:&err]) {
                    printf("write failed: %s\n", err.localizedDescription.UTF8String);
                    return 1;
                }
                usleep(150 * 1000);
                [ddc reloadVolume:NULL];
            }
            printf("%u/%u\n", ddc.volume, ddc.maximum);
            return 0;
        }

        if (argc >= 2 && strcmp(argv[1], "--login-status") == 0) {
            if (@available(macOS 13.0, *)) {
                const char *name = "unknown";
                switch (SMAppService.mainAppService.status) {
                    case SMAppServiceStatusNotRegistered:   name = "not-registered"; break;
                    case SMAppServiceStatusEnabled:         name = "enabled"; break;
                    case SMAppServiceStatusRequiresApproval:name = "requires-approval"; break;
                    case SMAppServiceStatusNotFound:        name = "not-found"; break;
                }
                printf("%s\n", name);
            } else {
                printf("unsupported\n");
            }
            return 0;
        }

        if (argc >= 3 && strcmp(argv[1], "--login") == 0) {
            if (@available(macOS 13.0, *)) {
                SMAppService *service = SMAppService.mainAppService;
                NSError *err = nil;
                BOOL ok;
                if (strcmp(argv[2], "on") == 0) {
                    ok = [service registerAndReturnError:&err];
                } else if (strcmp(argv[2], "off") == 0) {
                    ok = [service unregisterAndReturnError:&err];
                } else {
                    printf("usage: --login on|off\n");
                    return 2;
                }
                if (ok) {
                    printf("ok\n");
                    return 0;
                }
                printf("fail: %s\n", err.localizedDescription.UTF8String ?: "unknown");
                return 1;
            }
            printf("unsupported\n");
            return 1;
        }

        if (argc >= 2 && strcmp(argv[1], "--diagnose") == 0) {
            return SDRunDiagnose(argc >= 3 && strcmp(argv[2], "--probe") == 0);
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        SDAppDelegate *delegate = [[SDAppDelegate alloc] init];

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--selftest") == 0) {
                gSDRequestSelfTest = YES;
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
