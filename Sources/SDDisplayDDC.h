//
//  SDDisplayDDC.h
//  显示器 DDC/CI 通道：读取与设置音量。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SDDDCErrorDomain;

/// 通过 DDC/CI 操作显示器音量（VCP 0x62）。
///
/// 需要显示器本身支持音量 VCP，且系统存在 DCPAVServiceProxy 服务；
/// 任一条件不满足时 available 为 NO，调用方应隐藏相关入口。
@interface SDDisplayDDC : NSObject

@property (nonatomic, readonly, getter=isAvailable) BOOL available;
@property (nonatomic, readonly) unsigned minimum;
@property (nonatomic, readonly) unsigned maximum;
@property (nonatomic, readonly) unsigned volume;

/// 读取当前音量，结果更新 volume 与 maximum。
- (BOOL)reloadVolume:(NSError **)error;

/// 设置音量，取值会被夹到 [minimum, maximum]。
- (BOOL)setVolume:(unsigned)volume error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
