# Roadmap

This document is the source of truth for the framework's
architectural direction. It is in **active design** — the present
phase is "design the finished product, then implement separately."
Implementation tracking, refactor sequencing, cost analysis, and
short-term task lists belong in a different document; this file is
for *what we are building and why*.

Operator runbooks and host-specific service wishlists live in each
consuming fleet's own repo, not here. This file covers the
**framework** itself.

---

## Vision

**An opinionated, Nix-native personal-infrastructure framework.**
The Catppuccin of system configuration; the K3s of single-operator
fleets. A reasonable forker can stand up a workstation + headless
server pair in an afternoon, gets observability / backup / secrets /
TLS / DNS for free, and the host files read like declarations of
intent — not piles of plumbing.

Distinguishing properties:

- **Single operator, single fleet, multiple hosts.** Designed for
  the person managing 1–10 machines they own; not for multi-tenant
  cloud orchestration.
- **Fork-friendly.** Framework and fleet live in separate repos
  from day one — the framework at `github:fcalell/nixhold`,
  forkers' fleets in their own repos consuming `inputs.nixhold`.
  Identity, fleet topology, layout paths, and host roster are
  the forker-replaceable surfaces.
- **Convention-driven, opinionated.** Catppuccin's "set one flag,
  every program is themed" applied to system config. Agenix is
  the secrets system, not a backend choice; Caddy is the reverse
  proxy, not a backend choice; the framework picks one of each
  and lets consumers override when they really need to.
- **Extensible via Nix values, not filesystem discovery.** Service
  modules and profiles are exposed as flake outputs
  (`nixhold.modules.*`, `nixhold.profiles.*`). The framework reads
  Nix values handed to `mkFleet`, never filesystem paths in the
  forker's repo. A third-party module lands by being a Nix value
  the forker imports. A formal plugin model is deferred until
  there's evidence of need (Gap 2).

### Who this is for — and who it isn't

The framework's unit is **the machine** (whole-system NixOS / nix-darwin
configuration), not the service (container, pod, app). This is a
deliberate choice with consequences worth being explicit about.

**This framework wins for forkers who:**
- Manage workstation + multi-host fleet from one source of truth
  (e.g. Mac workstation + Linux desktop + homelab + maybe a VPS).
- Care about reproducible whole-machine builds, atomic activation,
  rollback-on-disk.
- Want identity, dotfiles, secrets, firewall, services, and the
  desktop environment all declared and version-controlled together.
- Are willing to pay an upfront wiring cost per service in exchange
  for typed options, lint-enforced conventions, and fleet-wide
  introspection.

**Docker / docker-compose wins for forkers who:**
- Just want a single VPS running a small set of off-the-shelf
  services and don't care about workstation config.
- Need to deploy the same service across heterogeneous hosts (any
  Linux with Docker).
- Want to try services ad-hoc (`docker run …` beats writing a
  service module).

The two aren't in competition at the same layer. NixOS has
first-class container support (`virtualisation.oci-containers`,
declarative `containers.<name>`, systemd-nspawn) and any
`nixhold.services.<x>` can be *implemented* as an OCI image with mounts
and env vars. The framework's value remains additive: whole-machine
declarability, secret manifest, expose contract, fleet view, atomic
activation — none of which Docker provides or tries to. If everything
worth running is a container, the framework is still the right layer
above; it's just that the service modules are container thin-wrappers.

The point of saying this out loud: when a forker asks "should I just
use docker-compose," the answer for some forkers should be **yes**.
The framework targets a specific shape of personal infra, not "any
service deployment use case."

---

## Architecture philosophy (decided)

These are committed; new work conforms or argues explicitly for
exception. Numbered to match (and extend) the README design
principles.

1. **Two layers: framework + personal config.** One repo, one flake,
   multiple outputs. Framework is consumed by forkers via flake
   outputs; personal config is the canonical usage example.
2. **Identity is the framework's central contract.** Operator
   identity is a Nix value the forker passes to `mkFleet` (alongside
   `networks`, `hosts`, `layout`), not a file read from disk.
3. **Auto-wiring (Catppuccin-style), not boilerplate.** Set
   identity once; user attr, home directory, git author, agenix
   owner, nix trust wire themselves with `lib.mkDefault`.
4. **`mkDefault` discipline + named exceptions.** Every auto-wired
   value is overridable by plain assignment. Hard-requirements (zsh)
   are named.
5. **Magic over explicit, opinionated over flexible.** Fewer knobs,
   more "set this one thing, the rest follows." Justifications are
   stronger for *removing* a knob than for adding one.
6. **Existing principles from README** — one secret/one host;
   recipient list = security boundary; composition over inheritance;
   hardware-is-data; no platform branching in modules.
7. **Unified framework, not a backend toolkit.** Agenix is part of
   the framework. Caddy is the reverse proxy. Tailscale is the mesh.
   Consumers who want sops/nginx/headscale fork harder. The
   framework's value comes from the integration; making any
   component pluggable dilutes that.
8. **Convention over configuration.** Predictable file shapes in
   predictable locations — `modules/services/<name>.nix`,
   `secrets/hosts/<host>/<name>.age`, `keys/hosts/<host>/host.pub`.
   **Declaration is the registry, not the filesystem**: an
   explicit `modules/<kind>/default.nix` index lists which modules
   are active, `nixhold.secrets.<name>` declares which secrets exist.
   Lint enforces the bidirectional invariant — every file has a
   matching declaration, every declaration has a matching file.
9. **Foundations over features.** The framework ships the option
   namespace, the discovery harness, and the lint surface; stacks
   built on top (monitoring, backup, mail, AI assistant) are
   consumers of the same namespace. If a new stack requires touching
   N existing modules, the foundation is incomplete.
10. **Plain NixOS options, not a separate publish/subscribe layer.**
    Modules expose typed options under `nixhold.services.<name>.*` (or
    `nixhold.infra.*`, `nixhold.home.*`). Consumers read options directly via
    `config.nixhold.services` walks. `mkOption` + `config` IS the
    publish/subscribe system, and it's the one Nix developers
    already know — no parallel "facet" vocabulary, no registry
    indirection, no separate schema layer.
11. **One operator CLI: `nixhold`.** Every operator action is
    reachable through one tool. The CLI is thin — most subcommands
    wrap existing tools (agenix, nixos-rebuild); the unique value
    is `nixhold status`, `nixhold lint`, and the scaffold commands,
    all reading `config.nixhold.services` directly.
12. **Total declarability of network presence.** Every endpoint a
    service exposes — public, tailnet, or localhost-only — is
    declared in its `expose` option. There is no "implicit" mode
    where a service binds a port the framework doesn't know about.
    The framework's invariant: it can answer "what is running on
    this host, where does it bind, how is each thing reachable" from
    config alone, never from running-system introspection. This
    enables `nixhold status`, monitoring autodiscovery, lint for orphan
    ports, and a coherent network model across the fleet.
13. **One-pass eval.** Each host evaluates independently and sees
    only its own services plus `config.nixhold.fleet`. Cross-host
    concerns are explicit (declared in the `mkFleet` topology), not inferred
    by re-evaluating every host with a global view. Keeps eval
    cost predictable and configs greppable.
14. **No filesystem-based discovery in the framework's eval.**
    `mkFleet` consumes Nix values (identity, networks, hosts,
    layout), not filesystem paths. The framework never reads
    `${root}/whatever` from disk and never walks directories. The
    CLI is allowed to write files to paths the operator declared in
    `nixhold.layout` (scaffolding is fine; *discovery* via the
    filesystem is not). Permissible exceptions: `facter.json`
    (nixos-facter's filename), SSH host pubkeys at `/etc/ssh/`,
    `flake.nix` itself, the `.age` extension. Everything else
    flows through declared options or explicit Nix imports.
15. **Thin operator glue.** Every `nixhold` verb that touches an
    existing tool (agenix, nixos-rebuild, nixos-anywhere, ssh,
    journalctl) is expressible as: configuration + invocation. If a
    verb's implementation grows logic that isn't (a) reading
    declared options under `config.nixhold.*`, (b) computing
    host/recipient/path arguments from those options, or (c)
    invoking the underlying tool — that logic is suspect and needs
    justification in the verb's docstring.

---

## Architecture spec (designed, not implemented)

These are the detailed designs agreed on. They define what the
framework *will be*; implementation sequencing comes later.

### The three layers

The forker's repo separates into three conceptual layers, each
with one job. Reading top-down: `mkFleet` is handed `hosts` and
`networks` (the fleet manifest); each host attaches a `profile`;
the profile says "a server runs these things"; per-host modules
fill in this-machine specifics; modules declare what options
exist and what activates when. Note that "layers" describes the
*concepts* — not the *filesystem*. Per principle 14, the
framework reads Nix values, not filenames.

```
┌─────────────────────────────────────────────────────────────┐
│           Fleet manifest — args to nixhold.lib.mkFleet      │
│   hosts.<name> = { arch, profile, modules, networks, … };    │
│   networks.<name> = { type, … };                             │
│   identity = { … };  layout = { … };                         │
└─────────────────────────────────────────────────────────────┘
                  │ attaches profile +
                  │ supplies per-host metadata
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ LAYER 3 — Per-host modules                                  │
│   This machine's specifics: which services run here, with   │
│   what configuration. Hardware imports (disko + facter)     │
│   live in the operator's `hosts.<n>.modules` list.          │
└─────────────────────────────────────────────────────────────┘
                  ▲ composed with
┌─────────────────────────────────────────────────────────────┐
│ LAYER 2 — Profiles                                          │
│   Opinionated bundles. "A server enables openssh +          │
│   fail2ban + tailscale; a desktop enables hyprland +        │
│   pipewire." Framework ships `nixhold.profiles.*`; forkers  │
│   compose their own by importing `nixhold.modules.*`.       │
└─────────────────────────────────────────────────────────────┘
                  ▲ configures
┌─────────────────────────────────────────────────────────────┐
│ LAYER 1 — Modules                                           │
│   Option declarations. nixhold.services.<name>,             │
│   nixhold.secrets.*, nixhold.types.*, identity options.     │
│   Doesn't activate anything itself. Baseline (identity,     │
│   secrets, fleet, types, layout) auto-imports on every      │
│   host; services + infra are profile-imported.              │
└─────────────────────────────────────────────────────────────┘
```

Each layer's job is genuinely different — modules *declare*,
profiles *configure*, hosts *specify*, and the `mkFleet` call
*attaches* profiles to hosts. This is the classic NixOS pattern
(nixpkgs has `nixos/modules/profiles/` for the same distinction),
recast for fleet semantics with profile assignment as a
fleet-level concern. The detailed sections below describe each
layer.

Top-level repo layouts. Two distinct shapes — forker and
framework — since dogfood is out-of-tree from day 1 (see
"Dogfood location" under Framework wiring).

**Forker repo layout** (`github:<forker>/fleet` or local). The
operator decides their filenames; what follows is a typical
shape, not a framework requirement:

```
flake.nix                   mkFleet call (identity, layout, networks, hosts)
hosts.nix                   CLI-managed: hosts attrset (declared via nixhold.layout.hostsFile)
hosts/                      operator-organized host modules
  └─ <name>/                arbitrary filenames; framework reads no paths here
secrets/                    encrypted age files (path declared in nixhold.layout.secrets)
keys/                       public keys (path declared in nixhold.layout.keysDir)
modules/                    optional — forker's own modules
profiles/                   optional — forker-authored profiles
operator.pub                operator's age recipient pubkey (path declared in nixhold.layout.ageRecipient)
operator.age                operator's wrapped age private key (path declared in nixhold.layout.ageIdentityWrapped)
```

**Framework repo layout** (`github:fcalell/nixhold`):

```
flake.nix                   library + apps + templates + profiles.* + modules.* outputs; NO mkFleet call
lib/                        framework helpers (mkFleet, …)
modules/                    LAYER 1 — option declarations, kind-organized internally
  ├─ identity/              baseline: nixhold.identity options + wiring
  ├─ secrets/               baseline: nixhold.secrets options + agenix activation
  ├─ fleet/                 baseline: nixhold.fleet view (read-only)
  ├─ types/                 baseline: shared option types
  ├─ layout/                baseline: nixhold.layout option
  ├─ home/                  baseline: home-manager wiring
  ├─ services/              service modules — exposed as nixhold.modules.services.*
  └─ infra/                 infra modules — exposed as nixhold.modules.infra.*
profiles/                   shipped profiles (server, workstationDarwin, desktopLinux)
                            exposed as nixhold.profiles.*
cli/                        operator CLI source tree (one writeShellApplication)
template/                   scaffold for `nix flake init -t github:fcalell/nixhold`
checks/                     synthetic fleet fixture mkFleet is run against in CI
```

Forkers consume LAYER 1 (modules) via the baseline bundles
(`inputs.nixhold.nixosModules.nixhold`) and the
`nixhold.modules.<kind>.<name>` escape hatch; they consume LAYER
2 (profiles) via `nixhold.profiles.<name>` — both are flake
outputs, not filesystem paths. Forkers extend LAYER 1 with their
own modules by importing them inside their own profiles or in
`hosts.<n>.modules` — there is no framework "modules dir is
auto-imported" behavior.

### Identity

Three fields, passed as a Nix value to `mkFleet`:

```nix
identity = {
  username = "fcalell";
  fullName = "Frankie Calella";
  email    = "frankie.calella@gmail.com";
};
```

Identity is about *who the operator is*, not where their keys
live. Age key paths (recipient pubkey, passphrase-wrapped
private key) live in `nixhold.layout` (see below) — they're CLI
filesystem state, not operator metadata. The age recipient name
defaults to `username` (single-operator framework; no need for an
explicit identity label distinct from the user account).

The framework auto-wires (via `lib.mkDefault`) the username into
`users.users.<u>`, the home directory, `home-manager.users.<u>`,
git author, agenix recipient list, and nix trust. Hard
requirements (e.g. zsh as login shell on darwin) override
without `mkDefault`. Options schema in `modules/identity/`,
included in the baseline bundle on every host.

### Fleet topology

`hosts` and `networks` are two of the five Nix-value arguments to
`mkFleet`. Forkers compose them however they want — inline in
`flake.nix`, imported from `nixhold.layout.hostsFile`, or split
across files of their choice. Shape:

```nix
hosts = {
  <name> = {
    arch       = "x86_64-linux" | "aarch64-darwin" | ...;
    profile    = nixhold.profiles.<name>;     # attribute reference into nixhold's flake outputs
    modules    = [ ./hosts/<name>.nix … ];     # operator's per-host modules (host config, disko, …)
    networks   = [ "tailnet" "public" ];       # default [ "tailnet" ]; add "public" on the gateway
    publicIp   = "203.0.113.42";               # optional; set on hosts with a stable public IP
    publicFqdn = "<name>.example.com";         # optional; DNS name for publicIp
    loginPubkey = "ssh-ed25519 AAAA…";         # optional; operator login pubkey, authorized fleet-wide
  };
};

networks = {
  <network-name> = { ... };  # see Gap 1 deep dive below
};
```

There is **no `type` or `primary` field on hosts**. Host kind
("server" / "desktop" / "workstation-darwin") is expressed by
the `profile` field — an attribute reference into the framework's
flake outputs (or a forker-authored profile module).  The
framework never inspects the *name* of a profile, it just imports
the module value the attribute resolves to. Typos fail at eval
time (`nixhold.profiles.serevr` → undefined attribute), not deep
in the framework. See "Profiles" below.

Surfaced as `config.nixhold.fleet.*` on every host. Auto-
derivations the framework provides from this data:

- SSH `matchBlocks` for every fleet host (no per-host hardcoding)
  — the operator's home-manager ssh config gains a `Host <peer>`
  block (`HostName` = `derived.address.<peer>.<net>` on the first
  network the peer shares with this host, `User` =
  `nixhold.identity.username`) for every other host. Replaces
  hand-written per-host ssh client config.
- Cross-host `authorizedKeys` wiring — every host authorizes the
  operator's login pubkey(s) on `users.users.<operator>` (operator
  account only; root login stays closed). The keys come from the
  per-host `loginPubkey` field — a Nix value, so the framework eval
  reads no files (principle 14) — aggregated into
  `derived.operatorAuthorizedKeys`.
- **Cross-host service addressing** via
  `derived.address.<host>.<network>` — consumers spell out which
  network they're resolving on. There is no `addressOf` shortcut
  (rejected in favor of explicit network choice; see the
  Architectural-gap notes on `addressOf`).
- Firewall public-interface identification (the netdev bound to
  `publicIp` is the public-facing interface for
  `expose.<x>.network = "<internet-typed-net>"` endpoints).
- Network-membership constraint enforcement: lint rejects an
  `expose.<x>.network` value that names a network the host isn't
  a member of. Network *names* are forker-chosen (e.g.,
  `tailnet`, `public`); network *types* are the framework enum
  (`tailscale`, `internet`).

### Fleet data surface — `nixhold.fleet.*` shape

`mkFleet` sets `nixhold.fleet = fleet` on every host's module list, but
`nixhold.fleet` is itself a **typed option tree**, not a free-form
pass-through. The typed declaration lives in `modules/fleet/` (a
module kind alongside `modules/identity/` and `modules/secrets/`)
and exposes three sub-trees:

| Sub-tree | Who sets it | Purpose |
|---|---|---|
| `nixhold.fleet.hosts`, `nixhold.fleet.network` | Forker (via `mkFleet` args) | Raw topology |
| `nixhold.fleet.derived.*` | Framework (`modules/fleet/derived.nix`) | Cross-host views read by infra + CLI |
| `nixhold._internal.fleet.*` | Framework | Intermediate computations not for consumers |

**Schema declared (`modules/fleet/default.nix`):**

```nix
options.nixhold.fleet = {
  hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        arch       = lib.mkOption { type = archEnum; };
        profile    = lib.mkOption { type = lib.types.deferredModule; };
        networks   = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "tailnet" ]; };
        publicIp   = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        publicFqdn = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null;
          description = ''
            DNS name for this host's `publicIp` when an A record exists.
            Operator-declared (DNS is operator-managed in v1).
            Consumed by `derived.address.<host>.<internet-typed-net>`.
          ''; };
        loginPubkey = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null;
          description = ''
            The operator's SSH login pubkey originating from this host
            (a Nix value — typically `lib.fileContents` of the host's
            committed `ssh-personal.pub`). Aggregated across hosts into
            `derived.operatorAuthorizedKeys` and authorized on every
            host's operator account. `null` until the host's key exists.
          ''; };
      };
    });
    default = {};
  };

  network = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        type           = lib.mkOption { type = lib.types.enum [ "tailscale" "internet" ]; };
        magicDnsSuffix = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null;
          description = ''
            For tailscale networks: the tailnet's MagicDNS suffix
            (visible in `tailscale status`, e.g. "tail-abc123.ts.net").
            Used to compute `derived.address.<host>.<this-network>` as
            `"<host>.<magicDnsSuffix>"`. Without it, tailscale
            addresses are null.
          ''; };
      };
    });
    default = {};
  };

  derived = {
    self           = lib.mkOption { readOnly = true; ... };
    publicHosts    = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true;
      description = ''
        Hosts with a non-null `publicIp`. v1 lint asserts `length ≤ 1`
        (single-gateway invariant). The list shape future-proofs
        against multi-gateway designs without renaming.
      ''; };
    hostsByNetwork = lib.mkOption { type = lib.types.attrsOf (lib.types.listOf lib.types.str); readOnly = true; };
    address = lib.mkOption {
      type     = lib.types.attrsOf (lib.types.attrsOf (lib.types.nullOr lib.types.str));
      readOnly = true;
      description = ''
        Per-host, per-network address. `derived.address.<host>.<network>`
        returns the FQDN (preferred) or IP for reaching `<host>` over
        `<network>`, or `null` if the pair has no resolvable address.
        Null entries are visible (not pruned) so consumers can pattern-
        match and produce useful error messages.

        There is no `addressOf` shortcut. Consumers spell out which
        network they're resolving on — making the topology choice
        explicit eliminates the "first shared network" guess and the
        eval-time throw it forced. Verbosity cost is small; the
        failure mode is gone, not merely better-messaged.
      '';
    };
  };
};
```

**Schema is closed.** `hostType` is a strict submodule — no
`freeformType`. Forkers who need per-host custom data declare
their own option (`options.myorg.<x>`) in their fork. Reasoning:
open schemas erode the contract; if a real forker need surfaces,
relax it deliberately.

**Derived values are options, not helper functions.** Cross-host
patterns that consumers would otherwise walk attrsets to compute
(list of hosts on a network, the gateway host, full FQDNs per
endpoint) are precomputed once in `modules/fleet/derived.nix` and
exposed as `readOnly` options. Matches principle 10 — `mkOption +
config IS the publish/subscribe system`, with no parallel
`nixhold.lib.fleet.*` function namespace.

```nix
# modules/fleet/derived.nix
config.nixhold.fleet.derived = {
  self = config.nixhold.fleet.hosts.${config.networking.hostName};

  publicHosts = lib.attrNames
    (lib.filterAttrs (_: h: h.publicIp != null) config.nixhold.fleet.hosts);

  hostsByNetwork = lib.mapAttrs
    (netName: _: lib.attrNames (lib.filterAttrs (_: h: lib.elem netName h.networks) config.nixhold.fleet.hosts))
    config.nixhold.fleet.network;

  address = lib.mapAttrs (hostName: host:
    lib.mapAttrs (netName: net:
      if !(lib.elem netName host.networks) then null
      else if net.type == "tailscale" then
        if net.magicDnsSuffix == null then null
        else "${hostName}.${net.magicDnsSuffix}"
      else if net.type == "internet" then
        if host.publicFqdn != null then host.publicFqdn
        else if host.publicIp != null then host.publicIp
        else null
      else null
    ) config.nixhold.fleet.network
  ) config.nixhold.fleet.hosts;
};
```

**Address resolution rule.** One consumer surface:

| Form | Use |
|---|---|
| `derived.address.<host>.<network>` | The caller spells out which network to resolve on. Returns FQDN/IP string, or `null` if unresolvable — the caller is responsible for the null path (typically an `assertion` near the consumer, which produces an error pointing at the consumer rather than deep in a derived option). |

Address shape per network type:

| Network type | Shape | Source |
|---|---|---|
| `tailscale` | `"<host>.<magicDnsSuffix>"` (MagicDNS FQDN) | computed from `network.<n>.magicDnsSuffix` + host name; `null` if suffix undeclared |
| `internet` | `host.publicFqdn` (preferred) or `host.publicIp` (fallback) | declared per-host; `null` if neither set |

DNS provisioning remains operator-managed in v1 (per the existing
DNS deferral). `publicFqdn` is the operator's **declaration** that
an A record exists — the framework doesn't create it.

**Self-shortcut: `config.nixhold.fleet.derived.self`** is this host's
own entry — `config.nixhold.fleet.hosts.${config.networking.hostName}`.
Used pervasively in infra modules and CLI subcommands. Doubles as
the single canonicalization point if hostname ↔ fleet-key mapping
ever needs to diverge.

**Consumer pattern** is one attribute read deep:

```nix
# modules/infra/firewall.nix — the operator named their internet-typed network "public"
networking.firewall.allowedTCPPorts = lib.optionals
  (lib.elem config.networking.hostName (config.nixhold.fleet.derived.hostsByNetwork.public or []))
  [ 443 80 ];

# hosts/myvps/default.nix — cross-host wiring (the daily case)
# VPS reverse-proxies to vaultwarden on homelab over tailnet:
services.caddy.virtualHosts."vault.example.com".extraConfig = ''
  reverse_proxy http://${config.nixhold.fleet.derived.address.homelab.tailnet}:8222
'';

# modules/services/backup.nix — service module references another fleet host
options.nixhold.services.backup = {
  target  = lib.mkOption { type = lib.types.str; };
  network = lib.mkOption { type = lib.types.str; default = "tailnet"; };
};
config = lib.mkIf config.nixhold.services.backup.enable {
  services.restic.backups.main.repository = let
    cfg  = config.nixhold.services.backup;
    addr = config.nixhold.fleet.derived.address.${cfg.target}.${cfg.network};
  in "sftp:root@${addr}:/srv/backups";
  assertions = [{
    assertion =
      config.nixhold.fleet.derived.address.${config.nixhold.services.backup.target}.${config.nixhold.services.backup.network} != null;
    message = "backup target is unreachable on the chosen network";
  }];
};
```

**Validation lives at three layers:**

- **Option types** catch shape errors at eval (wrong arity,
  string-where-list, unknown enum value). Cheap, immediate, no
  bespoke machinery.
- **NixOS `assertions`** catch invariants the framework should
  block builds on: e.g. `config.networking.hostName` must be a
  key in `nixhold.fleet.hosts`; a host with `publicIp != null` must
  have `"public"` in `host.networks`; at most one host with
  `publicIp` per `public` network (v1 single-gateway assumption).
- **`nixhold lint`** catches invariants where surfacing the error pre-
  rebuild beats catching it mid-eval: `host.profile` resolves in
  profiles index, every `host.networks` entry is declared, every
  `network.<name>.type` is known, no orphan declarations. Lint
  runs in CI before any rebuild; assertions are the build-time
  safety net.

**Initial `nixhold.fleet.derived.*` member list (v1):** `self`,
`publicHosts`, `hostsByNetwork`, `address`,
`operatorAuthorizedKeys`. Additions land alongside the consumer
that needs them — same rule as new shared option types.

**Empty / single-host fleet works without special-casing.**
A solo workstation fork (`hosts = { laptop = { ... }; }; networks
= {}; }`) yields `derived.publicHosts = []`,
`derived.hostsByNetwork = {}`, `derived.address.laptop = {}` (no
networks declared, so no rows). Cross-host consumers that filter
on non-empty inputs degrade gracefully.

### Host kinds and VPS support

The framework deliberately has **no `kind` field** distinguishing
VPS from on-prem hosts. VPS-ness is implicit from declarations:
"this host has `publicIp` set and is on the `public` network." Every
behavior that might want to branch (firewall posture, DNS records,
service exposure) is derivable from those declarations.

Concretely, deploying a fresh VPS is:

```
# 1. Provider web UI: create VPS, boot rescue mode, note IP.
# 2. Locally, on the operator's primary:
nixhold host add myvps --install root@203.0.113.42
# Interactive TUI: arch, profile, networks (tailnet + public),
# publicIp, publicFqdn. Generates host SSH+age keys. Writes the
# entry to nixhold.layout.hostsFile. Walks secret bootstrap.
# SSH-detects target hardware → disk picker → generates disko +
# facter → nixos-anywhere install → commits hardware files.
# 3. On next gateway rebuild:
#    - DNS infra publishes myvps.example.com A 203.0.113.42
#    - Firewall infra opens public-network ports on the public interface
#    - Services declare expose.public.subdomain = "..." and just work
```

There is one disko shape (single-disk, no encryption), generated
fresh from the target's actual hardware by `nixhold host install`
— operators don't author or edit `disko.nix` for the default
path. No `--with-luks`, no `--with-dropbear`, no `kind` enum.
Operators who want disk encryption author their own `disko.nix`
module before running install and pass `--disko-from <path>`
(power-user flag); the framework doesn't prescribe or assist with
it.

### Per-host configuration

Each host's `hosts.<name>.modules` list is a free-form set of
NixOS / Darwin modules the operator attaches to that host. The
framework places no naming or directory constraints on them —
principle 14 prohibits filesystem-based discovery of operator
content. The operator's flake imports whatever they want, with
whatever filenames they want.

In practice for NixOS hosts the operator typically attaches a
host config + disko import + facter pointer:

```nix
hosts.homelab = {
  arch       = "x86_64-linux";
  profile    = nixhold.profiles.server;
  modules = [
    ./hosts/homelab/configuration.nix
    ./hosts/homelab/disko.nix
    inputs.disko.nixosModules.disko
    { nixhold.hardware.facterReport = ./hosts/homelab/facter.json; }
  ];
  networks   = [ "tailnet" "public" ];
  publicIp   = "203.0.113.42";
  publicFqdn = "homelab.calell.com";
};
```

The names `configuration.nix`, `disko.nix`, `facter.json` are
operator choices — the framework only knows the *values* it's
handed (the modules list, the report path). `facter.json` is one
of the named exceptions in principle 14 because nixos-facter
itself writes that filename; the operator points at it via an
ordinary attribute, not via a path convention.

The framework derives `networking.hostName` from the attrset key
(passed through `specialArgs.hostname`, overridable inside the
host config). `disko.nixosModules.disko` and the facter report
path are operator-supplied via the `modules` list — the framework
doesn't inject them.

Host config example (`./hosts/homelab/configuration.nix`) — just
a plain NixOS module:

```nix
{ ... }: {
  system.stateVersion = "24.05";
  time.timeZone       = "Europe/Madrid";

  nixhold.services.vaultwarden = {
    enable = true;
    expose.web = { network = "tailnet"; subdomain = "vault"; backend = "rocket"; };
  };

  # Per-host HM additions:
  # nixhold.home.extraModules = [ ./home.nix ];
}
```

The host file is pure host-specific config — opt-ins, overrides.
Profile-level concerns (security hardening, ssh, fail2ban) come
from the profile attached in `hosts.<name>.profile`; the host
file doesn't import the profile.

```nix
# hosts/homelab/default.nix
{ ... }: {
  system.stateVersion = "24.05";
  time.timeZone       = "Europe/Madrid";

  nixhold.services.vaultwarden = {
    enable = true;
    expose.web = { network = "tailnet"; subdomain = "vault"; backend = "rocket"; };
  };

  # Per-host HM additions are an explicit option, not a sibling-file
  # convention. Forkers can write a ./home.nix sibling and reference
  # it here, or inline the modules.
  # nixhold.home.extraModules = [ ./home.nix ];
}
```

**Per-host HM additions.** Forkers add per-host home-manager
fragments via the `nixhold.home.extraModules` option declared by
`modules/home/`. The framework wires them into
`home-manager.users.${identity.username}.imports`. The option
*is* the wiring — there's no sibling-file convention. Forkers who
need finer control (different user, scoped `mkIf` block) write
the raw `home-manager.users.<user>.imports = [ … ]` themselves;
the option is the convenient path, not the only one.

**Hardware files.** `disko.nix` and `facter.json` are required
on every NixOS host. **Both are generated by `nixhold host
install` at install time**, from the target's actual hardware —
`lsblk -J` over SSH for the disk choice + `nixos-facter` for the
report. The CLI writes them to operator-chosen paths (typically
next to the host config) and prints the paste-line for the
operator's `hosts.<n>.modules` list. Once added to the modules
list, the framework consumes them as ordinary Nix imports —
there's no fixed `${root}/hosts/<name>/disko.nix` path the
framework reads. The operator does not author or edit either
file in the default flow.

Enforcement is at lint:
- `nixhold lint` checks every NixOS host's `modules` list
  contains a disko module import and a `nixhold.hardware.facterReport`
  setting. Missing either is a **warning** with the hint
  "run `nixhold host install <name>` to generate."
- `nixhold lint --strict` (CI on `main`) treats it as an
  **error** — strict mode runs after install has landed in a
  commit; missing hardware artefacts on `main` is a regression.

A bypass-lint rebuild against a host missing either file gets a
generic Nix path-not-found error — acceptable since lint is the
intended catch. Darwin hosts have no equivalents (Darwin owns
its own disk; nix-darwin has no facter).

Operators who want disk encryption or a custom disk layout write
their own disko module ahead of time and pass `--disko-from
<path>` to `nixhold host install`; the framework copies it into
place rather than generating from hardware. Power-user flag, not
the default path.

**Facter report guard.** A NixOS host's hardware report is wired
through the framework option `nixhold.hardware.facterReport` (a
path), not a direct `hardware.facter.reportPath` assignment. This
lets the framework own the pre-install bootstrap: until the report
exists, the host must still *evaluate* (so `nix eval`, `nixhold
lint`, and `nixhold status` work) while a *build* is blocked.

- When the file at `nixhold.hardware.facterReport` exists, the
  framework sets `hardware.facter.reportPath` to it (the
  `hardware.facter` module ships in nixpkgs — no extra input).
- When it doesn't (the pre-first-install state), the framework
  omits `reportPath` and emits a build-blocking `assertion`: "run
  `nixhold host install <host>` to generate it." Eval succeeds;
  only `system.build.toplevel` (a rebuild) trips the assertion.

This is what makes `nixhold host install` work on a fresh host:
`nixos-anywhere` evaluates the disko script (which does not force
`assertions`), kexecs, runs `nixos-facter` to write the report,
*then* builds the closure — by which point the file exists and the
assertion passes. The operator never hand-edits the report, and a
fleet with an un-installed host still introspects cleanly. The
option is NixOS-only (Darwin owns its own disk; nix-darwin has no
facter) — a Darwin host that sets it eval-fails, the right place to
catch the platform mistake.

### Secrets — unified, name-based

The framework treats agenix as part of itself, not as a backend
choice. The convention `secrets/hosts/<host>/<name>.age` is enforced.

**Single declaration pattern**: every secret — service-owned or
operator-owned — is declared under the `nixhold.secrets.<name>`
options namespace. No parallel auto-discovery, no `nixhold.ssh.keys`
option, no filename-glob magic. One mental model.

```nix
# Service-owned: enable-triggered, service-user reads at runtime.
config = lib.mkIf cfg.enable {
  nixhold.secrets.vaultwarden-env = {
    owner       = "vaultwarden";
    mode        = "0400";

    # CLI-facing metadata:
    description = "Vaultwarden ADMIN_TOKEN (argon2id hash)";
    template    = ''ADMIN_TOKEN=...'';
    generator   = null;        # or e.g. "openssl rand -base64 32"
    required    = true;
  };
};

# Operator-owned, no home-symlink (read by wrapper scripts, etc.):
nixhold.secrets.github-pat = {
  owner       = "user";        # shortcut: identity.username + mode 0600
  description = "GitHub PAT for gh CLI";
  required    = true;
};

# Operator-owned, symlinked into $HOME:
nixhold.secrets.ssh-personal = {
  owner       = "user";
  homePath    = ".ssh/personal";   # framework HM module symlinks here
  description = "Operator SSH key for github.com and personal hosts";
  required    = true;
};
```

The framework reads `nixhold.secrets` and populates:
- `age.secrets.<name>` (with
  `file = secrets/hosts/${config.networking.hostName}/${name}.age`
  derived from context) — for NixOS activation-time decryption.
- `config.nixhold.secrets.declared` — the manifest the CLI consumes.
- HM symlinks for entries with `homePath` set
  (`home.file.${homePath}.source = mkOutOfStoreSymlink
  osConfig.age.secrets.<name>.path`).

Operator writes 3–6 fields; framework derives `name` (from the
attribute key), `hostname` (from `config.networking.hostName`),
the encrypted-file path, and HM symlinks.

**Three API shortcuts the framework provides:**

- `owner = "user"` — expands to `owner =
  config.nixhold.identity.username; mode = "0600"`. The default for
  operator-owned secrets.
- `homePath` (optional, only meaningful with `owner = "user"`) —
  the framework HM module symlinks `~/${homePath}` to the decrypted
  path. Replaces what filename-glob did for SSH keys, generalized
  for any operator secret that lives in `$HOME`.
- Naming convention `ssh-*` with `owner = "user"` triggers
  automatic `.pub` derivation: `~/${homePath}.pub` is generated via
  `ssh-keygen -y` on activation. No extra field.

The framework-wide manifest drives `nixhold secret list`,
`nixhold secret bootstrap`, and missing-secret assertions — one source
of truth for "what secrets does this host need." The manifest the
CLI consumes is `config.nixhold.secrets` itself: each entry already
carries `owner` / `mode` / `description` / `template` / `generator`
/ `required` / `homePath` plus the derived `recipients`,
`resolvedOwner`, `resolvedMode`, and (store-path) `file`. There is
no separate `nixhold.secrets.declared` attribute — the option
attrset *is* the manifest.

#### Recipient model & agenix RULES generation

The declaration side above handles **activation**:
`age.secrets.<name>` decrypts at boot using the host's SSH host key
(agenix's default `age.identityPaths`, `/etc/ssh/ssh_host_ed25519_key`).
The **editing** side (`nixhold secret new` / `edit` / `rekey`, and
the bootstrap auto-walk) needs the recipient set agenix encrypts
to. The framework computes it; the operator never hand-maintains a
`secrets.nix` rules file.

- **Recipients are a derived option.** Each secret carries a
  `readOnly` `recipients` list, computed at eval from declared
  data:
  - the operator's age recipient — `builtins.readFile
    nixhold.layout.ageRecipient` (always included, so the operator
    can edit / rekey from any device with the wrapped key);
  - the owning host's SSH host pubkey —
    `nixhold.layout.keysDir/hosts/<host>/host.pub`, when committed.

  Reading these committed pubkeys at eval is `layout.keysDir`'s
  stated purpose ("build … agenix recipient registries") and one
  of principle 14's permitted path exceptions: the paths are
  derived from declared data (`config.networking.hostName`, the
  layout roots), not discovered by walking the filesystem. Lint
  reads the same option to enforce "every host is a recipient of
  the secrets it decrypts."

- **Recipients are materialized ephemerally, never committed.**
  `nixhold secret *` runs `nix eval` to read
  `config.nixhold.secrets` (recipients + metadata), writes the
  recipient set to a throwaway age recipients file, and drives
  `age` directly: `age -R <recipients> -o <file>` to encrypt, the
  passphrase-unwrapped operator identity via `-i` to decrypt for
  `edit` / `rekey`. agenix-the-*module* still owns activation-time
  decryption (host SSH key); agenix-the-*CLI* is intentionally not
  a CLI dependency — the recipient set is the contract, `age` is
  the tool. `nixhold.secrets` plus the committed pubkeys stay the
  single source of truth (principle 8); no derived `secrets.nix`
  or recipients file is checked into the fleet to drift.

- **Working-tree paths, not eval paths.** `nixhold.layout.*` is
  `types.path`; evaluating it yields a read-only
  `/nix/store/<hash>-source/…` path. That is *correct* for the
  activation side — `age.secrets.<name>.file` must reference the
  committed ciphertext in the store. But the CLI *writes* `.age`
  files in the operator's working tree, so it resolves their
  location as `$fleet_root` + the repo-relative layout subpath (the
  eval'd store path with its `/nix/store/<hash>/` prefix stripped).
  The recipient *data* comes from eval; the *paths* are
  working-tree-resolved. This split is why the CLI cannot simply
  `cd` into the eval'd `layout.secrets`.

### Service modules: plain NixOS options under `nixhold.services.<name>.*`

Service modules are normal NixOS modules. They declare typed options
under `nixhold.services.<name>.*` using `mkOption`. The shared option
sub-trees — `network` and `expose` — are just named options with
documented types, not a separate "facet" system.

```nix
# modules/services/vaultwarden.nix
{ config, lib, ... }:
let
  cfg   = config.nixhold.services.vaultwarden;
  types = config.nixhold.types;
in {
  options.nixhold.services.vaultwarden = {
    enable  = lib.mkEnableOption "vaultwarden";
    network = lib.mkOption { type = types.network; default = {}; };
    expose  = lib.mkOption { type = types.expose;  default = {}; };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = { ... };
    # cfg.expose, etc. are read by infra modules below.
  };
}
```

The shared option types (`nixhold.types.expose`, `nixhold.types.network`)
live in `modules/types/*.nix`. Each type is a normal
`lib.types.submodule` with documented options — same machinery as
the rest of NixOS. Additional shared types (e.g. `data`, `health`,
`metrics`, `logs`) land alongside their consumer infra modules
when those are built; designing the type without a consumer risks
getting the shape wrong.

Specialization is by **kind directory**, not by API. Each kind has
an explicit `default.nix` index that lists its members (see
"Framework wiring" below):
- `modules/services/*.nix` — services. Declare under
  `nixhold.services.<name>`; lint expects `expose` (or explicit empty).
  NixOS-only.
- `modules/infra/*.nix` — infrastructure. Reads `config.nixhold.services.*`
  to wire itself. NixOS-only; auto-activates from declared data,
  no `enable` knob.
- `modules/identity/{default,nixos,darwin}.nix` — identity options
  (shared) + per-platform wiring.
- `modules/secrets/{default,nixos,darwin}.nix` — `nixhold.secrets.*`
  API surface (shared) + per-platform activation.
- `modules/types/default.nix` — shared option types (`nixhold.types.expose`,
  `nixhold.types.network`).
- `modules/home/` — home-manager modules. Cross-platform HM
  concerns at top (`default.nix` + flat `*.nix` files); platform
  extras in `nixos.nix` / `darwin.nix`. Per-host HM additions go
  through `nixhold.home.extraModules` (declared option, set in the host
  file), not through a sibling-file convention.

Opinionated host-kind bundles live in **top-level `profiles/`**
(not under `modules/`), attached per host in `hosts.nix`. See
"Profiles" below.

### Infrastructure modules consume `nixhold.services.*`

The consumer pattern is a single `config.nixhold.services` walk:

```nix
# modules/infra/caddy.nix
{ config, lib, ... }:
let
  services   = lib.attrValues config.nixhold.services;
  endpoints  = lib.concatMap (s: lib.attrValues (s.expose or {})) services;
  httpEndpoints = lib.filter
    (e: e.protocol == "https" || e.protocol == "http")
    endpoints;
in {
  services.caddy.virtualHosts = lib.listToAttrs (map (e: {
    name  = lib.mkVhostFqdn e config.nixhold.fleet;
    value = lib.mkCaddyVhost e config.nixhold.fleet;
  }) httpEndpoints);
}
```

No `byName` / `byType` indexes — the walk is the index. No schema
registry — `mkOption` types do the validation. No publish/subscribe
ceremony — option declaration is the publish, `config` read is the
subscribe.

Starter infrastructure modules (one per starter option type):
- `modules/infra/caddy.nix` — consumes `expose` (HTTP-family
  protocols).
- `modules/infra/firewall.nix` — consumes `network` + `expose`.
- `modules/infra/dns.nix` — consumes `expose` for public
  endpoints + `fleet.hosts.*.publicIp` for host canonical records.
- `modules/infra/secrets-manifest.nix` — consumes the secrets
  registry.

Future infrastructure modules add new option types (`data`,
`health`, `metrics`, `logs`, etc.) at the same time they're
written — the type is designed alongside its consumer, not
speculatively.

### Profiles — opinionated host-kind bundles

A profile is a NixOS / Darwin module that imports the service +
infra modules a host *kind* needs and sets opinionated defaults.
The framework ships profiles for the canonical shapes
(`nixhold.profiles.server`, `nixhold.profiles.desktopLinux`,
`nixhold.profiles.workstationDarwin`); forkers compose their own
by importing module values.

```nix
# nixhold.profiles.server — shipped by the framework
{ inputs, ... }: {
  imports = [
    inputs.nixhold.modules.services.openssh
    inputs.nixhold.modules.services.tailscale
    inputs.nixhold.modules.infra.caddy
    inputs.nixhold.modules.infra.firewall
  ];

  nixhold.services.openssh.enable   = true;
  nixhold.services.tailscale.enable = true;

  security.fail2ban.enable = true;
  documentation.enable     = false;
  services.fwupd.enable    = false;
  # …other server-shape defaults
}
```

The framework's flake builds the `nixhold.profiles.*` attrset
explicitly in its `flake.nix` outputs. Forkers reference them by
attribute:

```nix
# In the forker's flake (mkFleet args)
hosts = {
  homelab = { arch = "x86_64-linux";   profile = nixhold.profiles.server;            … };
  desktop = { arch = "x86_64-linux";   profile = nixhold.profiles.desktopLinux;      … };
  mac     = { arch = "aarch64-darwin"; profile = nixhold.profiles.workstationDarwin; … };
};
```

`mkFleet` adds `host.profile` to the imports of each host's
module bundle. **There is no name resolution layer** — `profile`
is a Nix value, referenced via attribute access. Typos fail at
eval time (`nixhold.profiles.serevr` → undefined attribute).

Forkers compose a custom profile by importing the modules they
want:

```nix
# nixhold.layout.profilesDir / homelab.nix — forker-authored
{ inputs, ... }: {
  imports = [
    inputs.nixhold.profiles.server                  # start from the server baseline
    inputs.nixhold.modules.services.vaultwarden     # add vaultwarden
    inputs.nixhold.modules.services.jellyfin        # add jellyfin
  ];
  nixhold.services.vaultwarden.enable = true;
  nixhold.services.jellyfin.enable    = true;
}
```

`nixhold profile new <name>` scaffolds a fresh profile under
`nixhold.layout.profilesDir`. The operator imports it from their
flake however they want.

**Composition.** A host that needs multiple profiles either
wraps them at the call site (`profile = { imports = [
nixhold.profiles.server nixhold.profiles.monitored ]; }`) or
imports the secondary profile from a forker-authored profile.
NixOS module merging handles the rest. The common case is one
profile.

**Override.** Any value set by a profile is overridable via
plain assignment in the host config (or `lib.mkForce` for values
the profile itself set via `lib.mkForce`).

**Why at the fleet level, not the host file.** Earlier drafts
placed the profile import inside the host module. Putting it in
`hosts.<n>.profile` (a top-level field on the fleet entry) is a
net win: the fleet manifest reads end-to-end as "I have a
server, a desktop, and a workstation"; host files shrink to
pure host-specific config; the profile reference is a typed Nix
value (not a string lookup), so typos fail at eval. Topology and
behavior are *related* per host, and the profile field captures
that relation in one place.

**v1 framework-shipped profiles:**
- `nixhold.profiles.server` — NixOS server defaults.
- `nixhold.profiles.desktopLinux` — NixOS hyprland desktop defaults.
- `nixhold.profiles.workstationDarwin` — macOS workstation defaults.

These correspond to the host kinds in the author's own fleet —
same logic as v1's starter service set and starter infra
modules. Forker-added profiles live under
`nixhold.layout.profilesDir`; the operator's flake imports them
into the host's `profile` field by ordinary path reference.

### Framework wiring

How the framework loads itself. Five mechanisms.

**Single entrypoint: `nixhold.lib.mkFleet`.** The framework exposes
one function as its forker-facing API. The forker's `flake.nix`
hands `mkFleet` Nix values directly — no filesystem-side discovery
(see Principle 14). A complete forker flake:

```nix
{
  description = "<forker>'s fleet";
  inputs.nixhold.url = "github:fcalell/nixhold";  # or .../nixhold/<rev> or .../nixhold/v0.3.0
  outputs = { self, nixhold, ... } @ inputs: nixhold.lib.mkFleet {
    inherit inputs;

    identity = {
      username = "fcalell";
      fullName = "Frankie Calella";
      email    = "frankie.calella@gmail.com";
    };

    layout = {
      secrets            = ./secrets;
      hostsFile          = ./hosts.nix;
      modulesDir         = ./modules;
      profilesDir        = ./profiles;
      keysDir            = ./keys;
      ageRecipient       = ./operator.pub;
      ageIdentityWrapped = ./operator.age;
    };

    networks = {
      tailnet = { type = "tailscale"; magicDnsSuffix = "tail6ac451.ts.net"; };
      public  = { type = "internet";  domain = "example.com";
                  dns.provider = "cloudflare"; tls.method = "acme-dns01"; };
    };

    hosts = import ./hosts.nix { inherit nixhold; };
  };
}
```

The forker declares only `inputs.nixhold`. nixpkgs, home-manager,
agenix, disko, nixos-anywhere, nixos-hardware are pulled
transitively via `inputs.nixhold.inputs.*` — `mkFleet` reads them
from there, never from the forker's top-level `inputs`. A forker
who needs to bump nixpkgs ahead of nixhold's pin declares
`inputs.nixpkgs` themselves and rebinds
`inputs.nixhold.inputs.nixpkgs.follows = "nixpkgs"` — standard
flake follows idiom, no special API. Forker-added inputs (e.g.,
a custom service flake) still flow through to per-host
`specialArgs.inputs`.

**The `{ inputs, identity, networks, hosts, layout }` signature.**
Five parameters, no overloads. All are required Nix values
(attrsets, except `inputs` which is the flake-call attrset).
`mkFleet` reads no files from disk; it operates on the values it
receives.

| Parameter | Type | Purpose |
|---|---|---|
| `inputs` | attrset | flake inputs (passed via `@ inputs`); used to resolve nixpkgs and transitive deps |
| `identity` | attrset | operator identity: `{ username, fullName, email }` |
| `layout` | attrset | declared paths for the CLI: `secrets`, `hostsFile`, `modulesDir`, `profilesDir`, `keysDir`, `ageRecipient`, `ageIdentityWrapped` |
| `networks` | attrset | per-network definitions: `{ type, magicDnsSuffix?, domain?, dns?, tls? }` |
| `hosts` | attrset | per-host topology: `{ <name> = { arch, profile, modules, networks, publicIp?, publicFqdn?, loginPubkey? }; ... }` |

Profiles are referenced as Nix values (`profile = nixhold.profiles.server`),
never as strings. `mkFleet` does no name resolution; it just adds
`host.profile` to the per-host imports list. `hosts.<n>.modules`
is the forker's escape hatch: any extra NixOS/Darwin modules
attached to that host (host-specific configuration files, disko
imports, etc.). All of this is plain Nix — the framework reads no
"conventional" files.

**The `layout` contract.** Required, with every field set. The
framework eval never reads from these paths directly; the CLI
reads `layout` via `nix eval` to know where to write scaffolded
files and where to find committed secrets/keys. Splitting CLI-side
filesystem state from framework-side typed options is what
preserves Principle 14 while keeping `nixhold host add` /
`nixhold secret new` ergonomic. `layout.hostsFile` is a single Nix
file the CLI owns end-to-end — it manipulates the `hosts` attrset
inside it as `nixhold host add`/`remove` run.

`mkFleet` returns the full flake output set: `nixosConfigurations`,
`darwinConfigurations`, `apps.<system>.nixhold` (the one operator
CLI; no separate installer apps — see the Lifecycle workflow + CLI
implementation shape sections), `apps.<system>.default` (aliases
`nixhold`), `packages.<system>.nixhold`, and `formatter.<system>`
(`nixfmt`). All four are re-exported from the framework's own
per-system outputs, so a forker gets `nix run .#nixhold`,
`nix build .#nixhold`, and `nix fmt` from the fleet repo.

`mkFleet` deliberately does **not** emit a `checks.<system>`
gate. `nixhold lint --strict` shells out to `nix eval` against the
flake, which can't run inside a sandboxed, pure `nix flake check`
derivation — so lint runs from the CLI (dev loop) and CI (a plain
`nixhold lint --strict` step), not as a flake check. Eval-time
invariants that must hard-fail a build instead live as module
assertions (e.g. the facter-report guard), which
`nix build` / `nixos-rebuild` force regardless.

`mkFleet` is the recommended path; the framework's own outputs
(`inputs.nixhold.nixosModules.nixhold`,
`inputs.nixhold.darwinModules.nixhold`, `inputs.nixhold.lib.*`
helpers, `inputs.nixhold.profiles.*`, `inputs.nixhold.modules.*`)
are exposed for forkers who need to compose nixhold into a
non-`mkFleet` host builder, but the supported contract is the
`mkFleet` signature plus its output shape.

**What `inputs.nixhold.*` exposes.** The framework's own flake outputs:

| Output | Purpose |
|---|---|
| `lib.mkFleet` | the entrypoint above |
| `lib.<helpers>` | helpers that prove useful externally (e.g. `mkProfile`, `mkService`) — additive over time, gated on real consumers |
| `nixosModules.nixhold` | single bundled NixOS module set (programs.nixhold, nixhold.identity, nixhold.fleet, secrets, types, layout, plus baseline service+infra exposure) |
| `darwinModules.nixhold` | single bundled darwin module set |
| `homeManagerModules.nixhold` | the HM module bundle |
| `profiles.<name>` | plain NixOS/Darwin modules — `profiles.server`, `profiles.workstationDarwin`, `profiles.desktopLinux`. Referenced as Nix values from `hosts.<n>.profile`. Primary composition path. |
| `modules.<kind>.<name>` | individual service/infra modules — `modules.services.vaultwarden`, `modules.infra.caddy`, etc. Escape hatch for forkers composing their own profiles. Stability surface; expand on real consumer demand. |
| `apps.<system>.nixhold` | the operator CLI, callable bare as `nix run github:fcalell/nixhold#nixhold -- <verb>` (no fleet required for `init` / `host add` scaffolding) |
| `templates.default` | scaffold for `nix flake init -t github:fcalell/nixhold` |
| `formatter.<system>` | `nixfmt` |
| `checks.<system>.*` | the framework's own CI checks — builds the synthetic `checks/fixture` fleet (one host per platform) so mkFleet / baseline / profile drift fails here. Not emitted by `mkFleet` (see above). |

**Single bundled module per platform, not à-la-carte.** Forkers
import `nixosModules.nixhold` (not `nixosModules.identity`,
`nixosModules.secrets`, ...) and configure via options. Cherry-
picking submodules is rejected — splitting the export surface
would invite forkers to import partial sets and trip on missing
inter-module dependencies that the framework asserts are always
co-present.

**Module-internal imports use relative paths.** Inside the framework,
modules import siblings as `../common/identity.nix`, never as
`inputs.nixhold.nixosModules.nixhold`. That avoids self-import gymnastics
and keeps modules movable. The only consumers of `inputs.nixhold.*`
are forkers.

**Pre-`mkFleet` access to the CLI.** First-time setup
(`nixhold init`, `nixhold host add`) needs the CLI before a forker
has a working fleet. `nix run github:fcalell/nixhold#nixhold -- init`
works directly against the framework's flake —
`apps.<system>.nixhold` is exported unconditionally, not
parametrized by fleet content. CLI subcommands that need fleet
context (e.g. `nixhold host install`, `nixhold deploy --dry-run`,
`nixhold status`) error cleanly with a "no `flake.nix` calling
`mkFleet` found in $PWD" message when invoked against a bare repo.

**Versioning.** v1 forkers pin by SHA (`github:fcalell/nixhold/<rev>`)
or track `main` (discouraged in the README). Tagged releases
(`v0.1.0`, ...) land once the surface is stable enough that a
SemVer contract is meaningful. No CHANGELOG until the first
external consumer.

**Dogfood location: out-of-tree, from day 1.** The framework repo
(`github:fcalell/nixhold`) contains only framework code:

```
flake.nix              library + apps + templates; NO mkFleet call
lib/                   mkFleet, helpers
modules/               kind-organized module bundles (nixos/darwin/home),
                       exposed via flake outputs (profiles.*, modules.*)
cli/                   one writeShellApplication; subcommand sources
template/              scaffold for `nix flake init -t .#`
checks/                synthetic fleet fixture mkFleet is run against in CI
```

fcalell's actual fleet — the mac, desktop, and homelab hosts —
lives in a separate, pinned-on-nixhold repo and consumes
`inputs.nixhold` exactly like any external forker. There is no
in-tree dogfood phase; the split happens before the first machine
is provisioned. Dogfooder UX and forker UX are identical from the
start — no "framework dev mode" exception path, no migration step
later. Two-step verification (push framework → bump downstream
lock → build) is the cost; the gain is that any drift between
`mkFleet`'s contract and real fleet usage shows up the same way
for fcalell as for any external forker.

CI on the framework repo runs `nix flake check` against
`checks/fixture/` — a synthetic fleet with one of each host kind
that exercises the `mkFleet` output surface end-to-end. The
fixture catches `mkFleet` drift on every commit; the real
downstream fleet catches ergonomic and integration drift on the
cadence the operator naturally bumps.

**Dispatch: per-arch-family builders.** `mkFleet` partitions
`hosts` by arch suffix and calls a dedicated builder per family.
Two builders rather than one `mkHost` with `isDarwin` branches.
Note that `mkFleet` reads no files from disk — all input is the
Nix values passed in the signature. The operator's per-host
modules (host config, disko import, etc.) come from
`hosts.<name>.modules`:

```nix
{ inputs, identity, networks, hosts, layout }:
let
  inherit (inputs.nixhold.inputs) nixpkgs nix-darwin;
  lib = nixpkgs.lib;

  fleetView = { inherit hosts networks; };

  linuxHosts  = lib.filterAttrs (_: h: lib.hasSuffix "-linux"  h.arch) hosts;
  darwinHosts = lib.filterAttrs (_: h: lib.hasSuffix "-darwin" h.arch) hosts;

  baseline = name: host: [
    { networking.hostName = lib.mkDefault name;
      nixpkgs.hostPlatform = host.arch; }
    { nixhold = {
        inherit identity layout;
        fleet  = fleetView;
      }; }
  ];

  mkNixosHost = name: host: nixpkgs.lib.nixosSystem {
    system      = host.arch;
    specialArgs = { inherit inputs identity; fleet = fleetView; hostname = name; };
    modules =
      [ inputs.nixhold.nixosModules.nixhold ]   # baseline only: identity, secrets, fleet, types, layout
      ++ [ host.profile ]                       # profile imports its service + infra modules
      ++ baseline name host
      ++ host.modules;                          # operator's per-host modules (host config, disko, facter…)
  };

  mkDarwinHost = name: host: nix-darwin.lib.darwinSystem {
    system      = host.arch;
    specialArgs = { inherit inputs identity; fleet = fleetView; hostname = name; };
    modules =
      [ inputs.nixhold.darwinModules.nixhold ]
      ++ [ host.profile ]
      ++ baseline name host
      ++ host.modules;
  };
in {
  nixosConfigurations  = lib.mapAttrs mkNixosHost  linuxHosts;
  darwinConfigurations = lib.mapAttrs mkDarwinHost darwinHosts;
  # apps, packages, formatter re-exported from inputs.nixhold in the
  # rest of mkFleet; no checks gate (see contract above)
}
```

Each builder owns its own baseline module bundle and platform-
specific wiring without polluting the other. A third arch family
(WSL, FreeBSD) would be a third top-level builder + a third
output namespace — symmetric, not retrofitted.

**Disko and facter are operator-side imports.** Under Principle
14, the framework does not read `${root}/hosts/<name>/disko.nix`
or `facter.json` directly. The forker's `hosts.<name>.modules`
includes them as ordinary imports:

```nix
homelab = {
  arch    = "x86_64-linux";
  profile = nixhold.profiles.server;
  modules = [
    ./hosts/homelab/configuration.nix
    ./hosts/homelab/disko.nix
    inputs.disko.nixosModules.disko
    { nixhold.hardware.facterReport = ./hosts/homelab/facter.json; }
  ];
  # …
};
```

Filenames and locations are the forker's choice — only `.age` and
`facter.json` carry conventional names (the former because agenix
requires it, the latter because nixos-facter writes that name).
`nixhold lint` checks that every NixOS host imports a disko module
and references a facter report; missing them is a lint failure,
not a framework path error.

**Module exposure: flake outputs, not directory walks.** Within
the framework repo, modules are organized as files under
`modules/<kind>/<name>.nix` (see "Cross-platform split" below) —
that's source-tree organization, not eval-time discovery. The
framework's own `flake.nix` builds the `nixhold.modules.<kind>.<name>`
and `nixhold.profiles.<name>` output attrsets explicitly, by
listing each member in the flake's outputs. No `readDir`, no
`pathExists`. Adding a service inside the framework: write the
file, add the line to `flake.nix`. The "registry" is the flake
output table — visible to forkers via standard Nix tooling
(`nix flake show`, `nixos-option`).

Forkers compose profiles by importing module values:

```nix
# In the forker's profiles/server.nix
{ inputs, ... }: {
  imports = [
    inputs.nixhold.modules.services.vaultwarden
    inputs.nixhold.modules.services.tailscale
    inputs.nixhold.modules.infra.caddy
    inputs.nixhold.modules.infra.firewall
  ];
  # opinionated defaults for this profile…
}
```

Or skip the profile entirely and put module imports directly in
`hosts.<n>.modules`. Both paths read the same way: Nix values
passed by attribute reference.

**Cross-platform split: kind-first, platform variants nested.**
Module directories are organized by *kind* (the primary lookup
axis); each kind directory contains optional `nixos.nix` /
`darwin.nix` siblings for platform-specific wiring.

```
modules/
├── identity/             shared options + per-platform wiring
│   ├── default.nix
│   ├── nixos.nix
│   └── darwin.nix
├── secrets/              nixhold.secrets.* API + per-platform activation
│   ├── default.nix
│   ├── nixos.nix
│   └── darwin.nix
├── services/             NixOS service modules
│   ├── default.nix
│   └── *.nix
├── infra/                NixOS infrastructure modules
│   ├── default.nix
│   └── *.nix
├── types/                shared option types
│   └── default.nix
└── home/                 home-manager modules
    ├── default.nix       shared HM modules index
    ├── shell.nix
    ├── editor.nix
    ├── nixos.nix         NixOS-host HM extras
    └── darwin.nix        darwin-host HM extras
```

Each kind directory's `default.nix` self-gates its platform
variants explicitly — the framework just imports the kind directory,
the kind decides what's in scope:

```nix
# modules/identity/default.nix
{ pkgs, lib, ... }: {
  imports = [ ./options.nix ]
    ++ lib.optional pkgs.stdenv.isLinux  ./nixos.nix
    ++ lib.optional pkgs.stdenv.isDarwin ./darwin.nix;
}
```

The framework's baseline bundle is small. Per the new principle
14, services and infra are **not** auto-imported on every host —
they're picked up via profiles or per-host
`hosts.<n>.modules`. The baseline only contains what's cross-
cutting and always meaningful:

```nix
# Per-NixOS-host baseline:
nixosModules.nixhold.imports = [
  ./modules/identity        # nixhold.identity options + wiring
  ./modules/secrets         # nixhold.secrets options + agenix activation
  ./modules/fleet           # nixhold.fleet view (read-only on each host)
  ./modules/types           # shared option types (expose, network, address, …)
  ./modules/layout          # nixhold.layout option (CLI's filesystem contract)
  ./modules/home            # home-manager wiring, including nixhold.home.extraModules
];

# Per-darwin-host baseline (same minus NixOS-only systemd bits):
darwinModules.nixhold.imports = [
  ./modules/identity
  ./modules/secrets
  ./modules/fleet
  ./modules/types
  ./modules/layout
  ./modules/home
];
```

Service modules (`./modules/services/*`) and infra modules
(`./modules/infra/*`) are exposed as flake outputs
(`nixhold.modules.services.*`, `nixhold.modules.infra.*`) and
pulled in by profiles or by `hosts.<n>.modules` — never
auto-imported. A Mac host that doesn't import the vaultwarden
service module gets no `nixhold.services.vaultwarden.*` options
at all; cross-platform confusion is impossible by construction.

Per-host HM extras are declared, not discovered. `modules/home/`
exposes:

```nix
options.nixhold.home.extraModules = lib.mkOption {
  type    = lib.types.listOf lib.types.deferredModule;
  default = [ ];
  description = "Per-host home-manager module fragments.";
};

config.home-manager.users.${config.nixhold.identity.username}.imports =
  config.nixhold.home.extraModules;
```

The host file sets `nixhold.home.extraModules = [ ./home.nix ];` when
it needs per-host HM additions.

Cross-platform concepts (identity, secrets, home-manager) live in
one directory each: end-to-end understanding is `ls modules/<kind>/`.
NixOS-only options don't exist on darwin hosts; a darwin config
that references `nixhold.services.vaultwarden` eval-fails immediately —
the right place to catch platform-confusion.

A future genuinely-cross-platform service generalizes the same
pattern: `modules/services/tailscale/{default,nixos,darwin}.nix`,
no new layout invented.

**Infra activation: auto from declared data, no `enable` knob.**
Every infra module is imported on every NixOS host (per the bundle
above), and its `config` block guards on the data it consumes —
`mkIf (httpEndpoints != [])` for caddy, `mkIf (publicEndpoints !=
[])` for firewall, and so on. (See "Infrastructure modules consume
`nixhold.services.*`" above for the walk pattern.)

No `nixhold.infra.<name>.enable` option exists. A host with no HTTP
endpoints doesn't run caddy; a host with endpoints does,
automatically. Forkers who genuinely want to replace caddy with
nginx write a parallel infra module that consumes the same
`nixhold.services.*.expose` data (principle 7) — that's the prescribed
escape, not flipping an `enable` flag.

If a real consumer for "host with endpoints but framework infra
disabled" ever surfaces, adding an `enable` option with the
auto-derived default is purely additive — until then, the knob
stays absent (principle 5).

### Lifecycle workflow

The forker-facing flow is intentionally small: **fork → add a host
→ install it**, with the same shape across VPS, on-prem, and Mac.
This section is the operator's-view-of-the-framework, expressed as
the lifecycle events they actually walk through.

**Prereq:** Nix on the operator's primary machine (one-line
Determinate Systems installer). This is the only non-trivial
prerequisite; everything else is a tool the framework brings.

**L1 — First-time fork setup.** One-time per fork.

```
nix flake init -t github:fcalell/nixhold     # scaffolds flake.nix + minimal layout
$EDITOR flake.nix                            # fill identity (username, fullName, email)
                                             # and layout (paths under nixhold.layout)
nix run .#nixhold -- init                    # provisions ~/.config/nixhold/identity.age.txt
                                             # (operator's age key, unwrapped via passphrase)
```

**L2 — Add the first host (Mac as primary).**

```
nix run .#nixhold -- host add mac --install  # interactive TUI: arch, profile, networks;
                                             # generates SSH+age keys; writes the entry to
                                             # nixhold.layout.hostsFile; walks secret bootstrap;
                                             # runs darwin-rebuild in place
```

After this, `nixhold` is in PATH on the Mac (via
`programs.nixhold.enable`). Subsequent commands drop the
`nix run .#nixhold --` prefix.

**L3 — Add a NixOS host (VPS or on-prem).**

```
# (Operator creates VPS / boots installer USB, gets it to a reachable SSH state)
nixhold host add server --install root@203.0.113.42
```

The `--install` flag chains `host add` → `host install` in one
command. The TUI scaffolds the host entry, writes it to
`nixhold.layout.hostsFile`, then SSHes to the target, runs
hardware detection (`lsblk`, facter), prompts for the root disk
(or accepts `--disk /dev/disk/by-id/...`), generates `disko.nix`
and `facter.json` locally at the location the operator's flake
imports (typically alongside the host config), drives
`nixos-anywhere` with `--build-on-remote` (the installer
environment builds the target's closure; same
"each-machine-builds-its-own" rule as `nixhold deploy`), commits
the just-generated files after success. **The operator never
edits a `CHANGE_ME` marker, never hand-writes a disko layout,
and the operator's machine never builds the target's arch.**

On-prem installs use the same path: boot the official NixOS
installer USB, set a root SSH key on the installer
(`mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys`), note the
installer's DHCP IP, run `nixhold host add <name> --install
root@<installer-ip>` from the operator's primary.

If the operator prefers to scaffold first and install later:
`nixhold host add <name>` (no `--install`) writes the entry and
exits; `nixhold host install <name> --remote ...` provisions when
ready.

**L4 — Add a service to an existing host.**

```
$EDITOR <host or profile module>      # import a service module; set enable = true
nixhold deploy <name>                 # auto-walks secret bootstrap if any are missing,
                                      # then builds (on target) + activates
```

No new verb for "add a service" — services are options, the host
file (or its profile) is the source, `nixhold deploy --dry-run` is
the pre-rebuild review, `nixhold deploy` is the activation. The
target host builds its own closure; the operator's machine only
orchestrates. `nixhold deploy` auto-detects newly-declared secrets
that don't yet have ciphertext on disk and walks the bootstrap
prompts before proceeding (the former `nixhold secret bootstrap`
verb folded into the normal flow).

**L5 — Scaffold a new service module.**

```
nixhold service new my-thing          # scaffolds <nixhold.layout.modulesDir>/services/my-thing.nix
$EDITOR <nixhold.layout.modulesDir>/services/my-thing.nix
```

**L6 — Update flake inputs.**

```
nix flake update
for h in mac desktop server vps; do nixhold deploy --dry-run $h; done
# Review per-host delta; deploy the hosts you intended to change.
for h in <chosen>; do nixhold deploy $h; done
```

**L7 — Reinstall a host** (new hardware, VPS provider move; same
hostname, same fleet entry, host SSH identity preserved via cache):

```
nixhold host install vps --remote root@<new-ip>
# Reuses ~/.cache/nixhold/host-keys/vps/ → host's age identity unchanged →
# existing encrypted secrets still decrypt → no re-encryption needed.
```

If the cache is lost (operator machine rebuilt, no backup):

```
nixhold host rotate-key vps                  # new host SSH key, re-encrypt all of vps's secrets
nixhold host install vps --remote root@<ip>
```

**L8 — Rename a host.** No v1 verb — manual `git mv` of the
operator-owned host files + the secrets/keys directories, edit
the entry in `nixhold.layout.hostsFile`, then `nixhold secret
rekey` + `nixhold host install <new-name>`. Add `nixhold host
rename` later if it surfaces as a real need.

**L9 — Remove a host.**

```
nixhold host remove vps
# Confirms; deletes fleet entry, hosts/vps/, secrets/hosts/vps/, keys/hosts/vps/.
# Leaves ~/.cache/nixhold/host-keys/vps/ alone (operator can rm if they want).
# Decommissioning the running machine is the operator's job (provider tools).
```

**L10 — Recover.** Three scenarios with distinct paths:

- *Host died, repo + identity + cache intact* → same as L7.
- *Operator machine lost, repo + identity recoverable, cache lost* →
  restore identity to `~/.config/nixhold/identity.age.txt`; for each
  host: `nixhold host rotate-key <name>` + `nixhold host install <name>`.
- *Operator age identity lost* → catastrophic, no recovery path.
  Re-init identity, every secret needs regeneration. Documented in
  a `DR.md`-style note; no CLI assistance (per "operator key
  recovery beyond what we have" — deferred until Shamir or
  hardware-backed identity lands).

**Properties this workflow has:**

- One CLI, one entry pattern (`nixhold <verb>` or `nix run .#nixhold -- <verb>`).
- Verb-first vocabulary (`host add`, `host install`, `host remove`)
  reads like English.
- Platform context is a flag, not a separate command. Darwin auto-
  dispatches from `fleet.hosts.<name>.arch`.
- Idempotent throughout. `host add` on an existing host edits;
  `host install` reinstalls.
- The repo + operator age identity is the entire source of truth.
  The host-key cache is regeneratable (`rotate-key`).
- No `--here` mode; no `CHANGE_ME` markers; no separate
  installer flake apps.

### The `nixhold` operator CLI

`nixhold` is the **single operator CLI** — everything an operator
does to the fleet flows through it. Pre-install access is
`nix run .#nixhold -- <subcommand>` (works from a fresh clone, no PATH
dependency); post-install is bare `nixhold <subcommand>` (the
`programs.nixhold.enable` module puts it on PATH). Both run the same
bash scripts; the split is purely an access path. There are **no
separate installer flake apps** — the historical
`init-fc-identity`, `new-host`, `bootstrap-local`,
`bootstrap-remote` scripts are all absorbed as `nixhold init` and
`nixhold host {add,install}`. The CLI name does not collide with
the POSIX/zsh/bash `fc` builtin (history editor) — the legacy
short name was rejected for exactly that reason.

```
# One-time per fork
nixhold init                                       provision operator age identity

# Per host — lifecycle
nixhold host add  <name> [--install <user>@<ip>]   interactive TUI: prompts arch, profile, networks;
                                                   writes entry to nixhold.layout.hostsFile;
                                                   --install triggers nixos-anywhere immediately after
nixhold host install <name> [--remote <user>@<ip>] [--disk <by-id>]
                                                   re-provision an already-added host (deferred
                                                   installs, reinstalls); detects hardware, generates
                                                   disko + facter, runs nixos-anywhere or darwin-rebuild
nixhold host rotate-key <name>                     new host SSH key, re-encrypt secrets
nixhold host remove <name>                         delete fleet entry, hosts/, secrets/, keys/

# Day-to-day deploy + introspection
nixhold deploy <name> [--mode {switch|boot|test}] [--dry-run] [--target <addr>] [--yes]
                                                   build + activate <name>'s current config;
                                                   target builds itself for remote hosts;
                                                   --dry-run shows framework delta + activation diff
nixhold status [--host <name>] [--fleet]           enabled services, expose endpoints, secret status,
                                                   fleet summary (--fleet)
nixhold lint   [--strict]                          convention checks incl. required-secrets-present
                                                   (CI gate in --strict)
nixhold logs   <host> <service> [--lines N] [--since <when>] [--follow]
                                                   ssh + journalctl -u <unit> with sensible defaults

# Secrets (bootstrap auto-walks during host add and deploy when missing)
nixhold secret new   <host> <name>                 create a new secret (interactive)
nixhold secret edit  <host> <name>                 edit an existing secret
nixhold secret rekey                               re-encrypt all secrets to current recipient set

# Scaffolds (less frequent)
nixhold service new <name>                         scaffold a service module at nixhold.layout.modulesDir
nixhold profile new <name>                         scaffold a profile at nixhold.layout.profilesDir
```

**Surface count: 14 verbs.** Five verbs were dropped from the
earlier design: `host list` (folded into `status --fleet`), `diff`
(folded into `deploy --dry-run`), `secret list` (folded into
`status`), `secret check` (folded into `lint`), `secret bootstrap`
(auto-walks during `host add` and `deploy` when declared secrets
are missing — still an internal workflow, just not a top-level
verb). The principle: each verb does something the operator
actually performs, not a flag-shaped alias of another verb.

Notable shapes:
- **`--here` mode does not exist.** Local NixOS installs use the
  same `--remote root@<installer-ip>` path: the operator boots a
  NixOS installer USB on the target, the installer's sshd becomes a
  temporarily-reachable target, and the install runs from the
  operator's primary just like a VPS install. One code path.
- **Darwin installs auto-detect.** `nixhold host install mac` (no
  `--remote`) on a host whose `fleet.hosts.mac.arch` is
  `aarch64-darwin` runs `darwin-rebuild switch --flake .#mac` in
  place — the Mac is its own target.
- **Disko and facter are install-time outputs**, not
  scaffold-time placeholders. `nixhold host add` does *not* write a
  `disko.nix`; `nixhold host install` queries the target's hardware,
  prompts the operator with a disk picker (gum, pre-selecting the
  obvious choice; `--disk` flag skips the prompt), generates both
  files, commits them after the install succeeds. Operators never
  see a `CHANGE_ME` marker.

The CLI reads:
- `nixosConfigurations.<host>.config.nixhold.fleet`
- `nixosConfigurations.<host>.config.nixhold.services`
- `nixosConfigurations.<host>.config.nixhold.secrets.declared`

For per-option documentation, `nixos-option nixhold.services.<name>`
(part of stock NixOS) is the source of truth. The framework does
not re-generate documentation as a build artifact; option
`description` text + `nixos-option` covers it.

**Eval cost.** Every introspection command runs `nix eval --json`
against the host config. Cold cache: ~5–15 s depending on flake
size. Warm cache: sub-second. The framework does **not** maintain
its own caching layer (hidden state, stale view risk) or a
`--fast` mode (fragments the UX). Nix's eval cache is the cache.
Operators who notice slow `nixhold status` should run anything that
warms the eval cache once (e.g. `nix flake check` or any rebuild).

### CLI implementation shape

**Language: bash + `gum`.** Every subcommand is a shell script,
packaged via `pkgs.writeShellApplication`. `pkgs.gum` (from
nixpkgs) is the one third-party UX dependency, added to
`runtimeInputs` per-subcommand where it visibly helps (interactive
wizards, pickers, spinners, styled headers). Adoption is per-
command, not framework-wide: simple commands start with plain
`read -rp` / `case`; subcommands grow into gum as their flow earns
it. Compiled alternatives (Go, Rust) and interpreted alternatives
(Python) are rejected — bash matches the existing installer-script
fluency in the codebase, adds zero runtime closure beyond the
~10 MB gum binary, and the framework's structured-data work
belongs in Nix, not in the CLI.

**Layout.** One source tree under `cli/`, packaged as a single
`writeShellApplication` exposing the `nixhold` binary. Subcommands
are dispatched from one entry point:

```
cli/
├── nixhold.sh               dispatcher (case "$1" in … ; source cli/<sub>.sh ; ...)
├── lib/
│   ├── run.sh               common helpers: require_fork_root,
│   │                        nix_eval_host, jq_or_die, die, info, ...
│   ├── prompt.sh            gum wrappers (input, choose, confirm, spin)
│   └── ssh.sh               SSH helpers for nixhold host install (lsblk over ssh, etc.)
├── init.sh                  nixhold init
├── host-add.sh              nixhold host add (TUI + optional --install)
├── host-install.sh          nixhold host install
├── host-rotate-key.sh       nixhold host rotate-key
├── host-remove.sh           nixhold host remove
├── deploy.sh                nixhold deploy (handles --dry-run)
├── status.sh                nixhold status (handles --fleet)
├── logs.sh                  nixhold logs
├── secret.sh                nixhold secret * (sub-dispatched: new, edit, rekey)
├── service.sh               nixhold service new
├── profile.sh               nixhold profile new
└── lint/
    ├── lint.sh              nixhold lint runner
    └── rules/
        └── *.sh             one file per lint rule; lint.sh runs them
```

`cli/nixhold.sh` is a thin `case "$1" in init) source cli/init.sh ;;
host) source cli/host-${2}.sh ;; ...` dispatcher. Subcommand
files are sourced (not exec'd) so they share helper lib state and
the operator's TTY without re-parsing.

`runtimeInputs` for the single `writeShellApplication` is the
union of what any subcommand uses: `nix`, `jq`, `gum`, `age`,
`ssh`, `openssh`, `agenix`, `nixos-rebuild`, `nixos-anywhere`,
`coreutils`. Closure cost is acceptable; alternative ("one
writeShellApplication per subcommand") fragments the install
surface and gains nothing now that everything is one CLI.

**Packaging.** Two access paths to the same script:

- **System module** — `programs.nixhold.enable = true` (default for
  every host) adds the `nixhold` binary to
  `environment.systemPackages`. Daily-use lands in `$PATH`. The
  option is `programs.nixhold.enable`, not `nixhold.cli.enable` —
  matches `programs.git`, `programs.vim`, etc.; the `nixhold.*`
  namespace is for framework concerns, not "is nixhold installed."
- **One flake app: `apps.<system>.nixhold`.** `nix run .#nixhold --
  <verb> <args>` works from a fresh clone with no module activated.
  This is the entry path before the first install
  (`nix run .#nixhold -- init`,
  `nix run .#nixhold -- host add laptop`). After the first install,
  bare `nixhold <verb>` is the daily path.

Per-subcommand flake apps (`apps.<system>.nixhold-<sub>`) are
**not** shipped — they'd duplicate the access surface, and
`nix run .#nixhold -- <verb>` already handles the pre-install case.

**Subcommand dispatch.** Dispatcher reads `$1` (the verb) and
`$2` (sub-verb for `host`/`secret`), sources the matching script,
shifts argv, runs. Help text per subcommand
(`nixhold <sub> --help`) is a literal heredoc in each script —
readable, no `argparse`-equivalent needed.

**How subcommands read `config.nixhold.*`.** `nix eval --json
.#nixosConfigurations.<host>.config.nixhold.<path>` (or
`.#darwinConfigurations.<host>...`), piped through `jq`. A shared
helper `nix_eval_host <host> <path>` lives in `cli/lib/run.sh`.
Structured data is shaped in Nix (where typed options live) and
the CLI just renders the JSON. The CLI never re-derives data that
Nix already computed.

**Error model.** `set -euo pipefail` + a single `trap` for diag
context in every subcommand. Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | User error (bad args, missing host, declined confirm) |
| 2 | Framework error (`nix eval` failed, fork-root not detected) |
| 3 | Lint-rule violation (`nixhold lint` only) |

Matches `gh` / `git` conventions. Per-subcommand `die "<msg>"` and
`info "<msg>"` helpers in `cli/lib/run.sh` write to stderr with
consistent formatting.

**Output.** Plain text by default — greppable, pipeable. Every
command that returns structured data accepts `--json` and writes
the underlying `nix eval` output (or a shaped subset) to stdout
unchanged. `gum style` is used sparingly for headers / boxed
sections in `nixhold status`; the data rows are always plain text.

**TTY handling.** `gum`'s interactive primitives require a TTY;
CI / piped invocations either avoid them (lint, `--json` modes)
or pass `--header` only when stdin is a TTY (`[ -t 0 ]`). The
dispatcher does not check; each subcommand handles its own.

**Lint engine.** `nixhold-lint.sh` discovers rule scripts under
`cli/lint/rules/*.sh` (a `for f in cli/lint/rules/*.sh; do ...`
loop — this is allowed pattern discovery because it's the lint
engine reading its own rule directory, not the framework reading
forker content; principle 14 governs the framework eval, not the
CLI toolchain). Each rule is a shell function (or standalone script)
that prints `OK` or `VIOLATION: <message>` and exits 0/3. The
runner aggregates, prints the report, and exits with the worst
code. Forkers add a rule by dropping a file in
`cli/lint/rules/`; no registration needed (this is the same
seam-collapse as `modules/<kind>/default.nix` for *content*, but
here the "registry" *is* the directory because lint rules don't
participate in eval).

### `nixhold status` — bounded output

`nixhold status` is host-scoped by default. The output shows enabled
services, their `expose` endpoints, and secret status — nothing
else. Resists the "nixhold status shows everything" creep.

```
nixhold status                # current host (read from $HOSTNAME)
nixhold status --host <name>  # another host's view
nixhold status --fleet        # one-line-per-host summary only
```

Per-host output:

```
HOST: myvps  (x86_64-linux, public IP 203.0.113.42)
  networks: tailnet, public
  services (3 enabled):
    vaultwarden    expose: vault.<tail>  vault-admin.<tail>
    caddy          (infra)
    tailscale      (infra)
  secrets:       4 declared, 3 encrypted, 1 missing *
    cloudflare-api-token  [missing] *  required for ACME
```

`--fleet` output:

```
HOST       SERVICES  EXPOSE  SECRETS         DRIFT
mac        12        0       all encrypted   clean
desktop    8         0       all encrypted   clean
homelab    9         11      all encrypted   clean
myvps      3         2       1 missing *     clean
```

Anything richer per-host requires `--host <name>` or going to
`nix eval` / `nixos-option` directly.

### `nixhold deploy --dry-run` — framework-aware delta

`nixhold deploy --dry-run <host>` runs `nixos-rebuild dry-build`
with a structured prelude. The prelude is fast (eval-only, no
build) and shows the framework-level changes before the raw
rebuild output:

```
nixhold.services changes (myvps):
  + vaultwarden
  ~ caddy             (config drift)
  - old-blog

expose changes:
  + vault.tail6ac451.ts.net
  + vault-admin.tail6ac451.ts.net
  - blog.example.com

secrets changes:
  + vaultwarden-env (required)

--- nixos-rebuild dry-build ---
[stock output here]
```

Useful for sanity-checking a rebuild before pulling the trigger.
Without the prelude, the operator reads a wall of derivation
hashes; with it, the intent is visible at a glance.

### `nixhold deploy` — daily activation flow

`nixhold deploy <name>` is the daily verb. Thin wrapper over
`nixos-rebuild switch` / `darwin-rebuild switch` that
auto-detects local vs remote, picks the target's address via
`nixhold.fleet.derived.address.<name>.<deployNetwork>` (the
operator's flake configures which network is used for deploys via
a top-level `nixhold.deploy.network` option, default `"tailnet"`),
and runs the build **on the target itself** for remote NixOS
hosts.

```
$ nixhold deploy myvps
─ deploy myvps ──────────────────────
host:    myvps
arch:    x86_64-linux
mode:    switch
target:  100.64.1.4 (tailnet)
builds:  on target (myvps)

uploading flake to target... done [2s]
building on target... done [54s]
activating... done [3s]

✓ deployed at generation 42
```

**Dispatch table.** Three cases, no flag needed:

| Invocation context | Target arch | Result |
|---|---|---|
| Local host, name = `$HOSTNAME` | any | local rebuild (`darwin-rebuild switch` for darwin, `nixos-rebuild switch` for nixos), no `--target-host` |
| Operator → remote NixOS | linux | `nixos-rebuild switch --flake .#<name> --target-host root@<addr> --build-host root@<addr>` — target builds + activates |
| Operator → remote Darwin | darwin | unsupported in v1; refuses with "Darwin hosts are deployed locally only" |

**Each machine builds its own config.** The `--target-host` and
`--build-host` flags both point at the target, so the target
evaluates the flake source (rsync'd by `nixos-rebuild`), builds
the closure, and activates it. The operator's machine only
orchestrates — no local building, no cross-arch concerns, no
linux-builder VM on the Mac. Mac and desktop both deploy to a
remote VPS via the identical flow. Symmetric.

Tradeoffs accepted in this default:
- A 1 GB-RAM VPS *could* OOM on a heavy build. In practice
  `cache.nixos.org` covers >95% of derivations (only local config
  eval + small derivations actually compile), incremental rebuilds
  are tiny, and an operator who picked a 1 GB VPS picked it
  knowing the constraints.
- First deploy to a fresh host downloads its full closure — true
  of any nix-on-target strategy.
- Targets need internet access to substituters — always true for
  NixOS hosts.

**Override path: operator-managed remote builder.** The
operator who wants the desktop to build for the VPS does it
directly with raw `nixos-rebuild`:

```bash
nixos-rebuild switch --flake .#myvps \
  --target-host root@myvps --build-host root@desktop
```

`nixhold deploy` deliberately does **not** expose `--build-host` — the
moment that flag exists, "where should I build" becomes a
recurring decision. The framework picks one answer (target builds
itself); power users escape to raw `nixos-rebuild`. Foundation
namespace `nixhold.fleet.builders.<system>` is reserved for a future
iteration that wants framework-managed remote builders — not
declared in v1 (principle 5).

**Routing.** Target address resolved via
`nixhold.fleet.derived.addressOf.<name>` — picks the first network
shared between the operator's host and the target. Preference is
implicit from declared network ordering in `<name>.networks`
(operators put `tailscale` first if they want it preferred).
`--target <addr>` overrides (useful when the tailnet is down and
the host has a public IP, or for the post-install moment before
tailscale has joined). SSH user defaults to `root` (matches host
SSH key bootstrap).

**Local detection.** `nixhold deploy <name>` is local mode iff
`hostname` (system call) matches `<name>`. No `--local` flag —
auto-detection is reliable because the framework already controls
host naming (`fleet.hosts.<name>` ↔ `networking.hostName = name`).
The check happens pre-flake-eval so it works even if eval would
fail.

**Mode.** Default `switch` (activate now + boot config). `--mode
boot` (activate on next boot only) and `--mode test` (activate
now, don't update boot config) are exposed for the rare cases.
`dry-build` is **not** a mode — that's `fc diff <name>` (already
designed; runs as eval + dry-build prelude). Activation
failures leave NixOS's automatic rollback intact.

**Confirmation.** Shows the summary block above + `gum confirm`
prompt before proceeding. `--yes` skips. CI / scripted invocations
pass `--yes`; interactive operators see the prompt.

**Output.** Plain text passes `nixos-rebuild`'s output through
verbatim. Timing visible per phase (upload / build / activate)
because aggregate wall-clock is less useful than knowing which
phase took the time. No spinners during build — nix's own output
is the signal.

**`nixhold host install` follows the same rule.** Passes
`--build-on-remote` to `nixos-anywhere` so the installer
environment builds the target's closure rather than building on
the operator's machine. Removes "operator must be able to build
the target's arch" as a precondition for install too.

**No mass deploy in v1.** `nixhold deploy --fleet` or
`nixhold deploy <pattern>` deferred — destructive ops target one named
host. Adding a mass mode later is purely additive.

### Secret bootstrap workflow

The `nixhold secret *` commands are the design centerpiece of the
operator CLI. They consume `config.nixhold.secrets.declared` — the
framework-wide manifest populated by every `mkAgeSecret` call —
and turn it into an introspectable, automatable workflow.

The manifest entry shape, repeated from the Secrets section:

```nix
nixhold.secrets.cloudflare-api-token = {
  owner       = "caddy";
  mode        = "0400";
  description = "Cloudflare API token for ACME DNS-01 (Zone:DNS:Edit)";
  template    = ''CLOUDFLARE_DNS_API_TOKEN=<paste-token-here>'';
  generator   = null;        # interactive secret; no auto-generation
  required    = true;
};

nixhold.secrets.vaultwarden-env = {
  owner       = "vaultwarden";
  mode        = "0400";
  description = "Vaultwarden ADMIN_TOKEN";
  template    = ''ADMIN_TOKEN=<argon2id-hash>'';
  generator   = "vaultwarden hash --pre-auth | sed 's/^/ADMIN_TOKEN=/'";
  required    = true;
};
```

`nixhold secret bootstrap <host>` walks the manifest and for each
declared secret:

1. Check whether `secrets/hosts/<host>/<name>.age` exists.
   - **Exists**: skip (already provisioned).
   - **Missing**, `generator` set: run the shell command, capture
     stdout, encrypt the result to `<name>.age`. Non-interactive.
   - **Missing**, `template` set, no `generator`: write the
     template into a tempfile, open `$EDITOR`, encrypt what's
     saved. Interactive.
   - **Missing**, neither set: open `$EDITOR` with an empty
     buffer. Interactive.
2. After all secrets are processed, list what was added and prompt
   to `git add` + commit.
3. Suggest the next command (`sudo nixos-rebuild switch ...` or
   `nix run .#bootstrap-remote -- <host> <ip>` depending on
   whether the host is local or remote).

The workflow is idempotent — re-running on a host with some
secrets already provisioned skips them and prompts only for the
new ones. `nixhold host add` calls `nixhold secret bootstrap <host>` as its
final scaffolding step, so the fresh-VPS flow is two commands:

```
nixhold host add myvps                                    # interactive scaffold + secret bootstrap
nixhold host install myvps --remote root@203.0.113.42     # detect hardware, install, commit disko+facter
```

`nixhold secret bootstrap <host>` remains a standalone command for the
common case of "I just declared a new secret on an existing host"
— edit host file, run `nixhold secret bootstrap <host>`, rebuild.

`nixhold secret check <host>` is the lint-level sibling: errors on
`required = true` secrets that have no `.age` file. Runs in CI
and pre-deploy.

`nixhold secret list <host>` shows the manifest with current state:

```
HOST: myvps  (4 secrets declared, 3 encrypted, 1 missing)
  vaultwarden-env       [encrypted]   Vaultwarden ADMIN_TOKEN
  cloudflare-api-token  [missing]  *  Cloudflare API token for ACME DNS-01
  rclone-conf           [encrypted]   O365 rclone config
  ssh-personal          [encrypted]   Operator SSH key

  * required
```

The `[missing] *` row is what `nixhold secret check` errors on.

This workflow is what makes the "one operator CLI" principle
load-bearing — without it, secrets are a manual `agenix -e` ritual
that doesn't know what the framework declared. With it, the
framework's secret manifest *is* the bootstrap plan.

### `nixhold lint` — convention enforcement

The framework only stays clean if drift is caught early. Lint
rules (v1, expandable):

- Every service module exposed under `nixhold.modules.services.*`
  declares options under `nixhold.services.<name>`. Enforced by
  reading the framework's own flake outputs; no filesystem walk.
- Every `nixhold.fleet.hosts.<name>.profile` resolves to a value
  (caught at eval time by attribute access; lint surfaces it
  before `nixos-rebuild`).
- For every NixOS host in the fleet, `hosts.<name>.modules`
  contains a disko module import and a setting of
  `hardware.facter.reportPath`. Two modes: `nixhold lint` warns
  ("run `nixhold host install <name>` to generate");
  `nixhold lint --strict` errors. Strict is the CI gate on
  `main`.
- Every `nixhold.secrets.<name>` declaration has `owner`, `mode`,
  and routes through the manifest module (no manual
  `age.secrets.<x>` wiring).
- Every `expose.<name>.backend` references a port that exists in
  the same service's `network.ports`.
- Every `expose.<name>.network` is either `localhost` or a
  network declared in `mkFleet`'s `networks`, AND is included
  in the host's `hosts.<host>.networks` list.
- Every NixOS host's pubkey (under `nixhold.layout.keysDir`) is a
  recipient of every secret that host needs to decrypt.
- No orphan `.age` files: every file under
  `nixhold.layout.secrets/<host>/` has a matching
  `nixhold.secrets.<name>` declaration on that host.
- No undeclared secrets (something reads `age.secrets.<x>` but
  no `nixhold.secrets.<x>` declared it).
- Every `required = true` secret has a corresponding `.age` file
  on the using host. Replaces the dropped `secret check` verb.
- `homePath` is only set on `nixhold.secrets.<name>` entries with
  `owner = "user"` (no meaning for service-owned secrets).
- Naming conventions: `kebab-case` service names, `ssh-<name>.age`
  for SSH key secrets.
- **`derived.publicHosts` length ≤ 1.** v1 single-gateway
  assumption; future multi-gateway designs relax this without
  renaming.
- **Tailscale network declared without `magicDnsSuffix`.** Warn
  (dev) only — not strict-error, since some forkers may
  legitimately declare a tailscale network for membership
  tracking without ever using cross-host addressing via
  MagicDNS. Downstream consumers that read
  `derived.address.<host>.<this-net>` and find `null` are
  responsible for their own assertions.
- **No `expose.<x>.network = "<public-typed-net>"` on hosts not
  in `publicHosts`.** Enforces the v1 single-gateway invariant
  at the service level — keeps the door open for future
  cross-host routing relaxation without v1 footguns.
- **`nixhold.layout` is fully set.** All required paths
  (`secrets`, `hostsFile`, `modulesDir`, `profilesDir`,
  `keysDir`, `ageRecipient`, `ageIdentityWrapped`) point at
  paths that exist in-tree.

Exits non-zero on failure → CI gate.

Not lint-checkable: "service binds a port not declared in
`network.ports`." NixOS has no uniform "what ports does this
service bind" property; detecting this would require service-
specific heuristics. We trust the operator on the binding side
and lint the declarative side.

### Logging and monitoring posture

The framework leans on **NixOS defaults**. No log aggregation, no
shipped observability stack, no framework-managed alerting.
Personal infra at fc's target scale (1–10 hosts, one operator)
doesn't get observability value worth the operational tax of
Loki + Prometheus + Grafana + Alertmanager. SSH + journalctl +
`systemctl status` is what the operator actually does, and it
works.

| Concern | v1 answer |
| --- | --- |
| Service logs | `nixhold logs <host> <service>` (thin wrapper around `journalctl -u <unit>` over SSH); or raw `ssh <host> journalctl -u <unit>` |
| Service status (runtime) | `ssh <host> systemctl status <unit>` |
| Service config (declarative) | `nixhold status [--host <name>]` — enabled services, expose endpoints, secret status |
| Metrics | Not framework-managed. Forkers wire Prometheus + node-exporter + Grafana via standard NixOS modules in their own profile if they want them. |
| Alerting | Not framework-managed. Forkers wire Alertmanager / Healthchecks.io / ntfy / Discord webhooks themselves. |
| Log aggregation | Not framework-managed (no Loki, Vector, journald-remote). |
| Dashboards | Not framework-managed (no Grafana, no shipped dashboards). |

**`nixhold status` stays declaration-side.** It shows what's
*configured*, not what's *running*. Runtime state lives in
`systemctl status` and `nixhold logs`. This preserves the property
that `nixhold status` works without live SSH to every host — useful
when a host is down and the operator is debugging.

**`nixhold logs` is a thin wrapper.** ~30 lines of bash: look up the
systemd unit from `nixhold.services.<service>`, SSH to `<host>`, run
`journalctl -u <unit>` with sensible defaults. Same operator-
convenience tier as `nixhold deploy` is over raw `nixos-rebuild
--target-host`. Flags pass through to journalctl: `--lines N`,
`--since <when>`, `--follow`.

#### Foundation properties to maintain

Even punting on observability, four properties keep future
features cheap if/when they arrive:

- **`nixhold.services.<name>.expose` already declares listening
  ports.** A future metrics-scraper module reads this for
  Prometheus scrape-target discovery without new declarations.
- **`nixhold.services.<name>` namespace is open.** `metrics` and
  `logs` option types are non-breaking additions later (existing
  Out-of-scope already commits to designing them alongside their
  consumer module).
- **journald is uniform across NixOS.** Whatever log aggregator
  lands later (Loki, Vector, journald-remote) reads journald
  straight; no framework wrapping today, no framework re-design
  later.
- **No `nixhold.observability.*` namespace reservation.** Using a
  namespace before declaring it adds dead surface. The namespace
  is reserved when the first consumer module lands (same pattern
  as `nixhold.lib.utils.*`).

---

## Architectural gaps (active design)

The architecture above is a coherent slice but doesn't cover
everything a finished product needs. The following gaps were
identified during design; each has been **scoped against the
"foundations over features" lens** (principle 9): we design and
build foundation-level capabilities now, defer feature-level work
until there's evidence of need, and document the foundation
properties that keep deferred features cheap to add later. Each
gap below indicates its current status.

Gap statuses:
- **Resolved** — design complete, ready for implementation.
- **Re-scoped** — foundation work in scope; full feature deferred.
- **Deferred** — full work out of scope until specific evidence
  triggers a revisit; foundation properties maintained anyway.
- **Rejected** — out of scope by design; no foundation properties
  to maintain and no trigger to revisit.
- **Active** — design complete, no scope reduction needed.

### Gap 1: Network exposure model — resolved

Where does a service live? The `tls` facet from earlier drafts
implied "tailnet, TLS via tailscale cert" because that was the
only network the framework knew about. Public-facing services
and multi-network exposures had no design.

**Resolved.** See "Gap 1 deep dive" below for the full design:
typed networks in `mkFleet`'s `networks` arg (`tailscale` + `internet` in v1),
the `expose` option replacing `tls`. LAN-only networks, raw L4
services, and cross-host routing are deferred until consumers
surface (see Out of scope).

### Gap 2: Plugin architecture — deferred

A plugin model (third-party flakes contributing service modules,
infra modules, CLI subcommands) is desirable long-term but
**premature to design now**. The framework has no consumers;
designing a plugin contract for a hypothetical ecosystem risks
getting the API wrong, and the engineering cost (loader, schema,
version compatibility, conflict resolution, scaffold tooling,
plugin testing, plugin docs) is significant.

Revisit when there is **evidence of external interest**: forks,
issues asking "how do I add my own service," PR contributions from
non-maintainers, or in-repo sub-stacks that genuinely want to live
out-of-tree.

**Foundation properties to maintain anyway** — these cost
essentially nothing and keep the plugin door open:

- **Open `nixhold.services.*` namespace.** Anything declared
  under `nixhold.services.<name>` participates in introspection
  and infra consumption — including a module a plugin might
  contribute.
- **CLI as introspection harness.** Subcommands consume
  `config.nixhold.*`. Adding new commands later (in-tree or
  out-of-tree) follows the same pattern.
- **`nixhold.secrets.<name>` with metadata.** A plugin service
  would use the same secret declaration; the framework-wide
  manifest works without modification.
- **Modules and profiles exposed as flake outputs, not as
  filesystem indexes.** `nixhold.modules.<kind>.<name>` and
  `nixhold.profiles.<name>` are the Nix-value seam between
  framework content and contributed content. Plugins (when
  they land) extend the framework by exposing additional
  `modules.*` / `profiles.*` outputs — no parallel discovery
  path, no index file to edit.

**Explicitly not doing now**: plugin loading, version compatibility,
CLI command extension mechanism, plugin scaffold tooling, plugin
docs.

If plugins are added later, the work is ~6–8 weeks of focused
engineering — same cost whether done now or later, but later means
informed by real plugin developers' needs rather than guesses.

### Gap 3: Stability contracts and versioning — rejected

Stability handled via branches + versioning. No `unstable.*`
namespace prefix, no per-option stability tags, no
`lib.mkRenamedOptionModule` migration scaffolding, no
`requiresFcVersion` checks.

Mechanism: `main` is the stable surface; in-progress work lives
on feature branches. Forkers pin by SHA or by tag (`v0.x.0`)
and bump when ready. Breaking changes between tags are
documented in the tag release notes once tagging starts.

Cheap habits worth keeping regardless (Principle 4 +
hygiene — adopt from day one):

- `mkDefault` discipline so consumers absorb default changes
  without `mkForce`.
- Don't expose internals as options. Internal state lives under
  `nixhold._internal.*` (lint flags references from outside the
  framework).
- Naming hygiene: `nixhold.identity.username` is a stable name;
  a rename would be visible churn. Pick names that won't
  embarrass in a year.

Formal versioning machinery, CHANGELOG, and tiered stability
docs are off the table until they're actually load-bearing
(post-v1, after enough external use that breakage matters).
This is a deliberate choice — the framework is opinionated and
small enough that branches + git history are the contract.

### Gap 4: First-60-minutes experience — re-scoped to author productivity

The full "stranger clones the repo" experience (curated templates,
migration from other configs, interactive walkthroughs) is
**targeted at forkers who don't exist yet** — premature in the same
sense as Gap 2.

What's **not** premature: scaffolding tools that pay off for the
solo author too. Adding a new host, declaring a new service module,
previewing a change before applying it — these are productivity
wins regardless of forker count.

**Active scope (solo-author productivity):**

- **`nixhold init`** — provisions the operator age identity
  (passphrase-wrapped). One-time per fork. Refuses to overwrite on
  re-run; `--force` to override. Replaces the historical
  `init-fc-identity.sh`.
- **`nixhold host add <name> [--install <user>@<ip>]`** —
  interactive TUI (gum-driven): prompts arch, profile (picker
  from `nixhold.profiles.*`), network membership, optional
  `publicIp`/`publicFqdn`. Generates the host SSH+age keypair
  into the cache, commits the pubkey under
  `nixhold.layout.keysDir`, writes the host entry into
  `nixhold.layout.hostsFile`, walks secret bootstrap. With
  `--install`, chains through to `host install` automatically.
- **`nixhold host install <name> [--remote <user>@<ip>] [--disk <by-id>]
  [--disko-from <path>]`** — SSHes to target, detects hardware,
  prompts for disk choice (or accepts `--disk`), generates
  `disko.nix` + `facter.json` locally at the operator-declared
  location, prints the paste-line for `hosts.<n>.modules` if
  not already present, runs `nixos-anywhere
  --build-on-remote` (or `darwin-rebuild` for darwin arch),
  commits hardware files after success. Replaces the historical
  `new-host.sh` (SSH-key generation folded into `host add`) +
  `bootstrap-local.sh` + `bootstrap-remote.sh`.
- **`nixhold deploy <name> [--dry-run]`** — daily activation:
  `nixos-rebuild switch --target-host=<addr> --build-host=<addr>`
  (the target builds its own closure) for remote NixOS, local
  `nixos-rebuild` / `darwin-rebuild` when name matches
  `$HOSTNAME`. Auto-detected; one verb covers the daily push.
  Confirmation prompt by default; `--yes` to skip. `--dry-run`
  shows the framework delta (added/removed `expose` endpoints,
  added/removed secrets) and the `nixos-rebuild dry-build`
  output side-by-side — the former `nixhold diff` verb folded
  into this flag.
- **`nixhold service new <name>`** — scaffolds a service module
  at `<nixhold.layout.modulesDir>/services/<name>.nix` from a
  template with the standard option skeleton (`enable`,
  `network`, `expose`).
- **`nixhold profile new <name>`** — scaffolds a profile at
  `<nixhold.layout.profilesDir>/<name>.nix` from a template
  (imports a sensible baseline; ready for the operator to
  attach modules and defaults).
- **Forker README + template README structure** — section list,
  the 30-minute path's step sequence, audience gate, and the
  template-shipped scaffold files are all locked in v1; prose
  drafting and the `docs/` tree contents are written at
  implementation time. See "Gap 4 deep dive" below.

There are **no separate installer flake apps**. The pre-install
access path is `nix run .#nixhold -- <verb>` (a single
`apps.<system>.nixhold` flake app that resolves to the same
bash dispatcher); post-install is bare `nixhold <verb>`. The
historical `init-fc-identity` / `new-host` / `bootstrap-local`
/ `bootstrap-remote` scripts no longer exist as standalone
entry points.

**Deferred (until forkers exist):**

- **`nixhold init --template <name>`** — curated topology templates
  (`workstation-only`, `single-server`, `workstation-plus-server`,
  `laptop-plus-vps`).
- **`nixhold init --from <path>`** — migration from nix-darwin, plain
  home-manager configs, or other nix-fleets.
- **Interactive walkthroughs** for first-time users beyond the
  built-in gum prompts.

**Trigger to revisit**: someone asks "how do I start" in an issue;
or the framework crosses ~3 external forks.

### Gap 5: Testability as a framework primitive — re-scoped to lint

Testability matters; the full three-layer plan (lint + build +
VM integration tests) is **premature** until external contributions
or a real regression makes the investment pay off. The author
runs `nixos-rebuild build` manually when they care; CI is solo.

**Active (v1):**

- **Eval-level**: `nixhold lint` (defined in the spec section above).
  Fast (~seconds), runs on every commit, CI gate. This is the
  framework's confidence layer for now — convention violations,
  schema mismatches, orphan secrets, naming drift all caught at
  eval time.

**Deferred (until external PRs land or a regression bites):**

- **Build-level**: `fc check`. Parallelizable per-host
  `nixos-rebuild build` on PRs. Real value once others contribute
  changes; for solo dev, ad-hoc `nixos-rebuild build` is enough.
- **Integration-level**: `fc test`. Per-infra-module NixOS VM
  tests asserting wiring works. Real value but expensive to write
  and maintain. The test-helper API
  (`lib.test.mkFacetTest`-shaped) is itself speculative — write
  the first VM test by hand when one matters, see what shape the
  helper actually wants, then formalize.
- **Test fixtures library** (`lib.test.fixtures.*`). Emerges
  from the first written tests, not pre-designed.

**Trigger to revisit**: first external PR, first regression that
slipped through lint, or first claim by a forker that the
framework broke their setup.

### Smaller open architectural items

Same lens — foundation pieces worth defining now vs features
deferred until evidence of need.

**Foundation (worth defining early; cheap to do, expensive to
retrofit):**

- **Shared option types: `nixhold.types.*`.** `network` and `expose` —
  defined in `modules/types/*.nix`, imported by every service that
  wants the standard shape. Each is a `lib.types.submodule` with
  `mkOption`-declared fields and `description` text. Additional
  types (`data`, `health`, `metrics`, `logs`, etc.) land alongside
  their consumer infra modules.
- **Index-based module + profile discovery.**
  `modules/<kind>/default.nix` is an explicit `imports = [ ... ]`
  list; the shipped profiles are an explicit attrset in `flake.nix`
  (`nixhold.profiles.*`). Lint enforces filesystem ↔ index in both
  directions.
  Concrete deliverable for v1. (Per principle 14, the framework
  reads these indexes; it never walks the directory listing.)

**Features (defer until evidence of need):**

- **`data` / `health` / `metrics` / `logs` / `schedule` /
  `capabilities` option types.** Each is a wrap around something
  NixOS already does well (paths, healthchecks, Prometheus scrape
  configs, journald, `systemd.timers`, `systemd.serviceConfig`).
  Designing the option type without a consumer module risks
  getting the shape wrong; design alongside the consumer when one
  is built.
- **Backup as a framework concern.** Not in scope for the
  foreseeable future. When/if it lands, the `data` type is
  designed alongside the backup module.
- **State migration / data portability.** `nixhold service move <name>
  --from A --to B`. Real value but real complexity. Deferred.
- **Operator key recovery beyond what we have.** Today: passphrase
  is single recovery dependency. Shamir M-of-N or hardware-backed
  (yubikey) keys are real improvements but feature-level. Deferred.
- **Internal CA for LAN networks.** Tailscale + tailscale cert
  covers private TLS for the canonical topology. Internal CA is
  only needed for LAN-only devices that can't join tailnet;
  uncommon enough to defer.
- **Shared utility library `nixhold.lib.utils.*` as a designated
  namespace.** Shared utils will exist when needed; reserving the
  namespace doesn't prevent drift. Just write `nixhold.lib.utils.<x>`
  when the first util emerges.

---

## Gap 1 deep dive: Network exposure model

*(Following gaps will be added here as they are resolved.)*

### The gap

The current `tls` facet says "I want TLS at subdomain X" but doesn't
say *where* that subdomain lives or *who* can reach it. The
framework assumes one network reality (tailnet), and any deviation
is an escape hatch. The full problem space "exposure" could cover:

- A public-facing service (blog, OAuth callback, public API).
- A service exposed multiple ways (public read at `/`, tailnet-only
  admin at `/admin`).
- A LAN-only service (router admin, NAS panel, kids' Plex).
- A service reachable from a specific external host (CI runner
  pulling artifacts).
- A non-HTTP service (WireGuard endpoint, custom TCP, DNS server).

Without a model, every such case is bespoke. With a model, every
such case is `expose.<endpoint>.network = "<which>"` and the
framework wires it. **v1 ships the model and the first two cases**
(public + tailnet, HTTP-family, multi-network exposure); the rest
are deferred until a real consumer surfaces and are listed in
Out of scope. The model is designed to extend, not to be replaced.

### Decomposition: what "exposure" actually is

Eight concerns hide inside "expose a service":

1. **Reachability scope** — from where can a client reach this? (tailnet
   / public internet / specific LAN segment / localhost / specific
   peer hosts)
2. **Transport** — HTTPS / HTTP / GRPC / WebSocket / raw TCP / UDP.
3. **Naming** — what name resolves to this? (MagicDNS / public DNS
   record / mDNS / `/etc/hosts` / IP-only)
4. **TLS** — how are certificates issued? (Tailscale cert / ACME
   DNS-01 / ACME HTTP-01 / no TLS)
5. **Authentication** — who can reach it? (implicit-by-network /
   basic auth / per-service)
6. **Reverse proxy routing** — same backend, different paths, routed
   to different ports.
7. **Firewall** — which ports open on which interfaces.
8. **Cross-host routing** — service runs on host A, terminates on
   host B.

The current `tls` facet conflates 3, 4, 6, and partially 1. The
fixed design splits these cleanly.

### The fleet-side network definitions

`networks` (passed to `mkFleet`) declares the *networks* this
fleet knows about. Each network has a *type* the framework
recognizes, which determines defaults for naming, TLS, auth.

```nix
# In the operator's flake.nix mkFleet call
networks = {
  # Tailscale mesh — every host joins; no gateway concept.
  # Implicit authentication, MagicDNS, tailscale cert.
  tailnet = {
    type           = "tailscale";
    magicDnsSuffix = "tail6ac451.ts.net";
    # Framework infers: MagicDNS for naming, tailscale cert for TLS,
    # network-level auth (Tailscale ACL), private addressing.
  };

  # Public internet — DNS + ACME + external addressing.
  public = {
    type   = "internet";
    domain = "example.com";
    dns = {
      provider     = "cloudflare";
      tokenSecret  = "cloudflare-api-token";
      # Future: framework manages A/AAAA records for declared subdomains.
    };
    tls = {
      method = "acme-dns01";
      email  = "admin@example.com";
      # acme-dns01 (vs http01) is the framework default — works without
      # opening :80 publicly, supports wildcard.
    };
  };
};
```

Network types known to the framework:
- `tailscale` — implies MagicDNS naming, tailscale cert TLS,
  network-mediated auth.
- `internet` — public DNS provider, ACME TLS. The host with the
  public IP runs the proxy.

**The `localhost` network type is built-in**, not declared in
`networks`. Every host always has it; it represents endpoints
that bind 127.0.0.1 and are only reachable from the host itself.

Adding a new network type today means extending the framework
in-tree. When/if plugins land (Gap 2), they could contribute new
network types — but that's not on the foundation roadmap.

### The service-side `expose` option

A service declares **one or more named endpoints**. Each endpoint
picks a network, a transport, and the relevant routing.

```nix
nixhold.services.vaultwarden = {
  enable = true;

  network = {
    # Internal ports the service listens on (bind always 127.0.0.1
    # unless an endpoint references them):
    ports = {
      rocket    = 8222;
      websocket = 3012;
    };
  };

  expose = {
    web = {
      network   = "tailnet";       # which fleet network
      protocol  = "https";
      subdomain = "vault";         # full vhost: vault.<hostname>.<tailnet.domain>
      backend   = "rocket";        # named port from network.ports above
    };

    # A second endpoint for the admin interface, isolated subdomain:
    admin = {
      network   = "tailnet";
      protocol  = "https";
      subdomain = "vault-admin";
      backend   = "rocket";
    };

    # Backend websocket path needs its own endpoint declaration —
    # one endpoint maps to exactly one backend port.
    notifications = {
      network   = "tailnet";
      protocol  = "wss";
      subdomain = "vault";         # same vhost as `web`, different path
      backend   = "websocket";
      pathPrefix = "/notifications/hub";
    };
  };
};
```

Schema for each endpoint:

| Field | Type | Required | Default | Notes |
|---|---|---|---|---|
| `network` | enum (fleet networks + `localhost`) | yes | — | Must exist in `mkFleet`'s `networks`, except `localhost` (built-in). |
| `protocol` | enum | no | `"https"` | `https`, `http`, `ws`, `wss`. |
| `subdomain` | str or null | conditional | — | Used on `internet` networks (`<subdomain>.<domain>`). **Ignored on `tailscale` networks** — those route by `pathPrefix` under the node FQDN (see "Tailnet TLS provisioning"). Forbidden for `localhost`. |
| `backend` | str | yes | — | References `network.ports.<name>`. |
| `pathPrefix` | str or null | no | `null` | If set, this endpoint claims only `<subdomain>.<…>/<prefix>`. Multiple endpoints can share a subdomain by carving different prefixes — caddy generates a single vhost with location blocks. |
| `description` | str | no | — | Free text for `nixhold status`. Recommended for `localhost` endpoints. |
| `extraConfig` | lines | no | `""` | Raw Caddyfile directives injected inside this endpoint's handle block, before the default `reverse_proxy`. Escape hatch for `encode`, websocket splits, header tweaks — the data-driven model still owns the vhost/FQDN/TLS. |

`expose.<x>.routes` (per-path backend overrides on a single
endpoint) was dropped from v1 — no consumer needed it and the
declaration shape ("one endpoint = one (subdomain, backend) pair")
is cleaner. Multi-path services declare multiple endpoints with
the same subdomain and different `pathPrefix` values.

**Every port a service binds must be declared.** A service that
binds port X but has no `expose.*` entry referencing X is a lint
failure. There is no "implicit binding" — if it's bound, it's
declared, even if only as `localhost`. This is the total
declarability principle in action.

### How infrastructure modules consume `expose`

**Caddy** (`modules/infra/caddy.nix`):

```nix
{ config, lib, ... }:
let
  services   = lib.attrValues config.nixhold.services;
  endpoints  = lib.concatMap (s: lib.attrValues (s.expose or {})) services;
  httpEndpoints = lib.filter
    (e: e.protocol == "https" || e.protocol == "http")
    endpoints;
in {
  services.caddy.virtualHosts = lib.listToAttrs (map (e: {
    name  = lib.mkVhostFqdn e config.nixhold.fleet;
    value = lib.mkCaddyVhost e config.nixhold.fleet;
    # Picks TLS strategy from network type: tailscale → `tls ${tailscale-cert}`,
    # public → `tls { dns cloudflare ... }`.
  }) httpEndpoints);
}
```

**Firewall** (`modules/infra/firewall.nix`):

```nix
let
  publicPorts = lib.unique (lib.concatMap (e:
    if (config.nixhold.fleet.network.${e.network}.type or "") == "internet"
    then [ (config.nixhold.fleet.network.${e.network}.publicPort or 443) ]
    else []
  ) endpoints);
in {
  networking.firewall.allowedTCPPorts = publicPorts;
  # Tailnet ports do not need opening (Tailscale handles encapsulation).
}
```

**Certificates** (`modules/infra/certs.nix`):

The framework provides per-network-type cert acquisition:
- `tailscale` → `tailscale cert` invoked by systemd timer.
- `internet` (acme-dns01) → `security.acme` configured with the
  network's DNS provider tokens, using a wildcard cert when
  possible.
- `internet` (acme-http01) → opens :80, uses HTTP-01.

### Tailnet TLS provisioning — per-node FQDN + path routing

`tailscale cert` issues a certificate **only** for a node's own
MagicDNS name (`<host>.<magicDnsSuffix>`). It does not issue certs
for arbitrary subdomains of a node, and MagicDNS does not resolve
them. So the subdomain-per-service shape shown in the examples above
(`vault.<host>.<suffix>`) **does not work on `tailscale` networks** —
it would neither resolve nor get a valid cert.

**Resolved (locked).** On `tailscale` networks the vhost FQDN is the
node's own name — `<host>.<magicDnsSuffix>` — and every tailnet
service on a host collapses into that single vhost, differentiated by
`pathPrefix`. `subdomain` is ignored for tailscale endpoints
(`internet` endpoints still use it: `<subdomain>.<domain>`). One
`tailscale cert` per host covers all of its tailnet services. Apps
that can't live under a subpath set their own base-path/DOMAIN option
or expose on an `internet` network instead. `mkVhostFqdn` therefore
branches on network type:

- `tailscale` → `"${host}.${net.magicDnsSuffix}"` (subdomain dropped)
- `internet`  → `"${subdomain}.${net.domain}"`

**Cert mechanism (locked).** Provisioning lives in
`modules/infra/caddy.nix` (no separate `certs.nix` in v1) and uses the
proven systemd pattern, emitted only when the host has at least one
tailscale-typed HTTP endpoint:

1. a `tailscale-caddy-cert` oneshot that waits for `tailscaled`, then
   runs `tailscale cert --cert-file --key-file <host>.<suffix>` into
   `/var/lib/caddy/tls`, owned by `caddy`;
2. a weekly renewal timer (`OnBootSec=2min`, `OnCalendar=weekly`,
   `Persistent`) — Tailscale issues 90-day certs;
3. a path unit watching the cert file that reloads caddy on change.

Tailnet vhosts get `tls <cert> <key>`; the host sets
`auto_https disable_redirects` (no `:80` listener on the tailnet).
`internet` vhosts keep caddy's ACME per the network's `tls.method`.
v1 assumes a single tailscale network (one node cert per host); a
second tailnet would need per-network cert files.

### Composability: same service, multiple networks

A service can expose endpoints on multiple networks. Example: a
self-hosted blog with admin restricted to tailnet:

```nix
expose = {
  public = {
    network   = "public";
    protocol  = "https";
    subdomain = "blog";          # blog.example.com
    backend   = "web";
  };
  admin = {
    network   = "tailnet";
    protocol  = "https";
    subdomain = "blog-admin";    # blog-admin.<host>.tail*.ts.net
    backend   = "web";
  };
};
```

Caddy generates two vhosts; firewall opens :443 publicly; DNS
manages `blog.example.com`; Tailscale ACL allows tailnet access to
`blog-admin`. **The service module wrote a small option block.**
Every infra module did its part.

### Single-host assumption for public services

The canonical personal-infra topology has one host with the public
IP (homelab / VPS) and the rest behind it. **The framework's v1
assumption: public services run on the gateway.** Same host, same
eval, no cross-host wiring needed.

A service that declares `expose.<x>.network = "public"` must live
on a host whose `fleet.hosts.<host>.networks` includes `"public"`
— enforced by lint. There is no v1 syntax for "service on host A,
proxied through gateway B"; that case is deferred until a real
consumer surfaces, at which point the cross-host routing shape
gets designed informed by the consumer's needs.

### Edge cases

**Services with no network presence** (e.g. a pure background
worker that only writes to disk):

```nix
expose = {};   # empty — no endpoints, no bound ports
```

The service's `network.ports` is also empty. Lint passes (no orphan
ports, no orphan declarations).

**Services with localhost-only endpoints** (e.g. /metrics for local
Prometheus exporter, or an admin endpoint for debugging):

```nix
network.ports = { metrics = 9090; };
expose.metrics = {
  network     = "localhost";
  protocol    = "http";
  backend     = "metrics";
  description = "Prometheus scrape endpoint";
};
```

Localhost endpoints are always explicit — there is no implicit
"binds 127.0.0.1 without declaring." Caddy infra skips them
(localhost has no outside-the-host name). Firewall infra skips them
(no remote interface involved). `nixhold lint` verifies the bind address
is actually 127.0.0.1 — catching the "I forgot to restrict the
bind" leak.

**Same subdomain across networks** (allowed):

Two endpoints with `subdomain = "vault"` on different networks
collapse into one FQDN per network — no conflict. Same subdomain on
the same network is a lint failure.

### Open questions specific to Gap 1

1. **Does the framework prescribe Caddy?** Per Principle 7
   (unified framework), yes — prescribe Caddy. Forkers who need
   nginx/traefik write their own consumer of
   `nixhold.services.*.expose`.

2. **DNS provider.** Cloudflare today. **No abstraction layer.**
   `dns = { type = "cloudflare"; tokenSecret = "..."; }` is the
   shape; the DNS infra module pattern-matches on `type`. When a
   second provider lands, add a case branch — same pattern as
   `network.type` (`tailscale` / `internet`). Pre-designing a
   provider abstraction means anticipating what Route53 /
   DigitalOcean / deSEC will need, which we don't know.

3. **Default protocol when omitted.** **Default to `https`** —
   it's the >95% case; non-HTTP is intentional.

4. **Per-host vs auto-enabled infrastructure modules.** Should
   infra modules be opt-in per host (`nixhold.infra.caddy.enable = true`)
   or auto-enable when relevant options are present on that host?
   **Lean toward auto-enable** — matches the "convention over
   configuration" principle; lint flags hosts that have endpoints
   but lack the infra to serve them (probably wrong fleet
   declaration).

### Resolved decisions specific to Gap 1

Decisions made during design that don't need to be revisited:

- **Localhost is explicit, not implicit.** Every endpoint a service
  binds is declared in `expose`. No port is bound without a
  declaration. Per principle 12 (total declarability).
- **One-pass eval is a framework property** (principle 13). Each
  host evaluates independently against its own services plus
  `config.nixhold.fleet`.
- **Public services live on the public host.** Cross-host routing
  (service on A, terminated on B) is out of v1 scope; the lint rule
  forbidding `expose.<x>.network = "public"` on a non-`public` host
  is the foundation that holds the door open for a future relaxation
  when a real consumer surfaces.

### What Gap 1 commits us to

Adopting this design means:

- **Networks are typed fleet-level concerns**, declared once in the
  `mkFleet` `networks` argument. Hosts inherit; services reference
  network names.
- **Caddy is the framework's reverse proxy for HTTP-family
  protocols.** Replaceable only by writing a parallel infra module
  consuming `nixhold.services.*.expose`.
- **DNS is a framework concern** for public exposures. v1 locks a
  declaration contract — every record the fleet expects to exist is
  exposed via `nixhold.fleet.derived.records`. Per-provider modules that
  push records are deferred until a real consumer surfaces. See
  "Gap 1 extension: DNS declaration contract" below.
- **Per-network TLS strategy is declared, not per-service.**
  Services don't choose how their cert is issued; the network
  declares the strategy, every service on that network uses it.
- **`expose` replaces `tls`/`vhost` as the network option.**
- **Every bound port is declared.** Services with `network.ports`
  must have corresponding `expose.*` entries; orphan ports (bound
  but undeclared) fail lint. Localhost endpoints are valid; missing
  declarations are not.
- **v1 scope is HTTP-family on tailnet + public.** Raw L4 (UDP/TCP),
  LAN-only networks, cross-host routing, and caddy-mediated auth
  (`basic`/forward-auth) are deferred until a real consumer
  surfaces; the lint surface keeps the foundation honest in the
  meantime.

This is the largest single architectural surface in the framework.
Gets us multi-network, public-and-private services, and a coherent
network model across the fleet — with one-pass eval throughout and
explicit cross-host declarations where they're rare.

---

## Gap 4 deep dive: Forker README + template structure

### The gap

Gap 4's active scope locks the productivity verbs. What it didn't
specify: the first markdown surface a forker sees. The framework
README, the template README, the audience gate, the 30-minute
path — these are static documentation, but their *structure* is
product-design work that needs the same care as the verbs.

The principle pull: plan for the bigger vision, not effort
minimization. Designing the README structure now — even though
forkers don't exist yet — is in scope. Drafting prose can wait;
deciding *what the README says, in what order, with what
contract* cannot. Get the shape wrong and the framework feels
different even when the code is identical.

### Three README surfaces, two designed artifacts

`README.md` shows up in three places in the framework world;
they collapse to two designed artifacts.

| Surface | Job | Audience |
| --- | --- | --- |
| Framework repo (`github:fcalell/nixhold/README.md`) | "Is this for me?" + send to template | Stranger evaluating fc |
| Template (`templates/default/README.md`) | First-`nixhold deploy` walkthrough | Fresh forker post-`flake init` |
| Forker's repo post-fork (`<forker>/README.md`) | Fleet-level README (host list, ops notes) | Forker after they've forked |

The third is the second's afterlife — `nix flake init -t` copies
the template's `README.md` into the forker's repo verbatim, and
the forker rewrites it as they grow. One file, two stages, no
separate design.

### Audience gate

The non-audience callout names **module library authors**
specifically. Forkers building their own à-la-carte module
collection (snowfall-style, or directly extending nixpkgs) are
the most common confused audience — they want building blocks,
fc ships opinions.

Single-laptop seekers are *not* called out as non-audience: fc
works for one host. A fleet of one is a valid shape and a
reasonable on-ramp to a fleet of many.

### Framework repo README structure

Job: stranger → "is this for me?" → template, in under 60
seconds. Lean. No tutorial; only enough to decide-then-jump.

Sections (locked order):

1. Title + one-line value prop
2. **Is this for you?** — bullet list (audience + the
   module-library-author non-audience callout)
3. **What you get** — layers (modules → profiles → hosts), verbs
   (`deploy`, `host install`, `secret`), one batteries-included
   claim
4. **Start here** — single `nix flake init -t github:fcalell/nixhold`
   line + link to template walkthrough
5. **Status** — pre-1.0, SHA-pinned, what changes when
6. **Concepts** — one paragraph each, linking to `docs/`: layers,
   fleet schema, verbs, cross-host addressing
7. **Compared to** — short table (bare NixOS modules,
   nixos-anywhere, deploy-rs, colmena, snowfall); one sentence
   per row
8. **Repo layout (framework side)** — short tree
9. **Contributing / license**

### Template README structure

Job: fresh forker → first `nixhold deploy` succeeds in 30 minutes.
The same file becomes the forker's fleet-level README post-fork.

Sections (locked order):

1. Title — `# Your fleet` placeholder + one-line value prop
2. **What you're getting** — 3 bullets max + link to fc README
3. **Prerequisites** — explicit list: Nix installed, an SSH
   keypair, one target (NixOS installer USB *or* VPS rescue),
   ~30 minutes
4. **The 30-minute path** — numbered, copy-pasteable (step
   sequence below)
5. **What just happened** — one short paragraph naming the
   moving pieces (verbs ran, secrets decrypted, host addresses
   resolved via `derived.address.<host>.<network>`)
6. **Add a second host** — post-30-min section; demonstrates
   cross-host wiring via `derived.address.<host>.<network>`
7. **Your repo layout** — the tree the forker has after step 5
8. **Next steps** — bullets linking to deeper docs (add a
   profile, declare a service, add a network, install the
   `nixhold` CLI on PATH)
9. **Updating nixhold** — one line: bump `inputs.nixhold.url`'s rev

### The 30-minute path — locked contract and step sequence

The contract: **30 minutes ends at "one host deployed,
`nixhold deploy` works"**. Cross-host wiring is a post-30-min
section, not inside the path. Breaking the time promise to demo
more would undersell the time-to-value claim; the second-host
section captures the framework's real value separately, without
violating the contract.

Step-by-step (copy-pasteable in the README):

1. **Clone** (0:00) —
   `nix flake init -t github:fcalell/nixhold`
   (already done if reading this file)
2. **Identity + layout** (0:02) — open `flake.nix`, fill in
   `identity` (username, fullName, email) and `layout` (paths
   for `secrets`, `hostsFile`, `keysDir`, etc.)
3. **First host** (0:05) —
   `nix run .#nixhold -- host add <name> --install <user>@<addr>`.
   The TUI prompts arch, profile, networks; generates SSH+age
   keys; writes the host entry to `nixhold.layout.hostsFile`;
   walks secret bootstrap; runs the install (nixos-anywhere or
   darwin-rebuild)
4. **Deploy** (0:20) — change something,
   `nix run .#nixhold -- deploy <name>`

### Template-shipped files

The template ships **scaffolds with commented examples**, not
empty files. Examples-in-comments cut friction; deletion is
cheaper than authoring.

| File | State |
| --- | --- |
| `flake.nix` | `inputs.nixhold.url` + `nixhold.lib.mkFleet` call with placeholder identity/layout/networks/hosts |
| `hosts.nix` | Empty attrset (CLI-managed; populated by `nixhold host add`) |
| `README.md` | The template README from this section |
| `.gitignore` | Standard Nix + age cache + facter cache excludes |

No `disko.nix` ships — that's install-time, generated by
`nixhold host install` and added to the operator's
`hosts.<n>.modules` list. No `identity.nix` or `fleet.nix`
ships either — those are passed as Nix values directly to
`mkFleet` from `flake.nix`.

### CLI invocation form in walkthrough

Canonical: `nix run .#nixhold -- <subcmd>`. Always works, zero
PATH setup, works pre-install. The PATH option
(`programs.nixhold.enable = true` in the host config) is
mentioned in **Next steps** as a convenience — never in the
30-minute path itself. The path stays minimum-friction.

### `docs/` tree — filenames locked, prose deferred

The framework README links to deeper docs. Filenames are locked
now so README links are confident; prose drafting is
implementation work.

| File | Scope |
| --- | --- |
| `docs/concepts.md` | The three layers, fleet schema, derived surfaces |
| `docs/profiles.md` | Profile catalog + authoring guide |
| `docs/modules.md` | Foundation namespace + module authoring |
| `docs/verbs.md` | `nixhold deploy`, `nixhold host install`, `nixhold secret`, others |
| `docs/discovery.md` | Cross-host addressing deep-dive (Item C in prose) |

Adding a sixth file (e.g. `docs/secrets.md`) is non-breaking;
renaming any of the locked five is breaking — the framework
README's Concepts section links to them by name.

### Out-of-tree dogfood implication

When the framework splits out of `/home/fcalell/nix`, the
current `README.md` (fcalell-specific install log) is
**discarded, not migrated**. The dogfood repo gets a fresh
README in the template-README shape, with fcalell's actual host
list filled in — meaning the dogfood README *is* an instance of
the template README, demonstrating the artifact end-to-end.

### What the Gap 4 deep dive commits us to

- The 30-minute path is a **time-bounded contract**: single
  host, ends at a successful `nixhold deploy`. Future README changes
  don't break this contract without an explicit revisit.
- The template ships **scaffolds with commented examples**, not
  empty files and not interactive wizards.
- The framework README is **decide-and-jump**, not a tutorial.
  Anything tutorial-shaped lives in the template README or
  `docs/`.
- `docs/` has **five locked filenames** that the framework
  README links to. Adding files is cheap; renaming the locked
  five is breaking.
- The audience gate **names module library authors** as the
  non-audience callout. Single-laptop seekers are welcome.
- `nix run .#nixhold -- <subcmd>` is the **walkthrough's canonical
  invocation form**; PATH install is convenience, not required.

### Out of scope (for Gap 4 deep dive)

- **Prose drafting of either README.** Locked here is structure
  + step sequence + contracts. Writing the actual paragraphs is
  implementation work, not architecture.
- **Curated topology templates beyond `default`**
  (`workstation-only`, `single-server`, `laptop-plus-vps`).
  Gap 4 main scope already defers these to a "forkers exist"
  trigger.
- **Interactive walkthroughs** (gum-driven first-time setup
  beyond the verbs' built-in prompts). Gap 4 main scope already
  defers these.
- **README-as-marketing-site** (animated demos, screenshot
  galleries, comparison matrices beyond the short table).
  Pre-1.0, no consumers — the README is for evaluating, not
  selling.
- **Migration guides** from nix-darwin / plain home-manager /
  other fleets. Deferred to Gap 4's `nixhold init --from <path>`.
- **A `docs/index.md` or sitemap file.** The framework README's
  Concepts section is the index; a separate sitemap is overhead
  for five documents.
- **Forker-side `CONTRIBUTING.md` / issue templates.** Each
  forker's repo, each forker's call. The framework repo has its
  own.

---

## Gap 1 extension: DNS declaration contract

### The gap

Gap 1 committed to "DNS is a framework concern for public
exposures." Item C's schema work added `publicFqdn` and
`expose.<name>.public` as the declaration sources, then deferred
automated provisioning to Out-of-scope. What was missing: the
foundation contract — a stable read-surface that future provider
modules consume, plus the validation that catches reachability
failures at eval time.

This section locks that foundation. v1 = declare-only with one
introspectable derived view; v2+ = per-provider modules consume
the view and push records (deferred until a real consumer
surfaces).

### What's locked in v1

Declaration sources already exist:
- `hosts.<name>.publicFqdn` — operator-declared FQDN for the host's
  `publicIp`
- `nixhold.services.<name>.expose.<endpoint>.public` — service-level
  public FQDN

New derived view — the foundation read-surface:

```nix
options.nixhold.fleet.derived.records = lib.mkOption {
  type = lib.types.listOf (lib.types.submodule {
    options = {
      fqdn   = lib.mkOption { type = lib.types.str; };
      type   = lib.mkOption { type = lib.types.enum [ "A" ]; };
      rdata  = lib.mkOption { type = lib.types.str; };
      source = lib.mkOption { type = lib.types.str; };
    };
  });
  readOnly = true;
};
```

Example contents:

```nix
nixhold.fleet.derived.records = [
  { fqdn = "homelab.example.com";
    type = "A";
    rdata = "203.0.113.5";
    source = "nixhold.fleet.hosts.homelab.publicFqdn"; }
  { fqdn = "vault.example.com";
    type = "A";
    rdata = "203.0.113.5";
    source = "nixhold.services.vaultwarden.expose.web.public"; }
];
```

The `source` string traces back to the declaring option for
operator ops and lint error messages. Consumers:

- v1 `nixhold status` displays the record table for inspection
- v1 `nixhold lint` reads the table for cross-module validation
- v2+ per-provider modules read the table to push records

### Locked decisions

**Zone declaration is implicit.** A zone is the suffix shared by
FQDNs in use. The framework derives zones from `derived.records`
when needed; no `nixhold.fleet.dns.zones` declaration ships in v1.
Adding the explicit declaration is the trigger when per-zone
provider config arrives (different zones using different
providers).

**IPv4 only in v1.** `publicIp` stays a single string holding an
IPv4 address; `derived.records` emits A records only. `publicIp6`
and AAAA emission land when an actual dual-stack host appears —
splitting now without a consumer is speculation.

**Record type is always A at the declaration layer.** The
operator declares "FQDN Y resolves to host H's publicIp" via
`expose.<name>.public` + `publicFqdn`; `derived.records` emits
one A entry per FQDN. A vs CNAME is a provider-module concern:
a future Cloudflare module can choose to emit `vault.example.com
CNAME homelab.example.com.` instead of two A records based on
operator preference, provider capabilities, or zone-apex
constraints. The declaration layer doesn't decide.

**Wildcards are not in v1.** `expose.<name>.public` is a literal
FQDN, not a pattern. Wildcard records and wildcard-cert issuance
become provider-module options later.

### Validation — three enforcement layers

The four candidate rules considered settled across three layers:

| Concern | Enforcement | Why |
| --- | --- | --- |
| `expose.<name>.public` declared but host has no `publicIp` and isn't on an `internet`-typed network | **`nixhold lint` strict-error** | Cross-module invariant (service × host × network); type system can't see across modules. Silent unreachability is exactly what lint should catch. |
| Two services collide on the same public FQDN | **`assertion`** in the derived-records evaluator | Fleet-wide uniqueness check; identical effect to lint, lives closer to the data it's checking. |
| Public FQDN doesn't match a valid hostname pattern | **`lib.types.strMatching <hostname-regex>`** on the option type | Type-level rejection is cleaner than a lint pass — fails at declaration, not at lint. |

The candidate "zone suffix mismatch" warning was cut: operators
legitimately host services on FQDNs they don't otherwise own
(reverse proxies, vanity domains), and the warning catches no
real bug.

### What the Gap 1 extension commits us to

- **Public DNS is a framework declaration concern.** Every
  public-facing service FQDN the fleet expects appears in
  `derived.records`. Operators don't hide DNS state in non-Nix
  systems if they want fc to know about it.
- **Provider modules consume `derived.records` as their input.**
  When the first provider module lands (Cloudflare, Route53, …),
  it reads this table and pushes records. The declaration surface
  doesn't change at that point.
- **One record type (A) and one address family (IPv4) in v1.**
  AAAA, CNAME emission, and wildcard records are provider-module
  features when consumers surface.
- **One lint rule catches the high-value failure**
  (declared-but-unreachable). Cheaper invariants live in the type
  system or as assertions, not lint.

### Out of scope (for Gap 1 extension)

- **Per-provider modules** (Cloudflare, Route53, DNSimple, …).
  Deferred until a real consumer.
- **DNS-01 ACME challenges.** Caddy issues HTTP-01 certs by
  default (Gap 1); DNS-01 requires DNS provisioning, which is
  deferred.
- **AAAA records / dual-stack.** Lands with `publicIp6` when a
  dual-stack host appears.
- **Wildcard FQDNs / wildcard certs.** Lands as a provider-module
  option.
- **CNAME emission at the declaration layer.** Provider-module
  concern, not declaration.
- **`nixhold.fleet.dns.zones` explicit declaration.** Lands when
  per-zone provider config is needed.
- **TTL declarations** in `derived.records`. Provider-module
  concern; consumers can default.
- **TXT/MX/SRV/other record types.** Out until a service needs
  them; mail and SRV are very service-specific and design
  alongside the consumer.
- **DNSSEC support.** Provider-module concern.
- **Reverse DNS (PTR records).** Provider-specific (often the
  VPS provider, not the DNS zone host).
- **"Zone suffix mismatch" lint warning.** Cut — operators
  legitimately use FQDNs on zones they don't otherwise own
  (reverse proxies, vanity domains); warning catches no real
  bug.

---

## Out of scope (explicitly not building)

These have been considered and rejected. Including them here so
they don't re-surface.

- **A separate facet system distinct from NixOS options.** Modules
  expose plain `mkOption` declarations under `nixhold.services.<name>`;
  consumers walk `config.nixhold.services` directly. The publish/
  subscribe vocabulary, the `byName`/`byType` indexes, the
  consumer-declared schema registry, and `lib.mkFacetModule` are
  all out — `mkOption` is the publish, `config` is the subscribe.
- **LUKS / dropbear-initrd support.** The framework's threat model
  doesn't justify disk encryption: physical theft of a personal
  server is rare, the boot-complexity tax (passphrase entry,
  remote-unlock SSH attack surface, recovery dance) is paid every
  reboot. Operators who want it author their own
  `hosts/<name>/disko.nix`; the framework's scaffold and bootstrap
  paths don't.
- **A `kind` enum field on hosts** (VPS vs on-prem). VPS-ness is
  implicit from `publicIp` + `public` network membership; every
  behavior that might branch on it is derivable from declarations.
- **VPS provider provisioning** (`fc vps create hetzner ...`).
  Each provider's API is its own beast, and Terraform/OpenTofu /
  the provider's CLI already does it well. The "click Create" step
  is a one-time 30-second action; not worth integrating.
- **VPS lifecycle commands** (`fc vps destroy / snapshot / resize`).
  Same reason — use the provider's tools.
- **`fc recover <host>` CLI command.** Disaster recovery is
  `new-host` → `bootstrap` → service restore. Three existing
  commands and judgment. A scripted walkthrough for a
  once-in-years operation is over-engineering; documenting the
  sequence in `DR.md` is enough.
- **`fc check` and `fc test` (build-level + VM integration tests).**
  Deferred until external PRs land or a regression bites; for solo
  dev, ad-hoc `nixos-rebuild build` covers the build-level
  confidence. The test-helper API is itself speculative — write
  the first VM test by hand when one matters, then formalize.
- **Stability tags in option descriptions**
  (`[stable]`/`[evolving]`/`[internal]`). Without enforcement
  machinery they're inline noise. Adopt alongside the machinery.
- **CHANGELOG.md before first external consumer.** Pre-public
  framework with no consumers — git history covers the same
  ground.
- **`nixhold.lib.utils.*` as designated foundation work.** Use the
  namespace when a shared util appears; don't reserve it
  proactively.
- **DNS provider abstraction layer.** Hardcode the type enum;
  pattern-match in the DNS infra module.
- **`fleet.defaults.{timezone, locale}` block.** No consumer reads
  it. Hosts set `time.timeZone` directly.
- **`nixhold identity init`, `nixhold bootstrap`, `nixhold update`
  as additional verbs.** Identity provisioning is `nixhold init`;
  install is `nixhold host install`; updates are `nix flake update`
  + `nixhold deploy`. No additional verbs needed.
- **CLI in a compiled language (Go, Rust).** Single-binary,
  fast-startup, typed are real wins, but the CLI is shell glue
  around `nix eval`, `agenix`, `nixos-rebuild`, `$EDITOR` —
  bash's home turf. Compiled adds build latency to every framework
  change, narrows the contributor pool, and the closure cost
  (single binary, ~10 MB) is no better than `bash + gum`.
- **CLI in Python.** Considered; rejected. Python's wins
  (cleaner interactive flows, structured data) are real but
  bash + gum closes most of the interactive gap, and structured
  data belongs in Nix (where typed options live) rather than the
  CLI. The ~50 MB python3 closure tax is real on every host.
- **Hybrid "many flake apps pretending to be one binary"**
  (Q1 option E in design). One binary with subcommand dispatch +
  per-subcommand `writeShellApplication` files is the chosen
  shape; the cross-command helper layer (`cli/lib/run.sh`) is
  shared, not duplicated.
- **`dialog` / `whiptail` TUI.** ncurses-based, dated UX, GPL/
  LGPL licensing pulls in copyleft transitively. `gum` covers the
  same primitives with modern UX.
- **`bashly` / shell-CLI codegen tools.** YAML-driven generators
  produce bash; the bash should stay readable directly. Codegen
  hides what's actually running and breaks the "operators read
  the scripts" property.
- **CLI as a separate flake / external repo.** The CLI ships
  with the framework. Decoupling buys nothing — every CLI release
  is paired with framework changes anyway.
- **`nixhold.cli.enable` as the install knob** (under the
  `nixhold.*` namespace). Replaced by `programs.nixhold.enable`
  — matches `programs.git.enable` etc.; the `nixhold.*`
  namespace is for framework data, not toolchain installation.
- **Rich terminal libraries (`rich`-equivalent for bash, `bat`
  output coloring, `delta` for diffs).** v1 output is plain text
  with selective `gum style` for headers. Operators can pipe
  through `bat` / `delta` themselves if they want; the CLI
  doesn't impose a color theme.
- **Separate installer flake apps** (`init-fc-identity`,
  `new-host`, `bootstrap-local`, `bootstrap-remote`,
  `install-here`, `install-remote`, `install-darwin`). Replaced by
  `nixhold init` and `nixhold host {add,install,rotate-key,remove,list}` —
  one CLI, one entry pattern. Pre-install access is
  `nix run .#nixhold -- <verb>` (single flake app). The historical
  shell scripts are absorbed into the CLI scripts under `cli/`.
- **A `--here` mode for `nixhold host install`.** Local NixOS installs
  use the same `--remote root@<installer-ip>` path: operator boots
  the installer USB on the target, the installer's sshd becomes a
  temporarily-reachable SSH target. One code path; the operator's
  primary always drives. Auto-detect-by-hostname was considered and
  rejected (cleverness that bites in unforeseen contexts).
- **`CHANGE_ME` placeholder markers in scaffolded files.** Disko
  is generated from the target's actual hardware at install time
  by `nixhold host install`, not scaffolded with placeholders. Operators
  never edit a marker; they pick a disk from the install-time
  picker (or pass `--disk <by-id>` to skip the prompt). Custom
  disko (encryption, mirroring, custom layout) goes through
  `--disko-from <path>` — power-user flag, hand-authored file.
- **Facter scaffolded as a stub or marker file by `nixhold host add`.**
  Facter is generated from the target's hardware by
  `nixhold host install` (via `nixos-anywhere --generate-hardware-config
  nixos-facter` or an equivalent) and committed on success. Lint
  has dev (warning) vs strict (CI gate) modes for the gap between
  `host add` and `host install`.
- **`nixhold host install` auto-commits the install + lets the operator
  amend** (vs prompt-to-commit on each install). Auto-commit with
  a templated message keeps the flow streamlined; `git commit
  --amend` is the override path. The auto-commit is restricted to
  `hosts/<name>/disko.nix` + `hosts/<name>/facter.json` — never
  touches other paths.
- **`nixhold host install` running on the target itself** (target-driven
  install). The operator's primary always drives; the target is a
  passive SSH endpoint. Even for on-prem installs, the operator
  SSHes from their primary into the installer USB. Reduces context
  switching, keeps the operator-machine prereq honest (Nix on one
  machine, the primary).
- **Unifying `nixhold init` with `nixhold host install` for first-time
  setup.** Two distinct steps: `nixhold init` is per-fork (operator
  identity); `nixhold host install` is per-host. Combining them would
  hide the identity provisioning step and make re-running ambiguous.
- **`init --rotate` / `fc identity rotate-passphrase`** as v1
  features. Deferred until the use case surfaces; manual `agenix
  rekey` covers the rare passphrase-rotation case meanwhile.
- **Headscale as the control plane** (self-hosted alternative to
  Tailscale's SaaS). Considered; rejected for v1. Headscale
  doesn't reduce manual steps — it shifts them from a one-time
  SaaS signup to an ongoing self-hosted service the framework
  must provision (control-plane host, public DNS record, ACME
  cert, port :443, policy.hujson ACLs) and maintain (upgrade lag
  vs upstream Tailscale, headscale-dies-no-new-nodes failure
  mode). Tailscale Inc isn't a data-plane dependency: WireGuard
  is end-to-end encrypted between nodes; coordination doesn't see
  traffic. Foundation property maintained: the `network.<name>`
  schema reserves room for an optional `controlServer` override
  in the future — the tailscale module reads it and passes
  `--login-server=<x>` to `tailscale up`. Adding headscale-as-
  control-plane later is purely additive (one option field + one
  CLI flag). Trigger to revisit: forker asks for sovereignty-only
  operation, device count crosses 100, or Tailscale Inc
  materially changes free-tier terms.
- **`data` and `health` as v1 starter shared option types.** Starter
  types are `expose` and `network` only. Additional types land
  alongside their consumer infra modules.
- **Backup as a framework concern** for the foreseeable future.
  When/if it lands, the `data` type is designed alongside the
  backup module.
- **`nixhold lint` reverse port check** (service binds a port not in
  `network.ports`). NixOS has no uniform "what ports does a
  service bind" property; the forward check (declared port has no
  `expose` reference) covers the declarative side.
- **`hosts.<name>.type` enum** (`workstation` / `server` / `laptop`
  / `kiosk`). Constrains forker taxonomy without saving meaningful
  boilerplate. Profile selection is `hosts.<name>.profile` in
  `hosts.nix` — a Nix value (a `nixhold.profiles.<name>` attr or a
  local path), not a string the framework would resolve.
- **`hosts.<name>.primary` field.** No consumer; deploy targets
  are always named explicitly.
- **`nixhold.infra.<name>` namespace as a designated option space.**
  When the first infra module needs instance config, declare it
  then; until then, no namespace reservation.
- **`mkAgeSecret` as a builder function** (with `name`/`hostname`
  parameters). Replaced by the `nixhold.secrets.<name>` options API
  that derives both from context.
- **CLI eval caching layer / `--fast` mode.** Nix's eval cache is
  the cache. Cold-cache cost is accepted; no hidden state.
- **`nixhold status` as a dashboard.** Output is bounded to enabled
  services, `expose` endpoints, and secret status. Anything richer
  requires explicit `nix eval` or `nixos-option` invocations.
- **Cross-host routing via `fleet.routes`** (service on host A,
  proxied through gateway B). No consumer in v1 — the user's fleet
  runs public services on the gateway directly. Deferred until a
  real consumer surfaces, at which point the syntax (`fleet.routes`
  or something better) is designed informed by the consumer's
  needs. The lint rule "`expose.<x>.network = "public"` requires
  the host to be on the `public` network" is the foundation that
  keeps the door open.
- **`lan` network type.** v1 covers `tailscale` + `internet`. LAN
  brings firewall-by-interface, mDNS, no-TLS edge cases, and
  inter-host LAN transport assumptions — all speculative. Adding a
  third `type` branch later is mechanical when a LAN-only service
  surfaces.
- **`auth` field on `expose.<name>`.** Only `auth = "network"`
  (the no-op default) had any real semantics; `basic` and `none`
  were placeholder values with no consumer. When caddy-mediated
  auth (HTTP basic, forward-auth via Authelia, OIDC) lands, the
  shape will be a submodule (`{ type = ...; ... }`), not a single
  string — designed against the real consumer.
- **`grpc`, `tcp`, `udp` protocol values on `expose`.** v1 covers
  HTTP-family only (`https` / `http` / `ws` / `wss`). L4 services
  (WireGuard, raw TCP) likely land in a parallel namespace
  (`nixhold.services.<name>.l4` or similar) when needed — overloading
  `expose` with conditional schemas (forbidden-with-udp,
  required-with-http) is the wrong shape.
- **Filename-glob auto-discovery for secrets** (e.g.
  `secrets/hosts/<host>/ssh-*.age` → auto-wire). Replaced by
  explicit `nixhold.secrets.<name>` with `owner = "user"` and optional
  `homePath`. One declaration pattern, full manifest visibility,
  bidirectional lint enforcement.
- **`hosts/<name>/home.nix` framework auto-detect.** Per-host HM
  additions go through `nixhold.home.extraModules` (declared option set
  in the host file). Auto-detect would be the one `pathExists` check
  in the framework — replaced by the option so the framework has
  zero `pathExists` calls (principle 14). Forkers can still write a
  `./home.nix` sibling; they reference it explicitly via the option
  (or via raw `home-manager.users.<user>.imports`).
- **Profile selection by string** (`hosts.<name>.profile = "server"`
  with framework name resolution into `profiles/<name>.nix`).
  Replaced by attribute reference: `profile = profiles.server`
  where `profiles = import ./profiles`. Typo-proof at eval time;
  no resolution layer; no convention that filename = registered name.
- **`pathExists`-based platform variants under `modules/<kind>/`.**
  Each kind's `default.nix` self-gates platform variants
  (`lib.optional pkgs.stdenv.isLinux ./nixos.nix`). The framework
  imports the kind directory; the kind decides what's in scope.
  Discovery by pattern (framework walking every kind dir looking for
  `nixos.nix`/`darwin.nix`) is rejected.
- **`nixhold.ssh.keys` option** (or any parallel option for declaring
  operator-owned SSH keys outside `nixhold.secrets.*`). Subsumed by
  `nixhold.secrets.ssh-<name> = { owner = "user"; homePath = ".ssh/<name>"; ... }`
  with the `ssh-*` pubkey convention.
- **Two-pass fleet evaluation** (each host re-evaluated with a
  fleet-wide view). Replaced by explicit `fleet.routes` for
  cross-host concerns. One-pass eval is principle 13.
- **`nixhold doc` as a build artifact.**
  `nixos-option nixhold.services.<name>` covers per-option
  documentation; module `description` text covers the prose.
  No bespoke doc generator.
- **Plugin-CLI extension mechanism**
  (`nixholdCommands.<name>`). New subcommands land in-tree
  until plugins exist as a thing.
- **`nixhold.experimental.*` namespace.** Add when an
  experimental feature exists.
- **Internal CA for LAN networks.** Tailscale + tailscale cert
  covers private TLS for the canonical topology.
- **Speculative option types: `logs`, `schedule`, `capabilities`,
  `metrics`.** Design alongside the consumer when one is built.
- **In-tree dogfood** (framework + fcalell's personal fleet in
  the same repo). Considered (Item 13); rejected. In-tree dogfood
  creates a framework-dev exception path that drifts from real
  forker reality — the dogfooder gets relative-path imports and
  whatever the framework's `flake.nix` happens to expose, while
  forkers go through `inputs.nixhold.*`. Out-of-tree dogfood (fcalell's
  fleet in a separate repo pinning `inputs.nixhold` like any forker)
  makes dogfooder UX and forker UX identical, which is the property
  that makes "the framework eats its own dog food" meaningful. Cost
  is two-step verification (push framework → bump downstream lock);
  the framework repo carries a synthetic CI fixture (`checks/fixture`)
  to catch mkFleet contract drift on every commit.
- **À-la-carte module exports** (`nixosModules.identity`,
  `nixosModules.secrets`, ... cherry-pickable). Single bundled
  `nixosModules.nixhold` per platform. Splitting the export surface
  would invite forkers to import partial sets and trip on missing
  inter-module dependencies the framework assumes co-present.
  Forkers customize via options, not import surgery.
- **Forker re-declares nixpkgs / home-manager / agenix / disko /
  nixos-anywhere as required inputs.** Considered (Item 13);
  rejected. mkFleet reads heavy-machinery inputs from
  `inputs.nixhold.inputs.*`, not from the forker's top-level `inputs`.
  Forker's `flake.nix` declares only `inputs.nixhold.url`. Forkers who
  need to bump nixpkgs (or any framework dependency) ahead of fc's
  pin use the standard `inputs.nixhold.inputs.<x>.follows = "<x>"` idiom.
  The "transparent" alternative (forker passes whole `inputs`,
  mkFleet consumes those directly) couples mkFleet's resolution
  to whatever the forker happens to declare and creates two
  failure modes (missing input vs version mismatch) where one
  source of truth (`inputs.nixhold.inputs`) has neither.
- **Single `root` parameter** (`mkFleet { inputs, root }` reading
  `${root}/identity.nix`, `${root}/fleet.nix`, `${root}/hosts/*`,
  `${root}/modules/` from disk). Considered, then rejected for
  principle 14: mkFleet takes explicit Nix-value kwargs —
  `{ inputs, identity, networks, hosts, layout }` — and reads
  nothing from the filesystem. The forker assembles those values in
  their own `flake.nix` (host topology via `hosts.nix`), keeping
  eval pure-Nix and the framework free of `${root}/…` reads.
- **Module-internal imports via `inputs.nixhold.nixosModules.*` /
  `inputs.self.*`.** Modules inside the framework import siblings
  by relative path (`../common/identity.nix`). Self-import via
  flake inputs is gymnastics that buys nothing — the framework's
  own modules are co-located, the paths are stable, and the only
  consumers of `inputs.nixhold.*` are forkers.
- **CHANGELOG / tagged releases before the first external forker.**
  v1 pins by SHA; tags land when a stable contract is worth
  defending. Same reasoning as the existing CHANGELOG entry, kept
  alongside the SHA-pinning decision.
- **`nix.linux-builder.enable = true` as a Mac profile default.**
  Considered (Item A/B); rejected. Each machine builds its own
  config: `nixhold deploy <linux-host>` passes both `--target-host` and
  `--build-host` pointing at the target, so the target evaluates +
  builds + activates. The operator's Mac never builds Linux. No
  builder VM, no Rosetta prereq, no ~40 GiB disk allocation, no
  cross-arch concerns. `nixhold host install` follows the same rule via
  `nixos-anywhere --build-on-remote`. Tradeoff accepted: tiny VPSes
  (< 1 GB RAM) may struggle on heavy builds — substituters cover
  most cases, and the override (`nixos-rebuild --build-host
  <other-host>`) is operator-managed raw nix.
- **Framework-managed remote builders** (`nixhold.fleet.builders.<system>
  = <hostname>` resolved into `nix.buildMachines`). Considered;
  rejected. With "each machine builds its own" as the default,
  there's no framework need to manage cross-host build trust.
  Operators who want a beefier host to build for a smaller one
  configure `nixos-rebuild --build-host` themselves (or set
  `nix.buildMachines` in their host file). Foundation namespace
  `nixhold.fleet.builders.<system>` is **unclaimed** — when a future
  iteration adopts it, the design is informed by the consumer.
- **`nixhold deploy --build-host` flag.** Exposing it invites the
  recurring decision "where should I build" that the
  each-machine-builds-its-own default removes. Power users escape
  to raw `nixos-rebuild --build-host`; the framework picks one
  answer.
- **`nixhold deploy --fleet` / mass deploy / pattern deploy.** v1
  deploys one named host at a time. Adding a mass mode later is
  purely additive.
- **Remote Darwin deploy** (`nixhold deploy <mac> --remote ...`). Mac
  hosts are deployed locally only. `nixhold deploy mac` invoked on a
  non-Mac refuses with a clear message. Remote Darwin activation
  via `darwin-rebuild --target-host` is theoretically possible but
  carries authentication quirks (SSH-as-root on Darwin) and saves
  no time vs. SSHing in and running locally.
- **A separate `nixhold diff` verb.** Preview is
  `nixhold deploy --dry-run <name>` (eval + dry-build with the
  framework-aware prelude). One verb with a `--dry-run` flag is
  less surface than two verbs that share most of their
  implementation.
- **`derived.fqdn.<host>.<endpoint>` lookup table** (the v0
  design from earlier drafts, keyed by host + service-expose
  endpoint). Rejected. The endpoint FQDN already lives in
  `nixhold.services.<x>.expose.<y>.fqdn`; an extra `derived`
  mirror duplicated the data without adding lookup
  convenience. External-DNS consumers walk
  `nixhold.services.*` directly. Cross-host wiring uses
  `derived.address.<host>.<network>` (host-level, network-
  keyed, explicit).
- **`derived.addressOf.<host>` convenience option (picking the
  best shared network automatically).** Rejected. The implicit
  "first shared network" choice was a debuggability hazard —
  eval-time throws inside derived options point at the
  consumer rather than the topology mistake, and `null`
  returns would silently propagate into service config
  strings. The chosen path is to require the caller to spell
  out the network: `derived.address.<host>.<network>`. Tiny
  verbosity cost in consumers; the implicit-resolution failure
  mode is gone, not merely better-messaged.
- **`nixhold.lib.address` as a helper function** (vs a typed
  option attrset). Function-form helpers fragment the data
  surface — every other cross-host pattern is a typed option
  per principle 10, this should be too. The attrset form also
  gets introspection benefits (`nix eval`, `nixhold status`)
  for free.
- **`fleet.routes` / cross-host service routing** (declared
  relationship "service X lives on host A but is proxied via host
  B"). Kept deferred (existing Out-of-scope entry). Item C
  delivers the address-resolution primitive any future routing
  design would build on, but doesn't itself revisit routing.
- **Automated DNS provisioning** (framework creates A records for
  `publicFqdn` values). Out of scope for v1 — `publicFqdn` and
  `expose.<name>.public` are the operator's declarations that
  records exist; the framework exposes `nixhold.fleet.derived.records`
  for consumers to read but never pushes records itself. Per-provider
  modules that consume `derived.records` are deferred until a real
  consumer surfaces. See "Gap 1 extension: DNS declaration contract"
  for the locked foundation; DNS provider abstraction remains
  deferred per existing Out-of-scope entry.
- **`nixhold.identity.autoConfigure = false` opt-out.** Framework is
  opinionated by design.
- **Pluggable secrets backend** (sops/agenix/plain choice). Agenix
  is part of the framework.
- **Multi-operator / per-secret ACL** (different operators access
  different secrets). Solo framework.
- **Web dashboard / UI.** CLI is enough for solo personal infra.
- **Cloud-provider abstractions** (AWS/GCP/Azure modules).
  Out of scope for personal infra.
- **Container-orchestration layer** (k8s, nomad). NixOS handles
  service supervision directly.
- **Shipped observability stack** (Prometheus + Grafana + Loki +
  Alertmanager profile or infra module). Personal infra at fc's
  scale (1–10 hosts, one operator) doesn't earn the operational
  tax of a full stack. Forkers compose standard NixOS modules in
  their own profile if they want one. See "Logging and monitoring
  posture" in the architecture spec.
- **`nixhold status` runtime extension** (live `systemctl is-active`
  per service over SSH). `nixhold status` stays declaration-side —
  what's *configured*, not what's *running*. Preserves the
  property that `nixhold status` works without live SSH to every host.
  Runtime state lives in `systemctl status` and `nixhold logs`.
- **External alerting integrations** (Healthchecks.io, ntfy,
  Discord/Slack webhooks, PagerDuty, OpsGenie). Forker-specific
  service modules; no framework wrapping.
- **`nixhold.observability.*` namespace reservation.** Using a
  namespace before declaring it adds dead surface; the namespace
  is reserved when the first consumer module lands.
- **Log aggregation modules** (Loki, Vector, journald-remote,
  Grafana Loki promtail). journald is uniform across NixOS;
  whatever aggregator lands later reads it straight. No framework
  wrapping in v1.
- **Shipped Grafana dashboards.** No framework-managed dashboard
  set; forkers who want Grafana wire it themselves with whatever
  dashboards they pick.
