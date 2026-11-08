//
//  BLProbeCache.h
//  「这块显示器上哪些尺寸真能拿到 2×」的记忆。
//
//  系统对哪些尺寸降级成 1× 无公开规则，边界随面板、GPU 与系统版本变化。
//  记录检测结果：可用标 ✓，降级标 ⚠，避免重复尝试。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BLProbeResult) {
    BLProbeResultUnknown = -1,   // 没测过
    BLProbeResultDegraded = 0,   // 测过，被降级成 1×
    BLProbeResultHiDPI = 1,      // 测过，拿到 2× 背板
};

@interface BLProbeCache : NSObject

+ (instancetype)shared;

/// 该尺寸在该屏上的已知结果。键包含显示器身份，不同显示器互不影响。
- (BLProbeResult)resultForDisplay:(CGDirectDisplayID)did size:(CGSize)size;
- (void)setResult:(BLProbeResult)result forDisplay:(CGDirectDisplayID)did size:(CGSize)size;

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
