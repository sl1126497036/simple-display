//
//  SDTrace.h
//  临时诊断输出：文件存在时才写日志，不影响正常运行。
//

#import <Foundation/Foundation.h>

/// 仅在 /tmp/sd-trace-on 存在时追加写入 /tmp/sd-volume.log。
void SDTrace(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
