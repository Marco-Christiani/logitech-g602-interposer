# g602

Userspace input interposer for the Logitech G602 wireless gaming mouse. Maps the eight programmable G-buttons (G4-G11) to arbitrary keyboard shortcuts without any kernel driver or Logitech software. Supports two independent binding layers toggled by the DPI switch on the mouse.

## How it works

The daemon opens a hidraw node and a pointer evdev node:

- **hidraw** - reads proprietary HID report 0x80 from the G602, which carries a bitmask of currently-held G-buttons as a snapshot on every state change.
- **evdev** - exclusively grabs the real mouse event node, reads motion and standard button events, and relays them to a virtual mouse created via uinput. This prevents the desktop from seeing both the real and virtual device simultaneously.

A second uinput device (virtual keyboard) emits key events for configured G-button bindings. On receiver-level layouts, the daemon also grabs and drains the sibling keyboard evdev node. The daemon resolves these nodes from sysfs on startup, so no device paths need to be configured.

### Receiver and driver layouts

The physical receiver and logical HID++ G602 child use two product IDs:

- `046d:c537` is the physical Logitech receiver.
- `046d:402c` is the logical HID++ G602 child device.

When `hid_logitech_dj` and `hid_logitech_hidpp` bind the receiver, sysfs usually exposes a logical `Logitech G602` evdev node with product `402c`. The resolver prefers that node.

When the receiver is handled as generic HID, sysfs may expose only receiver-level `c537` nodes. In that layout the resolver uses the receiver pointer node, then grabs and drains the sibling `Logitech USB Receiver Keyboard` node so firmware key events from G-button presses do not reach the desktop.

The hidraw selection does not depend on either product ID. It scans Logitech hidraw nodes and chooses the one whose HID report descriptor declares report ID `0x80`, the G-button snapshot stream.

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

The auto-resolver picks the correct hidraw and evdev nodes from sysfs. Manual overrides are a debug escape hatch because the kernel-assigned `/dev/hidrawN` and `/dev/input/eventM` numbers shift on receiver replug. An `evdev` override also disables automatic suppression of a receiver-level keyboard node.

```toml
[devices]
hidraw = "/dev/hidraw2"
evdev  = "/dev/input/event5"
```

## CLI reference

```
g602 [--config PATH] [--list-devices] [--check-config] [--help]

  --config, -c PATH     Load config from PATH
  --list-devices, -l    Print resolved hidraw/evdev paths and all matching
                        nodes, then exit
  --check-config, -C    Parse and validate config, then exit
  --verbose, -v         Print hidraw reports and evdev events except EV_REL
                        movement and EV_SYN frame delimiters
                        Use -vv to include all evdev events
  --trace, -t           Alias for -v
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

The service validates its config before starting. An invalid config is not retried, so start the service after correcting it. Other failure paths permit at most five starts in one minute. After that limit, fix the cause and run:

```sh
systemctl --user reset-failed g602
systemctl --user start g602
```

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
