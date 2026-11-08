//
//  main.m
//  BetterLite VD — 用 CGVirtualDisplay 做真 2× HiDPI，并硬件镜像到物理屏。
//
//  用法：
//    BetterLiteVD                        菜单栏常驻
//    BetterLiteVD --apply W H [Hz] [ID]  启动即对某块屏应用（ID 缺省为主屏）
//    BetterLiteVD --selftest             自动跑一遍 建/拆/重建
//    BetterLiteVD --probe <displayID>    内部用：打印 "<点宽> <背板宽>"
//

#import <Cocoa/Cocoa.h>
#import "BLAppDelegate.h"

#include <stdlib.h>
#include <string.h>

BOOL gBLRequestSelfTest = NO;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);   // 自检/日志要即时可见
        // 子进程探针。必须在做任何 UI 初始化之前返回。
        // 为什么需要它：在创建虚拟屏的那个进程内，CGDisplayCopyDisplayMode 返回 NULL，
        // CGDisplayPixelsWide 首帧给点宽、重建时给 0，都不足以判断 2× 背板是否真的存在。
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
