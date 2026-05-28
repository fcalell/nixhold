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
    nixhold = self // {
      inputs = inputs;
    };
  };

  identity = {
    username = "fixture";
    fullName = "Fixture User";
    email = "fixture@example.invalid";
  };

  layout = {
    secrets = ./secrets;
    hostsFile = ./hosts.nix;
    modulesDir = ./modules;
    profilesDir = ./profiles;
    keysDir = ./keys;
    ageRecipient = ./keys/operator.pub;
    ageIdentityWrapped = ./keys/operator.age;
  };

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
    fixture-server = {
      arch = "x86_64-linux";
      profile = self.profiles.server;
      modules = [ ./host-stub.nix ];
      networks = [
        "tailnet"
        "public"
      ];
      publicIp = "203.0.113.10";
      publicFqdn = "fixture-server.fixture.example.invalid";
    };

    fixture-mac = {
      arch = "aarch64-darwin";
      profile = self.profiles.workstationDarwin;
      modules = [ ];
      networks = [ "tailnet" ];
    };
  };
}
