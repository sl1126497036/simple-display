//
//  BLVirtualScreen.h
//  一块物理显示器 ↔ 一块虚拟屏 的绑定。
//  负责：建虚拟屏 → 自检 2× 背板 → 把物理屏硬件镜像到它 → 还原。
//  每块物理屏一个实例，互不影响。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BLVirtualScreen : NSObject

@property (nonatomic, readonly) CGDirectDisplayID physicalDisplayID;
@property (nonatomic, readonly) CGDirectDisplayID virtualDisplayID;
@property (nonatomic, readonly) BOOL active;
/// 生效中的点尺寸（active 时有效）
@property (nonatomic, readonly) CGSize pointSize;
@property (nonatomic, readonly) double refreshRate;

/// 该物理屏被镜像之前的原生像素尺寸。
/// 成为 mirror slave 后模式表不再代表其自身，重扫时以此值兜底，
/// 避免菜单显示虚拟屏的尺寸。
@property (nonatomic, readonly) CGSize originalNativePixelSize;

- (instancetype)initWithPhysicalDisplay:(CGDirectDisplayID)did;

/// 当前系统的 CGVirtualDisplay 私有 API 是否可用。
/// 不可用时菜单要禁用并给出说明，而不是等用户点击后崩掉。
+ (BOOL)isPrivateAPIAvailable;

/// 这个 displayID 是否本工具创建的虚拟屏（重扫、选默认屏时要把自己排除掉）。
+ (BOOL)isOurVirtualDisplay:(CGDirectDisplayID)did;

/// 单尺寸探测：1 = 能拿到 2× 背板，0 = 会被系统降级成 1×，-1 = 建屏失败。
/// 不镜像，不改变用户当前画面；每档约 1~2 秒。
+ (int)probeSizeIsHiDPI:(CGSize)size
     forPhysicalDisplay:(CGDirectDisplayID)physID
            refreshRate:(double)hz;

/// 批量探测这块屏上哪些点尺寸真能拿到 2× 背板。
///
/// 系统对哪些尺寸降级成 1× 无公开规则，结论随面板、GPU 与 macOS 版本变化，
/// 只能逐个建屏探测。单档约 1~2 秒，仅在主动检测时调用。
+ (NSArray<NSValue *> *)probeHiDPISizesForPhysicalDisplay:(CGDirectDisplayID)physID
                                              pointSizes:(NSArray<NSValue *> *)candidates
                                             refreshRate:(double)hz;

/// 应用一组点尺寸 + 刷新率。失败时返回 NO 并给出原因，且保证屏幕状态未被破坏。
- (BOOL)applyPointSize:(CGSize)size refreshRate:(double)hz error:(NSError **)error;

/// 解除镜像并销毁虚拟屏（幂等）
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
