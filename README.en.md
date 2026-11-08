# Simple Display

[中文](README.md)

A macOS menu bar utility for HiDPI. It creates a 2× virtual display for an external monitor, then hardware-mirrors that monitor onto it, so macOS can offer HiDPI sizes beyond the panel's native resolution. Monitor volume is controlled over DDC/CI.

After launch, a monitor icon appears in the menu bar: an empty outline while off, and a 2×2 pixel grid inside the outline once on.

This project was written by DeepSeek-V4.1-Flash and verified only on a 3440×1440 display. Other displays have not been tested.

## Terminology

| Term | Meaning |
|---|---|
| Point size | Logical size used by the system UI. Menu entries and the `W H` command-line arguments both refer to this value |
| Backing pixels | Pixel size the virtual display renders. Under 2× HiDPI it is twice the point size |
| Hardware mirroring | The monitor follows the virtual display as a mirror slave; the GPU scales the output to the panel resolution |
| Degraded | The system generates no 2× backing store for some point sizes and presents them at 1×, so the UI overflows the screen |
| VCP | DDC/CI control parameter number. 0x62 is volume, 0x10 is brightness |

## Installation

```bash
./build.sh
ditto "build/Simple Display.app" "/Applications/Simple Display.app"
open "/Applications/Simple Display.app"
```

Requires macOS 13 or later. Launch at login uses `SMAppService` and works only when the app is inside the Applications folder.

If Gatekeeper blocks the first launch:

```bash
xattr -d com.apple.quarantine "/Applications/Simple Display.app"
```

## Usage

- Choosing a resolution or refresh rate rebuilds the virtual display and mirrors the monitor. Closing, quitting, or terminating the process removes the mirror and restores the monitor's previous mode.
- The applied combination is recorded together with the monitor identity and rebuilt automatically on the next launch, including at login. If the recorded size is unavailable, the app stays off, states the reason in the menu, and shows no dialog. "Turn Off Virtual Screen" clears the record as well.
- The resolution list follows the panel aspect ratio, with candidates from 0.50 to 1.00 of the native pixels in 10 steps. Sizes confirmed as degraded are not listed.
- "Detect Supported Sizes" probes each size and writes the result to the cache. "Restore All Sizes" clears that record, and hidden sizes reappear.
- The volume slider writes DDC while dragging. The monitor does not support the mute VCP (0x63), so "Mute" saves the current volume and sets it to 0.

### Command line

```bash
BIN="/Applications/Simple Display.app/Contents/MacOS/SimpleDisplay"

# Apply and restore
"$BIN" --apply 2580 1080 100      # point size 2580×1080 @100Hz
"$BIN" --apply 2580 1080 100 3    # explicit displayID

# Volume
"$BIN" --volume                   # prints "23/100"
"$BIN" --volume 60                # set to 60 and read back

# Launch at login
"$BIN" --login-status             # not-registered / enabled / requires-approval / not-found
"$BIN" --login on
"$BIN" --login off

# Diagnostics
"$BIN" --selftest                 # create → restore → rebuild at another refresh rate → restore
"$BIN" --diagnose                 # displays, native pixels, mode table summary, candidate sizes
"$BIN" --diagnose --probe         # adds a per-size 2× check
"$BIN" --probe-size 2580 1080 3   # single size, prints 2x / 1x / fail
"$BIN" --probe-all 3              # all candidates, results written to the cache
"$BIN" --probe 3                  # current mode of one display as "point width  backing width"
"$BIN" --modes 3                  # all modes as "point width  point height  pixel width  pixel height"
```

## Scope

Applies to:

- External monitors that lack the needed HiDPI sizes in macOS
- 2× rendering at a point size below the panel native resolution
- Monitors with DDC/CI volume control where the system volume panel shows the device in grey

Not applicable to:

- Changing the panel native resolution itself
- Built-in displays (usually already 2×; an extra virtual display only adds a compositing layer)
- HDR or colour profiles that must pass through the virtual display
- Volume control on monitors without the volume VCP (0x62)

## How It Works

### HiDPI virtual display

1. `CGVirtualDisplay` creates a virtual display and requests a 2× backing store.
2. A child process reads the real mode of that display and confirms that point width equals the requested width and that backing width equals 2 × requested width.
3. On success the monitor is mirrored onto the virtual display. On failure the virtual display is destroyed and display state is left unchanged.

The system provides no mode database for virtual displays, so the 2× check must run outside the process that created the display:

| Call | Inside the creating process | Child process |
|---|---|---|
| `CGDisplayCopyAllDisplayModes` | returns `NULL` | returns the full mode table |
| `CGDisplayCopyDisplayMode` | returns `NULL` | returns the current mode |
| `CGDisplayPixelsWide` | point width on the first frame, 0 after a rebuild | backing width |

### Volume

`DCPAVServiceProxy` is accessed through `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`, exchanging DDC/CI packets:

| Operation | Payload |
|---|---|
| Read VCP | `{0x01, vcp}`, wait 80 ms, read 11 bytes, verify `0x6E 88 02 00 <vcp>` |
| Write VCP | `{0x03, vcp, hi, lo}` |

The length byte (`0x80 | len`) and the checksum byte are generated by the driver layer; the caller supplies only the opcode and payload.

## Compatibility and Limitations

- Depends on the private `CGVirtualDisplay` API. If the system removes that API the feature is unavailable and the menu reports it; the class and methods are checked at launch rather than called directly.
- Some point sizes are degraded to 1× by the system, and the boundary varies with panel, GPU, and OS version. A failed self-check after creation rolls back, leaving display state unchanged.
- The cache lives in `~/Library/Application Support/SimpleDisplay/probe-cache.plist` and is keyed by display vendor, model, and native panel pixels.
- Master and slave do not synchronise refresh rate when mirroring. The app switches the monitor to the target refresh rate before creating the virtual display and restores the previous mode on close.
- A mirrored slave is not driven independently, so `CGDisplayIsActive` returning 0 is normal. The actual output follows the `Hardware Mirror` reported by the system.
- Slight periodic flicker can appear with some size combinations. Switching to another size avoids it; the cause has not been identified.
- Volume control uses the first `DCPAVServiceProxy` the system enumerates. With several monitors attached it may act on a different display; per-display routing is not implemented.
- Displays usually need tens of milliseconds to answer a DDC query. Dragging the slider coalesces writes to the last position.

## Troubleshooting

```bash
BIN="/Applications/Simple Display.app/Contents/MacOS/SimpleDisplay"
"$BIN" --diagnose --probe
```

The output covers macOS version, private API availability, native pixels, current mode, mode table summary, refresh rate list, candidate sizes, and the 2× result for each size.

If the volume cannot be read, verify the channel on its own:

```bash
"$BIN" --volume        # unavailable means no DCPAVServiceProxy or no IOAVService
```

If a virtual display or mirror is left behind, terminate the process:

```bash
pkill -f SimpleDisplay
```

## Files

```
simple-display/
├── Sources/
│   ├── main.m                      entry point; --apply / --volume / --selftest / --diagnose / --probe / --modes
│   ├── SDAppDelegate.h/.m          menu bar, single-display scheduling, volume UI
│   ├── SDDisplayInfo.h/.m          display info, native pixel inference, candidate sizes and refresh rates
│   ├── SDDisplayDDC.h/.m           DDC/CI transport: read VCP, write VCP
│   ├── SDVirtualScreen.h/.m        virtual display lifecycle: create / self-check / mirror / restore
│   ├── SDProbeCache.h/.m           supported size record
│   └── CGVirtualDisplayPrivate.h   private API declarations
├── Resources/
│   ├── Info.plist                 LSUIElement (no Dock icon)
│   ├── AppIcon.icns               application icon
│   └── AppIcon-1024.png           icon master
└── build.sh
```
