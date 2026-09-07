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

      # `layout` is optional: every path defaults to a subpath of
      # this flake (./secrets, ./keys/operator.pub, …). The repo
      # itself can't be derived — set it to build the installer ISO.
      # layout.repoUrl = "owner/repo";

      # The keys you log in to your own hosts with are fleet DATA,
      # not a flake argument: commit the public halves to
      # `keys/login.pub`, one per line (a hardware token's
      # `ssh-keygen -t ed25519-sk` key, one line per token you
      # carry). `nixhold secret edit identity` writes the fleet's own
      # key there when the file is missing.

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
