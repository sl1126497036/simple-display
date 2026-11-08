//
//  BLDisplayInfo.h
//  一块物理显示器的静态信息与「可选点尺寸 / 刷新率」推导。
//  全部按显示器自身的像素尺寸与宽高比推导，不假设任何固定分辨率。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BLDisplayInfo : NSObject

/// 物理屏 displayID
@property (nonatomic, readonly) CGDirectDisplayID displayID;
/// 人类可读名（来自 NSScreen.localizedName，取不到时退化为 "Display <id>"）
@property (nonatomic, readonly, copy) NSString *name;
/// 面板原生像素
@property (nonatomic, readonly) size_t pixelWidth;
@property (nonatomic, readonly) size_t pixelHeight;
/// 宽高比（如 3440/1440 = 2.389）
@property (nonatomic, readonly) double aspectRatio;
/// 宽高比标签（"21:9"-style 或 "2.39:1"）
@property (nonatomic, readonly, copy) NSString *aspectLabel;
/// 候选「点尺寸」（CGSize 装箱），按面积从大到小。已按本屏宽高比过滤。
@property (nonatomic, readonly, copy) NSArray<NSValue *> *pointSizes;
/// 本屏实际支持的全部刷新率（升序、去重）
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *refreshRates;
/// 是否主屏
@property (nonatomic, readonly) BOOL isMain;

/// 取不到则返回 nil（显示器可能刚被拔掉）
+ (nullable instancetype)infoWithDisplayID:(CGDirectDisplayID)did;

/// 默认点尺寸：原生像素的 0.75（3440 → 2580×1080）
@property (nonatomic, readonly) CGSize defaultPointSize;

/// 当前正在使用的点尺寸（若当前是一块虚拟屏则无意义）
@property (nonatomic, readonly) CGSize currentPointSize;

@end

NS_ASSUME_NONNULL_END
