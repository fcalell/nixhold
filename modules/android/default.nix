# The Android host: the option surface of a fleet entry whose arch is
# `aarch64-android` (ARCHITECTURE "Android hosts"). This tree stands
# where the NixOS module tree stands for the other platforms, so its
# names follow one rule: a NixOS name where the concept is the same
# (`networking.hostName`, `environment.systemPackages`), an `android.*`
# name where Android has no NixOS counterpart.
#
# Nothing here runs on the device. The build product is
# `system.build.plan`: one JSON of everything declared, with each
# APK's store path, package id, version and hash, built on the seat
# that runs `nixhold deploy`; the verb converges the device onto it
# over adb (cli/deploy-android.sh).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.android;
  self = config.nixhold.fleet.derived.self;
  apks = config.environment.systemPackages;

  # The package id and versionName are the APK's own (its manifest),
  # read at build time so the operator never types an id the artifact
  # already carries. pyaxmlparser is pure Python and builds on every
  # seat system; aapt does not.
  apkInfo =
    apk:
    pkgs.runCommand "${apk.name}.info.json"
      {
        nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyaxmlparser ])) ];
      }
      ''
        python3 - ${apk} >"$out" <<'EOF'
        import json, sys
        from pyaxmlparser import APK
        a = APK(sys.argv[1])
        json.dump({"id": a.package, "versionName": a.version_name}, sys.stdout)
        EOF
      '';

  declared = {
    hostName = config.networking.hostName;
    inherit (cfg)
      removedPackages
      settings
      launcher
      deviceOwner
      ;
  };

  planFile =
    pkgs.runCommand "android-plan-${config.networking.hostName}.json"
      {
        nativeBuildInputs = [ pkgs.jq ];
        declared = builtins.toJSON declared;
        passAsFile = [ "declared" ];
        inherit apks;
        infos = map apkInfo apks;
      }
      ''
        read -r -a apks <<<"$apks"
        read -r -a infos <<<"$infos"
        {
          for i in "''${!apks[@]}"; do
            sha="$(sha256sum "''${apks[$i]}" | cut -d' ' -f1)"
            jq --arg apk "''${apks[$i]}" --arg sha "$sha" \
              '. + { apk: $apk, sha256: $sha }' "''${infos[$i]}"
          done
        } | jq -s --slurpfile d "$declaredPath" '$d[0] + { packages: . }' >"$out"
      '';

  failed = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  plan =
    if failed != [ ] then
      throw "\nFailed assertions:\n${lib.concatMapStringsSep "\n" (m: "- ${m}") failed}"
    else
      lib.showWarnings config.warnings planFile;

  settingsNamespace =
    ns:
    mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        `settings put ${ns} <key> <value>`, converged against
        `settings get`. Values are the strings `settings` prints.
      '';
    };
in
{
  options = {
    networking.hostName = mkOption {
      type = types.str;
      description = ''
        The device's name (`settings global device_name`): what the
        tailnet, Bluetooth and a media server's client list show.
        Defaults to the fleet name, like every host.
      '';
    };

    environment.systemPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        The APKs on the device, each a derivation of the file
        (`pkgs.fetchurl` from a release URL by hash). Deploy installs
        one whose package id is absent or whose installed base APK
        hashes differently; the id and version are read from the
        APK when the plan is built.
      '';
    };

    android = {
      removedPackages = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Package ids uninstalled for the main user (`pm uninstall
          -k --user 0`): the vendor's preloads. The APK stays on the
          system partition, so a factory reset brings it back.
        '';
        example = [ "com.google.android.youtube.tv" ];
      };

      settings = {
        global = settingsNamespace "global";
        secure = settingsNamespace "secure";
        system = settingsNamespace "system";
      };

      launcher = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The activity HOME resolves to (`cmd package
          set-home-activity`), as `package/activity`. The app must
          declare itself a launcher and be on the device.
        '';
        example = "uk.nktnet.webviewkiosk/.MainActivity";
      };

      deviceOwner = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The device-admin receiver made device owner (`dpm
          set-device-owner`), as `package/receiver`. Only a device
          with no account takes one, and only once: Android changes
          an owner through a factory reset alone. A kiosk, never a
          person's phone.
        '';
        example = "uk.nktnet.webviewkiosk/.AdminReceiver";
      };

      summary = mkOption {
        type = types.attrs;
        readOnly = true;
        description = ''
          The declaration at a glance, eval-side (no APK fetched):
          what `nixhold status` shows for an Android host.
        '';
      };
    };

    assertions = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            assertion = mkOption { type = types.bool; };
            message = mkOption { type = types.str; };
          };
        }
      );
      default = [ ];
      description = "As on NixOS: a failed one fails the plan with its message.";
    };

    warnings = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "As on NixOS: printed when the plan is evaluated.";
    };

    system.build = mkOption {
      type = types.attrsOf types.raw;
      default = { };
      description = "Build products. `plan` is the JSON deploy converges the device onto.";
    };
  };

  imports = [ ./adb-key.nix ];

  config = {
    system.build.plan = plan;
    android.summary = declared // {
      apks = map (p: p.name) apks;
    };

    assertions = [
      {
        assertion = self == null || (self.disk == null && self.publicIp == null && self.publicFqdn == null);
        message = "${config.networking.hostName}: an Android host has no disk and no public address; drop disk/publicIp/publicFqdn from its roster entry";
      }
    ];
  };
}
