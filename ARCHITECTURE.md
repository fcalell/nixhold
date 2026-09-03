# nixhold — architecture

The architecture of nixhold as implemented. Every decision here is
the current one, the best shape known when it was written; code
implements this document. Planned work lives in ROADMAP.md. To
change the architecture, whether planned or because the work shows
a better shape: draft the change here, surface 2–4 decisions for
the operator, edit, then implement.

Format notes for readers (human or LLM): decisions are stated once,
in the section that owns them. "Rejected" entries at the bottom
record shapes turned down and why. Field shapes are given as tables; the implementation in
`modules/` and `cli/` is the reference for exact code. Operator
runbooks and fleet-specific wishlists live in consuming fleet repos,
not here.

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
| `networks` | `{ <name> = { type, magicDnsSuffix?, domain? }; }` |
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
  lint warns about the absent deploy key.
- **Lint is not a flake check.** It shells out to `nix eval` and
  can't run inside a pure flake-check sandbox. Build-blocking
  invariants are module assertions instead; the framework's own
  `checks` are the synthetic fixture fleet (`fixture-server`,
  `fixture-gateway`, `fixture-iso`, `fixture-mac`), which is what
  catches contract drift per commit.
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
- Versioning: pin by SHA.
- Dogfood is out-of-tree from day 1: the author's fleet consumes
  `inputs.nixhold` like any forker.

Framework flake outputs: `lib.mkFleet`, `nixosModules.nixhold`,
`darwinModules.nixhold`, `homeManagerModules.nixhold`,
`profiles.{server,desktopLinux,workstationDarwin}`,
`modules.services.*`, `modules.infra.*`, `apps.<sys>.nixhold`,
`templates.default`, `formatter`, `checks`.

`templates.default` is the fork scaffold: `nix flake init -t` writes
`flake.nix` (a placeholder `mkFleet` call), `hosts.nix`,
`.gitignore`, and empty `secrets/`, `keys/`, `profiles/`, `modules/`
directories.

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
declaration that an A record exists — DNS is operator-managed),
`loginPubkey?` (defaults from committed
`keys/hosts/<host>/identity.pub`, written by the CLI from the
`sshIdentity` secret).

Network fields: `type` (enum `tailscale` | `internet`),
`magicDnsSuffix?` (tailscale), `domain?` (internet).
`localhost` is a built-in pseudo-network, never declared.

Derived views (additions land with their consumer):

| Option | Content |
|---|---|
| `derived.self` | this host's own `fleet.hosts` entry |
| `derived.publicHosts` | hosts with non-null `publicIp`; lint asserts length ≤ 1 (single gateway) |
| `derived.hostsByNetwork` | `{ <net> = [ hosts ]; }` |
| `derived.address.<host>.<network>` | FQDN/IP for reaching host over network, or `null` (visible, not pruned). tailscale → `<host>.<magicDnsSuffix>`; internet → `publicFqdn` else `publicIp`. **No `addressOf` shortcut** — callers spell out the network; null-handling is the consumer's assertion. |
| `derived.operatorAuthorizedKeys` | aggregated `loginPubkey`s; authorized on every host's operator account (root stays closed) |

Framework auto-derivations from topology: ssh `matchBlocks` for
every fleet peer (HostName from `derived.address`, User =
operator, IdentityFile = the host's `sshIdentity` secret);
`programs.ssh.knownHosts` from committed host pubkeys; cross-host
authorized keys; public-interface identification for the firewall.

Validation lives at three layers: option types (shape), module
assertions (build-blocking invariants: endpoint resolution and
routing, secret declaration invariants, service enabled without its
implementation imported, facter report missing), and `nixhold
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
| `description`, `template`, `generator`, `required` | CLI-facing metadata driving `secret edit` and lint | — |
| `homePath` | HM symlink `~/<homePath>` → decrypted path (only with `owner = "user"`) | `.ssh/<name>` when `sshKey`, else null |
| `sshKey` | marks an SSH private key; `.pub` derived at HM activation via `ssh-keygen -y` (failure is loud) | false |
| `sshIdentity` | implies sshKey; ≤1 per host (assertion). THE outbound key: wired as IdentityFile in fleet-peer ssh config; CLI commits its pubkey as `keys/hosts/<host>/identity.pub`, which defaults `fleet.hosts.<host>.loginPubkey` | false |

The framework derives per-entry: the ciphertext's checkout location
`sourceFile` (fleet key + name; existence checks and messages only)
and `file`, the same bytes re-added to the store by content —
what agenix reads; `recipients` (readOnly: operator recipient from
`layout.ageRecipient` + owning host's committed `host.pub`),
`resolvedOwner`/`resolvedMode`, `age.secrets.<name>` activation
wiring, HM symlinks. The option attrset **is** the manifest — the
CLI reads `config.nixhold.secrets` directly; there is no separate
`declared` attribute.

**Ciphertexts enter the store by content.** A layout path is a
subpath of the fleet's own source store path, and its string
context references the *whole* checkout. Handing such a path to
agenix (or any derivation / activation script) would make every
host's ciphertexts, the wrapped operator identity, the deploy key
and every host-key escrow a runtime dependency of that host's
toplevel — world-readable in `/nix/store` for any local account,
which can include an unprivileged kiosk user. So `file` is
`builtins.path` of the single ciphertext, the same idiom the ISO's
`bake` uses. The rule generalises: a flake-relative path is only
ever consulted with `pathExists`/`readFile` (no context) or copied
by content; it never reaches a derivation as-is.

**Host identity is the fleet key.** Everything derived per host —
secret paths, recipients, `derived.self`, committed pubkeys — keys
off `nixhold.fleet.selfName`, the host's attribute name in the
`hosts` argument, which `mkFleet` sets. `networking.hostName` is
only `mkDefault`ed to it: a host renamed by an MDM policy keeps its
ciphertexts, and no two fleet entries can be made to share a
recipient set by an OS-level rename. The MagicDNS FQDN (caddy vhost,
peer addresses) legitimately follows the OS hostname, since that is
what tailscale registers.

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
  violation.
- `secret edit`/`rekey` refuse a recipient set that omits the
  operator, or the host when its `host.pub` is readable or it
  already owns ciphertexts (an untracked `host.pub` is invisible to
  eval; the fix is `git add --intent-to-add`). `$VISUAL`/`$EDITOR`
  are honored as command lines (`code --wait`).

**Host-key escrow (principle 16).**
`keys/hosts/<host>/host.key.age` — the host SSH private key,
encrypted to the operator recipient only — is committed alongside
`host.pub`. Single-writer invariant: `host.pub` and `host.key.age`
are always written together from one private key — by `host add`,
`host rotate-key`, `host key` and `host install`'s backfill — so the
pair can never come from different keypairs. Lint checks the tracked pair in both
directions (missing escrow, orphan escrow; warn dev / error
strict); equality is not provable without the passphrase (age
stanzas carry no fingerprint), the invariant holds it. Install
resolves the key: local cache only while it derives the committed
`host.pub` (a stale cache is set aside), else escrow (passphrase
prompt, verified against `host.pub`). The repo is authoritative,
and one verb applies that: `host key <name>` reads the machine's
live key (in place, or `--remote`), prints what it found, and does
the one thing the state calls for — live key equals the committed
recipient: refresh the escrow from it; the fleet can produce the
committed key (cache or escrow): install it on the machine, the
machine is corrected, never the repo; the fleet cannot and the host
owns no ciphertexts: adopt the live key (escrow + commit, then
rekey); the fleet cannot and the host owns ciphertexts: refuse, that
is a `rotate-key`. `host install` on darwin runs the same
reconciliation before activating (minting a key only for a machine
that has none and a host the fleet has never keyed). `host key` is
also the completion step for a `rotate-key --no-install` and the
non-destructive fix for a drifted machine. A rotation is complete
when the verb exits (repo and machine); the superseded escrow stays
in the key cache as `host.key.age.prev` until the new key is
confirmed installed. On
the ISO, everything that can fail or prompt (key resolution,
secret provisioning) runs before the disk is wiped. Trust delta ≈
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

**Identity resolution.** The operator identity lives in the fleet:
`layout.ageRecipient` (public) and `layout.ageIdentityWrapped`
(passphrase-wrapped private), both committed. Verbs that need the
private half unwrap `$NIXHOLD_IDENTITY_FILE` when it is set (the
ISO bakes it), else the committed copy — a passphrase prompt per
invocation, nothing persisted outside the fleet. A fleet with no
identity yet gets one from the first verb that needs the recipient
(the first `host add`, escrowing the first host key): it generates
the keypair, wraps it with a passphrase, writes both files under
`keysDir` and stages them. There is no init verb. Losing the
passphrase is catastrophic by design.

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
| `protocol` | `https` (default) / `http` / `ws` / `wss`. HTTP-family only |
| `subdomain` | internet networks: vhost = `<subdomain>.<domain>`. **Ignored on tailscale networks** (see TLS). Forbidden on localhost |
| `backend` | required; references `network.ports.<name>` — one endpoint = one (vhost, backend) pair |
| `pathPrefix` | endpoints sharing a vhost carve paths; caddy emits one vhost with a `redir <p> <p>/` and a `handle <p>/*` per endpoint (`uri strip_prefix` inside when `stripPrefix`), so `/tv` never claims `/tvx`; prefixes on one FQDN must not be path-segment prefixes of each other (assertion) |
| `description` | free text for status; recommended on localhost endpoints |
| `extraConfig` | raw Caddyfile lines inside the endpoint's handle block — escape hatch; the model still owns vhost/FQDN/TLS |
| `auth` | bool, default `true`: require the network's identity mechanism (tailscale → node identity, see Tailnet identity auth). `false` is the explicit opt-out. Required-explicit on `internet` endpoints, which have no mechanism yet |

**Tailnet TLS.** `tailscale cert` only issues for the node's own
MagicDNS name, so on tailscale networks the vhost is always
`<host>.<magicDnsSuffix>` and services differentiate by
`pathPrefix`; one node cert covers everything. Cert provisioning
lives in the caddy infra module, emitted only when tailscale HTTP
endpoints exist: a oneshot (`tailscale cert` into
`/var/lib/caddy/tls` after tailscaled is up), a weekly persistent
renewal timer (90-day certs), and a path unit reloading caddy.
Tailnet vhosts use `tls <cert> <key>` + `auto_https
disable_redirects`; internet vhosts use caddy ACME. Apps that can't
live under a subpath set their own base-path option or expose on an
internet network.

**Tailnet identity auth.** A tailnet connection arrives already
authenticated: tailscaled knows the node key and the login behind
every source address, exactly as sshd knows the key behind a
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
app-level auth is that endpoint's own business. Trust boundary =
tailnet membership: on a single-user tailnet that is exactly "a
device the operator enrolled"; multi-user tailnets restrict with
Tailscale ACLs, which are operator-managed like DNS. Backends keep
binding 127.0.0.1, so the only ways in are caddy or the box itself.
whois needs a live tailscaled, so the fixture check covers the
emitted config only; the runtime proof is one request from a tailnet
device and one from outside. Authentication, not authorization: any
non-tagged node of the tailnet passes; which devices may reach the
host is the Tailscale ACL's decision, per-user gating beyond that is
the backend's (the identity headers exist for it).

**Exposure invariants.** caddy's listener is not per-interface: one
`:443` on every address serves every vhost, and what keeps a tailnet
vhost tailnet-only is the interface-scoped firewall rule. An
internet endpoint opens 80/443 everywhere, so a host serving
internet endpoints may not also serve tailnet endpoints that opted
out of auth (assertion) — authenticated ones fail closed on a
non-tailnet source, opted-out ones would be world-reachable under a
valid tailnet cert. The caddy admin API lives on an owner-only unix
socket (`/run/caddy/admin.sock`), never on localhost:2019, where any
local uid could `POST /load` a config without the auth gate;
nixpkgs' reload reads the address from the config, so reloads keep
working. The tailnet cert oneshot retries on failure
(`Restart=on-failure`) so a first boot that precedes the tailnet
join converges, writes cert and key into a staging dir and moves
them into place, and the path unit watches the half moved last;
caddy is revived by that reload-or-restart, not by its own restart
policy.

**Infra consumers** (server bundle): caddy (HTTP endpoints →
vhosts, TLS strategy from network type) and firewall (80/443 tcp+udp
on every interface for internet-network endpoints; 443 tcp+udp
scoped to the tailscale interface for tailnet endpoints — the LAN
stays closed). Both read one derived list,
`nixhold.infra.endpoints` (internal): every non-localhost endpoint
annotated with its resolved backend port, network type and FQDN.
Nothing is filtered silently — an unknown network, a network lacking
the field its type needs, a backend not in the service's ports, a
`subdomain` where the type forbids or requires it, a malformed
`pathPrefix` are assertions, so a typo cannot yield a service the
operator believes exposed that is simply not served. Multi-network
exposure works by declaring endpoints on different networks.

**Single-gateway**: public services run on the host that has the
public IP; lint asserts at most one host declares a `publicIp`.

---

## Operator lifecycle

Prereq: Nix on whatever machine you start from. Once a fleet
exists, the installer ISO is itself a sufficient operator seat.

| Event | Flow |
|---|---|
| L1 fork | `nix flake init -t github:fcalell/nixhold` → fill identity (+ `layout.repoUrl`) → `nixhold host add`. The operator identity is generated on first need (see "Identity resolution"); there is no init step |
| L2 first host | `nixhold host add [<name>]` — the walk: name, arch, profile, networks, key generated + escrowed, entry written to `layout.hostsFile`, missing secrets provisioned, then "install now?" — this machine (on the ISO, or a Mac), over ssh to an address, or later |
| L3 NixOS host | On-prem: boot the fleet ISO on the target, `nixhold host install` → passphrase → "new host…" runs the add walk and installs in place. VPS / from another machine: `nixhold host add <name>` and answer "over ssh" with the address (scripted: `--install root@<ip>`); the fleet ISO makes the target reachable with zero typing, any installer works |
| L4 add service | edit host/profile module → `nixhold deploy <name>` (provisions missing required secrets first) |
| L5 new service module | `nixhold service new <name>` → edit |
| L6 update inputs | `nixhold update` (from any directory): pull → flake update → the inputs that moved, from the lock diff → `deploy`'s host picker → deploy each picked host |
| L7 reinstall/reformat | Boot the ISO, `nixhold host install` → passphrase → pick the host (or `host install <name> --remote root@<ip>` from a fleet machine; the picker there asks for the address). Host key from cache or escrow → identity unchanged → secrets still decrypt → nothing generated. Legacy host whose live key was never escrowed: `host key` on it first |
| L8 rename | manual (`git mv` + edit hostsFile + `secret rekey` + reinstall) |
| L9 remove | `nixhold host remove [<name>]` — deletes fleet entry, hosts/, secrets/, keys/; decommissioning the machine is the operator's job |
| L10 recover | host died → L7. All operator machines lost → clone + passphrase anywhere (or the ISO) is a complete seat. Passphrase lost → catastrophic, regenerate everything (documented, no CLI) |

Properties: one CLI; verb-first; an omitted argument opens a
picker; darwin auto-dispatch from arch; idempotent; repo +
passphrase is the whole source of truth; two install entry points
(local on the ISO by default, `--remote` from a fleet machine), one
phase sequence.

---

**Host-key trust.** The fleet commits every host's key as
`keys/hosts/<host>/host.pub`, so nothing that talks to a fleet host
over ssh accepts a key on first use when a committed one exists.
Every host renders `programs.ssh.knownHosts.<peer>` (bare name +
every derived address) from the committed pubkeys, and the framework
peer matchBlocks set `StrictHostKeyChecking yes` for pinned peers.
The CLI pins the same way (`nh_ssh … --host <name>`: a scratch
known_hosts under the process scratch root, strict checking; a
rotation window additionally accepts the superseded key recorded as
`host.pub.prev` until the new one is installed). Trust-on-first-use
survives only where there is nothing to pin to: a host the fleet
has never seen, and the installer ISO, whose key is random per boot
(`host install --remote` rides nixos-anywhere's own no-check ssh —
install over a LAN you control). A machine running a key the fleet
does not know is unreachable from the CLI by design; reconcile on
the machine (`host key` puts the fleet's key back when the fleet
can produce it, adopts the live one when it cannot), or over the
operator's own ssh after checking the fingerprint out of band. Plaintext key material the CLI
stages lives only under the one 0700 scratch root wiped on
EXIT/INT/TERM/HUP; per-subshell traps are not used for cleanup, since
bash resets them inside `( … )`.

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

One bash CLI, 14 verbs. Access: bare `nixhold` post-install
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
nixhold host add [<name>] [--install <user>@<ip>]
                                                    the walk: name, arch, profile, networks,
                                                    key + escrow, secrets, then "install now?"
nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>] [--disko-from <path>] [--yes]
                                                    reformat a host; the picker adds "new host…"
nixhold host key <name> [--remote <user>@<ip>] [--yes]
                                                    make machine and repo agree about the host
                                                    key (repo wins; adopt when the fleet has none)
nixhold host rotate-key <name> [--remote <user>@<ip>] [--no-install] [--yes]
                                                    new host key, escrow it, rekey that host's
                                                    secrets, install it on the machine
nixhold host remove [<name>] [--yes]
nixhold deploy [<name>…] [--mode switch|boot|test] [--dry-run] [--target <addr>] [--yes]
                                                    no name: pick the hosts; several: in order
nixhold update [--yes]                              git pull → nix flake update → moved inputs
                                                    → deploy's picker
nixhold status [<name>] [--fleet]
nixhold lint [--strict]
nixhold logs [<host>] [<service>] [--lines N] [--since <when>] [--follow]
nixhold secret edit [<host>] [<name>]               missing: provision; present: edit;
                                                    no name: every missing secret on the host
nixhold secret rekey
nixhold service new <name>
nixhold iso [--flash <device>]
```

Rule: each verb is a real operator action, not a flag-shaped
alias. Host listing is `status --fleet`, diffing is `deploy
--dry-run`, secret listing is `status`, secret checking is `lint`,
key reconciliation is `host key` whichever direction the state
calls for.

**Walkthrough shape.** The operator is walked, not quizzed:

- An omitted argument opens a picker built from the fleet view when
  a terminal is attached, and is a usage error when none is (scripts
  pass the arguments). Picking is the confirmation; `--yes` stands
  in for it in scripts.
- Every verb prints its plan before the first write and ends with
  the single next command.
- One fleet-view eval per process: `nixhold.fleet` (hosts, arch,
  networks, derived addresses) is read once from any host into the
  scratch root; pickers, platform dispatch and address resolution
  read it. No per-verb roster probes. A verb that rewrites
  `hostsFile` drops the memo.
- Identity on first need (see "Identity resolution"); required
  secrets on first deploy or install (see `secret edit`).

Notable shapes:

- **Install is local-first.** No `--remote` means install *this*
  machine — guarded by the installer-environment marker the ISO
  sets: outside it, local mode asks for the address of the booted
  installer (or refuses without a terminal), so a fleet machine
  can't be formatted by accident. No hostname auto-detection — the
  guard is the environment marker.
- **`host add` ends in the install question; `host install` is the
  reformat.** The install picker lists every host the machine can
  install (NixOS hosts; a darwin host only on that Mac) plus "new
  host…", which hands off to `host add` — whose own last step is the
  install question. Darwin `host install <mac>` auto-dispatches from
  arch and runs locally.
- disko + facter are install-time outputs (committed on success;
  auto-commit restricted to those two files), never scaffold-time
  placeholders. On the ISO the checkout is ephemeral, so `host add`
  also commits what it wrote there, and both verbs push what they
  committed.
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
their expose endpoints, and each declared secret with its
ciphertext present or missing; `--fleet` = one line per host.
Anything richer is `nix eval` / `nixos-option`. Never a
dashboard; never live systemctl.

### `nixhold deploy`

Daily verb; thin over `nixos-rebuild switch` / `darwin-rebuild
switch`. Local iff `$HOSTNAME == <name>` (reliable: the framework
owns host naming). Remote NixOS: `--target-host` **and**
`--build-host` point at the target — **each machine builds its own
closure**; the operator machine never builds foreign arches
(applies to install too via `--build-on-remote`). Remote darwin:
refused (deploy Macs locally). The address comes from
`derived.address.<name>`: the tailnet entry when it resolves,
otherwise the first non-null address of any other network;
`--target <addr>` overrides (single host only). Modes: switch
(default) / boot / test. Zero, one or several hosts: none opens a
multi-select of the hosts this machine can activate (every NixOS
host; a darwin host only on that Mac), and the selection is the
confirmation; explicit names confirm once as a list unless `--yes`;
several deploy in order, continuing past a failure and reporting at
the end. Required secrets with no ciphertext are provisioned before
the build. `--dry-run` runs `nixos-rebuild dry-build` (darwin:
`check`). Tradeoffs accepted: tiny VPSes may struggle building
(substituters cover most); power users escape to raw `nixos-rebuild
--build-host`.

### `nixhold update`

`git pull --ff-only` in the fleet root (skipped without an
upstream), `nix flake update`, then the inputs that moved — read
from the lock diff, `<input>: <old rev> → <new rev>` — and a hand-off
to `deploy` with no names (`--yes` deploys every eligible host). A
run where neither the checkout nor an input moved stops there. The
lock is never auto-committed; the verb ends with the commit command.

### `nixhold secret edit`

Provision-or-edit, decided by whether the ciphertext exists. Missing:
run `generator` (non-interactive) / open `$EDITOR` prefilled with
`template` / open an empty editor, encrypt to the computed
recipients. Present: decrypt with the operator identity, edit,
re-encrypt to the current recipients. No name: every missing secret
on the host is provisioned in one numbered walk (the plan is printed
before the first editor opens), and when none is missing the
existing ones are offered to edit. `sshIdentity` secrets get their
derived pubkey committed as `keys/hosts/<host>/identity.pub`. The
missing-required walk is what `deploy` and `host install` run
before building, and `host add` runs the full missing walk — at ISO
install time the passphrase is already in hand, so a new host
first-boots with every required secret decryptable, and a reformat
picks up secrets declared since the last deploy (generators run
non-interactively; templates open `$EDITOR` on the console).

### `nixhold lint`

Dev mode warns; `--strict` is the CI gate (exit 3). Rules, one
script each under `cli/lint/rules/`:

- every host's `profile` resolves (a host eval smoke test)
- `derived.publicHosts` length ≤ 1 (single-gateway invariant)
- every `expose.<name>.backend` references a port declared in the
  same service's `network.ports`
- every host that declares secrets has its committed `host.pub`
  among each secret's recipients
- no orphan `.age` file: every `secrets/hosts/<host>/<name>.age`
  has a matching `nixhold.secrets.<name>` on that host
- every `required` secret has ciphertext committed
- secret declaration invariants: `homePath` and `sshKey` only with
  `owner = "user"`; `sshIdentity` implies `sshKey`; ≤1
  `sshIdentity` per host
- every tracked `host.pub` has a tracked sibling `host.key.age`
  escrow and vice versa (warn dev / error strict)
- every layout path (defaulted or overridden) exists in the
  worktree; `layout.repoUrl` set with `keys/repo.key.age` missing
  is a warning

Enforced as assertions rather than lint (they block the build):
unknown network on an endpoint, a network missing the field its
type needs, a backend naming no declared port, `subdomain` where
the network type forbids or requires it, malformed `pathPrefix`,
overlapping path prefixes on one FQDN, two prefix-less endpoints
on one FQDN, one FQDN reached over two network types, `auth = true`
on an internet endpoint, authenticated tailnet endpoints without
`nixhold.services.tailscale.enable`.

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

## Rejected

Shapes turned down, with the reason. Reversing one is an
architecture change, drafted here like any other, and warranted
once its reason no longer holds.

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
  UX; the CI fixture covers contract drift.
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
- **Automated DNS provisioning** — DNS is operator-managed; the
  framework declares, providers push later.
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
- **`CHANGE_ME` markers in generated files; facter stubs** —
  hardware files are install-time outputs.
- **Prompt-to-commit after install** — auto-commit, restricted to
  the two generated hardware files; `--amend` to override.
- **Hostname auto-detection for install; unguarded local install
  on fleet machines** — local install is the default *on the ISO*,
  guarded by the installer-environment marker; every other machine
  is driven with `--remote`.
- **`--here` / `--install-here` as explicit flags** — superseded
  by local-as-default + the environment guard + the no-name host
  picker; the flags added surface without adding meaning.
- **`gh` device-flow auth on the ISO** — the operator-encrypted
  repo deploy key (`keys/repo.key.age`) covers clone + push from
  the passphrase alone: no second device, no `gh` in the tool belt.
- **Boot-to-wizard auto-launch on the ISO console** — the ISO
  boots to a root shell with a banner naming the one command; a
  live shell is the more predictable default.
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
- **Extra verbs (`init`, `identity init`, `secret bootstrap`,
  `host escrow`, `host install-key`, `profile new`)** — identity on
  first need; provision-or-edit in `secret edit`; one reconciling
  `host key`; profiles are copied, not scaffolded.
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
