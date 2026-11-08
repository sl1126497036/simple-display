//
//  BLDisplayInfo.m
//

#import "BLDisplayInfo.h"
#import <AppKit/AppKit.h>

static CFStringRef const kBLShowDuplicateModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");
static const double kBLMinPointWidth = 640.0;
static const double kBLMinPointHeight = 360.0;
static const double kBLAspectTolerance = 0.03;   // 3%

@implementation BLDisplayInfo {
    NSArray<NSValue *> *_pointSizes;
    NSArray<NSNumber *> *_refreshRates;
}

#pragma mark - 构造

+ (nullable instancetype)infoWithDisplayID:(CGDirectDisplayID)did {
    size_t pw = CGDisplayPixelsWide(did);
    size_t ph = CGDisplayPixelsHigh(did);
    if (pw == 0 || ph == 0) return nil;

    BLDisplayInfo *info = [[BLDisplayInfo alloc] init];
    if (!info) return nil;

    info->_displayID  = did;
    info->_pixelWidth = pw;
    info->_pixelHeight = ph;
    info->_aspectRatio = (double)pw / (double)ph;
    info->_isMain = CGDisplayIsMain(did);
    info->_name = [BLDisplayInfo nameForDisplay:did];
    info->_aspectLabel = [BLDisplayInfo labelForAspect:info->_aspectRatio];

    [info buildPointSizes];
    [info buildRefreshRates];
    return info;
}

+ (NSString *)nameForDisplay:(CGDirectDisplayID)did {
    if ([NSThread isMainThread]) {
        for (NSScreen *s in [NSScreen screens]) {
            NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
            if (n && [n unsignedIntValue] == did) {
                NSString *nm = s.localizedName;
                if (nm.length) return nm;
            }
        }
    }
    return [NSString stringWithFormat:@"Display %u", did];
}

+ (NSString *)labelForAspect:(double)ar {
    static const struct { double ar; const char *label; } table[] = {
        {16.0 / 9.0,  "16:9"},
        {16.0 / 10.0, "16:10"},
        {21.0 / 9.0,  "21:9"},
        {32.0 / 9.0,  "32:9"},
        {4.0 / 3.0,   "4:3"},
        {3.0 / 2.0,   "3:2"},
        {5.0 / 4.0,   "5:4"},
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (fabs(ar - table[i].ar) / table[i].ar <= kBLAspectTolerance) {
            return [NSString stringWithUTF8String:table[i].label];
        }
    }
    size_t g = 1, a = (size_t)llround(ar * 1000), b = 1000;
    size_t x = a, y = b;
    while (y) { size_t t = x % y; x = y; y = t; }
    g = x ? x : 1;
    a /= g; b /= g;
    if (a <= 64 && b <= 64) return [NSString stringWithFormat:@"%zu:%zu", a, b];
    return [NSString stringWithFormat:@"%.2f:1", ar];
}

#pragma mark - 候选点尺寸

- (NSArray<NSValue *> *)pointSizes { return _pointSizes ?: @[]; }

- (void)buildPointSizes {
    NSMutableDictionary<NSString *, NSValue *> *dict = [NSMutableDictionary dictionary];

    void (^add)(unsigned, unsigned) = ^(unsigned w, unsigned h) {
        if ((double)w < kBLMinPointWidth || (double)h < kBLMinPointHeight) return;
        double ar = (double)w / (double)h;
        if (fabs(ar - _aspectRatio) / _aspectRatio > kBLAspectTolerance) return;
        NSString *key = [NSString stringWithFormat:@"%ux%u", w, h];
        if (!dict[key]) dict[key] = [NSValue valueWithSize:CGSizeMake(w, h)];
    };

    // 1) 物理屏已认可的点尺寸（含系统提供的 HiDPI 变体）
    NSDictionary *opts = @{ (__bridge NSString *)kBLShowDuplicateModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_displayID, (__bridge CFDictionaryRef)opts);
    if (modes) {
        CFIndex n = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            add((unsigned)CGDisplayModeGetWidth(m), (unsigned)CGDisplayModeGetHeight(m));
        }
        CFRelease(modes);
    }

    // 2) 按本屏比例生成档位（覆盖系统没给出、但虚拟屏能建的尺寸）
    static const double ratios[] = {1.00, 0.95, 0.90, 0.85, 0.80, 0.75, 0.70, 0.65, 0.60, 0.50};
    for (size_t i = 0; i < sizeof(ratios) / sizeof(ratios[0]); i++) {
        unsigned w = (unsigned)(llround((double)_pixelWidth * ratios[i] / 2.0) * 2.0);
        unsigned h = (unsigned)(llround((double)w / _aspectRatio / 2.0) * 2.0);
        add(w, h);
    }

    _pointSizes = [dict.allValues sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGSize sa = a.sizeValue, sb = b.sizeValue;
        double aa = sa.width * sa.height, ab = sb.width * sb.height;
        if (aa > ab) return NSOrderedAscending;
        if (aa < ab) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

#pragma mark - 刷新率

- (NSArray<NSNumber *> *)refreshRates { return _refreshRates ?: @[]; }

- (void)buildRefreshRates {
    NSMutableArray<NSNumber *> *list = [NSMutableArray array];

    // 只收「面板原生像素尺寸」下的刷新率。模式表里 50/56/67Hz 之类往往属于别的分辨率，
    // 列出来会让用户选了个实际落不到的值。
    NSDictionary *opts = @{ (__bridge NSString *)kBLShowDuplicateModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_displayID, (__bridge CFDictionaryRef)opts);
    if (modes) {
        CFIndex n = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            if (CGDisplayModeGetWidth(m) != _pixelWidth) continue;
            if (CGDisplayModeGetHeight(m) != _pixelHeight) continue;
            double r = CGDisplayModeGetRefreshRate(m);
            if (r <= 1.0) continue;
            BOOL dup = NO;
            for (NSNumber *e in list) if (fabs(e.doubleValue - r) < 0.6) { dup = YES; break; }
            if (!dup) [list addObject:@(r)];
        }
        CFRelease(modes);
    }

    if (list.count == 0) [list addObject:@60.0];

    _refreshRates = [list sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
}

#pragma mark - 尺寸

- (CGSize)defaultPointSize {
    unsigned w = (unsigned)(llround((double)_pixelWidth * 0.75 / 2.0) * 2.0);
    unsigned h = (unsigned)(llround((double)w / _aspectRatio / 2.0) * 2.0);
    return CGSizeMake(w, h);
}

- (CGSize)currentPointSize {
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(_displayID);
    if (!m) return CGSizeZero;
    CGSize s = CGSizeMake(CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m));
    CGDisplayModeRelease(m);
    return s;
}

@end
