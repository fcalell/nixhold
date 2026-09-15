# The serviceConfig every framework or fleet unit starts from: the
# process sees a read-only system and no home, no kernel surface, no
# other processes, no new namespaces, no capabilities, unix and inet
# sockets only, the system-service syscall set, and writes nothing
# group- or world-readable.
#
# `CapabilityBoundingSet` bounds the effective and permitted sets too
# (systemd.exec(5)), so a unit at uid 0 that takes the set has no
# capability: it reads and writes only what any user could, which is
# what the owner and mode bits of another uid's files say. A unit
# that copies or fetches another uid's data either runs as the
# owning user (`User = …`) or names the capabilities it needs in
# `CapabilityBoundingSet`, each with its reason.
#
# A unit merges it (`hardening // { … }`) and names each exception
# as the systemd key set to its permissive value, beside the reason:
# a GPU is `PrivateDevices = false` plus a `DeviceAllow`, a JIT is
# `MemoryDenyWriteExecute = false`, a directory written outside the
# state directory is `ReadWritePaths`, reading a directory closed to
# root's own uid is `CAP_DAC_READ_SEARCH` in the bounding set. Lint
# rule 14 reads `NoNewPrivileges` as the mark of a unit that took the
# set.
{
  NoNewPrivileges = true;
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectControlGroups = true;
  ProtectClock = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  ProcSubset = "pid";
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  RemoveIPC = true;
  MemoryDenyWriteExecute = true;
  CapabilityBoundingSet = [ "" ];
  RestrictAddressFamilies = [
    "AF_UNIX"
    "AF_INET"
    "AF_INET6"
  ];
  SystemCallArchitectures = "native";
  SystemCallFilter = [
    "@system-service"
    "~@privileged"
  ];
  UMask = "0077";
}
