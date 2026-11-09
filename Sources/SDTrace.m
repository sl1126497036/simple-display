//
//  SDTrace.m
//

#import "SDTrace.h"

#import <stdio.h>

void SDTrace(NSString *format, ...) {
    static NSString *const kSwitch = @"/tmp/sd-trace-on";
    static NSString *const kLog    = @"/tmp/sd-volume.log";

    if (![NSFileManager.defaultManager fileExistsAtPath:kSwitch]) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *line = [NSString stringWithFormat:@"%.3f [%d] %@\n", now, getpid(), body];

    FILE *fp = fopen(kLog.UTF8String, "a");
    if (!fp) return;
    fputs(line.UTF8String, fp);
    fclose(fp);
}
