{
  description = "A nixhold-managed personal-infrastructure fleet.";

  inputs = {
    nixhold.url = "github:fcalell/nixhold";

    # The heavy inputs are the fleet's, not the framework's. Each is
    # declared here and nixhold is pointed at it below, so this lock
    # is the only lock that builds anything and `nixhold update`
    # moves all of it. The set mirrors nixhold's own root inputs,
    # follows included; `nixhold lint` (rule 13) reports one that is
    # missing, not followed, or older than nixhold's own pin.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.darwin.follows = "nix-darwin";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixhold.inputs = {
      nixpkgs.follows = "nixpkgs";
      nix-darwin.follows = "nix-darwin";
      home-manager.follows = "home-manager";
      agenix.follows = "agenix";
      disko.follows = "disko";
      nixos-anywhere.follows = "nixos-anywhere";
      nixos-hardware.follows = "nixos-hardware";
    };
  };

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
