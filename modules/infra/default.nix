# Infra index. Imports every framework-shipped infra module.
# These are NixOS-only and auto-activate based on the data they
# consume (`config.nixhold.services.*`). Profiles aimed at NixOS
# servers import this index; darwin profiles do not.
{ ... }:
{
  imports = [
    ./caddy.nix
    ./firewall.nix
  ];
}
