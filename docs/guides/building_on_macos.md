# Building DSDA-Doom on macOS

This is a basic guide for making a release build of DSDA-Doom on macOS with Zig.

## Prerequisites

In order to build DSDA-Doom, the following tools are needed:

- Xcode's Command Line Tools, installed by running `xcode-select --install` from a terminal.
- The Homebrew package manager, refer to [this page](https://brew.sh/) for installation.

This guide assumes all the commands are run from the root directory of the repository, so move into that
directory after cloning the sources:

```
git clone https://github.com/kraflab/dsda-doom.git
cd dsda-doom
```

## Installing Dependencies

Install the packaging tools and the version manager declared by the repository, then install the pinned Zig version:

```
brew bundle
mise install zig
```

On macOS, the Zig build uses Homebrew's `sdl2-compat` and SDL3 by default. SDL 3.4.14 and newer include the direct
driver for the 2026 Steam Controller, including its two touchpads. The remaining libraries are compiled from source.
Pass `-fno-sys=sdl2` to use the vendored SDL build for diagnostics, but that SDL2 build does not include the 2026
Steam Controller driver.

## Building a development application

The development application uses the same local WAD fixtures as the regression specs. Put `DOOM2.WAD` and
`rush.wad` in `spec/support/wads` as described in [`spec/README.md`](../../spec/README.md). These files are ignored by
git and are copied only into the local development application; they are not included in the release archive.

Build the command-line files and development application with:

```
mise exec zig -- zig build -Doptimize=ReleaseFast
```

This produces:

```
zig-out/bin/dsda-doom
zig-out/bin/dsda-doom.wad
zig-out/DSDA-Doom.app
zig-out/DSDA-Doom.app/Contents/Resources/WADs/iwad.wad
zig-out/DSDA-Doom.app/Contents/Resources/WADs/selected.wad
```

The selected WADs are copied into the signed bundle, making `DSDA-Doom.app` self-contained and safe to move elsewhere.
Double-clicking the app launches `DOOM2.WAD` with `rush.wad` by default. Rebuild the app after changing either source
WAD. The bundle exposes the native DSDA-Doom Mach-O directly so Steam can associate its overlay and Steam Input with
the game process.

Select another PWAD or base IWAD with `-Dapp-wad` and `-Dapp-iwad`:

```
mise exec zig -- zig build \
  -Doptimize=ReleaseFast \
  -Dapp-iwad=/path/to/DOOM2.WAD \
  -Dapp-wad=/path/to/sunlust.wad
```

Pass an empty `-Dapp-wad=` to launch only the selected IWAD.

## Installing

Choose another install prefix with Zig's `--prefix` option:

```
mise exec zig -- zig build -Doptimize=ReleaseFast --prefix /custom/install/prefix
```

The ordinary install contains the loose `bin/dsda-doom`, `bin/dsda-doom.wad`, and the development application.
Release packaging is a separate build step.

## Packaging

Build, ad hoc sign, validate, and archive the application with:

```
mise exec zig -- zig build package-macos -Doptimize=ReleaseFast
```

This validates `zig-out/DSDA-Doom.app` and generates `dsda-doom-x.y.z-mac-<architecture>.zip`. The archive contains
a portable, ad hoc-signed `DSDA-Doom.app` with its internal WAD, license, icon, and dynamic libraries. It is created
before the development WADs are embedded and deliberately excludes them, so users must provide their own IWAD. The
archived application can be moved to `/Applications`. The package step rewrites and collects Homebrew's SDL2
compatibility library, SDL3, and their dynamic dependencies into `Contents/Frameworks`; the resulting application
does not depend on Homebrew paths at runtime. Package validation also verifies that the bundled SDL3 links Apple's
GameController framework.

The application is not notarized with an Apple Developer ID. If macOS reports that it cannot verify the application,
remove its quarantine attribute:

```
xattr -dr com.apple.quarantine /Applications/DSDA-Doom.app
```

## Adding the application to Steam

1. Extract the package and move `DSDA-Doom.app` to `/Applications`.
2. In Steam, choose **Games > Add a Non-Steam Game to My Library**.
3. Browse to `/Applications`, select `DSDA-Doom.app`, and add it.
4. Open the shortcut's controller settings and select **Disable Steam Input**. DSDA-Doom reads the physical controller
   directly through SDL; Steam Input must not hide it behind a virtual gamepad.

After replacing an older development app that used the shell launcher, remove its non-Steam shortcut and add the app
again so Steam discovers the native executable.

Fresh DSDA-Doom configurations enable the first supported controller automatically. An existing configuration with
`use_game_controller 0`, or a launch using `-nojoy`, continues to disable controller input.

SDL presents the 2026 Steam Controller's buttons, sticks, triggers, D-pad, paddles, and touchpads directly to
DSDA-Doom. The right touchpad controls aim by default. Configure it under **Options > General > Controller** with
**Steam Trackpad Aim** and the horizontal and vertical trackpad sensitivity values. Vertical trackpad motion controls
free look when **Enable Free Look** is on; otherwise vertical motion is ignored.

DSDA-Doom leaves SDL's controller-driver selection at its macOS default. In particular, it does not force the
optional Steam Controller HIDAPI driver: doing so can prevent SDL from falling back to Apple's GameController
backend. `SDL_JOYSTICK_HIDAPI` and `SDL_JOYSTICK_HIDAPI_STEAM` remain available as explicit diagnostic overrides.

This direct path does not require an AppID, Steamworks SDK, macOS Input Monitoring permission, or an Accessibility
permission. SDL also exposes the controller's motion sensors, but native gyro aiming, controller-specific glyphs,
Grip Sense, and HD haptics are not implemented yet.

If Steam detects the controller but DSDA-Doom receives no input:

1. Confirm that the shortcut is set to **Disable Steam Input**, then quit and relaunch the game. With Steam Input
   enabled, Steam may add the physical controller to `SDL_GAMECONTROLLER_IGNORE_DEVICES` without providing a usable
   virtual replacement to a macOS non-Steam shortcut.
2. Confirm **Enable Controller** is on in DSDA-Doom, or set `use_game_controller 1` in the existing configuration.
   On macOS the configuration is at `~/Library/Application Support/dsda-doom/dsda-doom.cfg`; it is created after
   DSDA-Doom saves its configuration, so a missing file is not itself an error. Remove `-nojoy` from the shortcut's
   launch options if present.
3. Build without `-fno-sys=sdl2` and update the Homebrew libraries with `brew upgrade sdl3 sdl2-compat`. The default
   app embeds `libSDL3.dylib`; SDL 3.4.14 or newer is required for the 2026 controller's native touchpads.
4. Inspect `controller-status.txt`. A working native connection reports `steam_controller.native: yes`,
   `active.touchpad.count: 2`, and `steam_controller.right_trackpad.available: yes`. Touch and release the right pad
   before sharing the file so it also contains the latest touch coordinates and motion-event count. If
   `joystick.count` is zero, the `raw_hid` section shows whether SDL can still enumerate the physical Valve hardware.

DSDA-Doom writes `controller-status.txt` at startup, on controller connection changes, and when controller button,
axis, or touchpad input arrives. The report includes the effective controller configuration, SDL versions and
initialization state, Steam launch environment, every enumerated joystick and mapping, native touchpad availability,
the active controller, and the most recent input event. Find the report with:

```
find "$HOME/Library/Application Support/dsda-doom" "$HOME/.dsda-doom" \
  -name controller-status.txt -print 2>/dev/null
```

The legacy `~/.dsda-doom` directory takes precedence when it already exists, so configuration and the status report
may be there instead of under `Library/Application Support`.

When Steam Input is intentionally enabled, DSDA-Doom still opts into SDL's virtual gamepad as a compatibility fallback
for other controllers. Native right-trackpad aiming requires the physical 2026 Steam Controller, so use **Disable
Steam Input** for this controller.
