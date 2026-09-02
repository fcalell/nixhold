# nixhold

An opinionated, Nix-native personal-infrastructure framework for a
single operator managing 1–10 machines (workstations + servers) from
one source of truth. Set identity, network topology, and a host
roster; the framework wires the system user, home-manager, agenix
secrets, Caddy/TLS, firewall, cross-host SSH, and an operator CLI.

Status: **pre-v1.** The implemented design is the source of truth in
[ARCHITECTURE.md](./ARCHITECTURE.md); planned work is in
[ROADMAP.md](./ROADMAP.md); this README is the practical quickstart.

## How a fleet consumes it

A fleet lives in its own repo and pins `inputs.nixhold`. The whole
`flake.nix` is the `mkFleet` call — heavy inputs (nixpkgs,
home-manager, nix-darwin, agenix, disko, nixos-anywhere) come
transitively via `inputs.nixhold.inputs.*`.

```nix
{
  inputs.nixhold.url = "github:fcalell/nixhold";
  outputs =
    { nixhold, ... }@inputs:
    nixhold.lib.mkFleet {
      inherit inputs;
      identity = {
        username = "alice";
        fullName = "Alice Example";
        email = "alice@example.com";
      };
      # Optional: every layout path defaults to a subpath of this
      # flake (./secrets, ./keys/operator.pub, …). Only the repo
      # itself can't be derived, and only the ISO needs it.
      layout.repoUrl = "alice/nix";
      networks.tailnet = {
        type = "tailscale";
        magicDnsSuffix = "tailXXXXXX.ts.net";
      };
      hosts = import ./hosts.nix { inherit nixhold inputs; };
    };
}
```

`hosts.nix` is the roster — per host: `arch`, `profile` (e.g.
`nixhold.profiles.server`), `modules`, `networks`, and optional
`publicIp` / `publicFqdn` / `loginPubkey`. `nixhold host add` manages
it for you.

Scaffold a fresh fleet with `nix flake init -t github:fcalell/nixhold`.

## The operator CLI

Reach it pre-install as `nix run github:fcalell/nixhold#nixhold -- <verb>`,
and post-install as `nixhold <verb>` (on PATH via `programs.nixhold`,
default on).

```sh
nixhold host add <name>        # roster entry + host key + secret bootstrap;
                               # scaffolds hosts/<name>/{default.nix,disko.nix}
nixhold host install <name> --remote root@<ip>
                               # NixOS: disko + nixos-facter + nixos-anywhere.
                               # darwin: darwin-rebuild locally.
nixhold deploy <name>          # build + switch (local; or over ssh as the
                               # operator user with --use-remote-sudo)
nixhold secret edit <name>     # create/edit an agenix secret for a host
nixhold secret rekey           # re-encrypt to current recipients
nixhold status [<name>]        # services + endpoints + secret status
nixhold lint [--strict]        # convention / invariant checks
nixhold logs <name> <unit>     # journalctl over the tailnet
```

## Typical lifecycle for a new NixOS host

1. `nixhold host add web --install root@<installer-ip>` — generates the
   host key, scaffolds its module files, and chains into install.
   (Or run `host add` then `host install` separately.)
2. Install runs disko + `nixos-facter` and commits `disko.nix` +
   `facter.json`; the scaffolded `default.nix` already imports them.
3. Join the tailnet: either set
   `nixhold.services.tailscale.authKeySecret` (bootstrap a pre-auth
   key → auto-join on activation) or run `tailscale up` once on the box.
4. `nixhold deploy web` for subsequent changes.

Darwin hosts are already-running macOS — run `nixhold host install
mac` **on the Mac itself**. It is fresh-machine capable: it ensures
the host age identity at `/etc/ssh/ssh_host_ed25519_key` (installing
the `host add`-cached key, or generating one in place), commits that
key's pubkey as `keys/hosts/mac/host.pub` and rekeys secrets to it,
then activates with `sudo darwin-rebuild` — bootstrapping via the
fleet's pinned nix-darwin when `darwin-rebuild` isn't on PATH yet.
Day-to-day changes afterwards: `nixhold deploy mac`.

## What you get without wiring it yourself

- **Identity auto-wiring** — user, home, git author, agenix owner, nix
  trust from one `identity`.
- **Secrets** — `nixhold.secrets.<name>` → agenix, recipients computed
  from the operator + each host's key; `homePath` symlinks into `$HOME`;
  `sshKey = true` derives the `.pub` and defaults `homePath`.
- **Services + expose** — declare `nixhold.services.<name>` with
  `network.ports` + `expose`; Caddy and the firewall configure
  themselves from the declarations (tailnet TLS via `tailscale cert`).
- **Cross-host SSH** — `hosts.<name>.loginPubkey` (defaulted from the
  CLI-committed `keys/hosts/<host>/identity.pub` of the `sshIdentity`
  secret) authorizes the operator fleet-wide and generates `ssh`
  `matchBlocks` for every peer.
- **Profiles** — `nixhold.profiles.{server,desktopLinux,workstationDarwin}`,
  composable / extendable in your own repo.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full design and
rationale, and [ROADMAP.md](./ROADMAP.md) for what is still planned.
