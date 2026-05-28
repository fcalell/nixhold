{
  description = "A nixhold-managed personal-infrastructure fleet.";

  inputs.nixhold.url = "github:fcalell/nixhold";

  outputs =
    { self, nixhold, ... }@inputs:
    nixhold.lib.mkFleet {
      inherit inputs;

      identity = {
        username = "CHANGE_ME";
        fullName = "Your Name";
        email = "you@example.com";
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

      # Declare every network your hosts talk over here. Hosts
      # reference networks by name in their `networks` field.
      networks = {
        tailnet = {
          type = "tailscale";
          # Paste the suffix from `tailscale status` once your
          # first host has joined the tailnet.
          magicDnsSuffix = null;
        };
      };

      hosts = import ./hosts.nix { inherit nixhold; };
    };
}
