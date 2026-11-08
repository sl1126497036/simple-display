# BetterLite VD

用 `CGVirtualDisplay` 造一块真 2× HiDPI 的虚拟显示器，再硬件镜像到物理屏 —— 绕过面板原生分辨率 / EDID 带宽 / `DisplayHints` 对 HiDPI 尺寸的限制。

菜单栏常驻，多显示器、任意分辨率、任意刷新率都支持。

## 为什么需要它

物理屏原生 3440×1440 时，想用 5120×2160（2560×1080 点 @2×）这种超原生尺寸：

- `scale-resolutions` 覆盖文件写不进去 —— 生成阶段就被 `DisplayHints.MaxW` 和 EDID 的 `MaxTotalPixelRate` 否掉
- 虚拟屏没有物理时序限制，背板想多大就多大，再让 GPU 缩放到面板输出

实测这块屏（PHL349X7，3440×1440@100Hz，M4）：

| 请求点尺寸 | 背板 | 结果 |
|---|---|---|
| 2580×1080 | 5160×2160 | ✅ 2× |
| 2560×1080 | 5120×2160 | ✅ 2× |
| 3440×1440 | 6880×2880 | ✅ 2× |
| 2064×864 | 4128×1728 | ❌ 降级 1×（已拦截） |

## 用法

```bash
./build.sh
open "build/BetterLite VD.app"
```

或安装：

```bash
ditto "build/BetterLite VD.app" "/Applications/BetterLite VD.app"
```

命令行：

```bash
BIN="build/BetterLite VD.app/Contents/MacOS/BetterLiteVD"
"$BIN" --apply 2580 1080 100        # 主屏，点尺寸 2580×1080 @100Hz
"$BIN" --apply 2580 1080 100 3      # 指定 displayID
"$BIN" --selftest                   # 自动跑 建/拆/重建
```

菜单结构：

```
未启用（物理屏原生）
────────────────────────
石老板的PHL349X7 · 21:9 3440x1440 (主屏)  ▸
    当前：2580 × 1080 @ 100Hz
    ────────────────
    分辨率  ▸  3440×1440 / 3268×1368 / … / 2580×1080 / … / 1280×536
    刷新率  ▸  50.0 / 56.0 / 60.0 / 67.0 / 70.0 / 72.0 / 75.0 / 100.0
    ────────────────
    关闭本屏虚拟屏
────────────────────────
全部关闭
重新扫描显示器
────────────────────────
退出
```

## 通用性设计

不假设任何固定分辨率、刷新率或显示器数量。

| 维度 | 做法 |
|---|---|
| **多显示器** | 每块物理屏一个 `BLVirtualScreen` 实例，各自独立建屏 / 镜像 / 还原，互不干扰 |
| **热插拔** | `CGDisplayRegisterReconfigurationCallback` → 主队列 `rescan`，自动清理已拔屏、重建菜单 |
| **候选分辨率** | 两条来源合并去重：① 该屏模式表里已认可的点尺寸 ② 按该屏宽高比从 0.50~1.00 生成 |
| **宽高比** | 逐屏计算，按 3% 容差归类（16:9 / 21:9 / 32:9 / 16:10 / 4:3 …），生成时严格保持本屏比例 |
| **刷新率** | 遍历该屏模式表收集实际支持值（去重 ±0.6Hz），不硬编码 |
| **刷新率对齐** | 镜像前先把物理屏切到目标刷新率模式，并用该模式的精确值建虚拟屏 —— 硬件镜像不会自己同步 slave |
| **默认尺寸** | 面板像素 ×0.75（3440 → 2580×1080），即「21:9 的 1080」 |

## 关键实现细节

### HiDPI 必须从外部进程判定

建虚拟屏的进程内读不到真实背板：

- `CGDisplayCopyAllDisplayModes` → `NULL`（虚拟屏没有模式数据库）
- `CGDisplayCopyDisplayMode` → `NULL`
- `CGDisplayPixelsWide` → 首帧返回点宽、重建时返回 0

所以自检改成 `fork()` + `execv(self, "--probe", displayID)`，子进程读 `CGDisplayCopyDisplayMode`，判据：

```
点宽 == 请求宽  &&  背板宽 == 2 × 请求宽
```

不满足就立刻回滚，**绝不做镜像**，屏幕不会出现任何变化。

### 4× 背板不是全部尺寸都能拿到

部分点尺寸会被系统静默降级成 1×（`Resolution` 与 `UI Looks like` 数值相同，UI 撑出屏幕）。
成因未定位 —— 已排除宽高奇偶、8 对齐、`sizeInMillimeters`(DPI)、`maxPixelsWide`。
目前靠运行时自检兜住，降级即回滚并提示。

### 镜像后物理屏 `active == 0` 是正常的

`Hardware Mirror` 的 slave 不独立驱动，`CGDisplayIsActive` 为 0 属正常态，不是黑屏。
判断画面是否正常要看 `system_profiler` 的 `Mirror Status: Hardware Mirror`。

### 解镜必须用保存的物理屏 ID

虚拟屏成为主屏后 `CGMainDisplayID()` 返回的是虚拟屏，用它解镜会解错对象。
`BLVirtualScreen` 全程持有 `physicalDisplayID`。

### 镜像调用会偶发返回 1001

刚解除镜像的过渡态里 `CGConfigureDisplayMirrorOfDisplay` 必失败一次。
先等 `CGDisplayIsActive(phys) && CGDisplayMirrorsDisplay(phys) == kCGNullDirectDisplay`，再重试（最多 5 次）。

## 文件

```
betterlite-vd/
├── Sources/
│   ├── main.m                     入口 / --probe / --apply / --selftest
│   ├── BLAppDelegate.h/.m         菜单栏、多屏调度、热插拔
│   ├── BLDisplayInfo.h/.m         单屏信息、候选分辨率、刷新率推导
│   ├── BLVirtualScreen.h/.m       单屏虚拟屏生命周期（建/自检/镜像/还原）
│   └── CGVirtualDisplayPrivate.h  私有 API 声明
├── Resources/Info.plist           LSUIElement（无 Dock 图标）
└── build.sh
```

## 安全性

| 场景 | 行为 |
|---|---|
| 关闭虚拟屏 | 解除镜像，物理屏回原生模式 |
| 退出 app | `applicationWillTerminate` + `atexit` 双重解除镜像 |
| `kill -9` | 虚拟屏随进程销毁，系统自动把物理屏恢复成主屏 |
| 尺寸不支持 | 建屏后自检失败即回滚，屏幕不变 |

## 环境

Apple Silicon + macOS 13+（实测 macOS 27.0.1 / M4 / 3440×1440@100Hz）。
用的是 `CGVirtualDisplay` 私有 API，系统大版本升级后可能失效。
