//
//  SDVirtualScreen.h
//  一块物理显示器与一块虚拟屏的绑定。
//  负责：建虚拟屏 → 自检 2× 背板 → 将物理屏硬件镜像到它 → 还原。
//  每块物理屏一个实例，互不影响。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface SDVirtualScreen : NSObject

@property (nonatomic, readonly) CGDirectDisplayID physicalDisplayID;
@property (nonatomic, readonly) CGDirectDisplayID virtualDisplayID;
@property (nonatomic, readonly) BOOL active;
/// 生效中的点尺寸（active 时有效）
@property (nonatomic, readonly) CGSize pointSize;
@property (nonatomic, readonly) double refreshRate;

/// 该物理屏镜像前的原生像素尺寸。
/// 成为 mirror slave 后模式表不再代表其自身，重扫时以此值兜底，
/// 避免菜单显示虚拟屏的尺寸。
@property (nonatomic, readonly) CGSize originalNativePixelSize;

- (instancetype)initWithPhysicalDisplay:(CGDirectDisplayID)did;

/// 当前系统的 CGVirtualDisplay 私有 API 是否可用。
/// 不可用时禁用相关菜单项并显示说明。
+ (BOOL)isPrivateAPIAvailable;

/// 这个 displayID 是否本工具创建的虚拟屏（重扫与选默认屏时排除）。
+ (BOOL)isOurVirtualDisplay:(CGDirectDisplayID)did;

/// 单尺寸探测：1 = 能获得 2× 背板，0 = 会被系统降级成 1×，-1 = 建屏失败。
/// 不镜像，不改变用户当前画面；每档约 1~2 秒。
+ (int)probeSizeIsHiDPI:(CGSize)size
     forPhysicalDisplay:(CGDirectDisplayID)physID
            refreshRate:(double)hz;

/// 批量探测这块屏上哪些点尺寸能获得 2× 背板。
///
/// 系统对哪些尺寸降级成 1× 无公开规则，结论随面板、GPU 与 macOS 版本变化，
/// 只能逐个建屏探测。单档约 1~2 秒，仅在主动检测时调用。
+ (NSArray<NSValue *> *)probeHiDPISizesForPhysicalDisplay:(CGDirectDisplayID)physID
                                              pointSizes:(NSArray<NSValue *> *)candidates
                                             refreshRate:(double)hz;

/// 应用一组点尺寸 + 刷新率。失败时返回 NO 并给出原因，屏幕状态保持原样。
- (BOOL)applyPointSize:(CGSize)size refreshRate:(double)hz error:(NSError **)error;

/// 解除镜像并销毁虚拟屏（幂等）
- (void)teardown;

/// 当前配置是否仍与建屏时一致：虚拟屏在线、模式仍为记录的点尺寸 + 2× 背板、
/// 物理屏仍镜像它。显示器休眠唤醒后系统会重建显示管线，任一项可能被改变。
- (BOOL)isConfigurationIntact;

/// 自检状态摘要，用于唤醒前后的对照记录。
- (NSString *)configurationDiagnostic;

@end

NS_ASSUME_NONNULL_END
