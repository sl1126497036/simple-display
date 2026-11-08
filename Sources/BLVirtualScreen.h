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

- (instancetype)initWithPhysicalDisplay:(CGDirectDisplayID)did;

/// 应用一组点尺寸 + 刷新率。失败时返回 NO 并给出原因，且保证屏幕状态未被破坏。
- (BOOL)applyPointSize:(CGSize)size refreshRate:(double)hz error:(NSError **)error;

/// 解除镜像并销毁虚拟屏（幂等）
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
