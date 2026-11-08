//
//  SDProbeCache.m
//

#import "SDProbeCache.h"
#import "SDDisplayInfo.h"

@implementation SDProbeCache {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *_store;
    BOOL _dirty;
}

+ (instancetype)shared {
    static SDProbeCache *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[SDProbeCache alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [NSMutableDictionary dictionary];
        [self load];
    }
    return self;
}

#pragma mark - 显示器身份

/// 显示器身份由 vendor、model 与面板原生像素组成。
/// displayID 随插拔与重启变化，单独使用会使记录失效；
/// 仅用 vendor+model 无法区分同型号的两块屏。
static NSString *SDDisplayKey(CGDirectDisplayID did) {
    uint32_t vendor = CGDisplayVendorNumber(did);
    uint32_t model  = CGDisplayModelNumber(did);
    CGSize native = [SDDisplayInfo nativePixelSizeForDisplay:did];
    if (native.width <= 0 || native.height <= 0) {
        native = CGSizeMake(CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did));
    }
    return [NSString stringWithFormat:@"%u-%u-%zux%zu",
            vendor, model, (size_t)llround(native.width), (size_t)llround(native.height)];
}

+ (NSString *)displayKeyForDisplay:(CGDirectDisplayID)did {
    return SDDisplayKey(did);
}

static NSString *SDSizeKey(CGSize size) {
    return [NSString stringWithFormat:@"%ux%u",
            (unsigned)llround(size.width), (unsigned)llround(size.height)];
}

#pragma mark - 读写

- (SDProbeResult)resultForDisplay:(CGDirectDisplayID)did size:(CGSize)size {
    NSDictionary *perSize = _store[SDDisplayKey(did)];
    NSNumber *n = perSize[SDSizeKey(size)];
    return n ? (SDProbeResult)n.integerValue : SDProbeResultUnknown;
}

- (void)setResult:(SDProbeResult)result forDisplay:(CGDirectDisplayID)did size:(CGSize)size {
    if (result == SDProbeResultUnknown) return;
    NSString *key = SDDisplayKey(did);
    NSMutableDictionary *perSize = _store[key];
    if (!perSize) {
        perSize = [NSMutableDictionary dictionary];
        _store[key] = perSize;
    }
    perSize[SDSizeKey(size)] = @(result);
    _dirty = YES;
    [self flush];
}

- (BOOL)hasAnyResultForDisplay:(CGDirectDisplayID)did {
    return _store[SDDisplayKey(did)].count > 0;
}

- (NSUInteger)hiDPICountForDisplay:(CGDirectDisplayID)did {
    NSUInteger n = 0;
    for (NSNumber *v in _store[SDDisplayKey(did)].allValues) {
        if (v.integerValue == SDProbeResultHiDPI) n++;
    }
    return n;
}

- (void)forgetDisplay:(CGDirectDisplayID)did {
    [_store removeObjectForKey:SDDisplayKey(did)];
    _dirty = YES;
    [self flush];
}

#pragma mark - 落盘

- (NSString *)cachePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"SimpleDisplay"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:@"probe-cache.plist"];
}

- (void)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self cachePath]];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    for (NSString *key in d) {
        NSDictionary *perSize = d[key];
        if (![perSize isKindOfClass:[NSDictionary class]]) continue;
        _store[key] = [perSize mutableCopy];
    }
}

- (void)flush {
    if (!_dirty) return;
    _dirty = NO;
    // 先快照再异步写入，避免与主队列的更新并发。
    NSDictionary *snapshot = [_store copy];
    NSString *path = [self cachePath];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [snapshot writeToFile:path atomically:YES];
    });
}

- (void)flushSync {
    _dirty = NO;
    [_store writeToFile:[self cachePath] atomically:YES];
}

@end
