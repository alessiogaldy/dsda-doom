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

The default Zig build compiles its library dependencies from source. Homebrew libraries are only used when explicitly
enabled with Zig's `-fsys=<name>` options.

## Building

Build and install a release binary and the internal WAD into `zig-out/bin`:

```
mise exec zig -- zig build -Doptimize=ReleaseFast
```

## Installing

Choose another install prefix with Zig's `--prefix` option:

```
mise exec zig -- zig build -Doptimize=ReleaseFast --prefix /custom/install/prefix
```

The ordinary install remains a loose `bin/dsda-doom` and `bin/dsda-doom.wad`. Application packaging is a separate
build step.

## Packaging

Build, ad hoc sign, validate, and archive the application with:

```
mise exec zig -- zig build package-macos -Doptimize=ReleaseFast
```

This generates `dsda-doom-x.y.z-mac-<architecture>.zip`. The archive contains an ad hoc-signed
`DSDA-Doom.app` with its internal WAD, license, icon, and dynamic libraries. The application can be moved to
`/Applications` and opened normally. Zig's default vendored build has no Homebrew dylibs; when system integrations
such as `-fsys=sdl2` are requested, the package step rewrites and collects those dependencies into
`Contents/Frameworks`, including SDL3 for Homebrew's `sdl2-compat`.

The application is not notarized with an Apple Developer ID. If macOS reports that it cannot verify the application,
remove its quarantine attribute:

```
xattr -dr com.apple.quarantine /Applications/DSDA-Doom.app
```

## Adding the application to Steam

1. Extract the package and move `DSDA-Doom.app` to `/Applications`.
2. In Steam, choose **Games > Add a Non-Steam Game to My Library**.
3. Browse to `/Applications`, select `DSDA-Doom.app`, and add it.
4. In the shortcut's controller settings, enable Steam Input and start from the standard gamepad template.

Fresh DSDA-Doom configurations enable the first supported controller automatically. An existing configuration with
`use_game_controller 0`, or a launch using `-nojoy`, continues to disable controller input.

Steam Input presents the 2026 Steam Controller as standard gamepad and mouse input. Buttons, sticks, triggers, and the
D-pad use DSDA-Doom's existing controller bindings; trackpads and gyro can be assigned to mouse or gamepad actions in
Steam's configurator. Valve's
[gamepad emulation guidance](https://partner.steamgames.com/doc/features/steam_controller/steam_input_gamepad_emulation_bestpractices)
describes this compatibility path. This package does not integrate the Steamworks Input API, controller-specific
glyphs, Grip Sense, direct touchpad coordinates, or HD haptics.
