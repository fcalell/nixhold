# The one adb key every Android device is paired with: a fleet-scope
# secret, minted by its generator (RSA-2048 as PKCS#8 PEM, the shape
# adbd's key exchange takes). Imported by the android baseline, so
# every Android host declares it and `nixhold deploy` hands it to adb
# as ADB_VENDOR_KEYS; and by a NixOS host that drives a device itself
# (`inputs.nixhold.modules.infra.adbKey`), which has it placed at
# `config.age.secrets.adb.path`. One consent per device covers both.
{ ... }:
{
  nixhold.secrets.adb = {
    scope = "fleet";
    required = true;
    category = "framework";
    owner = "root";
    description = "the adb key every Android host is paired with (RSA-2048, PKCS#8)";
    generator = ''
      (
        umask 077
        d="$(mktemp -d)" || exit 1
        trap 'rm -rf "$d"' EXIT INT TERM
        ssh-keygen -q -t rsa -b 2048 -m PKCS8 -N "" -f "$d/key" || exit 1
        cat "$d/key"
      )
    '';
  };
}
