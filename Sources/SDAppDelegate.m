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
/// 走子进程而不是在本进程里建屏，有两个原因：
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
@end

@implementation SDAppDelegate {
    NSStatusItem *_statusItem;

    SDDisplayInfo *_info;
    SDVirtualScreen *_screen;
    NSValue *_prefSize;
    double   _prefHz;
    BOOL     _probing;
    BOOL     _rebuilding;

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
    _statusItem.button.title = @"HiDPI";

    CGDisplayRegisterReconfigurationCallback(SDReconfigCallback, (__bridge void *)self);
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
    }

    if (gSDRequestSelfTest) [self runSelfTest];
    if (gSDRequestDumpMenu) { [self dumpMenu]; exit(0); }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self turnOff];
    CGDisplayRemoveReconfigurationCallback(SDReconfigCallback, (__bridge void *)self);
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
    [self rebuildMenu];
}

static void SDReconfigCallback(CGDirectDisplayID did, CGDisplayChangeSummaryFlags flags, void *ctx) {
    SDAppDelegate *delegate = (__bridge SDAppDelegate *)ctx;
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                 kCGDisplayDisabledFlag | kCGDisplayMovedFlag)) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate rescan]; });
    }
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
        // code 4 = 没拿到 2× 背板。这是「这块屏 + 这个尺寸」的固有结论，
        // 记录后该尺寸不再列出。
        if (err.code == 4) {
            [[SDProbeCache shared] setResult:SDProbeResultDegraded forDisplay:physID size:size];
        }
        [self showError:err.localizedDescription];
    } else {
        fprintf(stderr, "APPLY OK: %ux%u @%.2fHz\n",
                (unsigned)size.width, (unsigned)size.height, _screen.refreshRate);
        [[SDProbeCache shared] setResult:SDProbeResultHiDPI forDisplay:physID size:size];
    }
    [self rescan];
}

- (void)turnOff {
    [_screen teardown];
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

/// 连续拖动只写最后落点，避免 DDC 通道被写满。
- (void)scheduleVolumeWrite:(unsigned)target {
    unsigned max = _ddc.maximum ? _ddc.maximum : 100;
    if (target > max) target = max;

    @synchronized (self) {
        _pendingVolume = target;
        _volumeMuted = (target == 0);
    }

    if (_volumeWriting) return;
    _volumeWriting = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(_volumeQueue, ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        while (1) {
            unsigned want;
            @synchronized (self) { want = self->_pendingVolume; }
            [self->_ddc setVolume:want error:NULL];
            unsigned now;
            @synchronized (self) { now = self->_pendingVolume; }
            if (now == want) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (s) s->_volumeWriting = NO;
        });
    });
}

- (void)volumeSliderChanged:(NSSlider *)slider {
    unsigned v = (unsigned)llround(slider.doubleValue);
    if (_volumeLabel) _volumeLabel.stringValue = [NSString stringWithFormat:@"%u", v];
    [self scheduleVolumeWrite:v];
}

- (void)toggleMute:(NSMenuItem *)item {
    if (_volumeMuted) {
        unsigned restore = _volumeSavedBeforeMute ?: (_ddc.maximum / 2);
        [self scheduleVolumeWrite:restore];
    } else {
        _volumeSavedBeforeMute = _ddc.volume;
        [self scheduleVolumeWrite:0];
    }
    // DDC 写入是异步的，先按预期刷新界面
    _volumeMuted = !_volumeMuted;
    if (_volumeSlider) _volumeSlider.doubleValue = _volumeMuted ? 0 : _volumeSavedBeforeMute;
    if (_volumeLabel) {
        _volumeLabel.stringValue = _volumeMuted ? @"0"
                                                : [NSString stringWithFormat:@"%u", _volumeSavedBeforeMute];
    }
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

/// 登录项记录的是 app 当前所在路径。从 build/ 或临时目录注册，
/// 该目录被清理后登录项会指向不存在的路径，因此只在应用程序目录内注册。
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
    if (!_screen.active) return @"未启用";
    return [NSString stringWithFormat:@"%u × %u  @ %.0fHz",
            (unsigned)_screen.pointSize.width,
            (unsigned)_screen.pointSize.height,
            _screen.refreshRate];
}

- (NSString *)statusBarTitle {
    if (!_screen.active) return @"HiDPI";
    return [NSString stringWithFormat:@"%u×%u",
            (unsigned)_screen.pointSize.width,
            (unsigned)_screen.pointSize.height];
}

/// 音量行：标题 + 滑块 + 数值。菜单项用自定义 view 承载，拖动即时生效。
- (NSMenuItem *)volumeMenuItem {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"音量" action:nil keyEquivalent:@""];

    CGFloat width = 250, height = 26;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 4, 44, 18)];
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
                                    : (probed ? @"重新检测尺寸" : @"检测可用尺寸");
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
    _statusItem.button.title = [self statusBarTitle];
}

#pragma mark - 菜单代理

- (void)menuWillOpen:(NSMenu *)menu {
    if (!_ddc.isAvailable) return;

    // 读 DDC 约 100ms，放后台避免菜单卡住
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *err = nil;
        BOOL ok = [self->_ddc reloadVolume:&err];
        if (!ok) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            unsigned v = self->_ddc.volume;
            self->_volumeMuted = (v == 0);
            self->_volumeSlider.maxValue = self->_ddc.maximum ? self->_ddc.maximum : 100;
            self->_volumeSlider.doubleValue = v;
            self->_volumeLabel.stringValue = [NSString stringWithFormat:@"%u", v];
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

- (void)turnOffAction { [self turnOff]; }
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
            [self dumpMenuLine:[NSString stringWithFormat:@"… %ld 项", (long)it.submenu.numberOfItems]
                         depth:depth + 1];
        }
    }
}

- (void)dumpMenu {
    // 触发一次 DDC 读取，确保音量值已就绪
    [_ddc reloadVolume:NULL];
    [self rebuildMenu];
    printf("STATUSBAR: %s\n", _statusItem.button.title.UTF8String);
    [self dumpMenu:_statusItem.menu depth:0];
}

#pragma mark - 自检

- (void)spin:(double)sec {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:sec]];
}

- (void)runSelfTest {
    gSDRequestSelfTest = YES;

    if (!_info) { printf("FAIL: 没有发现显示器\n"); exit(1); }
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
           _screen.active, afterHz, origHz, (fabs(afterHz - origHz) < 0.6 ? "还原OK" : "还原失败"));
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
           _screen.active, finHz, origHz, (fabs(finHz - origHz) < 0.6 ? "还原OK" : "还原失败"));

    printf("DDC: available=%d volume=%u/%u\n", _ddc.isAvailable, _ddc.volume, _ddc.maximum);
    [self spin:1.0];
    exit(0);
}

@end
