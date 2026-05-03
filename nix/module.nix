# NixOS module for the g602 userspace input interposer.
#
# Usage (in a consuming flake):
# ```nix
# {
#   inputs.g602.url = "github:Marco-Christiani/g602";
#   outputs = { nixpkgs, g602, ... }: {
#     nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#       modules = [
#         g602.nixosModules.default
#         {
#           services.g602.enable = true;
#           services.g602.users = [ "marco" ];
#         }
#       ];
#     };
#   };
# }
# ```
# The module:
#   - installs the package into systemPackages, creates a dedicated `g602` group
#   - adds configured users to that group
#   - installs udev rules granting the group access to the G602's hidraw / event
#      nodes and to /dev/uinput
#   - ensures the uinput kernel module is loaded
#   - enables a systemd user service that auto-starts on login
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.g602;
  tomlFormat = pkgs.formats.toml {};
  hasDeclarativeSettings = cfg.settings != {};
  configFile =
    if hasDeclarativeSettings
    then tomlFormat.generate "g602-config.toml" cfg.settings
    else null;
  execStart =
    if configFile != null
    then "${lib.getExe cfg.package} --config ${configFile}"
    else lib.getExe cfg.package;
in {
  options.services.g602 = {
    enable = lib.mkEnableOption "the g602 userspace input interposer";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The g602 package to install.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["alice"];
      description = ''
        Usernames to add to the `g602` group. Members of this group can
        open the matched G602 device nodes and /dev/uinput without sudo.
        Affected users must log out and back in before their session
        picks up the supplementary group.
      '';
    };

    silenceKernelSpam = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Replace the in-tree hid-logitech-dj kernel module with a patched
        build that silences the "Unexpected input report number 128" error
        logged on every G602 button press. The G602 sends HID report 0x80
        as its proprietary snapshot stream; the in-tree driver does not
        recognise it and logs hid_err, even though the daemon consumes it
        correctly via hidraw. Disabling this option restores the in-tree
        module and the kernel spam.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the per-user systemd service so the daemon starts on login.
        Disable if you prefer to control the service manually via
        `systemctl --user`.
      '';
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = {};
      description = ''
        When non-empty, rendered to TOML and passed to the daemon via
        `--config`, so system rebuilds update the bindings and hot reload
        is effectively "restart the service on rebuild". When left at the
        default empty set, the daemon searches
        `$XDG_CONFIG_HOME/g602/config.toml` and `~/.config/g602/config.toml`,
        which keeps inotify-based hot reload available for ad-hoc tweaking.

        The parser only accepts a TOML subset: string values, `[section]`
        headers, no arrays or inline tables. Use strings like
        `"super+left"` not arrays like `[ "super" "left" ]`.

        The daemon also accepts a `[devices]` section pinning explicit
        `hidraw`/`evdev` paths, but it is intentionally not advertised here:
        kernel-assigned `/dev/hidrawN` and `/dev/input/eventM` numbers shift
        on every receiver replug, so a hardcoded path becomes wrong as soon
        as the receiver is re-enumerated. The daemon's auto-resolver picks
        the right nodes by HID report descriptor and is the supported
        configuration. `[devices]` exists only as a debug escape hatch.
      '';
      example = lib.literalExpression ''
        {
          bindings = {
            g4 = "super+left";
            g5 = "super+right";
            g6 = "ctrl+c";
            g7 = "pageup";
            g8 = "pagedown";
            g9 = "mute";
            g10 = "alt+right";
            g11 = "alt+left";
          };
          daemon.log_level = "info";
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.g602 = {};

    users.users = lib.listToAttrs (map (u: {
        name = u;
        value = {extraGroups = ["g602"];};
      })
      cfg.users);

    # Narrow per-subsystem stanzas. We deliberately do not grant the whole input
    #  subsystem to g602, only the specific G602 device nodes and /dev/uinput.
    services.udev.extraRules = ''
      # Logitech G602 - raw HID for the G-button snapshot stream
      SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="402c", GROUP="g602", MODE="0660"

      # Logitech G602 - evdev node (exclusively grabbed by the daemon)
      SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="402c", GROUP="g602", MODE="0660"

      # /dev/uinput for creating the virtual mouse + virtual keyboard
      KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="g602", MODE="0660"
    '';

    # /dev/uinput only exists when the uinput module is loaded.
    # Not loaded by default on some kernels.
    boot.kernelModules = ["uinput"];

    boot.extraModulePackages = lib.optionals cfg.silenceKernelSpam [
      (config.boot.kernelPackages.callPackage ./hid-logitech-dj.nix {})
    ];

    # The patched out-of-tree module replaces the in-tree one. Both cannot
    # be loaded simultaneously; blacklisting ensures the kernel loads ours.
    boot.blacklistedKernelModules = lib.optionals cfg.silenceKernelSpam [
      "hid_logitech_dj"
    ];

    environment.systemPackages = [cfg.package];

    systemd.user.services.g602 = lib.mkIf cfg.autoStart {
      description = "G602 userspace input interposer";
      wantedBy = ["default.target"];
      serviceConfig = {
        ExecStart = execStart;
        Restart = "on-failure";
        # Back off enough that a genuinely broken config does not spin the
        #  restart loop, but short enough to pick up the device soon after
        #  the receiver appears.
        RestartSec = 3;
        # Journald captures stderr as the "info" level by default.
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
