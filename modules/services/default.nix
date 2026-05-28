# Services index — explicit list of framework-shipped service
# modules. Profiles import the entries they need; nothing here
# is auto-activated per principle 14 (no fs discovery).
{ ... }:
{
  imports = [
    ./openssh.nix
    ./tailscale.nix
  ];
}
