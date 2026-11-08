//
//  BLDisplayInfo.m
//

#import "BLDisplayInfo.h"
#import <AppKit/AppKit.h>

static CFStringRef const kBLShowDuplicateModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");
static const double kBLMinPointWidth = 640.0;
static const double kBLMinPointHeight = 360.0;
static const double kBLAspectTolerance = 0.03;   // 3%

/// 读取模式的像素尺寸；虚拟屏与镜像态下返回 0 时退化为点尺寸。
static void BLPixelSizeOfMode(CGDisplayModeRef m, size_t *w, size_t *h) {
    size_t pw = CGDisplayModeGetPixelWidth(m);
    size_t ph = CGDisplayModeGetPixelHeight(m);
    if (pw == 0 || ph == 0) { pw = CGDisplayModeGetWidth(m); ph = CGDisplayModeGetHeight(m); }
    if (w) *w = pw;
    if (h) *h = ph;
}

@implementation BLDisplayInfo {
    NSArray<NSValue *> *_pointSizes;
    NSArray<NSNumber *> *_refreshRates;
}

#pragma mark - 原生像素推断

+ (CGSize)nativePixelSizeForDisplay:(CGDirectDisplayID)did {
    size_t bestW = 0, bestH = 0;
    BOOL sawUnscaled = NO;

    NSDictionary *opts = @{ (__bridge NSString *)kBLShowDuplicateModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);

    if (modes) {
        CFIndex n = CFArrayGetCount(modes);

        // 第一轮：仅取「点 == 像素」的模式，即面板全分辨率模式；
        // 缩放态下产生的 HiDPI 变体（点 2560 / 像素 5120）被排除。
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
            size_t pw, ph;
            BLPixelSizeOfMode(m, &pw, &ph);
            if (pw != w || ph != h) continue;              // 缩放模式，跳过
            if ((double)w * (double)h > (double)bestW * (double)bestH) {
                bestW = w; bestH = h; sawUnscaled = YES;
            }
        }

        // 第二轮：全表均为缩放模式时，最大像素尺寸即面板像素容量。
        if (!sawUnscaled) {
            size_t pxW = 0, pxH = 0;
            for (CFIndex i = 0; i < n; i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                size_t pw, ph;
                BLPixelSizeOfMode(m, &pw, &ph);
                if ((double)pw * (double)ph > (double)pxW * (double)pxH) { pxW = pw; pxH = ph; }
            }
            if (pxW && pxH) { bestW = pxW; bestH = pxH; }
        }
        CFRelease(modes);
    }

    if (bestW == 0 || bestH == 0) {
        bestW = CGDisplayPixelsWide(did);
        bestH = CGDisplayPixelsHigh(did);
    }
    return CGSizeMake((CGFloat)bestW, (CGFloat)bestH);
}

#pragma mark - 构造

+ (nullable instancetype)infoWithDisplayID:(CGDirectDisplayID)did {
    return [self infoWithDisplayID:did nativePixelSize:CGSizeZero];
}

+ (nullable instancetype)infoWithDisplayID:(CGDirectDisplayID)did
                          nativePixelSize:(CGSize)override {
    CGSize native = override;
    if (native.width <= 0 || native.height <= 0) {
        native = [self nativePixelSizeForDisplay:did];
    }
    if (native.width <= 0 || native.height <= 0) return nil;

    BLDisplayInfo *info = [[BLDisplayInfo alloc] init];
    if (!info) return nil;

    info->_displayID   = did;
    info->_pixelWidth  = (size_t)llround(native.width);
    info->_pixelHeight = (size_t)llround(native.height);
    info->_aspectRatio = (double)info->_pixelWidth / (double)info->_pixelHeight;
    info->_isMain      = CGDisplayIsMain(did);
    info->_isBuiltin   = CGDisplayIsBuiltin(did);
    info->_name        = [BLDisplayInfo nameForDisplay:did];
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
    size_t a = (size_t)llround(ar * 1000), b = 1000;
    size_t x = a, y = b;
    while (y) { size_t t = x % y; x = y; y = t; }
    size_t g = x ? x : 1;
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

    // 1) 这块屏自己认可的点尺寸（含系统已提供的 HiDPI 变体）。
    //    用点尺寸，因为虚拟屏的 CGVirtualDisplayMode 收的是点尺寸。
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

    // 2) 按本屏原生像素等比生成档位，覆盖系统没列出来、但虚拟屏能建的尺寸。
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

    // 仅收集面板原生像素尺寸下的刷新率。
    // 筛选使用像素尺寸而非点尺寸：HiDPI 或缩放生效时点宽 != 像素宽，
    // 按点宽比对会筛掉全部模式，仅剩兜底值。
    // 50/56/67Hz 等刷新率通常属于其他分辨率，列出后无法落到实际模式。
    NSDictionary *opts = @{ (__bridge NSString *)kBLShowDuplicateModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_displayID, (__bridge CFDictionaryRef)opts);
    if (modes) {
        CFIndex n = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t pw, ph;
            BLPixelSizeOfMode(m, &pw, &ph);
            if (pw != _pixelWidth || ph != _pixelHeight) continue;
            double r = CGDisplayModeGetRefreshRate(m);
            if (r <= 1.0) continue;
            BOOL dup = NO;
            for (NSNumber *e in list) if (fabs(e.doubleValue - r) < 0.6) { dup = YES; break; }
            if (!dup) [list addObject:@(r)];
        }
        CFRelease(modes);
    }

    if (list.count == 0) {
        double fallback = 60.0;
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(_displayID);
        if (cur) {
            double r = CGDisplayModeGetRefreshRate(cur);
            if (r > 1.0) fallback = r;
            CGDisplayModeRelease(cur);
        }
        [list addObject:@(fallback)];
    }

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
