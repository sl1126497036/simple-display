//
//  SDAppDelegate.m
//

#import "SDAppDelegate.h"
#import "SDDisplayInfo.h"
#import "SDDisplayDDC.h"
#import "SDVirtualScreen.h"
#import "SDProbeCache.h"

#import <ServiceManagement/ServiceManagement.h>

#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

extern BOOL gSDRequestSelfTest;   // 定义在 main.m
extern BOOL gSDRequestDumpMenu;   // 定义在 main.m

/// 在后台探测当前屏的全部候选尺寸。
///
/// 探测走子进程：
///  1. 建屏为同步调用，单档 1~2 秒，置于主线程会阻塞菜单；
///  2. 探测需反复建拆虚拟屏，置于子进程可隔离失败，不影响正在使用的屏。
static void SDRunProbeAll(CGDirectDisplayID did,
                          void (^onLine)(unsigned w, unsigned h, int result),
                          void (^onDone)(void)) {
    NSString *exePath = [NSBundle mainBundle].executablePath;
    if (exePath.length == 0) { onDone(); return; }
    const char *exe = exePath.fileSystemRepresentation;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fds[2];
        if (pipe(fds) != 0) { onDone(); return; }

        pid_t pid = fork();
        if (pid == 0) {
            close(fds[0]);
            dup2(fds[1], STDOUT_FILENO);
            close(fds[1]);
            char idbuf[24];
            snprintf(idbuf, sizeof idbuf, "%u", did);
            execl(exe, exe, "--probe-all", idbuf, "--no-cache", (char *)NULL);
            _exit(127);
        }
        if (pid < 0) { close(fds[0]); close(fds[1]); onDone(); return; }

        close(fds[1]);
        FILE *f = fdopen(fds[0], "r");
        if (f) {
            char buf[256];
            while (fgets(buf, sizeof buf, f)) {
                unsigned w = 0, h = 0;
                int r = -1;
                if (sscanf(buf, "%u %u %d", &w, &h, &r) == 3) {
                    dispatch_async(dispatch_get_main_queue(), ^{ onLine(w, h, r); });
                }
            }
            fclose(f);
        } else {
            close(fds[0]);
        }

        int status = 0;
        waitpid(pid, &status, 0);
        dispatch_async(dispatch_get_main_queue(), ^{ onDone(); });
    });
}

/// 退出兜底：解除所有镜像，避免进程异常结束时屏幕停在虚拟屏上。
static void SDRestoreAtExit(void) {
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

static void SDReconfigCallback(CGDirectDisplayID did, CGDisplayChangeSummaryFlags flags, void *ctx);

@interface SDAppDelegate ()
- (void)rebuildMenu;
- (void)restoreLastConfiguration;
@end

@implementation SDAppDelegate {
    NSStatusItem *_statusItem;

    SDDisplayInfo *_info;
    SDVirtualScreen *_screen;
    NSValue *_prefSize;
    double   _prefHz;
    BOOL     _probing;
    BOOL     _rebuilding;
    BOOL     _restoring;          // 正在按上次记录自动应用
    BOOL     _restoreAttempted;   // 本次启动已开始过自动应用
    NSInteger _restoreRetries;    // 显示器尚未枚举时的重试次数
    NSString *_restoreFailure;    // 自动应用失败的原因，显示在状态行

    CGSize   _lastGoodSize;       // 最近一次成功应用的点尺寸，唤醒后按它重建
    double   _lastGoodHz;
    CGDirectDisplayID _lastGoodPhysID;
    BOOL     _wakeRecovering;     // 正在按记录配置恢复，失败不弹窗
    BOOL     _wakeRecoveryPending; // 已排入一次唤醒自检，避免重复触发
    BOOL     _rebuildOnWake;      // 经历过显示睡眠，唤醒后按记录值重建
    NSInteger _wakeBuildRetries;  // 唤醒建屏失败后的重试次数

    SDDisplayDDC *_ddc;
    NSSlider    *_volumeSlider;
    NSTextField *_volumeLabel;
    dispatch_queue_t _volumeQueue;
    BOOL _volumeWriting;
    BOOL _volumeMuted;
    unsigned _volumeSavedBeforeMute;
    unsigned _pendingVolume;
}

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _prefHz = 0;
    _volumeQueue = dispatch_queue_create("pro.simpledisplay.volume", DISPATCH_QUEUE_SERIAL);
    _ddc = [[SDDisplayDDC alloc] init];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = [self statusBarIconActive:NO];
    _statusItem.button.imagePosition = NSImageOnly;
    _statusItem.button.imageScaling = NSImageScaleNone;
    _statusItem.button.toolTip = @"Simple Display";

    CGDisplayRegisterReconfigurationCallback(SDReconfigCallback, (__bridge void *)self);

    // 显示器休眠会切断 DP 链路，唤醒后系统重建镜像关系，可能改掉虚拟屏的身份或时序。
    // 唤醒与屏幕唤醒两个通知都收，靠标志去重。
    NSNotificationCenter *wsnc = [NSWorkspace sharedWorkspace].notificationCenter;
    [wsnc addObserver:self selector:@selector(screensDidSleep:)
                 name:NSWorkspaceScreensDidSleepNotification object:nil];
    [wsnc addObserver:self selector:@selector(screensDidWake:)
                 name:NSWorkspaceScreensDidWakeNotification object:nil];
    [wsnc addObserver:self selector:@selector(screensDidWake:)
                 name:NSWorkspaceDidWakeNotification object:nil];

    atexit(SDRestoreAtExit);

    [self rescan];

    if (_ddc.isAvailable) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *err = nil;
            BOOL ok = [self->_ddc reloadVolume:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) [self syncVolumeUI];
            });
        });
    }

    if (self.hasStartupRequest) {
        CGDirectDisplayID did = self.startupDisplayID;
        if (did == kCGNullDirectDisplay) did = CGMainDisplayID();
        double hz = self.startupHz > 1.0 ? self.startupHz : [self preferredHz];
        [self applyToDisplay:did size:self.startupSize refreshRate:hz];
    } else if (!gSDRequestSelfTest && !gSDRequestDumpMenu) {
        [self restoreLastConfiguration];
    }

    if (gSDRequestSelfTest) [self runSelfTest];
    if (gSDRequestDumpMenu) { [self dumpMenu]; exit(0); }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self turnOff];
    CGDisplayRemoveReconfigurationCallback(SDReconfigCallback, (__bridge void *)self);
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

#pragma mark - 显示器

/// 当前操作对象。虚拟屏启用时主屏即虚拟屏，此时应继续指向原物理屏。
- (CGDirectDisplayID)targetDisplay {
    if (_screen.active) return _screen.physicalDisplayID;
    return CGMainDisplayID();
}

- (void)rescan {
    if (_rebuilding) return;
    _rebuilding = YES;

    CGDirectDisplayID did = [self targetDisplay];

    // 该屏正被虚拟屏镜像时，模式表不代表其自身，使用激活前记录的原生尺寸
    CGSize override = _screen.active ? _screen.originalNativePixelSize : CGSizeZero;
    _info = [SDDisplayInfo infoWithDisplayID:did nativePixelSize:override];

    _rebuilding = NO;
    // 重配后旧的 DDC 通道会失效，丢弃让下次读写重新枚举
    [_ddc refreshChannel];
    [self rebuildMenu];
}

static void SDReconfigCallback(CGDirectDisplayID did, CGDisplayChangeSummaryFlags flags, void *ctx) {
    SDAppDelegate *delegate = (__bridge SDAppDelegate *)ctx;
    BOOL added = (flags & kCGDisplayAddFlag) != 0;
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                 kCGDisplayDisabledFlag | kCGDisplayMovedFlag)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate rescan];
            // 目标屏晚于进程启动才枚举出时，在此补一次自动恢复。
            if (added) [delegate restoreLastConfiguration];
        });
    }
}

#pragma mark - 休眠与唤醒

/// 把一次唤醒自检的结论写入偏好设置。
static void SDRecordWakeCheck(NSString *verdict) {
    [[NSUserDefaults standardUserDefaults] setObject:
        [NSString stringWithFormat:@"%@ %@", [NSDate date], verdict]
                                              forKey:@"SDLastWakeCheck"];
}

/// 唤醒后的状态时间线。登录界面的闪烁可能持续数秒，单次采样会漏掉中途的变化。
static void SDAppendWakeTimeline(NSString *line) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSMutableArray *a = [[u arrayForKey:@"SDWakeTimeline"] mutableCopy];
    if (!a) a = [NSMutableArray array];
    [a addObject:[NSString stringWithFormat:@"%@ %@", [NSDate date], line]];
    while (a.count > 8) [a removeObjectAtIndex:0];
    [u setObject:a forKey:@"SDWakeTimeline"];
}

- (void)recordWakeState:(NSString *)tag {
    SDAppendWakeTimeline([NSString stringWithFormat:@"%@ %@", tag,
                          [_screen configurationDiagnostic]]);
}

- (void)screensDidSleep:(NSNotification *)note {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SDWakeTimeline"];
    [self recordWakeState:@"sleep"];

    // 睡眠期间不改显示配置：CGBeginDisplayConfiguration 会挂起，
    // 直到唤醒才返回，屏幕可能停在半完成的配置上。
    // 这里只做标记，建屏留到唤醒之后。
    _rebuildOnWake = YES;
}

/// 显示器休眠会切断 DP 链路，唤醒后系统重新建立镜像，虚拟屏的身份、点尺寸或
/// 镜像关系都可能被动过，画面表现为周期性闪烁。唤醒后按记录值重建一次。
- (void)screensDidWake:(NSNotification *)note {
    SDRecordWakeCheck([NSString stringWithFormat:@"wake: %@", [_screen configurationDiagnostic]]);
    [self recordWakeState:@"t+0s"];
    if (_wakeRecoveryPending) return;
    _wakeRecoveryPending = YES;

    __weak typeof(self) weakSelf = self;
    // 唤醒后系统还要重建镜像关系，立即检查会读到过渡态，因此稍等再动手。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_wakeRecoveryPending = NO;
        [s recoverAfterWake];
    });

    // 登录界面会停留一段时间，继续采样以覆盖途中可能发生的变化。
    for (NSNumber *delay in @[@5, @10]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            [s recordWakeState:[NSString stringWithFormat:@"t+%ds", delay.intValue]];
        });
    }
}

- (void)recoverAfterWake {
    // 本次运行没有成功应用过配置时无从恢复，交给启动恢复处理。
    if (_lastGoodSize.width < 320) return;

    [self recordWakeState:@"wake+1.2s"];

    // 唤醒后直接建屏，不等登录完成。此时屏幕上只有登录界面，重建表现为一次切换；
    // 若等桌面排布完成再建，窗口会跟着整体重排，幅度比一次切换大得多。
    _wakeBuildRetries = 0;
    [self buildForCurrentSession];
}

/// 按记录值建屏。
- (void)buildForCurrentSession {
    if (_lastGoodSize.width < 320) return;

    // 刚经历过显示睡眠：系统重建过显示管线，此时虚拟屏的时序已不可信，
    // 即使自检通过也重建一次，重建本身就是恢复手段。
    BOOL forced = _rebuildOnWake;
    _rebuildOnWake = NO;

    if (!forced && _screen.active && [_screen isConfigurationIntact]) {
        SDRecordWakeCheck([NSString stringWithFormat:@"wake ok %ux%u@%.2f (%@)",
                           (unsigned)_lastGoodSize.width, (unsigned)_lastGoodSize.height,
                           _lastGoodHz, [_screen configurationDiagnostic]]);
        return;
    }

    CGDirectDisplayID phys = _lastGoodPhysID ?: (_info ? _info.displayID : kCGNullDirectDisplay);
    if (phys == kCGNullDirectDisplay) return;

    SDRecordWakeCheck([NSString stringWithFormat:@"wake rebuild (%@) -> %ux%u@%.2f",
                       [_screen configurationDiagnostic],
                       (unsigned)_lastGoodSize.width, (unsigned)_lastGoodSize.height, _lastGoodHz]);

    // 用记录值重建，不重新探测：唤醒路径上要的是回到原状态，不是重新选型。
    NSTimeInterval buildStart = [NSDate timeIntervalSinceReferenceDate];

    _wakeRecovering = YES;
    [self applyToDisplay:phys size:_lastGoodSize refreshRate:_lastGoodHz];
    _wakeRecovering = NO;

    SDAppendWakeTimeline([NSString stringWithFormat:@"rebuilt cost=%.1fs active=%d",
                          [NSDate timeIntervalSinceReferenceDate] - buildStart,
                          _screen.active]);

    // 唤醒后链路尚未就绪时建屏会失败，此时画面停在原生分辨率上。
    // 隔一会儿再试，最多两次。
    if (!_screen.active && _wakeBuildRetries < 2) {
        _wakeBuildRetries++;
        [self recordWakeState:@"rebuild-retry"];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            [s buildForCurrentSession];
        });
    }
}

#pragma mark - 上次组合

static NSString *const kSDLastDisplayKey = @"SDLastDisplayKey";
static NSString *const kSDLastWidth      = @"SDLastPointWidth";
static NSString *const kSDLastHeight     = @"SDLastPointHeight";
static NSString *const kSDLastHz         = @"SDLastRefreshRate";

/// 记录一组已生效的尺寸与刷新率，供下次启动恢复。
/// 显示器身份一并记录：换屏后旧尺寸不再适用。
- (void)rememberConfigurationForDisplay:(CGDirectDisplayID)physID size:(CGSize)size hz:(double)hz {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    [u setObject:[SDProbeCache displayKeyForDisplay:physID] forKey:kSDLastDisplayKey];
    [u setDouble:llround(size.width) forKey:kSDLastWidth];
    [u setDouble:llround(size.height) forKey:kSDLastHeight];
    [u setDouble:hz forKey:kSDLastHz];
}

- (void)forgetConfiguration {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    [u removeObjectForKey:kSDLastDisplayKey];
    [u removeObjectForKey:kSDLastWidth];
    [u removeObjectForKey:kSDLastHeight];
    [u removeObjectForKey:kSDLastHz];
}

/// 启动时重建上次成功的组合。
/// 显示器枚举在启动阶段尚未稳定，延迟 1.2 秒再建屏。
- (void)restoreLastConfiguration {
    if (_restoreAttempted) return;
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSString *key = [u stringForKey:kSDLastDisplayKey];
    double w = [u doubleForKey:kSDLastWidth];
    double h = [u doubleForKey:kSDLastHeight];
    double hz = [u doubleForKey:kSDLastHz];
    if (!key || w < 320 || h < 200) return;
    if (!_info) {
        // 显示器枚举可能晚于进程启动完成，重试三次后放弃，避免反复建屏。
        if (_restoreRetries < 3) {
            _restoreRetries++;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf restoreLastConfiguration];
            });
        }
        return;
    }
    // 目标屏尚未枚举（开机时外接屏可能晚于进程启动）时直接返回，
    // 由显示器接入回调再次触发。
    if (![key isEqualToString:[SDProbeCache displayKeyForDisplay:_info.displayID]]) return;
    _restoreAttempted = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s || s->_screen.active || !s->_info) return;
        s->_restoring = YES;
        s->_restoreFailure = nil;
        [s applyToDisplay:s->_info.displayID size:CGSizeMake(w, h) refreshRate:hz];
        s->_restoring = NO;
        [s rebuildMenu];
    });
}

#pragma mark - 应用

- (CGSize)preferredSize {
    if (_screen.active && _screen.pointSize.width > 0) return _screen.pointSize;
    if (_prefSize) return _prefSize.sizeValue;
    return _info ? _info.defaultPointSize : CGSizeMake(1280, 720);
}

- (double)preferredHz {
    if (_screen.active && _screen.refreshRate > 0) return _screen.refreshRate;
    if (_prefHz > 1.0) return _prefHz;
    if (_info.refreshRates.count) return _info.refreshRates.lastObject.doubleValue;
    return 60.0;
}

- (void)applyToDisplay:(CGDirectDisplayID)physID size:(CGSize)size refreshRate:(double)hz {
    if (!_screen) _screen = [[SDVirtualScreen alloc] initWithPhysicalDisplay:physID];
    _prefSize = [NSValue valueWithSize:size];
    _prefHz = hz;

    NSError *err = nil;
    if (![_screen applyPointSize:size refreshRate:hz error:&err]) {
        fprintf(stderr, "APPLY FAIL: %s\n", err.localizedDescription.UTF8String);
        // code 4 = 未获得 2× 背板。该结论对「这块屏 + 这个尺寸」成立，
        // 记录后该尺寸不再列出。
        if (err.code == 4) {
            [[SDProbeCache shared] setResult:SDProbeResultDegraded forDisplay:physID size:size];
        }
        if (_restoring || _wakeRecovering) {
            // 自动恢复与唤醒恢复失败都不弹窗，只在状态行提示。
            _restoreFailure = _wakeRecovering ? @"唤醒后恢复失败，请手动选择"
                                              : @"上次的尺寸无法应用，请手动选择";
            if (_restoring) [self forgetConfiguration];
        } else {
            [self showError:err.localizedDescription];
        }
    } else {
        fprintf(stderr, "APPLY OK: %ux%u @%.2fHz\n",
                (unsigned)size.width, (unsigned)size.height, _screen.refreshRate);
        [[SDProbeCache shared] setResult:SDProbeResultHiDPI forDisplay:physID size:size];
        [self rememberConfigurationForDisplay:physID size:size hz:_screen.refreshRate];
        _lastGoodSize = _screen.pointSize;
        _lastGoodHz = _screen.refreshRate;
        _lastGoodPhysID = physID;
        _restoreFailure = nil;
        // 已经建好屏，本次唤醒不再重试。
        _rebuildOnWake = NO;
        _wakeBuildRetries = 0;
    }
    [self rescan];
}

- (void)turnOff {
    [_screen teardown];
    _restoreFailure = nil;
    // 用户主动关屏：不再自动建回来。
    _rebuildOnWake = NO;
    _wakeBuildRetries = 0;
    [self rescan];
}

#pragma mark - 提示

- (void)showAlert:(NSString *)title info:(NSString *)info {
    if (gSDRequestSelfTest) {
        fprintf(stderr, "ALERT: %s | %s\n", title.UTF8String, info.UTF8String);
        return;
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = info;
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"好"];
    [a runModal];
}

- (void)showError:(NSString *)msg {
    [self showAlert:@"无法应用这个组合"
               info:[NSString stringWithFormat:@"%@\n\n屏幕已被还原，换一个尺寸或刷新率再试。", msg]];
}

#pragma mark - 音量

/// 把控件状态对齐到 DDC 读到的值。
- (void)syncVolumeUI {
    unsigned v = _ddc.volume;
    unsigned max = _ddc.maximum ? _ddc.maximum : 100;
    _volumeMuted = (v == 0);
    if (_volumeSlider) {
        _volumeSlider.maxValue = max;
        _volumeSlider.doubleValue = v;
    }
    if (_volumeLabel) {
        _volumeLabel.stringValue = [NSString stringWithFormat:@"%u", v];
    }
    [self rebuildMenu];
}

/// 拖动期间只保留最新落点：写队列空闲时立即下发，写入进行中到达的落点不逐个下发，
/// 待本次写入结束后取最新值继续。
///
/// 完成标志在写队列内复位，回显另走主队列；回显执行时机不影响后续写入。
- (void)scheduleVolumeWrite:(unsigned)target {
    unsigned max = _ddc.maximum ? _ddc.maximum : 100;
    if (target > max) target = max;

    BOOL start = NO;
    @synchronized (self) {
        _pendingVolume = target;
        _volumeMuted = (target == 0);
        if (!_volumeWriting) {
            _volumeWriting = YES;
            start = YES;
        }
    }
    if (!start) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(_volumeQueue, ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;

        for (;;) {
            unsigned want;
            @synchronized (self) { want = self->_pendingVolume; }

            [self->_ddc setVolume:want error:NULL];

            BOOL settled = NO;
            @synchronized (self) {
                if (self->_pendingVolume == want) {
                    self->_volumeWriting = NO;
                    settled = YES;
                }
            }
            if (settled) break;
        }

        unsigned landed;
        @synchronized (self) { landed = self->_pendingVolume; }
        // 回显走主队列，执行时机不影响写入结果
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s || !s->_volumeLabel) return;
            s->_volumeLabel.stringValue = [NSString stringWithFormat:@"%u", landed];
        });
    });
}

- (void)volumeSliderChanged:(NSSlider *)slider {
    unsigned v = (unsigned)llround(slider.doubleValue);
    if (_volumeLabel) _volumeLabel.stringValue = [NSString stringWithFormat:@"%u", v];
    [self scheduleVolumeWrite:v];
}

- (void)toggleMute:(NSMenuItem *)item {
    // 静音状态由 scheduleVolumeWrite 依落点同步维护，这里只决定目标值
    unsigned fallback = _ddc.maximum ? (_ddc.maximum / 2) : 50;
    unsigned target;
    if (_volumeMuted) {
        target = _volumeSavedBeforeMute ?: fallback;
    } else {
        _volumeSavedBeforeMute = _ddc.volume ?: fallback;
        target = 0;
    }

    [self scheduleVolumeWrite:target];
    // DDC 写入是异步的，先按预期刷新界面
    if (_volumeSlider) _volumeSlider.doubleValue = target;
    if (_volumeLabel) _volumeLabel.stringValue = [NSString stringWithFormat:@"%u", target];
}

#pragma mark - 开机启动

- (BOOL)launchAtLoginSupported {
    if (@available(macOS 13.0, *)) return YES;
    return NO;
}

- (BOOL)launchAtLoginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

/// 登录项记录 app 当前所在路径，仅在应用程序目录内注册。
/// 从 build/ 或临时目录注册时，该目录被清理后登录项指向不存在的路径。
- (BOOL)isInApplicationsFolder {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSString *userApps = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    return [bundle hasPrefix:@"/Applications/"] ||
           [bundle hasPrefix:[userApps stringByAppendingString:@"/"]];
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)item {
    if (![self launchAtLoginSupported]) return;

    if (![self isInApplicationsFolder]) {
        [self showAlert:@"需要先安装"
                   info:@"请将 app 移入「应用程序」文件夹后再开启开机启动。"];
        return;
    }

    if (@available(macOS 13.0, *)) {
        SMAppService *service = SMAppService.mainAppService;
        NSError *err = nil;
        BOOL ok;
        if (service.status == SMAppServiceStatusEnabled) {
            ok = [service unregisterAndReturnError:&err];
        } else {
            ok = [service registerAndReturnError:&err];
        }

        if (!ok) {
            [self showAlert:@"无法修改登录项"
                       info:err.localizedDescription ?: @"系统拒绝了该操作。"];
        } else if (service.status == SMAppServiceStatusRequiresApproval) {
            [self showAlert:@"需要批准"
                       info:@"请在 系统设置 → 通用 → 登录项 中允许 Simple Display。"];
        }
        [self rebuildMenu];
    }
}

#pragma mark - 菜单

- (NSString *)statusText {
    if (_probing) return @"正在检测可用尺寸…";
    if (!_info) return @"未检测到显示器";
    if (!_screen.active) {
        return _restoreFailure ?: @"未启用";
    }
    return [NSString stringWithFormat:@"%u × %u  @ %.0fHz",
            (unsigned)_screen.pointSize.width,
            (unsigned)_screen.pointSize.height,
            _screen.refreshRate];
}

/// 菜单栏图标：显示器轮廓；启用时轮廓内出现 2×2 像素块。
/// 以 template image 提供，由系统按菜单栏明暗着色。
- (NSImage *)statusBarIconActive:(BOOL)active {
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(18, 18)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set];

        NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.3, 4.9, 15.4, 10.0)
                                                             xRadius:2.2
                                                             yRadius:2.2];
        frame.lineWidth = 1.3;
        [frame stroke];

        if (active) {
            for (NSInteger row = 0; row < 2; row++) {
                for (NSInteger col = 0; col < 2; col++) {
                    NSRect cell = NSMakeRect(5.9 + col * 4.2, 6.8 + row * 4.2, 2.0, 2.0);
                    [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:0.6 yRadius:0.6] fill];
                }
            }
        }

        NSBezierPath *stand = [NSBezierPath bezierPath];
        [stand moveToPoint:NSMakePoint(9, 4.9)];
        [stand lineToPoint:NSMakePoint(9, 3.1)];
        [stand moveToPoint:NSMakePoint(6.3, 2.4)];
        [stand lineToPoint:NSMakePoint(11.7, 2.4)];
        stand.lineWidth = 1.3;
        stand.lineCapStyle = NSLineCapStyleRound;
        [stand stroke];
        return YES;
    }];
    icon.template = YES;
    return icon;
}

/// 音量行：标题 + 滑块 + 数值。菜单项用自定义视图承载，拖动即时生效。
- (NSMenuItem *)volumeMenuItem {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"音量" action:nil keyEquivalent:@""];

    CGFloat width = 250, height = 26;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(27, 4, 30, 18)];
    title.stringValue = @"音量";
    title.bezeled = NO;
    title.drawsBackground = NO;
    title.editable = NO;
    title.selectable = NO;
    title.font = [NSFont menuFontOfSize:13];
    [box addSubview:title];

    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(60, 3, 150, 20)];
    slider.minValue = 0;
    slider.maxValue = _ddc.maximum ? _ddc.maximum : 100;
    slider.doubleValue = _ddc.volume;
    slider.continuous = YES;
    slider.target = self;
    slider.action = @selector(volumeSliderChanged:);
    [box addSubview:slider];
    _volumeSlider = slider;

    NSTextField *value = [[NSTextField alloc] initWithFrame:NSMakeRect(214, 4, 30, 18)];
    value.stringValue = [NSString stringWithFormat:@"%u", _ddc.volume];
    value.bezeled = NO;
    value.drawsBackground = NO;
    value.editable = NO;
    value.selectable = NO;
    value.alignment = NSTextAlignmentRight;
    value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [box addSubview:value];
    _volumeLabel = value;

    item.view = box;
    return item;
}

- (void)rebuildMenu {
    _volumeSlider = nil;
    _volumeLabel = nil;

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    NSMenuItem *st = [[NSMenuItem alloc] initWithTitle:[self statusText] action:nil keyEquivalent:@""];
    st.enabled = NO;
    [menu addItem:st];

    // 私有 API 缺失时在菜单中提示
    if (![SDVirtualScreen isPrivateAPIAvailable]) {
        NSMenuItem *warn = [[NSMenuItem alloc]
                            initWithTitle:@"缺少 CGVirtualDisplay，无法使用"
                                   action:nil keyEquivalent:@""];
        warn.enabled = NO;
        [menu addItem:warn];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    if (!_info) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"未检测到显示器" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [menu addItem:none];
        [self finishMenu:menu];
        return;
    }

    BOOL on = _screen.active;

    // 分辨率
    NSMenuItem *resRoot = [[NSMenuItem alloc] initWithTitle:@"分辨率" action:nil keyEquivalent:@""];
    NSMenu *resMenu = [[NSMenu alloc] init];
    for (NSValue *v in _info.pointSizes) {
        CGSize s = v.sizeValue;
        // 已知会降级的尺寸不列出：菜单只保留可用的档位
        if ([[SDProbeCache shared] resultForDisplay:_info.displayID size:s] == SDProbeResultDegraded) {
            continue;
        }
        NSMenuItem *it = [[NSMenuItem alloc]
                          initWithTitle:[NSString stringWithFormat:@"%u × %u",
                                         (unsigned)s.width, (unsigned)s.height]
                               action:@selector(pickResolution:)
                        keyEquivalent:@""];
        it.representedObject = v;
        it.target = self;
        if (on && (unsigned)_screen.pointSize.width == (unsigned)s.width &&
                  (unsigned)_screen.pointSize.height == (unsigned)s.height) {
            it.state = NSControlStateValueOn;
        }
        [resMenu addItem:it];
    }
    if (resMenu.numberOfItems == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"无可列出的尺寸"
                                                      action:nil keyEquivalent:@""];
        none.enabled = NO;
        [resMenu addItem:none];
    }
    resRoot.submenu = resMenu;
    [menu addItem:resRoot];

    // 刷新率
    NSMenuItem *hzRoot = [[NSMenuItem alloc] initWithTitle:@"刷新率" action:nil keyEquivalent:@""];
    NSMenu *hzMenu = [[NSMenu alloc] init];
    for (NSNumber *n in _info.refreshRates) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:
                          [NSString stringWithFormat:@"%.1f Hz", n.doubleValue]
                                                    action:@selector(pickRefresh:)
                                             keyEquivalent:@""];
        it.representedObject = n;
        it.target = self;
        if (on && fabs(_screen.refreshRate - n.doubleValue) < 0.6) it.state = NSControlStateValueOn;
        [hzMenu addItem:it];
    }
    if (hzMenu.numberOfItems == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"无可用的刷新率"
                                                      action:nil keyEquivalent:@""];
        none.enabled = NO;
        [hzMenu addItem:none];
    }
    hzRoot.submenu = hzMenu;
    [menu addItem:hzRoot];

    [menu addItem:[NSMenuItem separatorItem]];

    // 音量
    if (_ddc.isAvailable) {
        [menu addItem:[self volumeMenuItem]];

        NSMenuItem *mute = [[NSMenuItem alloc] initWithTitle:@"静音"
                                                      action:@selector(toggleMute:)
                                               keyEquivalent:@""];
        mute.target = self;
        mute.state = _volumeMuted ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:mute];

        [menu addItem:[NSMenuItem separatorItem]];
    }

    // 尺寸检测
    BOOL probed = [[SDProbeCache shared] hasAnyResultForDisplay:_info.displayID];
    NSString *probeTitle = _probing ? @"正在检测…"
                                    : (probed ? @"重新检测尺寸"
                                              : @"检测可用尺寸");
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:probeTitle
                                                   action:@selector(probeAction:)
                                            keyEquivalent:@""];
    probe.target = self;
    probe.enabled = (!on && !_probing);
    [menu addItem:probe];

    // 清除检测记录后，被隐藏的尺寸会重新列出
    NSMenuItem *forget = [[NSMenuItem alloc] initWithTitle:@"恢复全部尺寸"
                                                    action:@selector(forgetAction:)
                                             keyEquivalent:@""];
    forget.target = self;
    forget.enabled = probed && !_probing && !on;
    [menu addItem:forget];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"关闭虚拟屏"
                                                 action:@selector(turnOffAction)
                                          keyEquivalent:@""];
    off.target = self;
    off.enabled = on;
    [menu addItem:off];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"开机启动"
                                                   action:@selector(toggleLaunchAtLogin:)
                                            keyEquivalent:@""];
    login.target = self;
    login.enabled = [self launchAtLoginSupported];
    login.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];

    [self finishMenu:menu];
}

- (void)finishMenu:(NSMenu *)menu {
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出"
                                                  action:@selector(quitAction)
                                           keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    _statusItem.menu = menu;
    _statusItem.button.image = [self statusBarIconActive:_screen.active];
}

#pragma mark - 菜单代理

- (void)menuWillOpen:(NSMenu *)menu {
    if (!_ddc.isAvailable) return;

    // 读 DDC 约 100ms，置于后台，避免菜单阻塞
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(self) reader = weakSelf;
        if (!reader) return;
        if (![reader->_ddc reloadVolume:NULL]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            // 有未落地的写入时不回填：此时滑块值来自拖动，DDC 回读值已过期
            @synchronized (s) {
                if (s->_volumeWriting) return;
                unsigned v = s->_ddc.volume;
                s->_volumeMuted = (v == 0);
                s->_volumeSlider.maxValue = s->_ddc.maximum ? s->_ddc.maximum : 100;
                s->_volumeSlider.doubleValue = v;
                s->_volumeLabel.stringValue = [NSString stringWithFormat:@"%u", v];
            }
        });
    });
}

#pragma mark - Actions

- (void)pickResolution:(NSMenuItem *)item {
    CGSize s = [item.representedObject sizeValue];
    [self applyToDisplay:_info.displayID size:s refreshRate:[self preferredHz]];
}

- (void)pickRefresh:(NSMenuItem *)item {
    double hz = [item.representedObject doubleValue];
    [self applyToDisplay:_info.displayID size:[self preferredSize] refreshRate:hz];
}

- (void)probeAction:(NSMenuItem *)item {
    if (_probing) return;
    if (_screen.active) {
        [self showError:@"请先关闭虚拟屏，再开始检测。"];
        return;
    }

    CGDirectDisplayID did = _info.displayID;
    _probing = YES;
    [self rebuildMenu];

    __weak typeof(self) weakSelf = self;
    SDRunProbeAll(did, ^(unsigned w, unsigned h, int result) {
        [[SDProbeCache shared] setResult:(SDProbeResult)result
                             forDisplay:did
                                    size:CGSizeMake(w, h)];
    }, ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_probing = NO;
        [s rebuildMenu];
    });
}

- (void)forgetAction:(NSMenuItem *)item {
    [[SDProbeCache shared] forgetDisplay:_info.displayID];
    [self rebuildMenu];
}

/// 关闭虚拟屏时一并清除自动恢复记录。
- (void)turnOffAction { [self forgetConfiguration]; [self turnOff]; }
- (void)quitAction { [self turnOff]; [NSApp terminate:nil]; }

- (void)dumpMenuLine:(NSString *)text depth:(int)depth {
    printf("%*s%s\n", depth * 2, "", text.UTF8String);
}

- (void)dumpMenu:(NSMenu *)menu depth:(int)depth {
    for (NSMenuItem *it in menu.itemArray) {
        if (it.isSeparatorItem) { [self dumpMenuLine:@"----" depth:depth]; continue; }
        NSString *line = it.title;
        if (it.view) {
            NSString *extra = @"";
            if (it.view.subviews.count >= 3) {
                NSSlider *sl = (NSSlider *)it.view.subviews[1];
                NSTextField *tf = (NSTextField *)it.view.subviews[2];
                if ([sl isKindOfClass:[NSSlider class]]) {
                    extra = [NSString stringWithFormat:@" [slider %.0f/%.0f -> %@]",
                             sl.doubleValue, sl.maxValue, tf.stringValue];
                }
            }
            line = [line stringByAppendingString:extra];
        }
        if (it.state == NSControlStateValueOn) line = [line stringByAppendingString:@" [选中]"];
        [self dumpMenuLine:line depth:depth];
        if (it.submenu && it.submenu.numberOfItems <= 24) {
            [self dumpMenu:it.submenu depth:depth + 1];
        } else if (it.submenu) {
            [self dumpMenuLine:[NSString stringWithFormat:@"… %ld 项",
                                (long)it.submenu.numberOfItems]
                         depth:depth + 1];
        }
    }
}

- (void)dumpMenu {
    // 触发一次 DDC 读取，确保音量值已就绪
    [_ddc reloadVolume:NULL];
    [self rebuildMenu];
    printf("STATUSBAR: icon=%.0fx%.0f position=%ld title=\"%s\"\n",
           _statusItem.button.image.size.width,
           _statusItem.button.image.size.height,
           (long)_statusItem.button.imagePosition,
           _statusItem.button.title.UTF8String);
    [self dumpMenu:_statusItem.menu depth:0];
}

#pragma mark - 自检

- (void)spin:(double)sec {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:sec]];
}

- (void)runSelfTest {
    gSDRequestSelfTest = YES;

    if (!_info) { printf("FAIL: %s\n", "没有发现显示器"); exit(1); }
    printf("DISPLAY: %s  %zux%zu  %s\n", _info.name.UTF8String,
           _info.pixelWidth, _info.pixelHeight, _info.aspectLabel.UTF8String);
    printf("REFRESH: ");
    for (NSNumber *n in _info.refreshRates) printf("%.1f ", n.doubleValue);
    printf("\nSIZES(%lu): ", (unsigned long)_info.pointSizes.count);
    for (NSValue *v in _info.pointSizes) {
        CGSize s = v.sizeValue;
        printf("%ux%u ", (unsigned)s.width, (unsigned)s.height);
    }
    printf("\n");

    double hz = _info.refreshRates.count ? _info.refreshRates.lastObject.doubleValue : 60.0;
    CGSize def = _info.defaultPointSize;

    // 记录物理屏原始刷新率，用于验证还原
    double origHz = 0;
    CGDisplayModeRef orig = CGDisplayCopyDisplayMode(_info.displayID);
    if (orig) { origHz = CGDisplayModeGetRefreshRate(orig); CGDisplayModeRelease(orig); }

    [self applyToDisplay:_info.displayID size:def refreshRate:hz];
    printf("A apply %ux%u @%.0f -> active=%d\n", (unsigned)def.width, (unsigned)def.height, hz, _screen.active);
    [self spin:3.0];

    [self turnOff];
    usleep(600 * 1000);
    double afterHz = 0;
    CGDisplayModeRef after = CGDisplayCopyDisplayMode(_info.displayID);
    if (after) { afterHz = CGDisplayModeGetRefreshRate(after); CGDisplayModeRelease(after); }
    printf("B teardown -> active=%d  physHz=%.2f (原 %.2f) %s\n",
           _screen.active, afterHz, origHz,
           fabs(afterHz - origHz) < 0.6 ? "还原OK"
                                        : "还原失败");
    [self spin:2.0];

    // 用最低刷新率验证对齐与还原
    double lowHz = _info.refreshRates.count ? _info.refreshRates.firstObject.doubleValue : 60.0;
    [self applyToDisplay:_info.displayID size:def refreshRate:lowHz];
    double duringHz = 0;
    CGDisplayModeRef during = CGDisplayCopyDisplayMode(_info.displayID);
    if (during) { duringHz = CGDisplayModeGetRefreshRate(during); CGDisplayModeRelease(during); }
    printf("C apply %.0fHz -> active=%d  physHz=%.2f\n", lowHz, _screen.active, duringHz);
    [self spin:2.5];

    [self turnOff];
    usleep(600 * 1000);
    double finHz = 0;
    CGDisplayModeRef fin = CGDisplayCopyDisplayMode(_info.displayID);
    if (fin) { finHz = CGDisplayModeGetRefreshRate(fin); CGDisplayModeRelease(fin); }
    printf("D final -> active=%d  physHz=%.2f (原 %.2f) %s\n",
           _screen.active, finHz, origHz,
           fabs(finHz - origHz) < 0.6 ? "还原OK"
                                      : "还原失败");

    printf("DDC: available=%d volume=%u/%u\n", _ddc.isAvailable, _ddc.volume, _ddc.maximum);
    [self spin:1.0];
    exit(0);
}

@end
