# nixhold — architecture spec

The source of truth for the framework's architecture. Every locked
decision lives here; code implements this document. To change the
architecture: draft the section, surface 2–4 decisions for the
operator to lock, edit this file, then implement. Operator runbooks
and fleet-specific wishlists live in consuming fleet repos, not
here.

Format notes for readers (human or LLM): decisions are stated once,
in the section that owns them. "Rejected" entries at the bottom are
final unless explicitly overturned (two have been; they say so).
Field shapes are given as tables; the implementation in `modules/`
and `cli/` is the reference for exact code.

---

## Vision

**An opinionated, Nix-native personal-infrastructure framework.**
Single operator, single fleet, 1–10 machines they own. A forker
stands up a workstation + server pair in an afternoon; host files
read as declarations of intent, not plumbing.

Product pillars:

1. **Easy install / configure / reformat of whole systems** — one
   CLI, generated hardware config, no hand-authored boilerplate.
2. **No primary machine** — repo + passphrase reconstructs the
   entire fleet (principle 16). The operator may have access to no
   existing machine at a given moment; a bootable installer ISO +
   the passphrase must suffice.
3. **Easy secrets management** — one declaration pattern, one
   manifest, agenix as part of the framework.
4. **Sync between systems** — fleet-wide identity, ssh wiring, and
   shared services from one source of truth.

Audience: people managing whole machines (workstation + homelab +
maybe a VPS) who want reproducible builds, atomic activation, and
everything declared together. Non-audience: module-library authors
wanting building blocks (the framework ships opinions), and people
who just want docker-compose on one VPS (tell them so — the
framework's unit is the machine, not the container; NixOS
containers can still implement any `nixhold.services.*` module).

---

## Principles

1. **Two layers: framework + personal config.** Framework consumed
   via flake outputs; the author's fleet is the canonical example,
   in a separate repo.
2. **Identity is the central contract** — a Nix value passed to
   `mkFleet`, not a file read from disk.
3. **Auto-wiring, Catppuccin-style.** Set identity once; user,
   home dir, git author, agenix owner, nix trust follow via
   `mkDefault`.
4. **`mkDefault` discipline + named exceptions.** Everything
   auto-wired is overridable; hard requirements (zsh) are named.
5. **Magic over explicit, opinionated over flexible.** Removing a
   knob needs less justification than adding one.
6. **README principles carry over**: one secret/one host;
   recipient list = security boundary; composition over
   inheritance; hardware-is-data; no platform branching in
   modules.
7. **Unified framework, not a backend toolkit.** Agenix is the
   secrets system, Caddy the reverse proxy, Tailscale the mesh.
   Consumers who want sops/nginx/headscale fork harder.
8. **Convention over configuration; declaration is the registry.**
   Predictable file shapes at declared paths; explicit indexes
   (`modules/<kind>/default.nix`, `nixhold.secrets.<name>`); lint
   enforces file ↔ declaration in both directions.
9. **Foundations over features.** Framework ships namespaces,
   introspection, lint; stacks (monitoring, backup) are consumers
   of the same namespace.
10. **Plain NixOS options are the API.** `mkOption` is the
    publish, `config` read is the subscribe. No facet vocabulary,
    no registry indirection.
11. **One operator CLI: `nixhold`.** Thin verbs over existing
    tools; unique value is status/lint/scaffolds reading
    `config.nixhold.*`.
12. **Total declarability of network presence.** Every endpoint a
    service exposes is declared in `expose`; the framework answers
    "what runs where, bound how, reachable how" from config alone.
13. **One-pass eval.** Each host evaluates independently, seeing
    its own services + `config.nixhold.fleet`. Cross-host concerns
    are explicit topology, never re-evaluation with a global view.
14. **No filesystem discovery in framework eval.** `mkFleet`
    consumes Nix values; the framework never walks directories.
    Layout defaults are computed subpaths of `inputs.self` —
    values, not discovery. The CLI may *write* to layout paths.
    Named path exceptions: `facter.json`, `/etc/ssh` host keys,
    `flake.nix`, the `.age` extension, committed pubkeys under
    `layout.keysDir` (read at eval to compute recipients).
15. **Thin operator glue.** Every verb = reading declared options
    + computing arguments + invoking an underlying tool. Logic
    beyond that needs justification in the verb's docstring.
16. **Repo + passphrase reconstructs the fleet.** No machine is
    special. Every artifact needed to rebuild/reinstall/reformat
    any host is committed (encrypted to the operator when
    private: wrapped operator identity, secret ciphertexts,
    escrowed host SSH keys). The only state outside git is the
    passphrase. `~/.config/nixhold` and `~/.cache/nixhold` are
    caches, never the sole copy of anything. Any host can be
    installed or recovered from the installer ISO + passphrase.

---

## Fleet contract — `mkFleet`

Single forker-facing entrypoint: `nixhold.lib.mkFleet { inputs,
identity, networks, hosts, layout? }`. All Nix values; no files
read from disk. A minimal fork passes only `inputs`, `identity`,
`networks`, `hosts` — `layout` is fully defaulted.

| Parameter | Purpose |
|---|---|
| `inputs` | the forker's flake-call attrset; heavy deps resolved from `inputs.nixhold.inputs.*`; `inputs.self` roots the layout defaults |
| `identity` | `{ username, fullName, email }` |
| `layout` (optional) | CLI filesystem contract; every field defaults from `inputs.self`: `secrets` → `/secrets`, `hostsFile` → `/hosts.nix`, `modulesDir` → `/modules`, `profilesDir` → `/profiles`, `keysDir` → `/keys`, `ageRecipient` → `/keys/operator.pub`, `ageIdentityWrapped` → `/keys/operator.age`. `repoUrl` is the one non-derivable field — a bare `owner/repo` slug (github.com assumed, cloned over SSH via the deploy key), typed to reject URL schemes and a `.git` suffix since both the remote and `programs.nixhold.fleetDir` are built out of it; required to build the installer ISO, unused otherwise. Defaulting is computed values off `self`, not filesystem discovery (principle 14 intact) |
| `networks` | `{ <name> = { type, magicDnsSuffix?, domain?, dns?, tls? }; }` |
| `hosts` | `{ <name> = { arch, profile, modules, networks, publicIp?, publicFqdn?, loginPubkey? }; }` |

Rules:

- The forker declares only `inputs.nixhold` (plus fleet-unique
  inputs). nixpkgs / home-manager / nix-darwin / agenix / disko /
  nixos-anywhere come transitively; bumping ahead of the pin uses
  the standard `inputs.nixhold.inputs.<x>.follows` idiom.
- Per-host module list, in order: platform baseline bundle
  (`nixosModules.nixhold` / `darwinModules.nixhold`) →
  `host.profile` → framework baseline (hostname, platform,
  `nixhold.{identity,layout,fleet}`) → `host.modules`.
  `specialArgs` = `{ inputs, identity, fleet, hostname }`.
- Dispatch is per arch family: separate NixOS and Darwin builders,
  no `isDarwin` branching inside one builder. A third family (WSL,
  BSD) would be a third builder + output namespace.
- Outputs: `nixosConfigurations`, `darwinConfigurations`, plus
  re-exported `packages`/`apps` (the `nixhold` CLI), `formatter`
  (nixfmt), and `packages.<arch>.installerIso` per Linux arch with
  ≥1 host — emitted only once the image is actually buildable:
  `layout.repoUrl` set *and* both baked ciphertexts
  (`layout.ageIdentityWrapped`, `keys/repo.key.age`) present. A
  fleet that hasn't reached `nixhold iso` yet simply has no such
  attribute, so `nix flake check` / `nix flake show` stay green;
  `nixhold iso` is the one place that explains what is missing, and
  lint warns about the absent deploy key. **No `checks` gate** —
  lint shells out to `nix eval` and can't run inside a pure
  flake-check sandbox; build-blocking invariants live as module
  assertions instead.
- `profile` is a Nix value (attr reference), never a string. Typos
  fail at eval. No name-resolution layer anywhere.
- Platform module bundles are single exports
  (`nixosModules.nixhold`), not à-la-carte — partial imports would
  trip on asserted-co-present inter-module deps. Forkers customize
  via options.
- Module-internal imports use relative paths; only forkers consume
  `inputs.nixhold.*`.
- Pre-fleet CLI access: `nix run github:fcalell/nixhold#nixhold --
  <verb>` works without a fleet; fleet-context verbs error cleanly
  when no `mkFleet` flake is found.
- Versioning: pin by SHA; tags when a stable contract is worth
  defending; no CHANGELOG until an external consumer exists.
- Dogfood is out-of-tree from day 1: the author's fleet consumes
  `inputs.nixhold` like any forker. CI runs a synthetic fixture
  fleet (`checks/fixture`, one host per platform) to catch
  contract drift per commit.

Framework flake outputs: `lib.mkFleet`, `nixosModules.nixhold`,
`darwinModules.nixhold`, `homeManagerModules.nixhold`,
`profiles.{server,desktopLinux,workstationDarwin}`,
`modules.services.*`, `modules.infra.*`, `apps.<sys>.nixhold`,
`templates.default`, `formatter`, `checks`.

---

## Layers

Concepts, not filesystem (principle 14):

- **Modules (layer 1)** declare typed options; activate nothing by
  themselves. Baseline kinds (identity, secrets, fleet, types,
  layout, home) auto-import on every host — and so does the shipped
  services' *option namespace* (`modules/services/default.nix`, the
  declarations only). `nixhold.services` is therefore part of every
  host's readable surface on both platforms, which is what lets
  `nixhold status` walk it without knowing which profile a host
  drew. The platform *implementations* stay separate — the value
  behind `modules.services.<name>` is `<service>/nixos.nix`, which
  re-imports the same declarations and adds the NixOS config — and
  are imported only by profiles or `hosts.<n>.modules`. Enabling a
  service whose implementation this host never imported is an
  assertion failure, not a silent no-op; infra modules keep the
  older shape (no options unless imported).
- **Profiles (layer 2)** are opinionated host-kind bundles: import
  service/infra modules, set defaults. Shipped:
  `server`, `desktopLinux`, `workstationDarwin` (matching the
  author's host kinds). Forkers compose their own by importing
  module values; multiple profiles compose via
  `{ imports = [ ... ]; }`. Everything profile-set is overridable
  in the host file.
- **Per-host modules (layer 3)** are free-form NixOS/Darwin
  modules (host config, disko import, facter pointer) — operator
  filenames, no framework path conventions.
- **Fleet manifest** — the `mkFleet` args attach a profile to each
  host; the manifest reads as "I have a server, a desktop, a
  workstation."

Source-tree layout inside the framework: kind-first
(`modules/<kind>/`), with `nixos.nix`/`darwin.nix` platform
siblings self-gated by each kind's `default.nix`
(`lib.optional pkgs.stdenv.isLinux ./nixos.nix`). The registry is
the explicit index + flake output table — no `readDir`, no
`pathExists`.

**Infra activates from data, no `enable` knob.** Every infra
module is in the server-side bundle and guards on the data it
consumes (`mkIf (httpEndpoints != [])`). A host with no HTTP
endpoints runs no caddy. Replacing caddy = writing a parallel
consumer of the same `expose` data, not flipping a flag.

**Per-host home-manager**: `nixhold.home.extraModules` (list of
deferred modules), wired into
`home-manager.users.<operator>.imports`. An option, not a
sibling-file convention.

---

## Fleet data — `nixhold.fleet.*`

Typed option tree on every host: `hosts` + `network` (raw
topology, forker-set via mkFleet), `derived.*` (framework-computed
readOnly views), `nixhold._internal.*` (not for consumers).
Schema is **closed** (strict submodules, no freeform); forkers
needing custom per-host data declare their own `options.myorg.*`.

Host fields: `arch`, `profile` (deferredModule), `networks`
(default `["tailnet"]`), `publicIp?`, `publicFqdn?` (operator's
declaration that an A record exists — DNS is operator-managed in
v1), `loginPubkey?` (defaults from committed
`keys/hosts/<host>/identity.pub`, written by the CLI from the
`sshIdentity` secret).

Network fields: `type` (enum `tailscale` | `internet`),
`magicDnsSuffix?` (tailscale), `domain?`/`dns?`/`tls?` (internet).
`localhost` is a built-in pseudo-network, never declared.

Derived views (v1 members; additions land with their consumer):

| Option | Content |
|---|---|
| `derived.self` | this host's own `fleet.hosts` entry |
| `derived.publicHosts` | hosts with non-null `publicIp`; lint asserts length ≤ 1 (v1 single gateway) |
| `derived.hostsByNetwork` | `{ <net> = [ hosts ]; }` |
| `derived.address.<host>.<network>` | FQDN/IP for reaching host over network, or `null` (visible, not pruned). tailscale → `<host>.<magicDnsSuffix>`; internet → `publicFqdn` else `publicIp`. **No `addressOf` shortcut** — callers spell out the network; null-handling is the consumer's assertion. |
| `derived.operatorAuthorizedKeys` | aggregated `loginPubkey`s; authorized on every host's operator account (root stays closed) |
| `derived.records` | DNS declaration table — see Network exposure |

Framework auto-derivations from topology: ssh `matchBlocks` for
every fleet peer (HostName from `derived.address`, User =
operator, IdentityFile = the host's `sshIdentity` secret);
cross-host authorized keys; public-interface identification for
the firewall; lint rejection of `expose` on networks the host
isn't a member of.

Validation lives at three layers: option types (shape), module
assertions (build-blocking invariants: hostname ∈ fleet, publicIp
⇒ public-network membership, gateway uniqueness), and `nixhold
lint` (pre-build conventions; see CLI). Single-host fleets degrade
gracefully (empty derived views, no special-casing).

VPS-ness has **no `kind` field** — it's implicit from `publicIp` +
internet-network membership; all branching behavior derives from
declarations.

---

## Hardware

`disko.nix` + `facter.json` are required per NixOS host, **both
generated by `nixhold host install`** from the target's real
hardware (disk picker over `lsblk`; `nixos-facter` report). The
operator imports them via `hosts.<n>.modules`; never authors or
edits them on the default path. One shipped disko shape:
whole-disk, GPT, 512M ESP + ext4 root, no encryption. Custom
layouts (LUKS, mirrors, sizes) go through `--disko-from <path>` —
power-user flag, hand-authored, unassisted.

**Disk picker UX.** The operator never types or copies a device
path. The picker lists whole disks with size, model, bus, and a
*current-contents* summary (partition table, filesystem labels,
detected previous install, or "empty") so the choice is about
content, not device names; the destructive confirmation lists the
exact partitions about to be erased. The CLI resolves the pick to
a stable `/dev/disk/by-id` path itself. `--disk <by-id>` exists
only to skip the prompt in scripted runs.

**Facter guard**: hosts wire the report through
`nixhold.hardware.facterReport` (NixOS-only; Darwin setting it is
an eval error). File exists → framework sets
`hardware.facter.reportPath`. File missing → eval still succeeds
(lint/status work) but build is blocked by an assertion pointing
at `nixhold host install`. This is what lets nixos-anywhere
evaluate the disko script, kexec, generate the report, then build.

---

## Secrets

Agenix is part of the framework. Convention:
`secrets/hosts/<host>/<name>.age`.

**One declaration pattern** — everything is
`nixhold.secrets.<name>` (service modules declare their own under
`mkIf cfg.enable`; operators declare theirs directly). No
filename-glob magic, no parallel SSH-key option. Names never carry
behavior; behavior is always an explicit option.

| Field | Meaning | Default |
|---|---|---|
| `owner`, `mode` | runtime ownership | `"user"` → operator + `0600` |
| `description`, `template`, `generator`, `required` | CLI-facing metadata driving bootstrap and lint | — |
| `homePath` | HM symlink `~/<homePath>` → decrypted path (only with `owner = "user"`) | `.ssh/<name>` when `sshKey`, else null |
| `sshKey` | marks an SSH private key; `.pub` derived at HM activation via `ssh-keygen -y` (failure is loud) | false |
| `sshIdentity` | implies sshKey; ≤1 per host (assertion). THE outbound key: wired as IdentityFile in fleet-peer ssh config; CLI commits its pubkey as `keys/hosts/<host>/identity.pub`, which defaults `fleet.hosts.<host>.loginPubkey` | false |

The framework derives per-entry: the ciphertext `file` path (from
hostname + name), `recipients` (readOnly: operator recipient from
`layout.ageRecipient` + owning host's committed `host.pub`),
`resolvedOwner`/`resolvedMode`, `age.secrets.<name>` activation
wiring, HM symlinks. The option attrset **is** the manifest — the
CLI reads `config.nixhold.secrets` directly; there is no separate
`declared` attribute.

Recipient/editing model:

- Activation decrypts with the host SSH key
  (`/etc/ssh/ssh_host_ed25519_key`, agenix default).
- Editing verbs materialize the recipient set ephemerally and
  drive `age` directly (`age -R` / `age -d -i`); agenix-the-CLI is
  not a dependency; no `secrets.nix` rules file is ever committed.
- Eval paths are store paths; the CLI writes ciphertexts at
  `$fleet_root` + repo-relative subpath (working-tree resolution).
  Only the fleet's own source store path is re-rooted: a layout
  path into another flake input is a hard CLI error and a lint
  violation (a separate private-secrets input would need its own
  write root — a ROADMAP decision, not a re-root).
- `edit`/`bootstrap`/`rekey` refuse a recipient set that omits the
  operator, or the host when its `host.pub` is readable or it
  already owns ciphertexts (an untracked `host.pub` is invisible to
  eval; the fix is `git add --intent-to-add`). `$VISUAL`/`$EDITOR`
  are honored as command lines (`code --wait`).

**Host-key escrow (principle 16).**
`keys/hosts/<host>/host.key.age` — the host SSH private key,
encrypted to the operator recipient only — is committed alongside
`host.pub`. Single-writer invariant: `host.pub` and `host.key.age`
are always written together from one private key — by `host add`,
`host rotate-key`, `host escrow` (re-escrows a machine's live key,
no rekey) and `host install`'s backfill — so the pair can never
come from different keypairs. Lint checks the tracked pair in both
directions (missing escrow, orphan escrow; warn dev / error
strict); equality is not provable without the passphrase (age
stanzas carry no fingerprint), the invariant holds it. Install
resolves the key: local cache only while it derives the committed
`host.pub` (a stale cache is set aside), else escrow (passphrase
prompt, verified against `host.pub`). The repo is authoritative:
on darwin, a machine key that disagrees with the committed
recipient is replaced by the fleet's; the machine key is adopted
(escrowed, then rekeyed to) only when the fleet has no committed
recipient. `host install-key` pushes the committed key onto a
machine with no repo writes — the completion step for a
`rotate-key --no-install`, and the non-destructive fix for a
drifted machine. A rotation is complete when the verb exits (repo
and machine); the superseded escrow stays in the key cache as
`host.key.age.prev` until the new key is confirmed installed. On
the ISO, everything that can fail or prompt (key resolution,
secret bootstrap) runs before the disk is wiped. Trust delta ≈
none: the operator recipient already decrypts every secret, so
repo + passphrase was already total compromise.

**Repo deploy key.** `keys/repo.key.age` — an SSH deploy key for
the fleet repo, encrypted to the operator recipient only; its
pubkey is registered once on the git host as a deploy key with
write access. It exists so the installer ISO can clone and push
the (typically private) fleet repo with nothing but the
passphrase. Generated and escrowed by `nixhold iso` when missing
(the pubkey is printed for registration); lint warns when
`layout.repoUrl` is set but the escrow is absent. Every
network-facing git call (clone, pull, push) goes through one
helper: with `$NIXHOLD_REPO_KEY_FILE` set (the ISO exports it) it
unwraps the identity, decrypts the deploy key into the process
scratch root and runs git with it; otherwise the operator's own
credentials. The decrypted key is never persisted into the clone.

**Identity resolution.** Verbs needing the operator identity use
`$NIXHOLD_IDENTITY_FILE` if present, else fall back to the
committed `layout.ageIdentityWrapped` (passphrase prompt per
invocation). A fresh clone can edit secrets without `nixhold
init`; init's restore flow persists the identity locally. Losing
the passphrase remains catastrophic by design (Shamir/hardware
keys deferred).

---

## Network exposure

Fleet declares typed networks; services declare named endpoints;
infra modules consume the walk. Eight concerns (reachability,
transport, naming, TLS, auth, proxy routing, firewall, cross-host
routing) split across these declarations instead of one conflated
option.

**Service side** — every service module follows one pattern:

```nix
options.nixhold.services.<name> = {
  enable  = mkEnableOption ...;
  network = mkOption { type = nixhold.types.network; };  # { ports = { <name> = <port>; }; }
  expose  = mkOption { type = nixhold.types.expose;  };  # { <endpoint> = { ... }; }
};
```

Endpoint fields:

| Field | Notes |
|---|---|
| `network` | required; a declared fleet network or `localhost` |
| `protocol` | `https` (default) / `http` / `ws` / `wss`. HTTP-family only in v1 |
| `subdomain` | internet networks: vhost = `<subdomain>.<domain>`. **Ignored on tailscale networks** (see TLS). Forbidden on localhost |
| `backend` | required; references `network.ports.<name>` — one endpoint = one (vhost, backend) pair |
| `pathPrefix` | endpoints sharing a vhost carve paths; caddy emits one vhost with handle blocks |
| `description` | free text for status; recommended on localhost endpoints |
| `extraConfig` | raw Caddyfile lines inside the endpoint's handle block — escape hatch; the model still owns vhost/FQDN/TLS |
| `auth` | bool, default `true`: require the network's identity mechanism (tailscale → node identity, see Tailnet identity auth). `false` is the explicit opt-out. Required-explicit on `internet` endpoints, which have no mechanism yet |

**Every bound port is declared** — a bound port with no `expose`
entry (even `localhost`) is a lint failure; lint also verifies
localhost endpoints actually bind 127.0.0.1.

**Tailnet TLS (locked).** `tailscale cert` only issues for the
node's own MagicDNS name, so on tailscale networks the vhost is
always `<host>.<magicDnsSuffix>` and services differentiate by
`pathPrefix`; one node cert covers everything. Cert provisioning
lives in the caddy infra module, emitted only when tailscale HTTP
endpoints exist: a oneshot (`tailscale cert` into
`/var/lib/caddy/tls` after tailscaled is up), a weekly persistent
renewal timer (90-day certs), and a path unit reloading caddy.
Tailnet vhosts use `tls <cert> <key>` + `auto_https
disable_redirects`; internet vhosts use caddy ACME per the
network's `tls` declaration. Apps that can't live under a subpath
set their own base-path option or expose on an internet network.

**Tailnet identity auth (locked).** A tailnet connection arrives
already authenticated: tailscaled knows the node key and the login
behind every source address, exactly as sshd knows the key behind a
session. The caddy infra module turns that into HTTP auth without a
credential of its own. Every endpoint on a `tailscale`-typed network
gets a `forward_auth` to tailscale's `nginx-auth` daemon
(`services.tailscaleAuth`, unix socket; caddy joins its group),
sending `Remote-Addr`/`Remote-Port`/`Original-URI` and
`Expected-Tailnet: <magicDnsSuffix>`. Non-tailnet sources get 401;
tagged nodes, sharee nodes and nodes of another tailnet get 403; on
success the `Tailscale-User`/`-Login`/`-Name`/`-Tailnet`/
`-Profile-Picture` headers are copied to the backend, where they are
trustworthy because caddy overwrites any client-supplied copy. On
opted-out endpoints the same headers are stripped, so a backend can
never see a forged one. The daemon activates from data, like caddy:
any authenticated endpoint on the host enables it, and an assertion
requires `nixhold.services.tailscale.enable` (the nixpkgs module
would otherwise force-enable tailscaled behind the framework's
back). Nothing is declared — the mechanism is a property of the
network type, so there is no mode, no allow-list, no network knob;
the endpoint carries one field, `auth`, whose only use is the
explicit opt-out. `internet` networks have no identity mechanism, so
an endpoint there must set `auth = false` explicitly (assertion):
app-level auth is that endpoint's own business until an internet
mechanism lands (deferred). Trust boundary = tailnet membership: on
a single-user tailnet that is exactly "a device the operator
enrolled"; multi-user tailnets restrict with Tailscale ACLs, which
are operator-managed like DNS. Backends keep binding 127.0.0.1, so
the only ways in are caddy or the box itself. whois needs a live
tailscaled, so the fixture check covers the emitted config only;
the runtime proof is one request from a tailnet device and one from
outside.

**Infra consumers** (server bundle): caddy (HTTP endpoints →
vhosts, TLS strategy from network type), firewall (opens public
ports only for internet-network endpoints; tailnet needs no
opening), DNS declaration (below). Multi-network exposure works by
declaring endpoints on different networks; same subdomain on the
same network is a lint failure, across networks is fine.

**Single-gateway v1**: public services run on the host that has
the public IP. `expose.<x>.network = <internet-net>` on a host not
in that network fails lint (this rule is also the door-opener for
future cross-host routing).

**DNS declaration contract (v1 = declare-only).** Sources:
`hosts.<n>.publicFqdn` + service-level public endpoints. Derived
read-surface `nixhold.fleet.derived.records`: list of `{ fqdn,
type = "A", rdata, source }` (source traces the declaring option).
Consumers: `status` renders it, lint validates it, future provider
modules push it. Locked: zones implicit (derived from record
suffixes), IPv4/A-only until a dual-stack host exists, no
wildcards, A-vs-CNAME is a provider-module concern. Validation:
declared-but-unreachable (no publicIp / not on internet network) =
lint strict-error; FQDN collision = assertion in the derived
evaluator; hostname syntax = option type regex.

---

## Operator lifecycle

Prereq: Nix on whatever machine you start from. Once a fleet
exists, the installer ISO is itself a sufficient operator seat.

| Event | Flow |
|---|---|
| L1 fork | `nix flake init -t github:fcalell/nixhold` → fill identity (+ `layout.repoUrl`) → `nix run .#nixhold -- init` (or skip: identity falls back to the committed wrapped copy) |
| L2 first host | `nixhold host add <name> --install` — TUI (arch, profile, networks), keys generated + escrowed, entry written to `layout.hostsFile`, secret bootstrap walked, install runs in place (darwin) |
| L3 NixOS host | On-prem: boot the fleet ISO on the target, `nixhold host install` → passphrase → "new host…" in the picker. VPS / from another machine: `nixhold host add <name> --install root@<ip>` (fleet ISO makes the target reachable with zero typing; any installer works) |
| L4 add service | edit host/profile module → `nixhold deploy <name>` (auto-walks missing secret bootstrap) |
| L5 new service module | `nixhold service new <name>` → edit |
| L6 update inputs | `nixhold update` (from any directory): pull → flake update → secret bootstrap walk (on the terminal, before any piped step) → per-host delta review (hosts still missing required secrets show "unknown") → deploy the confirmed hosts |
| L7 reinstall/reformat | Boot the ISO, `nixhold host install` → passphrase → pick the host (or `--remote root@<ip>` from a fleet machine). Host key from cache or escrow → identity unchanged → secrets still decrypt → nothing generated, nothing pushed. Legacy host whose live key was never escrowed: `host escrow` (no rekey), then install |
| L8 rename | manual (`git mv` + edit hostsFile + `secret rekey` + reinstall); a verb only if real need surfaces |
| L9 remove | `nixhold host remove <name>` — deletes fleet entry, hosts/, secrets/, keys/; decommissioning the machine is the operator's job |
| L10 recover | host died → L7. All operator machines lost → clone + passphrase anywhere (or the ISO) is a complete seat. Passphrase lost → catastrophic, regenerate everything (documented, no CLI) |

Properties: one CLI; verb-first; darwin auto-dispatch from arch;
idempotent; repo + passphrase is the whole source of truth; two
install entry points (local on the ISO by default, `--remote`
from a fleet machine), one phase sequence.

---

## Fleet installer ISO

The no-other-machine install/reformat path. **Thin** live image:
`packages.<arch>.installerIso` from the fleet flake (nixpkgs
`installation-cd-minimal` + a small framework module); built or
flashed via `nixhold iso [--flash <device>]`.

Baked in — nothing *unencrypted* is secret; stick + passphrase
equals repo + passphrase, the same boundary as principle 16:

- the `nixhold` CLI + tool belt (git, gum, age, jq, disko,
  nixos-facter); no `gh`;
- operator login pubkeys authorized for root (the passive
  `--remote` path needs zero target-side typing);
- two ciphertexts: `keys/operator.age` (wrapped operator
  identity) and `keys/repo.key.age` (repo deploy key) — the
  passphrase alone unlocks clone, push, escrow, and secrets. Each
  is re-added *by content* (`builtins.path`) rather than coerced
  out of the fleet checkout, which would put the whole checkout —
  hosts, ciphertexts, escrows — in the squashfs. The ISO module
  asserts it: every `/etc/nixhold/keys/*` entry must be a store
  path of its own, and the `fixture-iso` check evaluates the
  fixture's image so a regression fails in CI;
- `layout.repoUrl` (required to build the ISO), plus
  `$NIXHOLD_IDENTITY_FILE` and `$NIXHOLD_REPO_KEY_FILE` pointing
  the CLI at the two ciphertexts, and github.com's published SSH
  host keys so the first clone needs no fingerprint prompt;
- a console banner printing the DHCP address + the one command to
  run; avahi (`root@nixhold-installer.local`).

Not baked: repo contents, plaintext secrets, host keys, build
closures. The ISO goes stale only when the repo location, login
keys, operator identity, or deploy key change — flash once, reuse
for years. Installs need network (private repo clone + closure
downloads).

Target-driven flow — the ISO boots to a root shell with the
banner; the operator runs one command:

```
nixhold host install          # passphrase → unwrap identity → decrypt
                              # deploy key → clone repoUrl → host picker
```

With no `<name>`, a gum picker offers every fleet host (reformat)
plus "new host…" (runs the `host add` TUI, then installs). Local
mode then runs the remote path's phases in place: disk pick →
disko → stage host key (cache/escrow) into `/mnt/etc/ssh` → local
closure build → `nixos-install` → facter written into the
checkout. A reformat pushes nothing; a new host commits + pushes
exactly what it generated (hosts-file entry, `keys/hosts/<n>/`,
`secrets/hosts/<n>/`, `disko.nix`, `facter.json`) over the
deploy-key remote. Darwin is untouched (ISO is NixOS-only).

---

## CLI

One bash CLI, 18 verbs. Access: bare `nixhold` post-install
(`programs.nixhold.enable`, default on) or `nix run .#nixhold --
<verb>` pre-install. No separate installer apps, no
per-subcommand flake apps.

**Fleet-root resolution — verbs work from anywhere.** Fleet
context resolves as: `$NIXHOLD_FLEET` → upward walk from `$PWD`
(wins inside any checkout, e.g. a second worktree) →
`programs.nixhold.fleetDir` (default `~/<repo-basename>` derived
from `layout.repoUrl`; the module bakes the value into the
wrapped CLI). When the resolved directory doesn't exist — a
fresh machine after an ISO install — the CLI offers to clone
`repoUrl` there, through the repo deploy key on the installer and
the operator's normal SSH credentials everywhere else (see "Repo
deploy key").

```
nixhold init                                        provision/restore operator age identity
nixhold host add <name> [--install <user>@<ip>]
nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>] [--disko-from <path>] [--yes]
nixhold host rotate-key <name> [--remote <user>@<ip>] [--no-install] [--yes]
                                                    new host key, escrow it, rekey that host's
                                                    secrets, install it on the machine
nixhold host escrow <name> [--remote <user>@<ip>] [--yes]
                                                    re-escrow a host's live /etc/ssh key (no rekey)
nixhold host install-key <name> [--remote <user>@<ip>] [--yes]
                                                    install the committed host key on the machine
nixhold host remove <name>
nixhold deploy <name> [--mode switch|boot|test] [--dry-run] [--target <addr>] [--yes]
nixhold update [--yes]                              git pull → nix flake update → per-host dry-run
                                                    delta → pick which hosts to deploy
nixhold status [--host <name>] [--fleet]
nixhold lint [--strict]
nixhold logs <host> <service> [--lines N] [--since <when>] [--follow]
nixhold secret bootstrap <host> [name]
nixhold secret edit <host> <name>
nixhold secret rekey
nixhold service new <name>
nixhold profile new <name>
nixhold iso [--flash <device>]
```

Folded-away verbs: `host list`→`status --fleet`, `diff`→`deploy
--dry-run`, `secret list`→`status`, `secret check`→`lint`,
`secret new`→`secret bootstrap <host> [name]`. Rule: each verb is
a real operator action, not a flag-shaped alias. `update` was
first rejected under that rule, then reinstated once fleet-root
resolution made it a from-anywhere workflow (pull → flake update
→ per-host delta review → selective deploy) rather than an alias
of two commands.

Notable shapes:

- **Install is local-first.** No `--remote` means install *this*
  machine — guarded by the installer-environment marker the ISO
  sets: outside it, local mode refuses with "pass --remote or
  boot the installer ISO", so a fleet machine can't be formatted
  by accident. `--remote` drives over SSH from any fleet machine
  (VPSes, or a target booted from any installer). No hostname
  auto-detection — the guard is the environment marker.
- **No `<name>` opens the picker** (installer environment only):
  every fleet host (reformat) + "new host…" (add TUI → install).
  Darwin `host install <mac>` auto-dispatches from arch and runs
  locally.
- disko + facter are install-time outputs (committed on success;
  auto-commit restricted to those two files), never scaffold-time
  placeholders.
- The CLI reads config via `nix eval --json
  .#<platform>Configurations.<host>.config.nixhold.<path>`; data
  is shaped in Nix, rendered by the CLI. Per-option docs =
  `nixos-option`; no doc generator.
- Eval cost: nix's eval cache is the cache; no CLI caching layer,
  no `--fast`.

Implementation: bash + gum, one `writeShellApplication`, one
dispatcher sourcing per-verb scripts (`cli/<verb>.sh`, shared
helpers in `cli/lib/`). Lint rules are per-file scripts under
`cli/lint/rules/` discovered by the lint runner (allowed: the CLI
reading its own rule dir is not framework eval). Exit codes: 0
ok, 1 user error, 2 framework error, 3 lint violation. Output:
plain text, `--json` passthrough where structured; gum only where
a TTY exists.

### `nixhold status` — bounded

Declaration-side only (works with hosts down): enabled services,
expose endpoints, secret status; `--fleet` = one line per host.
Anything richer is `nix eval` / `nixos-option`. Never a
dashboard; never live systemctl.

### `nixhold deploy`

Daily verb; thin over `nixos-rebuild switch` / `darwin-rebuild
switch`. Local iff `$HOSTNAME == <name>` (reliable: the framework
owns host naming). Remote NixOS: `--target-host` **and**
`--build-host` point at the target — **each machine builds its own
closure**; the operator machine never builds foreign arches
(applies to install too via `--build-on-remote`). Remote darwin:
refused (deploy Macs locally). Address from
`derived.address.<name>.<net>` where `<net>` is the
`nixhold.deploy.network` option (default `"tailnet"`); `--target
<addr>` overrides. Modes: switch (default) / boot / test.
Confirmation prompt unless `--yes`. `--dry-run` prints a
framework-aware prelude (service/expose/secret delta) before
`nixos-rebuild dry-build` output. Tradeoffs accepted: tiny VPSes
may struggle building (substituters cover most); power users
escape to raw `nixos-rebuild --build-host`.

### `nixhold secret bootstrap`

Walks the host's `nixhold.secrets` manifest; for each missing
ciphertext: run `generator` (non-interactive) / open `$EDITOR`
prefilled with `template` / open empty editor; encrypt to the
computed recipients. Idempotent; skips existing. `sshIdentity`
secrets get their derived pubkey committed as
`keys/hosts/<host>/identity.pub`. Auto-walked by `host add`, by
`deploy`, and by `host install` when required ciphertexts are
missing — at ISO install time the passphrase is already in hand,
so a new host first-boots with every required secret decryptable,
and a reformat picks up secrets declared since the last deploy
(generators run non-interactively; templates open `$EDITOR` on
the console).

### `nixhold lint`

Dev mode warns; `--strict` is the CI gate (exit 3). Rules:

- every shipped service module declares `nixhold.services.<name>`
- every host profile resolves
- every NixOS host imports disko + sets the facter report
  (warn dev / error strict)
- every secret declaration routes through the manifest (no manual
  `age.secrets` wiring); owner/mode present
- every `expose.backend` references a declared port; every
  `expose.network` is declared and includes the host
- every host pubkey is a recipient of its secrets
- every tracked `host.pub` has a tracked sibling `host.key.age`
  escrow and vice versa (warn dev / error strict)
- no orphan `.age` files; no undeclared `age.secrets` reads;
  every `required` secret has ciphertext
- `homePath` only with `owner = "user"`; kebab-case service names
- (assertion, not lint) `auth = true` on an internet endpoint;
  authenticated tailnet endpoints without
  `nixhold.services.tailscale.enable`
- `publicHosts` length ≤ 1; no public endpoints on non-gateway
  hosts; tailscale network without `magicDnsSuffix` = dev warning
- every layout path (defaulted or overridden) exists in-tree;
  `layout.repoUrl` set but `keys/repo.key.age` missing = warning

Not lintable: a service binding a port it never declared — no
uniform NixOS "bound ports" property; the declarative side is
linted, the binding side is trusted.

### Logs & observability posture

NixOS defaults; no shipped observability stack at 1–10 host
scale. `nixhold logs` = ~30 lines of ssh + `journalctl -u` with
passthrough flags. Metrics/alerting/aggregation/dashboards are
forker-composed from standard NixOS modules. Foundation kept
cheap for later: `expose` already declares ports (future scrape
discovery); the services namespace accepts new option types;
journald is uniform; no namespace reserved before a consumer.

---

## Docs & template (structure locked, prose deferred)

- Framework README: decide-and-jump in 60 seconds — audience gate
  (non-audience: module-library authors; single-laptop users are
  welcome), what-you-get, `nix flake init -t` pointer, status,
  concepts linking to `docs/`, short comparison table.
- Template README: the 30-minute path — a time-bounded contract
  ending at one host deployed + `nixhold deploy` working;
  cross-host wiring demoed *after* the 30 minutes. Becomes the
  forker's fleet README post-init.
- Template ships scaffolds with commented examples (flake.nix
  with placeholder mkFleet call, empty hosts.nix, README,
  .gitignore) — no disko, no wizards, no CHANGE_ME markers.
- `docs/` filenames locked (renames are breaking): `concepts.md`,
  `profiles.md`, `modules.md`, `verbs.md`, `discovery.md`.
- Canonical invocation in walkthroughs: `nix run .#nixhold --`;
  PATH install is a next-step convenience.

---

## Deferred (with revisit triggers)

| Item | Trigger |
|---|---|
| Plugin architecture (third-party modules/CLI verbs). Foundation already open: services namespace, flake-output seams, secrets manifest | external forks / "how do I add my service" issues |
| Build + VM test layers beyond lint; test-helper API | first external PR or a regression lint missed |
| Curated init templates, `init --from` migrations, walkthroughs | forkers exist (~3) / "how do I start" issue |
| Mass deploy (`--fleet`, patterns) | additive whenever wanted; v1 deploys one named host |
| `host rename` verb | manual flow (L8) becomes a real pain |
| DNS provider modules pushing `derived.records`; zones option; AAAA; wildcards; TTL; other record types | first real consumer / dual-stack host |
| Cross-host routing (service on A, gateway B) | real consumer; lint rule holds the door open |
| `lan` network type + identity for LAN clients (internal CA / mTLS — a LAN address carries no identity signal); L4 protocols (`tcp`/`udp`/`grpc`) | first LAN-only / L4 consumer |
| Identity on `internet` endpoints (forward_auth against an IdP / OIDC) | first internet endpoint that wants framework auth rather than app auth |
| Additional shared option types (`data`, `health`, `metrics`, `logs`, `schedule`) | designed alongside their consumer module |
| Backup as a framework concern; state migration (`service move`) | not foreseeable |
| Operator key recovery beyond passphrase (Shamir, hardware) | use case surfaces |
| Framework-managed remote builders (`fleet.builders.<system>` reserved, unclaimed) | a consumer informs the design |
| Passphrase rotation verb | use case surfaces; manual rekey covers it |
| Tags/CHANGELOG/SemVer | first external consumer |

---

## Rejected (final unless explicitly overturned)

Architecture:

- **Facet system / registry / `byName` indexes** — `mkOption` is
  the publish, `config` the subscribe.
- **Two-pass fleet eval** — one-pass (principle 13).
- **`mkFleet { root }` reading config from disk** (identity/hosts
  imported by convention); any `pathExists`/`readDir` in framework
  eval; `hosts/<n>/home.nix` auto-detect — all replaced by
  explicit Nix values/options (principle 14). Distinct from the
  *adopted* layout defaults: computing default paths off
  `inputs.self` is fine; importing config by convention is not.
- **Profile-by-string with name resolution** — attr references
  only.
- **À-la-carte platform module exports** — single bundle per
  platform.
- **Forker re-declaring heavy inputs** — transitive via
  `inputs.nixhold.inputs.*` + follows idiom.
- **Module self-imports via flake inputs** — relative paths
  inside the framework.
- **In-tree dogfood** — out-of-tree keeps dogfooder UX = forker
  UX; CI fixture covers contract drift.
- **Host `kind`/`type`/`primary` fields** — profile is the kind;
  VPS-ness derives from declarations; no primary (principle 16).
- **`fleet.defaults.{timezone,locale}`** — hosts set options
  directly.
- **`identity.autoConfigure = false`** — opinionated by design.
- **Open/freeform fleet schema** — closed; forkers declare their
  own namespaces.

Secrets:

- **Pluggable secrets backend** — agenix is the framework.
- **Filename-glob secret discovery; `ssh-*` name triggers;
  `nixhold.ssh.keys`** — names never carry behavior; `sshKey` /
  `sshIdentity` options instead.
- **`mkAgeSecret` builder function** — the options API derives
  name/host from context.
- **Multi-operator / per-secret ACLs** — solo framework.

Network:

- **`addressOf` auto-picking a shared network** — callers name
  the network; implicit resolution was a debuggability hazard.
- **Address helper function instead of typed option** —
  options give introspection for free (principle 10).
- **`derived.fqdn` endpoint mirror** — endpoint FQDNs live on the
  service; cross-host wiring uses `derived.address`.
- **`expose.<x>.routes` per-path backend map** — multiple
  endpoints share a vhost via `pathPrefix`.
- **`auth` mode / allow-list on expose** — auth is derived from
  the network type (Tailnet identity auth); the endpoint field is
  a bool opt-out only. An allow-list would restate Tailscale ACLs;
  a mode would restate the network type.
- **DNS provider abstraction layer** — pattern-match on a type
  enum; add branches per provider.
- **Automated DNS provisioning in v1** — declare-only
  (`derived.records`); providers push later.
- **Headscale control plane** — shifts work from one-time SaaS
  signup to an operated service; WireGuard is E2E regardless.
  Foundation kept: a future `controlServer` field →
  `--login-server`. Revisit on sovereignty demand / 100+ devices
  / free-tier changes.

Install & deploy:

- **LUKS / dropbear-initrd** — threat model doesn't justify it;
  power users bring `--disko-from`.
- **Sub-disk install choices in the wizard** (dual-boot /
  install-into-free-space / root-size prompt) — disko and
  nixos-anywhere format the whole declared disk; adopting
  existing partitions is unsupported territory. One shape,
  whole disk; dual-boot machines are hand-partitioned outside
  the framework, custom sizes via `--disko-from`.
- **VPS provisioning/lifecycle verbs** — provider tools do it.
- **`recover` verb** — DR is existing verbs + judgment,
  documented.
- **`CHANGE_ME` markers; facter stubs** — hardware files are
  install-time outputs.
- **Prompt-to-commit after install** — auto-commit, restricted to
  the two generated hardware files; `--amend` to override.
- **Target-driven install** — ~~rejected~~ **overturned**: "the
  primary always drives" conflicted with "no primary machine".
  Local install on the ISO is now the *default* mode (guarded by
  the installer-environment marker); the passive-SSH path
  survives as `--remote`. Still rejected: hostname
  auto-detection, and unguarded local install on fleet machines.
- **`--here` / `--install-here` as explicit flags** — superseded
  by local-as-default + the environment guard + the no-name host
  picker; the flags added surface without adding meaning.
- **`gh` device-flow auth on the ISO** — briefly the design;
  replaced by the operator-encrypted repo deploy key
  (`keys/repo.key.age`): the passphrase alone covers clone +
  push, no second device, no `gh` in the tool belt.
- **Boot-to-wizard auto-launch on the ISO console** — the ISO
  boots to a root shell with a banner naming the one command;
  auto-launching the wizard on tty1 was considered and declined
  (a live shell is the more predictable default).
- **Merging `init` into `host install`** — per-fork vs per-host
  steps stay distinct.
- **linux-builder on the Mac; framework remote builders;
  `deploy --build-host`** — each machine builds its own closure;
  raw `nixos-rebuild` is the escape.
- **Remote darwin deploy** — local-only; refuses clearly.
- **Separate `diff` verb** — `deploy --dry-run`.

CLI:

- **Compiled (Go/Rust) or Python CLI** — bash + gum is the home
  turf; structured data belongs in Nix.
- **Many flake apps pretending to be one binary;
  per-subcommand apps** — one dispatcher.
- **`dialog`/`whiptail`; bashly codegen; rich output theming** —
  gum; readable bash; plain text.
- **CLI as separate repo/flake** — ships with the framework.
- **`nixhold.cli.enable`** — `programs.nixhold.enable`.
- **Extra verbs (`identity init`, `bootstrap`)** — covered by
  `init` and the install/bootstrap flows. (`update` was in this
  entry too — overturned: fleet-root resolution turned it into a
  real from-anywhere workflow; see the CLI section.)
- **Eval caching / `--fast`** — nix's eval cache is the cache.
- **Doc generator** — option descriptions + `nixos-option`.
- **Stability tags in descriptions** — only with enforcement
  machinery.
- **Web dashboard / UI; runtime status over SSH** — status stays
  declaration-side; CLI is enough.

Observability:

- **Shipped monitoring/alerting/log-aggregation stack, Grafana
  dashboards, alerting integrations, `nixhold.observability.*`
  reservation** — forker-composed; namespace reserved when a
  consumer lands.

Platform breadth:

- **Cloud-provider abstractions; container orchestration** — out
  of scope for personal infra.
