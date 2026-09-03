# nixhold

An opinionated, Nix-native personal-infrastructure framework for a
single operator managing 1–10 machines (workstations + servers) from
one source of truth. Set identity, network topology, and a host
roster; the framework wires the system user, home-manager, agenix
secrets, Caddy/TLS, firewall, cross-host SSH, and an operator CLI.

Status: **pre-v1.** The implemented design is described in
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
`nixhold.profiles.server`), `modules`, and optional `networks`
(default: every tailscale network), `disk` (the install target,
written by `host install`), `publicIp` / `publicFqdn` /
`loginPubkey`. `nixhold host add` manages it for you.

Scaffold a fresh fleet with `nix flake init -t github:fcalell/nixhold`.

## The operator CLI

Reach it pre-install as `nix run github:fcalell/nixhold#nixhold -- <verb>`,
and post-install as `nixhold <verb>` (on PATH via `programs.nixhold`,
default on).

Every argument in brackets opens a picker when left out.

```sh
nixhold host add [<name>]      # the walk: roster entry, host key, secrets,
                               # then "install now?"
nixhold host install [<name>]  # reformat a host (NixOS: disk picker + disko +
                               # nixos-facter; darwin: darwin-rebuild locally)
nixhold deploy [<name>…]       # build + switch (local; or over ssh as the
                               # operator user with --use-remote-sudo)
nixhold update                 # pull, update inputs, deploy what you pick
nixhold secret edit [<host>] [<name>]
                               # provision a missing secret, or edit one
nixhold secret rekey           # re-encrypt to current recipients
nixhold status [<name>]        # services + endpoints + secret status
nixhold lint [--strict]        # convention / invariant checks
nixhold logs [<host>] [<unit>] # journalctl over the tailnet
```

## Typical lifecycle for a new NixOS host

1. `nixhold host add web` — generates the host key, scaffolds its
   module, provisions its secrets, commits all of it, and ends by
   asking whether to install now: over ssh to the booted installer
   (`--install root@<ip>` scripts it), or later with
   `nixhold host install web --remote root@<ip>`. Every prompt
   defaults from what the fleet already knows.
2. Install picks the disk (written into the roster as
   `hosts.web.disk`, from which the framework renders the one disko
   layout), runs disko + `nixos-facter`, and commits the disk and
   `facter.json`.
3. Join the tailnet: either set
   `nixhold.services.tailscale.authKeySecret` (bootstrap a pre-auth
   key → auto-join on activation) or run `tailscale up` once on the box.
4. `nixhold deploy web` for subsequent changes.

Darwin hosts are already-running macOS — run `nixhold host install
mac` **on the Mac itself**. It is fresh-machine complete: after a
preflight (the login account is the operator, Command Line Tools,
vanilla Nix) it makes `/etc/ssh/ssh_host_ed25519_key` the fleet's key
for the host (installing the committed one, or adopting and
escrowing the machine's), rekeys secrets when needed, activates with
`sudo darwin-rebuild` — bootstrapping via the fleet's pinned
nix-darwin when it isn't on PATH yet, and moving aside the `/etc`
files nix-darwin refuses to overwrite — then waits for agenix and
switches once more so the SSH `.pub` files exist. On a Mac with no
checkout yet:

```sh
nix run --extra-experimental-features 'nix-command flakes' \
  github:fcalell/nixhold#nixhold -- host install mac \
  --repo alice/nix --keys <dir-with-operator.age-and-repo.key.age>
```

clones the fleet into `~/nix` over the deploy key first. Day-to-day
changes afterwards: `nixhold deploy mac`.

Every verb commits exactly the files it generated (roster entry,
keys, ciphertexts, facter report); only the installer ISO pushes.

## What you get without wiring it yourself

- **Identity auto-wiring** — user, groups, home, git author, agenix
  owner, nix trust + flakes, weekly gc, and a console password secret
  from one `identity`.
- **Hardware as data** — `hosts.<n>.disk` renders the shipped disko
  layout (systemd-boot, zram implied); the facter report has a
  default path. Custom layouts are a `disko.devices` declaration.
- **Secrets** — `nixhold.secrets.<name>` → agenix, recipients computed
  from the operator + each host's key; `homePath` symlinks into `$HOME`;
  `sshKey = true` derives the `.pub`, defaults `homePath`, and
  generates the key (or takes a pasted one).
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
