//
//  BLAppDelegate.m
//

#import "BLAppDelegate.h"
#import "BLDisplayInfo.h"
#import "BLVirtualScreen.h"

#include <stdlib.h>

extern BOOL gBLRequestSelfTest;   // 定义在 main.m

/// 退出兜底：把所有处于镜像状态的屏解除镜像。
/// 不依赖具体实例，避免对象已释放时漏还原。
static void BLRestoreAllAtExit(void) {
    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    CGGetOnlineDisplayList(32, ids, &n);

    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;

    BOOL any = NO;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) {
            CGConfigureDisplayMirrorOfDisplay(cfg, ids[i], kCGNullDirectDisplay);
            any = YES;
        }
    }
    if (any) {
        CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    } else {
        CGCancelDisplayConfiguration(cfg);
    }
}

/// 显示器配置变化（插拔 / 改模式 / 移动）
static void BLReconfigCallback(CGDirectDisplayID did, CGDisplayChangeSummaryFlags flags, void *ctx) {
    BLAppDelegate *delegate = (__bridge BLAppDelegate *)ctx;
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                 kCGDisplayDisabledFlag | kCGDisplayMovedFlag)) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate rescan]; });
    }
}

@implementation BLAppDelegate {
    NSStatusItem *_statusItem;
    NSMutableArray<BLDisplayInfo *> *_displays;
    NSMutableDictionary<NSNumber *, BLVirtualScreen *> *_screens;
    NSMutableDictionary<NSNumber *, NSValue *> *_prefSize;
    NSMutableDictionary<NSNumber *, NSNumber *> *_prefHz;
    BOOL _rebuilding;
}

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _displays = [NSMutableArray array];
    _screens = [NSMutableDictionary dictionary];
    _prefSize = [NSMutableDictionary dictionary];
    _prefHz = [NSMutableDictionary dictionary];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = @"HiDPI";

    CGDisplayRegisterReconfigurationCallback(BLReconfigCallback, (__bridge void *)self);
    atexit(BLRestoreAllAtExit);

    [self rescan];

    if (self.hasStartupRequest) {
        CGDirectDisplayID did = self.startupDisplayID;
        if (did == kCGNullDirectDisplay) did = CGMainDisplayID();
        double hz = self.startupHz > 1.0 ? self.startupHz : [self preferredHzForDisplay:did];
        [self applyToDisplay:did size:self.startupSize refreshRate:hz];
    } else if (gBLRequestSelfTest) {
        [self runSelfTest];
    }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self turnOffAll];
    CGDisplayRemoveReconfigurationCallback(BLReconfigCallback, (__bridge void *)self);
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

#pragma mark - 枚举

- (BLDisplayInfo *)infoForDisplay:(CGDirectDisplayID)did {
    for (BLDisplayInfo *i in _displays) if (i.displayID == did) return i;
    return nil;
}

- (void)rescan {
    if (_rebuilding) return;
    _rebuilding = YES;

    uint32_t n = 0;
    CGDirectDisplayID ids[32];
    CGGetOnlineDisplayList(32, ids, &n);

    NSMutableSet<NSNumber *> *alive = [NSMutableSet set];
    for (uint32_t i = 0; i < n; i++) {
        if (ids[i] == kCGNullDirectDisplay) continue;
        BOOL ours = NO;
        for (BLVirtualScreen *vs in _screens.allValues) {
            if (vs.virtualDisplayID == ids[i]) { ours = YES; break; }
        }
        if (!ours) [alive addObject:@(ids[i])];
    }

    // 拔掉的屏：销毁其虚拟屏
    for (NSNumber *key in _screens.allKeys) {
        if (![alive containsObject:key]) {
            [_screens[key] teardown];
            [_screens removeObjectForKey:key];
            [_prefSize removeObjectForKey:key];
            [_prefHz removeObjectForKey:key];
        }
    }

    NSMutableArray<BLDisplayInfo *> *arr = [NSMutableArray array];
    for (NSNumber *num in alive) {
        BLDisplayInfo *info = [BLDisplayInfo infoWithDisplayID:num.unsignedIntValue];
        if (info) [arr addObject:info];
    }
    [arr sortUsingComparator:^NSComparisonResult(BLDisplayInfo *a, BLDisplayInfo *b) {
        if (a.isMain != b.isMain) return a.isMain ? NSOrderedAscending : NSOrderedDescending;
        return a.displayID < b.displayID ? NSOrderedAscending : NSOrderedDescending;
    }];
    _displays = arr;

    _rebuilding = NO;
    [self rebuildMenu];
}

#pragma mark - 应用

- (CGSize)preferredSizeForDisplay:(CGDirectDisplayID)did {
    BLVirtualScreen *vs = _screens[@(did)];
    if (vs.active && vs.pointSize.width > 0) return vs.pointSize;
    NSValue *v = _prefSize[@(did)];
    if (v) return v.sizeValue;
    BLDisplayInfo *info = [self infoForDisplay:did];
    return info ? info.defaultPointSize : CGSizeMake(1280, 720);
}

- (double)preferredHzForDisplay:(CGDirectDisplayID)did {
    BLVirtualScreen *vs = _screens[@(did)];
    if (vs.active && vs.refreshRate > 0) return vs.refreshRate;
    NSNumber *num = _prefHz[@(did)];
    if (num) return num.doubleValue;

    CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
    double hz = m ? CGDisplayModeGetRefreshRate(m) : 60.0;
    if (m) CGDisplayModeRelease(m);
    return hz > 1.0 ? hz : 60.0;
}

- (void)applyToDisplay:(CGDirectDisplayID)physID size:(CGSize)size refreshRate:(double)hz {
    BLVirtualScreen *vs = _screens[@(physID)];
    if (!vs) {
        vs = [[BLVirtualScreen alloc] initWithPhysicalDisplay:physID];
        _screens[@(physID)] = vs;
    }
    _prefSize[@(physID)] = [NSValue valueWithSize:size];
    _prefHz[@(physID)] = @(hz);

    NSError *err = nil;
    if (![vs applyPointSize:size refreshRate:hz error:&err]) {
        fprintf(stderr, "APPLY FAIL: %s\n", err.localizedDescription.UTF8String);
        [self showError:err.localizedDescription];
    } else {
        fprintf(stderr, "APPLY OK: %ux%u @%.2fHz\n",
                (unsigned)size.width, (unsigned)size.height, vs.refreshRate);
    }
    [self rebuildMenu];
}

- (void)turnOffDisplay:(CGDirectDisplayID)physID {
    [[_screens objectForKey:@(physID)] teardown];
    [self rebuildMenu];
}

- (void)turnOffAll {
    for (BLVirtualScreen *vs in _screens.allValues) [vs teardown];
    [self rebuildMenu];
}

- (void)showError:(NSString *)msg {
    if (gBLRequestSelfTest) { fprintf(stderr, "ALERT: %s\n", msg.UTF8String); return; }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"无法应用这个组合";
    a.informativeText = [NSString stringWithFormat:@"%@\n\n屏幕已被还原，换一个尺寸或刷新率再试。", msg];
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"好"];
    [a runModal];
}

#pragma mark - 菜单

- (NSArray<BLVirtualScreen *> *)activeScreens {
    NSMutableArray *a = [NSMutableArray array];
    for (BLVirtualScreen *vs in _screens.allValues) if (vs.active) [a addObject:vs];
    return a;
}

- (NSString *)statusText {
    NSArray *on = [self activeScreens];
    if (on.count == 0) return @"未启用（物理屏原生）";
    if (on.count == 1) {
        BLVirtualScreen *vs = on.firstObject;
        return [NSString stringWithFormat:@"%u × %u  @ %.0fHz  HiDPI 2×",
                (unsigned)vs.pointSize.width, (unsigned)vs.pointSize.height, vs.refreshRate];
    }
    return [NSString stringWithFormat:@"%lu 块屏已启用 HiDPI", (unsigned long)on.count];
}

- (NSString *)statusBarTitle {
    NSArray *on = [self activeScreens];
    if (on.count == 0) return @"HiDPI";
    if (on.count == 1) {
        BLVirtualScreen *vs = on.firstObject;
        return [NSString stringWithFormat:@"%u×%u",
                (unsigned)vs.pointSize.width, (unsigned)vs.pointSize.height];
    }
    return [NSString stringWithFormat:@"HiDPI %lu", (unsigned long)on.count];
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *st = [[NSMenuItem alloc] initWithTitle:[self statusText] action:nil keyEquivalent:@""];
    st.enabled = NO;
    [menu addItem:st];
    [menu addItem:[NSMenuItem separatorItem]];

    if (_displays.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"未发现显示器" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [menu addItem:none];
    }

    for (BLDisplayInfo *info in _displays) {
        NSString *title = [NSString stringWithFormat:@"%@  ·  %@  %zux%zu%@",
                           info.name, info.aspectLabel, info.pixelWidth, info.pixelHeight,
                           info.isMain ? @"  (主屏)" : @""];
        NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        root.submenu = [self submenuForDisplay:info];
        [menu addItem:root];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *offAll = [[NSMenuItem alloc] initWithTitle:@"全部关闭" action:@selector(turnOffAllAction) keyEquivalent:@""];
    offAll.target = self;
    offAll.enabled = [self activeScreens].count > 0;
    [menu addItem:offAll];

    NSMenuItem *rescan = [[NSMenuItem alloc] initWithTitle:@"重新扫描显示器" action:@selector(rescanAction) keyEquivalent:@"r"];
    rescan.target = self;
    [menu addItem:rescan];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quitAction) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    _statusItem.menu = menu;
    _statusItem.button.title = [self statusBarTitle];
}

- (NSMenu *)submenuForDisplay:(BLDisplayInfo *)info {
    NSMenu *m = [[NSMenu alloc] init];
    BLVirtualScreen *vs = _screens[@(info.displayID)];
    BOOL on = vs.active;

    NSString *cur = on
        ? [NSString stringWithFormat:@"当前：%u × %u  @ %.0fHz",
           (unsigned)vs.pointSize.width, (unsigned)vs.pointSize.height, vs.refreshRate]
        : @"当前：未启用";
    NSMenuItem *curItem = [[NSMenuItem alloc] initWithTitle:cur action:nil keyEquivalent:@""];
    curItem.enabled = NO;
    [m addItem:curItem];
    [m addItem:[NSMenuItem separatorItem]];

    // 分辨率
    NSMenuItem *resRoot = [[NSMenuItem alloc] initWithTitle:@"分辨率" action:nil keyEquivalent:@""];
    NSMenu *resMenu = [[NSMenu alloc] init];
    for (NSValue *v in info.pointSizes) {
        CGSize s = v.sizeValue;
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:
                          [NSString stringWithFormat:@"%u × %u", (unsigned)s.width, (unsigned)s.height]
                                                    action:@selector(pickResolution:)
                                             keyEquivalent:@""];
        it.representedObject = @{ @"did": @(info.displayID), @"size": v };
        it.target = self;
        if (on && (unsigned)vs.pointSize.width == (unsigned)s.width &&
                  (unsigned)vs.pointSize.height == (unsigned)s.height) {
            it.state = NSControlStateValueOn;
        }
        [resMenu addItem:it];
    }
    resRoot.submenu = resMenu;
    [m addItem:resRoot];

    // 刷新率
    NSMenuItem *hzRoot = [[NSMenuItem alloc] initWithTitle:@"刷新率" action:nil keyEquivalent:@""];
    NSMenu *hzMenu = [[NSMenu alloc] init];
    for (NSNumber *n in info.refreshRates) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:
                          [NSString stringWithFormat:@"%.1f Hz", n.doubleValue]
                                                    action:@selector(pickRefresh:)
                                             keyEquivalent:@""];
        it.representedObject = @{ @"did": @(info.displayID), @"hz": n };
        it.target = self;
        if (on && fabs(vs.refreshRate - n.doubleValue) < 0.6) it.state = NSControlStateValueOn;
        [hzMenu addItem:it];
    }
    hzRoot.submenu = hzMenu;
    [m addItem:hzRoot];

    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"关闭本屏虚拟屏"
                                                 action:@selector(turnOffOneAction)
                                          keyEquivalent:@""];
    off.representedObject = @(info.displayID);
    off.target = self;
    off.enabled = on;
    [m addItem:off];

    return m;
}

#pragma mark - Actions

- (void)pickResolution:(NSMenuItem *)item {
    NSDictionary *d = item.representedObject;
    CGDirectDisplayID did = [d[@"did"] unsignedIntValue];
    CGSize s = [d[@"size"] sizeValue];
    [self applyToDisplay:did size:s refreshRate:[self preferredHzForDisplay:did]];
}

- (void)pickRefresh:(NSMenuItem *)item {
    NSDictionary *d = item.representedObject;
    CGDirectDisplayID did = [d[@"did"] unsignedIntValue];
    double hz = [d[@"hz"] doubleValue];
    [self applyToDisplay:did size:[self preferredSizeForDisplay:did] refreshRate:hz];
}

- (void)turnOffOneAction:(NSMenuItem *)item {
    [self turnOffDisplay:(CGDirectDisplayID)[item.representedObject unsignedIntValue]];
}

- (void)turnOffAllAction { [self turnOffAll]; }
- (void)rescanAction { [self rescan]; }
- (void)quitAction { [self turnOffAll]; [NSApp terminate:nil]; }

#pragma mark - 自检

- (void)spin:(double)sec {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:sec]];
}

- (void)runSelfTest {
    gBLRequestSelfTest = YES;

    BLDisplayInfo *info = _displays.firstObject;
    if (!info) { printf("FAIL: 没有发现显示器\n"); exit(1); }
    printf("DISPLAY: %s  %zux%zu  %s\n", info.name.UTF8String,
           info.pixelWidth, info.pixelHeight, info.aspectLabel.UTF8String);
    printf("REFRESH: ");
    for (NSNumber *n in info.refreshRates) printf("%.1f ", n.doubleValue);
    printf("\nSIZES(%lu): ", (unsigned long)info.pointSizes.count);
    for (NSValue *v in info.pointSizes) {
        CGSize s = v.sizeValue;
        printf("%ux%u ", (unsigned)s.width, (unsigned)s.height);
    }
    printf("\n");

    double hz = info.refreshRates.count ? info.refreshRates.lastObject.doubleValue : 60.0;
    CGSize def = info.defaultPointSize;

    // 记录物理屏原始刷新率，用于验证还原
    double origHz = 0;
    CGDisplayModeRef orig = CGDisplayCopyDisplayMode(info.displayID);
    if (orig) { origHz = CGDisplayModeGetRefreshRate(orig); CGDisplayModeRelease(orig); }

    [self applyToDisplay:info.displayID size:def refreshRate:hz];
    BLVirtualScreen *vs = _screens[@(info.displayID)];
    printf("A apply %ux%u @%.0f -> active=%d\n", (unsigned)def.width, (unsigned)def.height, hz, vs.active);
    [self spin:3.0];

    [self turnOffDisplay:info.displayID];
    usleep(600 * 1000);
    double afterHz = 0;
    CGDisplayModeRef after = CGDisplayCopyDisplayMode(info.displayID);
    if (after) { afterHz = CGDisplayModeGetRefreshRate(after); CGDisplayModeRelease(after); }
    printf("B teardown -> active=%d  physHz=%.2f (原 %.2f) %s\n",
           vs.active, afterHz, origHz, (fabs(afterHz - origHz) < 0.6 ? "还原OK" : "还原失败"));
    [self spin:2.0];

    // 用最低刷新率再测一次对齐 + 还原
    double lowHz = info.refreshRates.count ? info.refreshRates.firstObject.doubleValue : 60.0;
    [self applyToDisplay:info.displayID size:def refreshRate:lowHz];
    double duringHz = 0;
    CGDisplayModeRef during = CGDisplayCopyDisplayMode(info.displayID);
    if (during) { duringHz = CGDisplayModeGetRefreshRate(during); CGDisplayModeRelease(during); }
    printf("C apply %.0fHz -> active=%d  physHz=%.2f\n", lowHz, vs.active, duringHz);
    [self spin:2.5];

    [self turnOffAll];
    usleep(600 * 1000);
    double finHz = 0;
    CGDisplayModeRef fin = CGDisplayCopyDisplayMode(info.displayID);
    if (fin) { finHz = CGDisplayModeGetRefreshRate(fin); CGDisplayModeRelease(fin); }
    printf("D final -> active=%d  physHz=%.2f (原 %.2f) %s\n",
           vs.active, finHz, origHz, (fabs(finHz - origHz) < 0.6 ? "还原OK" : "还原失败"));
    [self spin:1.0];
    exit(0);
}

@end
