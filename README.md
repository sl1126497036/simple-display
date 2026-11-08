# BetterLite VD

macOS 菜单栏工具。为外接显示器创建一块 2× 渲染的虚拟屏，再把该显示器硬件镜像上去，使 macOS 可获得面板原生分辨率之外的 HiDPI 尺寸。

装到 `/Applications/BetterLite VD.app`，或直接运行 `build/` 下的产物。运行后菜单栏出现 `HiDPI` 条目。

## 术语

| 术语 | 含义 |
|---|---|
| 点尺寸 | 系统 UI 使用的逻辑尺寸，菜单与命令行参数 `W H` 均指这个值 |
| 背板像素 | 虚拟屏实际渲染的像素尺寸。2× HiDPI 下等于点尺寸的两倍 |
| 硬件镜像 | 显示器作为 mirror slave 跟随虚拟屏输出，由 GPU 缩放到面板分辨率 |
| 降级 | 系统对某些点尺寸不生成 2× 背板，按 1× 呈现，UI 会撑出屏幕 |

## 安装

```bash
./build.sh
open "build/BetterLite VD.app"
```

安装到应用程序目录：

```bash
ditto "build/BetterLite VD.app" "/Applications/BetterLite VD.app"
```

首次运行若被 Gatekeeper 拦截，对 app 执行：

```bash
xattr -d com.apple.quarantine "/Applications/BetterLite VD.app"
```

## 使用

菜单栏 `HiDPI` 条目展开后，每块显示器一个子菜单：

```
2580 × 1080  @ 100Hz
────────────
显示器名 · 21:9 3440x1440 (主屏)  ▸
    当前：2580 × 1080  @ 100Hz
    分辨率  ▸  3440 × 1440 / … / 2580 × 1080 / …
    刷新率  ▸  60.0 Hz / 100.0 Hz
    检测可用尺寸
    恢复全部尺寸
    关闭本屏虚拟屏
────────────
全部关闭
重新扫描显示器
────────────
开机启动
────────────
退出
```

选择分辨率或刷新率即重建虚拟屏并镜像。关闭、退出或进程终止时解除镜像并恢复物理屏原模式。

### 命令行

应用与还原：

```bash
BIN="build/BetterLite VD.app/Contents/MacOS/BetterLiteVD"
"$BIN" --apply 2580 1080 100      # 主屏，点尺寸 2580×1080 @100Hz
"$BIN" --apply 2580 1080 100 3    # 指定 displayID
```

自检：

```bash
"$BIN" --selftest                 # 建屏 → 还原 → 换刷新率重建 → 还原
```

开机启动：

```bash
"$BIN" --login-status              # not-registered / enabled / requires-approval
"$BIN" --login on                  # 注册为登录项
"$BIN" --login off                 # 取消
```

诊断：

```bash
"$BIN" --diagnose                 # 输出显示器、原生像素、模式表统计、候选尺寸
"$BIN" --diagnose --probe         # 附加：逐档检测哪些点尺寸能拿到 2×
"$BIN" --probe-size 2580 1080 3   # 单档检测，输出 2x / 1x / fail
"$BIN" --probe-all 3              # 全部候选逐档检测，结果写入缓存
"$BIN" --probe 3                  # 输出某屏当前模式的 "点宽 背板宽"
"$BIN" --modes 3                  # 输出某屏全部模式的 "点宽 点高 像素宽 像素高"
```

## 适用范围

适用：

- 外接显示器在 macOS 上缺少所需 HiDPI 档位
- 需要以低于面板原生的点尺寸获得 2× 渲染
- 多显示器独立配置

不适用：

- 需要改变面板原生分辨率本身
- 内建屏（通常已是 2×，叠加虚拟屏只增加一层合成）
- 需要 HDR 或色彩配置随虚拟屏透传的场景

## 工作原理

1. `CGVirtualDisplay` 创建虚拟屏，申请 2× 背板
2. 子进程读取该屏真实模式，确认「点宽 == 请求宽」且「背板宽 == 2 × 请求宽」
3. 确认通过后，把物理屏镜像到虚拟屏；未通过则销毁虚拟屏，不改动显示状态

系统在虚拟屏上不提供模式数据库，因此 2× 判定必须在创建虚拟屏的进程之外完成：

| 调用 | 建屏进程内 | 子进程 |
|---|---|---|
| `CGDisplayCopyAllDisplayModes` | 返回 `NULL` | 返回完整模式表 |
| `CGDisplayCopyDisplayMode` | 返回 `NULL` | 返回当前模式 |
| `CGDisplayPixelsWide` | 首帧为点宽，重建时为 0 | 返回背板宽 |

## 兼容性与限制

- 依赖 `CGVirtualDisplay` 私有 API。系统移除该 API 时功能不可用，菜单会提示；程序启动时检查类与方法是否存在，不直接调用。
- 部分点尺寸会被系统降级为 1×，边界随面板、GPU 与系统版本变化。建屏后自检失败即回滚，屏幕状态不变。菜单中的「检测可用尺寸」会逐档检测并把结果写入缓存，已知降级的档位不再列出；「恢复全部尺寸」清除该记录。
- 缓存位于 `~/Library/Application Support/BetterLiteVD/probe-cache.plist`，按显示器 vendor、model 与面板原生像素区分。
- 镜像时 master 与 slave 不会自动同步刷新率，程序在建屏前将物理屏切换到目标刷新率，并在关闭时恢复原模式。
- 硬件镜像的 slave 不独立驱动，`CGDisplayIsActive` 返回 0 属正常状态，实际输出以系统报告的 `Hardware Mirror` 为准。
- 部分尺寸组合下画面可能出现轻微周期性闪烁。更换分辨率档位可规避，成因尚未定位。
- 开机启动使用 `SMAppService`（macOS 13 及以上）。注册记录 app 当前所在路径，因此仅在 app 位于「应用程序」文件夹时可用；在其它位置点击会提示先安装。

## 故障排查

```bash
BIN="build/BetterLite VD.app/Contents/MacOS/BetterLiteVD"
"$BIN" --diagnose --probe
```

输出包含 macOS 版本、私有 API 可用性、每块屏的原生像素、当前模式、模式表统计、刷新率列表、候选尺寸，以及各档尺寸的 2× 检测结果。

残留虚拟屏或镜像未解除时，终止进程后恢复：

```bash
pkill -f BetterLiteVD
```

## 文件

```
betterlite-vd/
├── Sources/
│   ├── main.m                     入口；--apply / --selftest / --diagnose / --probe / --modes / --probe-size / --probe-all
│   ├── BLAppDelegate.h/.m         菜单栏、多屏调度、热插拔
│   ├── BLDisplayInfo.h/.m         单屏信息、原生像素推断、候选尺寸与刷新率
│   ├── BLVirtualScreen.h/.m       虚拟屏生命周期：建屏 / 自检 / 镜像 / 还原
│   ├── BLProbeCache.h/.m          各屏可用尺寸记录
│   └── CGVirtualDisplayPrivate.h  私有 API 声明
├── Resources/Info.plist           LSUIElement（无 Dock 图标）
└── build.sh
```
