//
//  SDDisplayDDC.m
//

#import "SDDisplayDDC.h"

#import <dlfcn.h>
#import <IOKit/IOKitLib.h>

NSString * const SDDDCErrorDomain = @"SimpleDisplay.DDC";

typedef CFTypeRef SDIOAVServiceRef;
typedef CFTypeRef (*SDCreateFn)(CFAllocatorRef, io_service_t);
typedef IOReturn  (*SDWriteFn)(SDIOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn  (*SDReadFn)(SDIOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

/// 显示器在 DDC/CI 总线上的 7 位地址（8 位地址 0x6E 右移一位）。
static const uint32_t kSDDDCChipAddress = 0x37;
/// DDC/CI 通道的 I2C 子地址。
static const uint32_t kSDDDCDataAddress = 0x51;

/// VCP 0x62 = 音量。
static const uint8_t kSDVCPVolume = 0x62;

/// DDC/CI 操作码。
static const uint8_t kSDOpGetVCP = 0x01;
static const uint8_t kSDOpSetVCP = 0x03;

static NSError *SDDDCError(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:SDDDCErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: reason }];
}

@implementation SDDisplayDDC {
    SDIOAVServiceRef _service;
    SDCreateFn _create;
    SDWriteFn _write;
    SDReadFn  _read;
    NSLock   *_lock;

    unsigned _volume;
    unsigned _maximum;
    BOOL     _available;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _lock = [[NSLock alloc] init];
    _maximum = 100;
    _volume = 0;

    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) return self;

    _create = (SDCreateFn)dlsym(handle, "IOAVServiceCreateWithService");
    _write  = (SDWriteFn)dlsym(handle, "IOAVServiceWriteI2C");
    _read   = (SDReadFn)dlsym(handle, "IOAVServiceReadI2C");
    if (!_create || !_write || !_read) return self;

    [self openChannel];
    _available = (_service != NULL);
    return self;
}

/// 重新枚举 DCPAVServiceProxy 并建立通道。
///
/// 显示器重配（虚拟屏建立、镜像切换、模式变更）会销毁旧的 proxy，
/// 已持有的 handle 随之失效，之后的读写会静默失败；因此失败时必须重建。
/// 调用方需持有 _lock，启动路径除外。
- (BOOL)openChannel {
    if (_service) {
        CFRelease(_service);
        _service = NULL;
    }
    if (!_create) return NO;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("DCPAVServiceProxy"), &iter) != KERN_SUCCESS) {
        return NO;
    }

    // 逐个记录候选：多路 DCPAVServiceProxy 时取枚举到的第一个，记录其余便于对照
    int index = 0;
    io_service_t service = 0;
    io_service_t candidate = IOIteratorNext(iter);
    while (candidate) {
        uint64_t eid = 0;
        IORegistryEntryGetRegistryEntryID(candidate, &eid);
        CFTypeRef loc = IORegistryEntryCreateCFProperty(candidate, CFSTR("Location"),
                                                        kCFAllocatorDefault, 0);
        if (loc) CFRelease(loc);

        if (index == 0) {
            service = candidate;
        } else {
            IOObjectRelease(candidate);
        }
        index++;
        candidate = IOIteratorNext(iter);
    }
    IOObjectRelease(iter);

    if (service) {
        _service = _create(kCFAllocatorDefault, service);
        IOObjectRelease(service);
    }

    return _service != NULL;
}

- (void)refreshChannel {
    [_lock lock];
    if (_service) {
        CFRelease(_service);
        _service = NULL;
    }
    [_lock unlock];
}

- (void)dealloc {
    if (_service) CFRelease(_service);
}

- (BOOL)isAvailable { return _available; }
- (unsigned)minimum { return 0; }
- (unsigned)maximum { return _maximum; }
- (unsigned)volume  { return _volume; }

#pragma mark - DDC/CI 收发

/// 读取一个 VCP。驱动负责补 0x80|长度 与校验字节，载荷仅含操作码与参数。
- (BOOL)readVCPOnce:(uint8_t)vcp current:(uint16_t *)current maximum:(uint16_t *)maximum {
    if (!_service) return NO;

    uint8_t request[2] = { kSDOpGetVCP, vcp };
    IOReturn rq = _write(_service, kSDDDCChipAddress, kSDDDCDataAddress, request, sizeof request);
    if (rq != kIOReturnSuccess) {
        return NO;
    }

    // 显示器应答有延迟，过早读取会得到空应答
    usleep(80 * 1000);

    uint8_t reply[11] = { 0 };
    IOReturn rr = _read(_service, kSDDDCChipAddress, kSDDDCDataAddress, reply, sizeof reply);
    if (rr != kIOReturnSuccess) {
        return NO;
    }

    // 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>

    if (reply[2] != 0x02 || reply[3] != 0x00 || reply[4] != vcp) return NO;

    if (maximum) *maximum = (uint16_t)((reply[6] << 8) | reply[7]);
    if (current) *current = (uint16_t)((reply[8] << 8) | reply[9]);
    return YES;
}

- (BOOL)readVCP:(uint8_t)vcp current:(uint16_t *)current maximum:(uint16_t *)maximum {
    if ([self readVCPOnce:vcp current:current maximum:maximum]) return YES;

    // 通道可能已随显示重配失效，重建后再试一次
    if (![self openChannel]) return NO;
    usleep(40 * 1000);
    return [self readVCPOnce:vcp current:current maximum:maximum];
}

- (BOOL)writeVCPOnce:(uint8_t)vcp value:(uint16_t)value {
    if (!_service) {
        return NO;
    }

    uint8_t request[4] = {
        kSDOpSetVCP,
        vcp,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFF),
    };
    IOReturn r = _write(_service, kSDDDCChipAddress, kSDDDCDataAddress, request, sizeof request);
    if (r != kIOReturnSuccess) {
        return NO;
    }

    usleep(50 * 1000);

    // 显示器对 SET 也会返回一条消息。不读走它，命令缓冲会一直被占用，
    // 后续 SET 将被静默丢弃（写入仍返回成功）。这里只做读空，不校验内容。
    uint8_t reply[11] = { 0 };
    (void)_read(_service, kSDDDCChipAddress, kSDDDCDataAddress, reply, sizeof reply);

    return YES;
}

- (BOOL)writeVCP:(uint8_t)vcp value:(uint16_t)value {
    if ([self writeVCPOnce:vcp value:value]) return YES;

    // 通道可能已随显示重配失效，重建后再试一次
    if (![self openChannel]) return NO;
    usleep(40 * 1000);
    return [self writeVCPOnce:vcp value:value];
}

#pragma mark - 音量

- (BOOL)reloadVolume:(NSError **)error {
    if (!_available) {
        if (error) *error = SDDDCError(1, @"当前系统未提供 DDC/CI 通道。");
        return NO;
    }

    [_lock lock];
    BOOL ok = NO;
    uint16_t current = 0, maximum = 0;
    // 部分显示器首个请求不应答，重试三次
    for (int attempt = 0; attempt < 3 && !ok; attempt++) {
        ok = [self readVCP:kSDVCPVolume current:&current maximum:&maximum];
        if (!ok) usleep(40 * 1000);
    }
    if (ok) {
        _maximum = maximum > 0 ? maximum : 100;
        _volume = current;
    }
    [_lock unlock];


    if (!ok && error) {
        *error = SDDDCError(2, @"显示器未响应音量查询。");
    }
    return ok;
}

- (BOOL)setVolume:(unsigned)volume error:(NSError **)error {
    if (!_available) {
        if (error) *error = SDDDCError(1, @"当前系统未提供 DDC/CI 通道。");
        return NO;
    }

    if (volume > _maximum) volume = _maximum;

    [_lock lock];
    BOOL ok = [self writeVCP:kSDVCPVolume value:(uint16_t)volume];
    if (ok) _volume = volume;
    [_lock unlock];


    if (!ok && error) {
        *error = SDDDCError(3, @"写入音量失败。");
    }
    return ok;
}

@end
