# Synthetic fleet used by `nix flake check` to exercise mkFleet
# end-to-end without any operator wiring. Builds at least one
# host of each platform so a regression in baseline modules,
# profile composition, or mkFleet dispatch shows up here first.
#
# Consumed from the framework flake's `checks.<system>` output.
{ inputs, self }:
self.lib.mkFleet {
  # The fixture stands in for a forker repo. A real forker's flake
  # resolves `inputs.nixhold` from `inputs.nixhold.url`; here the
  # framework is testing itself, so we synthesize that self-input:
  # the framework's own outputs (`self`) carrying its own `inputs`
  # (so `inputs.nixhold.inputs.<dep>` and
  # `inputs.nixhold.<platform>Modules.nixhold` both resolve).
  inputs = inputs // {
    # mkFleet roots the layout defaults at `inputs.self`; a forker's
    # self is their fleet repo, so the fixture substitutes its own
    # directory — that is what makes the defaults resolve to the
    # keys/ and secrets/ trees committed beside this file. It is a
    # store path of its own, exactly like a real `self` — see
    # ./self.nix for why that shape matters.
    self = import ./self.nix;
    nixhold = self // {
      inputs = inputs;
    };
  };

  identity = {
    username = "fixture";
    fullName = "Fixture User";
    email = "fixture@example.invalid";
  };

  # Every path is left to the defaults on purpose — that is the
  # primary path a forker takes. Only the non-derivable field is set.
  layout.repoUrl = "example/fleet";

  networks = {
    tailnet = {
      type = "tailscale";
      magicDnsSuffix = "fixture.ts.net";
    };
    public = {
      type = "internet";
      domain = "fixture.example.invalid";
    };
  };

  hosts = {
    # `disk` set: the framework renders the shipped disko layout and
    # the loader/zram defaults that go with it. `publicFqdn` is left
    # to its default (`<host>.<domain>`, since `public` is the one
    # internet network); `networks` is spelled out because the host is
    # on more than the tailscale default.
    fixture-server = {
      arch = "x86_64-linux";
      profile = self.profiles.server;
      modules = [ ./host-stub.nix ];
      networks = [
        "tailnet"
        "public"
      ];
      disk = "/dev/disk/by-id/fixture-root";
      publicIp = "203.0.113.10";
    };

    # The internet-facing half of the caddy coverage. It is a host of
    # its own because caddy's listener is not per-interface: a host
    # that serves an internet endpoint may not also serve
    # unauthenticated tailnet ones (assertion in modules/infra/caddy.nix),
    # so fixture-server keeps the tailnet branches and this one carries
    # the ACME vhost.
    # No `disk`: the custom-layout path, with ./hardware-stub.nix
    # standing in for an operator's own `disko.devices`.
    fixture-gateway = {
      arch = "x86_64-linux";
      profile = self.profiles.server;
      modules = [ ./gateway-stub.nix ];
      networks = [
        "tailnet"
        "public"
      ];
    };

    # `networks` left to its default: every tailscale-typed network.
    fixture-mac = {
      arch = "aarch64-darwin";
      profile = self.profiles.workstationDarwin;
      # The darwin side of the host-key pinning check: from here
      # fixture-server is a peer *with* a committed host key.
      modules = [ ./known-hosts-assertions.nix ];
    };
  };
}
