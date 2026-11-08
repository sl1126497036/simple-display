//
//  BLAppDelegate.h
//  菜单栏主控：为每块物理显示器维护一个 BLVirtualScreen 实例。
//

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BLAppDelegate : NSObject <NSApplicationDelegate>

/// 重新枚举显示器并重建菜单（显示器插拔后也可调用）
- (void)rescan;

/// 对某块物理屏应用一组点尺寸 / 刷新率
- (void)applyToDisplay:(CGDirectDisplayID)physID size:(CGSize)size refreshRate:(double)hz;

/// 关闭某块屏的虚拟屏
- (void)turnOffDisplay:(CGDirectDisplayID)physID;

/// 关闭全部
- (void)turnOffAll;

/// 自检入口（--selftest）
- (void)runSelfTest;

/// 启动参数 --apply 的落点
@property (nonatomic) BOOL hasStartupRequest;
@property (nonatomic) CGDirectDisplayID startupDisplayID;
@property (nonatomic) CGSize startupSize;
@property (nonatomic) double startupHz;

@end

NS_ASSUME_NONNULL_END
