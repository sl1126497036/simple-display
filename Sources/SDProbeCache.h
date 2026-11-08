//
//  SDProbeCache.h
//  记录这块显示器上各点尺寸能否获得 2× 背板。
//
//  系统对哪些尺寸降级成 1× 无公开规则，边界随面板、GPU 与系统版本变化。
//  检测结果按显示器身份缓存，避免每次启动重新探测。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SDProbeResult) {
    SDProbeResultUnknown = -1,   // 没测过
    SDProbeResultDegraded = 0,   // 测过，被降级成 1×
    SDProbeResultHiDPI = 1,      // 测过，获得 2× 背板
};

@interface SDProbeCache : NSObject

+ (instancetype)shared;

/// 显示器身份标识（vendor-model-原生像素）。displayID 随插拔与重启变化，
/// 跨进程判断是否同一块显示器时以此为准。
+ (NSString *)displayKeyForDisplay:(CGDirectDisplayID)did;

/// 该尺寸在该屏上的已知结果。键包含显示器身份，不同显示器互不影响。
- (SDProbeResult)resultForDisplay:(CGDirectDisplayID)did size:(CGSize)size;
- (void)setResult:(SDProbeResult)result forDisplay:(CGDirectDisplayID)did size:(CGSize)size;

/// 这块屏是否已有任何探测记录
- (BOOL)hasAnyResultForDisplay:(CGDirectDisplayID)did;
/// 这块屏已知可用的尺寸个数
- (NSUInteger)hiDPICountForDisplay:(CGDirectDisplayID)did;

/// 清除该屏记录（更换线材或系统版本后重新检测）
- (void)forgetDisplay:(CGDirectDisplayID)did;

- (void)flush;
/// 同步写入。命令行进程退出前使用。
- (void)flushSync;

@end

NS_ASSUME_NONNULL_END
