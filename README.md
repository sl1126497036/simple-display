# Simple Display

[English](README.en.md)

macOS HiDPI 工具。为外接显示器以虚拟屏投影的方式开启HiDPI，让高分辨率显示器搭配macOS纵享丝滑。同时可通过 DDC/CI 控制显示器音量。

本项目由 DeepSeek-V4.1-Flash 编写，只在飞利浦 3440×1440 显示器上验证，未适配其他显示器。

## 术语

| 术语 | 含义 |
|---|---|
| 点尺寸 | 系统 UI 使用的逻辑尺寸，菜单与命令行参数 `W H` 均指这个值 |
| 虚拟屏 | 由 `CGVirtualDisplay` 创建的离屏显示器对象，承载 2× 背板，生命周期绑定创建它的进程 |
| 背板像素 | 虚拟屏实际渲染的像素尺寸。2× HiDPI 下等于点尺寸的两倍 |
| 硬件镜像 | 显示器作为 mirror slave 跟随虚拟屏输出，由 GPU 缩放到面板分辨率 |
| 降级 | 系统对某些点尺寸不生成 2× 背板，按 1× 呈现，UI 会撑出屏幕 |
| VCP | DDC/CI 的可控参数编号，0x62 为音量，0x10 为亮度 |

## 安装

```bash
./build.sh
ditto "build/Simple Display.app" "/Applications/Simple Display.app"
open "/Applications/Simple Display.app"
```

需要 macOS 13 及以上。开机启动依赖 `SMAppService`，仅在 app 位于「应用程序」文件夹时可用。

首次运行若被 Gatekeeper 拦截：

```bash
xattr -d com.apple.quarantine "/Applications/Simple Display.app"
```

## 使用

- 选择分辨率或刷新率即重建虚拟屏并镜像。关闭、退出或进程终止时解除镜像并恢复物理屏原模式。
- 生效的组合与显示器身份一并记录，下次启动（含开机自启）自动重建。目标尺寸不可用时停在未启用状态，在菜单注明原因，不弹窗。点「关闭虚拟屏」时记录一并清除。
- 分辨率列表按本屏宽高比过滤：取该屏模式表提供的点尺寸，并按面板原生像素的 0.50~1.00 生成 10 档补充；已确认会被系统降级的档位不列出。
- 「检测可用尺寸」逐档建屏检测，结果写入缓存；「恢复全部尺寸」清除该记录，被隐藏的档位重新出现。
- 音量滑块拖动时下发 DDC 写入，写入进行中到达的落点只保留最后一个，最终落到松手位置。显示器不支持静音 VCP（0x63），「静音」通过记录当前音量并置 0 实现。

### 命令行

```bash
BIN="/Applications/Simple Display.app/Contents/MacOS/SimpleDisplay"

# 应用与还原
"$BIN" --apply 2580 1080 100      # 点尺寸 2580×1080 @100Hz
"$BIN" --apply 2580 1080 100 3    # 指定 displayID

# 音量
"$BIN" --volume                   # 输出 "23/100"
"$BIN" --volume 60                # 设为 60 并回读

# 开机启动
"$BIN" --login-status             # not-registered / enabled / requires-approval / not-found
"$BIN" --login on
"$BIN" --login off

# 诊断
"$BIN" --selftest                 # 建屏 → 还原 → 换刷新率重建 → 还原
"$BIN" --diagnose                 # 显示器、原生像素、模式表统计、候选尺寸
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
- 显示器支持 DDC/CI 音量，但系统音量面板中该设备为灰色

不适用：

- 需要改变面板原生分辨率本身
- 内建屏（通常已是 2×，叠加虚拟屏只增加一层合成）
- 需要 HDR 或色彩配置随虚拟屏透传的场景
- 显示器不支持音量 VCP（0x62）时的音量控制

## 工作原理

### HiDPI 虚拟屏

1. `CGVirtualDisplay` 创建虚拟屏，申请 2× 背板
2. 子进程读取该屏真实模式，确认「点宽 == 请求宽」且「背板宽 == 2 × 请求宽」
3. 确认通过后，把物理屏镜像到虚拟屏；未通过则销毁虚拟屏，不改动显示状态

系统在虚拟屏上不提供模式数据库，因此 2× 判定必须在创建虚拟屏的进程之外完成：

| 调用 | 建屏进程内 | 子进程 |
|---|---|---|
| `CGDisplayCopyAllDisplayModes` | 返回 `NULL` | 返回完整模式表 |
| `CGDisplayCopyDisplayMode` | 返回 `NULL` | 返回当前模式 |
| `CGDisplayPixelsWide` | 首帧为点宽，重建时为 0 | 返回背板宽 |

### 音量

经 `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` 访问 `DCPAVServiceProxy`，收发 DDC/CI 报文：

| 操作 | 载荷 |
|---|---|
| 读 VCP | `{0x01, vcp}`，等 80ms 后读 11 字节，校验 `0x6E 88 02 00 <vcp>` |
| 写 VCP | `{0x03, vcp, hi, lo}`，等 50ms 读 11 字节丢弃；应答不读走时后续写入会被显示器丢弃 |

长度字节（`0x80 | len`）与校验字节由驱动层生成，调用方只提供操作码与载荷。

## 兼容性与限制

- 依赖 `CGVirtualDisplay` 私有 API。系统移除该 API 时功能不可用，菜单会提示；启动时检查类与方法是否存在，不直接调用。
- 部分点尺寸会被系统降级为 1×，边界随面板、GPU 与系统版本变化。建屏后自检失败即回滚，屏幕状态不变。
- 缓存位于 `~/Library/Application Support/SimpleDisplay/probe-cache.plist`，按显示器 vendor、model 与面板原生像素区分。
- 镜像时 master 与 slave 不会自动同步刷新率，程序在建屏前将物理屏切换到目标刷新率，并在关闭时恢复原模式。
- 硬件镜像的 slave 不独立驱动，`CGDisplayIsActive` 返回 0 属正常状态，实际输出以系统报告的 `Hardware Mirror` 为准。
- 部分尺寸组合下画面可能出现轻微周期性闪烁。更换分辨率档位可规避，成因尚未定位。
- 音量控制使用系统枚举到的第一个 `DCPAVServiceProxy`。接多块显示器时可能作用于非当前屏，暂未按显示器区分。
- 显示器对 DDC 查询通常需要数十毫秒应答，对 SET 也会返回应答；应答未被读走时后续写入会被丢弃，因此写入进行中的落点按最后一个合并。

## 故障排查

```bash
BIN="/Applications/Simple Display.app/Contents/MacOS/SimpleDisplay"
"$BIN" --diagnose --probe
```

输出包含 macOS 版本、私有 API 可用性、原生像素、当前模式、模式表统计、刷新率列表、候选尺寸，以及各档尺寸的 2× 检测结果。

音量读不到时先单独验证通道：

```bash
"$BIN" --volume        # unavailable 表示没有 DCPAVServiceProxy 或未取到 IOAVService
```

残留虚拟屏或镜像未解除时，终止进程后恢复：

```bash
pkill -f SimpleDisplay
```

## 文件

```
simple-display/
├── Sources/
│   ├── main.m                     入口；--apply / --volume / --selftest / --diagnose / --probe / --modes
│   ├── SDAppDelegate.h/.m         菜单栏、单屏调度、音量界面
│   ├── SDDisplayInfo.h/.m         屏信息、原生像素推断、候选尺寸与刷新率
│   ├── SDDisplayDDC.h/.m          通道建立与重建；DDC/CI 收发：读 VCP、写 VCP
│   ├── SDVirtualScreen.h/.m       虚拟屏生命周期：建屏 / 自检 / 镜像 / 还原
│   ├── SDProbeCache.h/.m          可用尺寸记录
│   └── CGVirtualDisplayPrivate.h  私有 API 声明
├── Resources/
│   ├── Info.plist                 LSUIElement（无 Dock 图标）
│   ├── AppIcon.icns               应用图标
│   └── AppIcon-1024.png           图标母版
└── build.sh
```
