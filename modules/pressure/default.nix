# The pressure floor every NixOS machine stands on (ARCHITECTURE
# "Pressure"): the recovery path keeps its memory, systemd-oomd kills a
# leaf before the machine thrashes, and builds yield. NixOS-only, and
# off in a guest: its container unit is a leaf of the machine's
# system.slice, and the store and its daemon are the machine's.
#
# Every value is mkDefault, a share of physical memory or a fixed
# floor, so a host changes one by setting the same systemd key.
{ config, lib, ... }:
let
  # sshd runs as `sshd@` instances when socket-activated; the socket
  # itself is pid 1's and holds no memory worth protecting.
  sshdUnit = if config.services.openssh.startWhenNeeded then "sshd@" else "sshd";

  # The recovery path. MemoryMin holds only in a slice whose every
  # ancestor reserves it, the root slice excepted, so these units sit
  # in a top-level slice. `omit` is honoured because the cgroups are
  # root's (systemd.resource-control(5), ManagedOOMPreference=).
  core = {
    Slice = lib.mkDefault "core.slice";
    ManagedOOMPreference = lib.mkDefault "omit";
    OOMScoreAdjust = lib.mkDefault (-900);
  };
in
{
  config = lib.mkIf (!config.boot.isContainer) {
    systemd.slices.core = {
      description = "The recovery path: sshd and tailscaled";
      sliceConfig = {
        MemoryMin = lib.mkDefault "256M";
        CPUWeight = lib.mkDefault 1000;
      };
    };
    systemd.services.${sshdUnit}.serviceConfig = lib.mkIf config.services.openssh.enable core;
    systemd.services.tailscaled.serviceConfig = lib.mkIf config.services.tailscale.enable core;

    # The NixOS switches (`enableRootSlice` and its siblings) set every
    # scope to 80%, which oomd reaches long after the machine stops
    # answering, and none of them sets the swap trigger; the slices are
    # spelled out instead. oomd itself is on by nixpkgs' default.
    systemd.slices."-".sliceConfig.ManagedOOMSwap = lib.mkDefault "kill";
    systemd.slices.system.sliceConfig = {
      ManagedOOMMemoryPressure = lib.mkDefault "kill";
      ManagedOOMMemoryPressureLimit = lib.mkDefault "60%";
      ManagedOOMMemoryPressureDurationSec = lib.mkDefault "30s";
    };
    systemd.slices.user.sliceConfig = {
      ManagedOOMMemoryPressure = lib.mkDefault "kill";
      ManagedOOMMemoryPressureLimit = lib.mkDefault "50%";
      ManagedOOMMemoryPressureDurationSec = lib.mkDefault "20s";
    };

    # Every build is the daemon's, an agent's included. `idle` for
    # either class starves a build for as long as anything else runs,
    # which on a machine running agents is always (nixpkgs' option
    # docs); best-effort 7 is the lowest that still reaches the disk.
    nix.daemonCPUSchedPolicy = lib.mkDefault "batch";
    nix.daemonIOSchedClass = lib.mkDefault "best-effort";
    nix.daemonIOSchedPriority = lib.mkDefault 7;
    systemd.services.nix-daemon.serviceConfig.MemoryHigh = lib.mkDefault "50%";
  };
}
