//
//  SDAppDelegate.h
//  菜单栏主控：为当前显示器维护一块虚拟屏，并提供分辨率、刷新率与音量控制。
//

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface SDAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

/// 对当前显示器应用一组点尺寸 / 刷新率
- (void)applyToDisplay:(CGDirectDisplayID)physID size:(CGSize)size refreshRate:(double)hz;

/// 关闭虚拟屏，恢复物理屏
- (void)turnOff;

/// 自检入口（--selftest）
- (void)runSelfTest;

/// 启动参数 --apply 的落点
@property (nonatomic) BOOL hasStartupRequest;
@property (nonatomic) CGDirectDisplayID startupDisplayID;
@property (nonatomic) CGSize startupSize;
@property (nonatomic) double startupHz;

@end

NS_ASSUME_NONNULL_END
