//
//  BLProbeCache.m
//

#import "BLProbeCache.h"
#import "BLDisplayInfo.h"

@implementation BLProbeCache {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *_store;
    BOOL _dirty;
}

+ (instancetype)shared {
    static BLProbeCache *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[BLProbeCache alloc] init]; });
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
static NSString *BLDisplayKey(CGDirectDisplayID did) {
    uint32_t vendor = CGDisplayVendorNumber(did);
    uint32_t model  = CGDisplayModelNumber(did);
    CGSize native = [BLDisplayInfo nativePixelSizeForDisplay:did];
    if (native.width <= 0 || native.height <= 0) {
        native = CGSizeMake(CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did));
    }
    return [NSString stringWithFormat:@"%u-%u-%zux%zu",
            vendor, model, (size_t)llround(native.width), (size_t)llround(native.height)];
}

static NSString *BLSizeKey(CGSize size) {
    return [NSString stringWithFormat:@"%ux%u",
            (unsigned)llround(size.width), (unsigned)llround(size.height)];
}

#pragma mark - 读写

- (BLProbeResult)resultForDisplay:(CGDirectDisplayID)did size:(CGSize)size {
    NSDictionary *perSize = _store[BLDisplayKey(did)];
    NSNumber *n = perSize[BLSizeKey(size)];
    return n ? (BLProbeResult)n.integerValue : BLProbeResultUnknown;
}

- (void)setResult:(BLProbeResult)result forDisplay:(CGDirectDisplayID)did size:(CGSize)size {
    if (result == BLProbeResultUnknown) return;
    NSString *key = BLDisplayKey(did);
    NSMutableDictionary *perSize = _store[key];
    if (!perSize) {
        perSize = [NSMutableDictionary dictionary];
        _store[key] = perSize;
    }
    perSize[BLSizeKey(size)] = @(result);
    _dirty = YES;
    [self flush];
}

- (BOOL)hasAnyResultForDisplay:(CGDirectDisplayID)did {
    return _store[BLDisplayKey(did)].count > 0;
}

- (NSUInteger)hiDPICountForDisplay:(CGDirectDisplayID)did {
    NSUInteger n = 0;
    for (NSNumber *v in _store[BLDisplayKey(did)].allValues) {
        if (v.integerValue == BLProbeResultHiDPI) n++;
    }
    return n;
}

- (void)forgetDisplay:(CGDirectDisplayID)did {
    [_store removeObjectForKey:BLDisplayKey(did)];
    _dirty = YES;
    [self flush];
}

#pragma mark - 落盘

- (NSString *)cachePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"BetterLiteVD"];
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
