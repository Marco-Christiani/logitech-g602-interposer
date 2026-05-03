# g602

Userspace input interposer for the Logitech G602 wireless gaming mouse. Maps the eight programmable G-buttons (G4-G11) to arbitrary keyboard shortcuts without any kernel driver or Logitech software. Supports two independent binding layers toggled by the DPI switch on the mouse.

## How it works

The daemon opens two device nodes:

- **hidraw** - reads proprietary HID report 0x80 from the G602, which carries a bitmask of currently-held G-buttons as a snapshot on every state change.
- **evdev** - exclusively grabs the real mouse event node, reads motion and standard button events, and relays them to a virtual mouse created via uinput. This prevents the desktop from seeing both the real and virtual device simultaneously.

A second uinput device (virtual keyboard) emits key events for configured G-button bindings. The daemon auto-resolves both device paths from sysfs on startup; no hardcoded paths needed.

## Quick start

```sh
# check which device nodes were selected
g602 --list-devices

# validate a config file without starting the daemon
g602 --check-config --config config.toml

# start it (will need sudo without udev setup, see below)
g602 --config ~/.config/g602/config.toml
```

The daemon requires access to the G602 hidraw node, the evdev node, and `/dev/uinput`. On NixOS the module handles this via udev rules and a dedicated group. Elsewhere, run as root or add yourself to the appropriate groups.

## Configuration

Config is TOML, searched in order:

1. `--config PATH` (explicit)
2. `$XDG_CONFIG_HOME/g602/config.toml`
3. `~/.config/g602/config.toml`
4. Built-in defaults

When a config file is found, the daemon watches it via inotify and reloads on write without restarting (does not apply if no config is supplied, of course).

### Bindings

```toml
[bindings]
g4  = "super+left"
g5  = "super+right"
g6  = "ctrl+c"
g7  = "ctrl+z"
g8  = "pageup"
g9  = "pagedown"
g10 = "alt+right"
g11 = "alt+left"
```

Key names are matched case-insensitively against Linux `KEY_*` and `BTN_*` constants, with or without the prefix (`pageup` and `KEY_PAGEUP` both work). Common aliases: `ctrl`, `shift`, `alt`, `super`/`meta`, `escape`, `return`. Up to four modifiers per binding.

### Two-layer bindings

The physical DPI-mode toggle on top of the mouse switches between layers A and B. Per-layer entries override the base `[bindings]` table; missing entries fall back to the base.

```toml
[bindings]
g4 = "f13"       # used when no layer-specific override exists
g5 = "f14"

[bindings.a]     # DPI toggle position A
g4 = "super+left"

[bindings.b]     # DPI toggle position B
g4 = "super+right"
```

### Daemon options

```toml
[daemon]
log_level = "info"   # debug | info | warn | err
```

### Device overrides

The auto-resolver picks the correct hidraw and evdev nodes from sysfs. Manual overrides exist as a debug escape hatch - the kernel-assigned `/dev/hidrawN` and `/dev/input/eventM` numbers shift on receiver replug, so hardcoded paths break.

```toml
[devices]
hidraw = "/dev/hidraw2"
evdev  = "/dev/input/event5"
```

## CLI reference

```
g602 [--config PATH] [--list-devices] [--check-config] [--trace] [--help]

  --config, -c PATH     Load config from PATH
  --list-devices, -l    Print resolved hidraw/evdev paths and all matching
                        nodes, then exit
  --check-config, -C    Parse and validate config, then exit
  --trace, -t           Print every hidraw report and evdev event to stderr
  --help, -h            Show usage
```

## NixOS

Add the flake as an input and import the module:

```nix
# flake.nix
inputs.g602.url = "github:Marco-Christiani/g602";

outputs = { nixpkgs, g602, ... }: {
  nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
    modules = [
      g602.nixosModules.default
      {
        services.g602.enable = true;
        services.g602.users = [ "marco" ];
      }
    ];
  };
};
```

The module:

- Creates a `g602` group and adds listed users to it
- Installs udev rules granting the group access to the G602 hidraw/evdev nodes and `/dev/uinput`
- Loads the `uinput` kernel module
- Installs a per-user systemd service that starts on login

### Declarative bindings

Bindings can be declared in NixOS config instead of a separate file. Hot reload via inotify is replaced by service restart on rebuild.

```nix
services.g602.settings = {
  bindings = {
    g4 = "super+left";
    g5 = "super+right";
    g6 = "ctrl+c";
  };
  daemon.log_level = "info";
};
```

### Module options

| Option | Default | Description |
|--------|---------|-------------|
| `enable` | `false` | Enable the interposer |
| `users` | `[]` | Users to add to the `g602` group |
| `autoStart` | `true` | Start the systemd user service on login |
| `settings` | `{}` | Declarative config (TOML rendered from Nix attrs) |
| `silenceKernelSpam` | `true` | Replace the in-tree `hid_logitech_dj` module with a patched build that silences the per-button-press kernel error (see below) |

### Kernel log spam

The Unifying receiver's kernel driver (`hid_logitech_dj`) logs an error for every G-button press:

```
logitech-djreceiver: Unexpected input report number 128
```

Report 0x80 is the G602's proprietary snapshot stream. The driver does not handle it, but the daemon reads it correctly via hidraw. The upstream patch silencing this has not been merged. With `silenceKernelSpam = true` (the default), the module builds a patched `hid_logitech_dj.ko` that guards the `hid_err` call and installs it as a replacement for the in-tree module. Only the one changed `.c` file is compiled; the full kernel is not rebuilt.

Set `silenceKernelSpam = false` to opt out and keep the in-tree module.

## Building from source

Requires Zig (see `flake.nix` for the pinned version). With the nix devshell:

```sh
nix develop
zig build
./zig-out/bin/g602 --help
```

Run tests:

```sh
zig build test
```
