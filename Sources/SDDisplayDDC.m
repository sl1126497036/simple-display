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

    SDCreateFn create = (SDCreateFn)dlsym(handle, "IOAVServiceCreateWithService");
    _write = (SDWriteFn)dlsym(handle, "IOAVServiceWriteI2C");
    _read  = (SDReadFn)dlsym(handle, "IOAVServiceReadI2C");
    if (!create || !_write || !_read) return self;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("DCPAVServiceProxy"), &iter) != KERN_SUCCESS) {
        return self;
    }

    io_service_t service = IOIteratorNext(iter);
    if (service) {
        _service = create(kCFAllocatorDefault, service);
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    _available = (_service != NULL);
    return self;
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
- (BOOL)readVCP:(uint8_t)vcp current:(uint16_t *)current maximum:(uint16_t *)maximum {
    if (!_service) return NO;

    uint8_t request[2] = { kSDOpGetVCP, vcp };
    if (_write(_service, kSDDDCChipAddress, kSDDDCDataAddress, request, sizeof request) != kIOReturnSuccess) {
        return NO;
    }

    // 显示器应答有延迟，过早读取会得到空应答
    usleep(80 * 1000);

    uint8_t reply[11] = { 0 };
    if (_read(_service, kSDDDCChipAddress, kSDDDCDataAddress, reply, sizeof reply) != kIOReturnSuccess) {
        return NO;
    }

    // 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
    if (reply[2] != 0x02 || reply[3] != 0x00 || reply[4] != vcp) return NO;

    if (maximum) *maximum = (uint16_t)((reply[6] << 8) | reply[7]);
    if (current) *current = (uint16_t)((reply[8] << 8) | reply[9]);
    return YES;
}

- (BOOL)writeVCP:(uint8_t)vcp value:(uint16_t)value {
    if (!_service) return NO;

    uint8_t request[4] = {
        kSDOpSetVCP,
        vcp,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFF),
    };
    if (_write(_service, kSDDDCChipAddress, kSDDDCDataAddress, request, sizeof request) != kIOReturnSuccess) {
        return NO;
    }
    usleep(60 * 1000);
    return YES;
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
