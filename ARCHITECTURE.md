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
2. **No primary machine** — repo + an operator route reconstructs
   the entire fleet (principle 16). The operator may have access to
   no existing machine at a given moment; a bootable installer ISO
   plus the passphrase, or the hardware token, must suffice.
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
6. **README principles carry over**: the recipient list is the
   security boundary; composition over inheritance;
   hardware-is-data; no platform branching in modules. That
   boundary is drawn once, around the fleet: every ciphertext is
   encrypted to the operator recipients plus the single fleet key
   every host holds. A secret's `scope` picks the path the
   ciphertext lives at, never who can open it (see "One fleet
   key").
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
    Named path exceptions: `facter.json`, `/etc/nixhold/fleet.key`,
    `flake.nix`, the `.age` extension, committed pubkeys under
    `layout.keysDir` (read at eval to compute recipients,
    authorized keys and known_hosts).
15. **Thin operator glue.** Every verb = reading declared options
    + computing arguments + invoking an underlying tool. Logic
    beyond that needs justification in the verb's docstring.
16. **Repo + an operator route reconstructs the fleet.** No
    machine is special. Every artifact needed to
    rebuild/reinstall/reformat any host is committed (encrypted to
    the operator when private: secret ciphertexts, the fleet key
    at `keys/fleet.key.age`, and the wrapped operator identity
    when the fleet keeps one). The only state outside git is the
    operator's own route to the age identity: a passphrase, a
    FIDO2 hardware token, or both (see "Operator routes"). A
    host's own ssh key is deliberately *not* in that set: it is
    random per install, pins `known_hosts` and decrypts nothing,
    so a lost one costs a single line in `keys/hosts/<host>.pub`.
    What every host needs to read its secrets is the fleet key,
    and the repo is the only place it survives. Plaintext key
    material lives in a verb's scratch root for the span of that
    verb and never at rest. Any host can be installed or recovered
    from the installer ISO + a route.

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
| `layout` (optional) | CLI filesystem contract; every field defaults from `inputs.self`: `secrets` → `/secrets`, `hostsFile` → `/hosts.nix`, `modulesDir` → `/modules`, `profilesDir` → `/profiles`, `hostsDir` → `/hosts`, `keysDir` → `/keys`, `ageRecipient` → `/keys/operator.pub` (the operator recipient *list*, one age recipient per line), `ageIdentityWrapped` → `/keys/operator.age` when that file exists and `null` when it does not (`nullOr path`; see "Operator routes"). `repoUrl` is the one non-derivable field — a bare `owner/repo` slug (github.com assumed, cloned over SSH with the fleet's `identity` key), typed to reject URL schemes and a `.git` suffix since both the remote and `programs.nixhold.fleetDir` are built out of it; required to build the installer ISO, unused otherwise. Defaulting is computed values off `self`, not filesystem discovery (principle 14 intact) |
| `networks` | `{ <name> = { type, magicDnsSuffix?, domain? }; }` |
| `hosts` | `{ <name> = { arch, profile, modules, networks?, disk?, publicIp?, publicFqdn? }; }` |

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
  `layout.repoUrl` set, the `identity` ciphertext present (the
  ISO clones with it), *and* the fleet holding at least one
  operator route (a token recipient line in `layout.ageRecipient`,
  or a non-null `layout.ageIdentityWrapped`). A
  fleet that hasn't reached `nixhold iso` yet simply has no such
  attribute, so `nix flake check` / `nix flake show` stay green;
  `nixhold iso` is the one place that explains what is missing, and
  lint warns when `repoUrl` is set with no `identity` ciphertext
  to clone with.
- **Lint is not a flake check.** It shells out to `nix eval` and
  can't run inside a pure flake-check sandbox. Build-blocking
  invariants are module assertions instead; the framework's own
  `checks` are the synthetic fixture fleet (`fixture-server`,
  `fixture-gateway`, `fixture-node`, `fixture-desktop`,
  `fixture-iso`, `fixture-mac`), which is what catches contract
  drift per commit. Every shipped profile is drawn by a host there:
  a profile nothing builds is a profile nothing checks.
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
- Versioning: the fleet's own `flake.lock` is the pin. The
  template writes the input unpinned (`github:fcalell/nixhold`) and
  the first `nix flake lock` nails it to a revision; `nixhold
  update` is what moves it. No tags, no ref in the url — a ref
  would be a second pin to keep in step with the lock.
- Dogfood is out-of-tree from day 1: the author's fleet consumes
  `inputs.nixhold` like any forker.

Framework flake outputs: `lib.mkFleet`, `nixosModules.nixhold`,
`darwinModules.nixhold`,
`profiles.{server,desktopLinux,workstationDarwin}`,
`modules.services.<platform>.*`, `modules.infra.*`,
`apps.<sys>.nixhold`, `templates.default`, `formatter`, `checks`.

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
  drew. The platform *implementations* stay separate, and the export
  table is keyed by platform: the value behind
  `modules.services.<platform>.<name>` (`modules.services.nixos.*`,
  `modules.services.darwin.*`) is `<service>/<platform>.nix`, which
  re-imports the same declarations and adds that platform's config.
  The import path is therefore what names the platform, so one
  service can ship an implementation on both, as tailscale does.
  Implementations are imported only by profiles or
  `hosts.<n>.modules`. `modules.infra.*` stays flat: infra is
  NixOS-only. Enabling a service whose implementation this host
  never imported is an assertion failure, not a silent no-op; infra
  modules keep the older shape (no options unless imported).
- **Profiles (layer 2)** are opinionated host-kind bundles: import
  service/infra modules, set defaults. Shipped:
  `server`, `desktopLinux`, `workstationDarwin` (matching the
  author's host kinds). Forkers compose their own by importing
  module values; multiple profiles compose via
  `{ imports = [ ... ]; }`. Everything profile-set is overridable
  in the host file. A profile owns the whole shape of its host
  kind, not a starting point for it: `desktopLinux` carries the
  graphical seat end to end — greetd as the session entry,
  hyprland, pipewire + rtkit, portals, graphics, NetworkManager,
  nix-ld, a file manager, the workstation font set, and the wayland
  environment PAM exports (`NIXOS_OZONE_WL`, `XDG_CURRENT_DESKTOP`,
  the toolkit backends) — because a variable set in a compositor
  config reaches that compositor's children and nothing else.
  `workstationDarwin` carries the mac equivalent: Touch ID on
  `sudo_local` (the darwin half of "Sudo asks") and the same font
  set. Every value is `mkDefault`, so a host overrides the one
  option rather than opting out of the profile.
- **Per-host modules (layer 3)** are free-form NixOS/Darwin
  modules (service enables, home fragments, host extras) —
  operator filenames, no framework path conventions. Hardware is
  not in them: the disk is roster data and the facter report sits
  at its default path (see Hardware).
- **Fleet manifest** — the `mkFleet` args attach a profile to each
  host; the manifest reads as "I have a server, a desktop, a
  workstation."

Source-tree layout inside the framework: kind-first
(`modules/<kind>/`), with `nixos.nix`/`darwin.nix` platform
siblings beside each kind's `default.nix`. Nothing self-gates on
`pkgs.stdenv`: the platform baseline names the sibling it wants
(`modules/baseline-darwin.nix` imports `identity/darwin.nix` and its
peers, `baseline-nixos.nix` the `nixos.nix` ones), and a service's
sibling is named by the profile that imports it through the
platform-keyed export table. A module that ends up on a host is one
some module list asked for by path, never one a conditional selected.
The registry is the explicit index + flake output table — no
`readDir`, and no `pathExists` beyond principle 14's named path
exceptions (`facter.json`, `/etc/nixhold/fleet.key`, `flake.nix`,
the `.age` extension, committed pubkeys under `layout.keysDir`).

**Infra activates from data, no `enable` knob.** Every infra
module is in the server-side bundle and guards on the data it
consumes (`mkIf (httpEndpoints != [])`). A host with no HTTP
endpoints runs no caddy. Replacing caddy = writing a parallel
consumer of the same `expose` data, not flipping a flag.

**No service runs as the operator uid.** A service module that
needs a uid gets a dedicated one: `DynamicUser` when the unit owns
nothing but a `StateDirectory`, a static user when file ownership
has to stay stable across restarts. Groups exist per data flow —
one group per "these units share this directory" — never a shared
`services` group, and the operator's primary group `users` is not
a sharing mechanism. The operator's uid is the seat a browser, an
editor plugin, a self-updating binary and the assistant all run
under; a service borrowing it hands every one of them the
service's data and its ability to write the service's state. Not
an assertion: the framework can't tell a deliberate
`User = <operator>` in a host module from an accident, so the rule
is lint rule `10-service-user` (see `nixhold lint`).

**Per-host home-manager**: `nixhold.home.extraModules` (list of
deferred modules), wired into
`home-manager.users.<operator>.imports`. An option, not a
sibling-file convention.

**Claude Code is bootstrapped, not packaged.**
`programs.claude-code-native` (default off, opted into from an HM
fragment) runs the vendor's install script once, when
`~/.local/bin/claude` is absent, and passes it the release named by
`programs.claude-code-native.version` — a pinned default, bumped
like any other framework value. The binary's own auto-updater is
disabled, so the installed version is the declared one and a
rebuild is what moves it. The fetch itself is unverified: the
vendor publishes no checksum for the script, so this is a trusted
`curl | bash` against `claude.ai` and the framework says so rather
than implying a supply-chain guarantee it does not have. A failed
fetch warns and the next activation retries; it never aborts
activation.

**Identity auto-wiring (principle 3).** What one `identity` sets,
all `mkDefault` unless named:

| Surface | Wiring |
|---|---|
| system user | name, home, gecos = `fullName`, uid 1000, shell zsh (named exception: normal priority) |
| groups | `wheel` at normal priority (a fleet's own list merges rather than replaces), plus `networkmanager` whenever NetworkManager is enabled |
| nix | `trusted-users`; `nix-command` + `flakes` enabled in the baseline, since every verb needs them on every host |
| home-manager | the user's HM module; `home.stateVersion` tied to the system's on NixOS; git author `name = username`, `email = email`, gated on `programs.git.enable` |
| console password | `nixhold.secrets.password` declared by the NixOS identity module, `required = true` there (it is the way in when ssh is not), **fleet scope** — one password for every NixOS host (see Secrets) |
| outbound ssh | `nixhold.secrets.identity` — the fleet's single outbound key, **fleet scope**. `IdentityFile ~/.ssh/identity` on every fleet-peer matchBlock, gated on the secret being `active`; never `IdentitiesOnly`, there or in the framework-owned `Host *` block, so an agent-held token key is offered alongside it (see "Login keys") |
| git signing | `programs.git.signing = { format = "ssh"; key = "~/.ssh/identity.pub"; }`, gated on `identity.active` + `programs.git.enable`. Named, never automatic: `signByDefault` stays off, so `git commit -S` signs and a plain commit does not (see "Signing is opt-in") |
| global env | `nixhold.secrets.env` (fleet scope) sourced into every login shell of the operator, both platforms, gated on `env.active` (see Repositories & env) |
| forge ssh | one matchBlock per distinct forge host derived from `nixhold.repositories.*.url`, plus github.com for the fleet repo itself whenever `layout.repoUrl` is set — `IdentityFile ~/.ssh/identity`, `IdentitiesOnly`, no `User` |
| sudo | nothing. `wheel` membership is the whole grant; the framework writes no `security.sudo.extraRules`, so sudo asks for the operator's password like it does on any NixOS box (see "Sudo asks") |
| store hygiene | every shipped profile runs weekly `nix.gc` (`--delete-older-than 14d`) and `nix.optimise`; on darwin with the explicit launchd interval `nix.gc.automatic` needs |

**Sudo asks.** The login key activates closures; a password on
sudo is what separates *code running as the operator uid* — the
browser, editor plugins, self-updating binaries, the assistant —
from root. That separation is worth one prompt, so there is no
`NOPASSWD` rule and no `SETENV`. Three consequences, all of them
the framework's job rather than the operator's:

- **The `password` secret is `required = true` on NixOS** — though
  for a reason that outlives any sudo posture: it is the way in
  when ssh is not. A host with no console password is unreachable
  the moment the network is (an unjoined tailnet, a broken
  interface, a reformat at the machine's own keyboard), with a
  locked account and no way to log in and fix it. Requiring it
  costs nothing past the first host: `password` is fleet-scoped,
  and the first `host add` mints the one ciphertext before any host
  is installed, so every later host finds it already provisioned.
- **Every remote verb that elevates allocates a tty**, so the
  prompt lands on the operator's terminal: `host key --remote`,
  `logs` and the fleet-key helpers' remote `sudo cat` / install
  all run `ssh -t`, and `deploy` passes
  `nixos-rebuild --ask-sudo-password` where the installed
  nixos-rebuild supports the flag, `NIX_SSHOPTS=-t` where it does
  not. One prompt per host per verb is the accepted cost; a verb
  that touches several hosts prompts several times.
- **The console password is the recovery path.** It is what the
  operator types at the machine's own keyboard when the tailnet
  has not joined and ssh is scoped to it (see "sshd exposure
  follows the topology" under Network exposure).

---

## Repositories & env

The operator's working checkouts are declarations, not manual
clones. One option names them; ssh identity, the clone, the env
file and its direnv loading all follow (principle 3, the same
auto-wiring shape as identity).

```nix
nixhold.repositories.<name> = "<url>";        # or { url; path?; key?; }
nixhold.home.repositoriesDir = "~/projects";  # default; sits next to
                                              # nixhold.home.extraModules
```

A bare string is the url; the submodule adds `path`, defaulting to
`<repositoriesDir>/<name>`, and `key`, the algorithm of the outbound
key the forge takes (`ed25519`, the default, or `rsa`; see "One
outbound key, and a named exception"). Both are normalised into a
readOnly derived `{ url, path, key }` per repository — the one shape
every consumer below reads.

| Derived | From |
|---|---|
| `nixhold.secrets.<name>` | fleet scope, `category = "repository"`, owner user, `required = false`, described by name + url. Colliding with a non-repository secret of the same name is an assertion |
| one HM `programs.ssh.settings."<forge host>"` per **distinct** forge host | the url's host, parsed from scp-like `user@host:path` and `ssh://user@host/path` (https urls get none), and github.com for the fleet repo itself whenever `layout.repoUrl` is set — the checkout the CLI clones is no declared repository, but its forge takes the same key, so a host that declares nothing still reaches the fleet as the fleet. `IdentityFile = "~/.ssh/<key secret>"; IdentitiesOnly = true;`, `mkDefault`, gated on that secret's `active` — and **no `User`**: the url carries it. Every repository on one forge host names the same `key` (assertion) |
| `nixhold.secrets.identity-<key>` | for every `key` a repository names other than `ed25519`: `sshKey = true`, `sshKeyType = <key>`, and `mkDefault` fleet scope, `category = "framework"`, owner user, `required = false` — the same posture as `identity` |
| `~/.config/direnv/lib/nixhold.sh` | an HM `xdg.configFile` direnv library, emitted only under `mkIf programs.direnv.enable` (the framework never enables direnv). For the directory being loaded it finds the declared repository path containing `$PWD` (longest prefix wins, `~` expanded) and `dotenv_if_exists`es that repository's decrypted age path |
| an HM activation step per repository | after `writeBoundary`: clone the url to `path` when `path` is absent and the repository's key file is readable, then write a managed empty `.envrc` when there is none, append it to `<path>/.git/info/exclude` once, and `direnv allow` when direnv is available |

**The first clone is not TOFU.** Both baselines pin github.com's
published SSH host keys in `programs.ssh.knownHosts` (see Host-key
trust), so the activation step below authenticates the forge
against a committed key on a host that has never talked to it.
A forge the framework does not pin is the operator's to add.

**The clone skips loudly, never fails.** `~/.ssh/identity` may not
be readable yet — agenix on darwin decrypts asynchronously under
launchd, and a first activation runs before the operator has
provisioned the key at all — so the step prints why it is skipping
and exits 0. The next activation clones. It never pulls, and it
never touches an existing `.envrc`: the framework's write is a
comment pointing at the direnv library, and the exclude entry
keeps it out of a repo whose other contributors never asked for
it.

**One outbound key, and a named exception.** The fleet has one
outbound key, `identity`, and registers it everywhere. Per-forge
*users* never justify a second key: forges that need one already
put it in the url (CodeCommit's grant-specific user is the ssh
username); that is why the derived matchBlock deliberately omits
`User`, and why there is no `nixhold.forges`. What does justify one
is a forge that cannot take the identity's **algorithm**: AWS
CodeCommit accepts only ssh-rsa (2048 to 16384 bits), so no
registration of an ed25519 key ever works there. For that case a
repository names the algorithm, `key = "rsa"`, and the rest
follows: the framework declares `identity-rsa` — fleet-scoped,
framework-owned, `sshKeyType = "rsa"`, not required — the forge's
block names it instead of `identity` once it is provisioned, and
the clone waits for it. The key is per *algorithm*, not per
repository or forge: two forges that both need rsa share
`identity-rsa`, exactly as every ed25519 forge shares `identity`.
The manual step is the same one: `nixhold secret edit identity-rsa`
mints the key and prints the pubkey to register on that forge,
**once** (CodeCommit mints an ssh key ID on upload; that ID is the
url's user). `keys/login.pub`, commit signing and the fleet repo's
own clone stay on `identity`.

The only manual step in the whole chain is registering an outbound
pubkey on each forge — **once**, for both auth and signing, and
never again when a machine joins. The CLI prints that line when it
mints the key, and on a fleet with no login keys of its own the
`identity` line is also what `keys/login.pub` is seeded with (see
"Login keys").

**Signing is opt-in.** `signByDefault` stays off, so a plain
`git commit` writes an unsigned commit and `git commit -S` signs
with the identity key. The framework still names `format` and
`key`, so the opt-in needs no further configuration.

Signing every commit by default cost more than it proved. The
signature is made with the key that already authorized the push:
one key does auth and signing (see "No forge keys"), so possession
of it is what the transport established before the commit object
was written. What it detects is a forge-account compromise that
does not include the ssh key — a stolen token, a session, a commit
authored in a web UI — and that detection only pays out on a fleet
whose branch protection requires signed commits.

Against that, `signByDefault` gates every commit on a file that
only exists after a deploy. `identity.active` means the ciphertext
is committed, not that this machine has decrypted it, so a fresh
host, a fresh checkout, and every verb running between `secret
rekey` and the deploy that follows it have signing on and no key.
A CLI verb that commits its own generated files dies mid-way
there, which is the worst moment to fail: the files are written
and the commit is not. An opt-in has no such window, and a fleet
that wants signed history turns it on in its own HM config
alongside the branch protection that makes it mean something.

**Env is opaque.** Neither the global `env` secret nor a
repository's is a Nix-declared list of variable names: they are
`KEY=value` files, edited with `nixhold secret edit`, sourced
wholesale (`set -a`). Declaring the names in Nix would put half of
each pair in the repo in cleartext and buy nothing the file does
not already say — and a repository's env changes far more often
than its host's closure should.

---

## Fleet data — `nixhold.fleet.*`

Typed option tree on every host: `hosts` + `network` (raw
topology, forker-set via mkFleet), `derived.*` (framework-computed
readOnly views), `nixhold._internal.*` (not for consumers).
Schema is **closed** (strict submodules, no freeform); forkers
needing custom per-host data declare their own `options.myorg.*`.

Host fields: `arch`, `profile` (deferredModule), `networks`
(default: every tailscale-typed network the fleet declares — the
name `tailnet` is the forker's, never the framework's), `disk?`
(the install target as a `/dev/disk/by-id` path, written by `host
install`; see Hardware), `publicIp?`, `publicFqdn?` (the name an
A record exists for — DNS is operator-managed; defaults to
`<host>.<domain>` when the host is on exactly one internet-typed
network that declares a `domain`, which is also the record the
DNS declaration contract will emit). There is no per-host login
key field: who may log in is one fleet-wide list, `keys/login.pub`
(see "Login keys").

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
| `derived.operatorAuthorizedKeys` | the lines of the committed `keys/login.pub`, and `[ ]` when that file is absent. Authorized on every host's operator account (root stays closed) |

**Login keys.** `keys/login.pub` is the whole answer to "who may
log in": one committed file, one ssh pubkey line each, `#`
comments and blank lines ignored, read at eval as a layout-path
exception (principle 14) into `derived.operatorAuthorizedKeys`.
Every host authorizes exactly those keys and the installer ISO
bakes the same list for root, so the seat the ISO offers is the
seat the fleet authorizes. An empty or missing file authorizes
nobody — lint says so, because an ISO built from it boots
unreachable.

The file is separable from the outbound key on purpose. By default
the fleet's one `identity` key does both jobs, and the CLI seeds
`login.pub` with its pubkey line the first time it mints the
secret — so a fleet that never thinks about this keeps the "one
key does everything" posture. The reason to list something else is
hardware: a resident FIDO2 credential (`ssh-keygen -t ed25519-sk
-O resident -O verify-required` is the recommended shape) is a
login key the repo cannot hold and a stolen checkout cannot use,
which is the one property the `identity` key can never have. Such
a fleet appends the sk line to `login.pub` and deploys; whether it
also keeps the `identity` line there is its own call. Adding a
line is an edit and a deploy, never a rekey — login keys are ssh,
and no age recipient set moves with them.

The fleet-peer matchBlocks need no switch for any of this: they
set `IdentityFile ~/.ssh/identity` whenever the `identity` secret
is active and never set `IdentitiesOnly`, so an agent-held token
key is offered alongside the file-backed one and whichever the
host authorizes wins. Recovering a resident handle onto a new
machine (`ssh-keygen -K`) is a runbook line on the fleet side, not
framework work — the handle is a file only the token can produce.

**The framework owns the `Host *` block too**, for the same
reason: `IdentitiesOnly` there applies to every named block under
it, so a fleet setting it globally would restore exactly the
lockout the peer blocks avoid, and it would do so invisibly —
nothing in the generated file says which block decided. The
framework therefore declares the client defaults itself
(`enableDefaultConfig = false` plus a `settings."*"` of
`AddKeysToAgent yes`, no agent forwarding, no compression, no
connection multiplexing, `known_hosts` unhashed at its usual
path), each directive `mkDefault` so a fleet overrides one line
without restating the block. The accepted cost is the other half
of the trade: with no `IdentitiesOnly` at the top, ssh offers
every agent-held key to every host it connects to, so an unrelated
server learns which pubkeys the operator holds. Forge blocks pin
themselves regardless, so what widens is fleet peers and ad-hoc
hosts. A fleet that would rather have the tighter posture sets
`IdentitiesOnly` itself and accepts that its token then needs a
file at a default identity name on every machine — an artifact the
repo cannot hold, which is why it is not the default.

Framework auto-derivations from topology: ssh `matchBlocks` for
every fleet peer (HostName from `derived.address`, User =
operator, IdentityFile = `~/.ssh/identity`, the fleet's one
outbound key); `programs.ssh.knownHosts` from committed host
pubkeys; cross-host authorized keys; public-interface
identification for the firewall.

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

Hardware is data, generated by `nixhold host install` from the
target's real machine. Two artifacts per NixOS host, neither
authored nor imported by the operator:

- **The install disk** — `hosts.<n>.disk`, a `/dev/disk/by-id`
  path in the roster, written by the disk picker. The framework
  renders the one shipped layout from it into `disko.devices`:
  whole disk, GPT, 1G ESP mounted `umask=0077` (kernels and the
  loader's random seed are not for other local accounts) + ext4
  root, no encryption. The disko module is in the NixOS baseline; a
  host with `disk = null` and no `disko.devices` of its own is an
  install-time error, never a placeholder. What the shape implies is set alongside it
  (`mkDefault`): systemd-boot with EFI variables, and zram swap,
  since the layout has no swap partition.
- **The facter report** — `nixhold.hardware.facterReport` defaults
  to `<layout.hostsDir>/<host>/facter.json`, a computed subpath like
  every layout default; install writes it there.

Custom layouts (LUKS, mirrors, sizes, a second OS on the same
disk) are a `disko.devices` declaration in the host's own module
with `disk` left null; install then skips the picker and formats
what the declaration names. There is no file to copy into place.

**A second OS on its own disk is inside the shape.** The framework
formats only the declared disk and never touches a sibling drive;
a shared data disk is an ordinary `fileSystems` entry. Two things
make it a walked path rather than a hazard: the picker mounts the
chosen disk's ESP read-only and, when it holds another OS's boot
files (`EFI/Microsoft`, or any loader that is not systemd-boot's),
names that OS and requires a second explicit confirmation — that
OS stops booting when its loader is erased, and should be moved
to its own ESP first; and when such an ESP sits on a *non-target*
disk the picker prints the one line that chainloads it,
`boot.loader.systemd-boot.windows.<n>.efiDeviceHandle`. The
handle is readable only from the UEFI shell (`map -c`), so it is
operator-set in the host module and the framework wraps nothing;
the firmware boot menu works with no configuration at all. A
second OS on the *same* disk stays outside the framework: disko
rewrites the whole partition table of the disk it is given.

**Disk picker UX.** The operator never types or copies a device
path. The picker lists whole disks with size, model, bus, and a
*current-contents* summary (partition table, filesystem labels,
detected previous install, or "empty") so the choice is about
content, not device names; the destructive confirmation lists the
exact partitions about to be erased. The CLI resolves the pick to
a stable `/dev/disk/by-id` path itself and writes it into the
roster. `--disk <by-id>` exists only to skip the prompt in
scripted runs. The picker runs on every install: the roster `disk`
is its output, never its input, so a stale or hand-written value
cannot steer a reformat and there is no "reuse the roster disk"
question to get wrong. Lint reports a roster disk that is not a by-id
path: a warning in dev, an error under `--strict`.

**Facter guard**: NixOS-only (Darwin setting it is an eval error).
File exists → framework sets `hardware.facter.reportPath`. File
missing → eval still succeeds (lint/status work) but build is
blocked by an assertion pointing at `nixhold host install`. This
is what lets nixos-anywhere evaluate the disko script, kexec,
generate the report, then build.

---

## Secrets

Agenix is part of the framework.

**One fleet key.** The fleet owns exactly one age identity —
`keys/fleet.key.age`, a native X25519 key generated by
`age-keygen` and committed encrypted to the operator recipients —
and every host holds it at `/etc/nixhold/fleet.key`. Every
ciphertext the CLI writes under `secrets/` goes to the same
recipient set: every line of `keys/operator.pub`, plus the one
line in `keys/fleet.pub`. No recipient set varies per host, ever.

The trade-off is accepted and worth stating plainly: **any host
can read every secret.** A compromised machine can open another
machine's service credentials, which per-host recipient sets would
have prevented. At 1–10 machines one operator owns, that boundary
was largely fictional anyway — `identity`, `env` and `password`
are fleet-scoped and reach every host by design, so a compromised
host already held the fleet's outbound ssh key and console
password. What the per-host set cost was paid continuously: a
recipient union no single host's eval could compute, a committed
sidecar to record it, a widening rekey on every host add and
install, a shrinking rekey on every remove, an escrow of each
host's ssh key so a reinstall could reproduce it, and a rotation
verb to go with it. One key deletes all of that. `secret rekey` is
now needed only when `keys/operator.pub` changes or the fleet key
rotates — never when a machine joins or leaves.

**The committed files.** Everything the model needs is in the
repo, under `layout.keysDir` (`keys/`) and `layout.secrets`
(`secrets/`):

| File | What | Encrypted to |
|---|---|---|
| `keys/operator.pub` | the operator recipient *list*, one age recipient per line (`age1fido2-hmac1…` token lines, the passphrase identity's `age1…`, or both); `#` comments and blank lines ignored | public |
| `keys/operator.age` | the operator's age identity, passphrase-wrapped. Optional — a token-only fleet commits none | passphrase (scrypt) |
| `keys/fleet.key.age` | **the fleet key** — the one identity every host decrypts with | the operator lines alone |
| `keys/fleet.pub` | its recipient line | public |
| `keys/login.pub` | ssh login pubkeys, one per line: authorized for the operator on every host and for root on the ISO (see "Login keys") | public |
| `keys/hosts/<host>.pub` | that machine's ssh host pubkey, for `known_hosts` pinning only. Random per install, never a recipient, never escrowed | public |
| `secrets/<name>.age` | a fleet-scoped ciphertext | operator lines + `fleet.pub` |
| `secrets/<host>/<name>.age` | a host-scoped ciphertext | operator lines + `fleet.pub` |

`keys/fleet.key.age` is the only file encrypted to the operator
lines *alone*. On every host the key lands as
`/etc/nixhold/fleet.key` (root, 0400) next to
`/etc/nixhold/fleet.pub` (0444, the public recipient line) — so a
verb can ask which key a machine holds with one `cat`, without
opening a route. Both platforms set `age.identityPaths =
[ "/etc/nixhold/fleet.key" ]`: agenix decrypts with `age -d -i`,
which takes a native age identity as happily as an ssh key.

**One declaration pattern** — everything is
`nixhold.secrets.<name>`. No filename-glob magic, no parallel
SSH-key option. Names never carry behavior; behavior is always an
explicit option.

**A secret is owned and named by whatever consumes it.** The
operator never names a secret in Nix: a secret is declared by the
module that reads it, named after that thing, and exists only
while that thing is on. The operator's host file declares service
enables and `nixhold.repositories` — the secrets follow.

| Declared by | Name | Scope | Use |
|---|---|---|---|
| framework identity module, every NixOS host | `password` | fleet | console hash for the operator — the way in when ssh is not |
| framework, every host | `identity` | fleet | THE outbound ssh key: fleet peers *and* every git forge |
| framework, every host | `env` | fleet | global env file (`KEY=value`) sourced into every operator shell |
| a service module, under `mkIf cfg.enable` | `<svc>` (`<svc>-<slot>` for a second one) | host | `unit`'s EnvironmentFile, or a plain file the module reads |
| `nixhold.repositories.<name>` | `<name>` | fleet | env file direnv sources inside the checkout |
| the operator, directly | anything | either | escape hatch, `category = "operator"` |

Fields:

| Field | Meaning | Default |
|---|---|---|
| `scope` | **a path choice, not a boundary**: `fleet` → one ciphertext at `<layout.secrets>/<name>.age` for the whole fleet; `host` → one per machine at `<layout.secrets>/<host>/<name>.age`, so two hosts running the same service do not collide. Recipients are identical either way (operator lines + `fleet.pub`) | `host` |
| `owner`, `mode` | runtime ownership | `"user"` → operator + `0600`; root + `0400` when `unit` is set |
| `description`, `template`, `required` | CLI-facing metadata driving `secret edit`/`secret list` and lint | — |
| `required` | false means *optional*: the walk lists it, never prompts for it unless named | true for service declarations and for `password`, false for the other framework ones |
| `category` | enum `framework` \| `service` \| `repository` \| `operator`; set by the declarer, groups the CLI's output | `operator`; `service` (mkDefault) when `unit` is set |
| `generator` | shell command whose stdout is the initial content; runs instead of an editor when the ciphertext is missing | a keygen of `sshKeyType` when `sshKey` (pubkey printed for registration), else null |
| `homePath` | HM symlink `~/<homePath>` → decrypted path (only with `owner = "user"`) | `.ssh/<name>` when `sshKey`, else null |
| `sshKey` | marks an SSH private key: generated at provisioning unless the operator chooses to paste one, `.pub` derived at HM activation via `ssh-keygen -y` (failure is loud) | false |
| `sshKeyType` | the algorithm the default generator mints: `ed25519`, or `rsa` (4096 bits) for a forge that cannot take ed25519. Read only with `sshKey` | `ed25519` |
| `unit` | NixOS only: `systemd.services.<unit>.serviceConfig.EnvironmentFile += [ <age path> ]`, gated on `active`. Mutually exclusive with `homePath`/`sshKey` (assertion) — systemd reads the file as root, a home symlink is the operator's | null |

The framework derives per-entry: the ciphertext's checkout location
`sourceFile` (scope + name; existence checks and messages only)
and `file`, the same bytes re-added to the store by content —
what agenix reads; `recipients`, `resolvedOwner`/`resolvedMode`,
`age.secrets.<name>` activation wiring, HM symlinks, unit
EnvironmentFiles. The option attrset **is** the manifest — the CLI
reads `config.nixhold.secrets` directly; there is no separate
`declared` attribute. Each entry carries `scope`, `category`,
`unit`, `required`, `active`, `sshKey`, `description`,
`sourceFile`, `recipients`, `homePath`, `owner` for the CLI to read.

**Recipients are computable from one host's eval.** A host's eval
cannot know which *other* hosts declare a fleet-scoped secret
(principle 13: one-pass, no global view) — and with one fleet key
it no longer has to. `recipients` is the lines of
`keys/operator.pub` plus the line in `keys/fleet.pub`, both read
from committed pubkeys at eval (principle 14's named exception),
identical on every host and for every secret. There is nothing to
union, so there is nothing to record: no `.recipients` sidecar, no
lint rule keeping it in step, and no state that can go stale
between a ciphertext and a roster. Age stanzas still carry no
recipient fingerprint, but the question the sidecar answered —
"does this ciphertext reach that host?" — has one fleet-wide
answer now, and `keys/fleet.pub` is it.

**Framework-declared secrets.** A few secrets every fleet needs
are declared by the framework, so a forker never writes them:

| Secret | Declared by | Shape |
|---|---|---|
| `password` | NixOS identity module | **fleet scope**, owner root, **`required = true`**, generator `mkpasswd -m yescrypt` (prompts on the TTY, emits the hash); wired to the operator's `hashedPasswordFile`. Declared by the NixOS half only, so a Darwin-only fleet never provisions it. Required because it is the way in when ssh is not: a box with no console password is unreachable the moment the network is (unjoined tailnet, broken interface, a reformat at its own keyboard), with a locked account and nothing to log in as. It costs nothing past the first host — the first `host add` mints the one ciphertext before any host is installed, and every later host reads that same file |
| `identity` | secrets baseline, both platforms | **fleet scope**, `sshKey = true`, `required = false`. The fleet's single outbound ssh key: `IdentityFile` on every fleet-peer and forge matchBlock, git signing key, the credential the installer ISO clones the fleet repo with, and — on a fleet that lists nothing else — the line `keys/login.pub` is seeded with when the CLI mints it. One ed25519 key per fleet, by construction rather than by assertion; the one second outbound key the framework mints is `identity-rsa`, declared by a repository whose forge cannot take ed25519 (see "One outbound key, and a named exception") |
| `env` | secrets baseline, both platforms | fleet scope, owner user (0600), `required = false`. Sourced into every operator shell by system-level shell init on both platforms (`set -a; . <path>; set +a`, guarded on readability), gated on `active`. Its blast radius is every process the operator starts from a login shell — editor, browser, build, assistant — so it holds what genuinely belongs to the whole seat; anything narrower goes in a repository's own env, which direnv loads only inside that checkout |
| `<authKeySecret>` | tailscale service when the option is set | host scope, owner root, 0400, `category = "service"`; the join unit retries on failure every 30 s, so a late network or a slow control plane converges and only a spent key stays failed |

The framework knowing the literal names `identity` and `env` does
not violate "names never carry behavior" — that rule is about
*operator-chosen* names triggering framework behavior. These are
framework declarations: the framework names them and the framework
reads them, the same relationship any service module has with its
own secret.

Only `password` forces provisioning; the rest are
`required = false`, which keeps the host evaluable before any of
them exist. The first `host add` asks for the required ones up
front and mints `identity` alongside them. **No framework secret
is host-scoped**: host scope exists for service secrets, whose
values genuinely differ per machine. So every later `host add`
mints nothing and rekeys nothing — the ciphertexts are already
there and already reach the new machine, because the fleet key it
will be handed at install is one of their recipients.

**Ciphertexts enter the store by content.** A layout path is a
subpath of the fleet's own source store path, and its string
context references the *whole* checkout. Handing such a path to
agenix (or any derivation / activation script) would make every
host's ciphertexts, the wrapped operator identity and the fleet
key a runtime dependency of that host's
toplevel — world-readable in `/nix/store` for any local account,
which can include an unprivileged kiosk user. So `file` is
`builtins.path` of the single ciphertext, the same idiom the ISO's
`bake` uses. The rule generalises: a flake-relative path is only
ever consulted with `pathExists`/`readFile` (no context) or copied
by content; it never reaches a derivation as-is.

**Host identity is the roster name.** Everything derived per host —
secret paths, `derived.self`, committed pubkeys — keys
off `nixhold.fleet.selfName`, the host's attribute name in the
`hosts` argument, which `mkFleet` sets. `networking.hostName` is
only `mkDefault`ed to it: a host renamed by an MDM policy keeps its
ciphertexts and its pinned pubkey, and no two fleet entries can be
made to collide by an OS-level rename. The MagicDNS FQDN (caddy vhost,
peer addresses) legitimately follows the OS hostname, since that is
what tailscale registers.

Recipient/editing model:

- Activation decrypts with the fleet key
  (`age.identityPaths = [ "/etc/nixhold/fleet.key" ]` on both
  platforms, replacing agenix's host-ssh-key default).
- Editing verbs materialize the recipient set ephemerally and
  drive `age` directly (`age -R` / `age -d -i`); agenix-the-CLI is
  not a dependency; no `secrets.nix` rules file is ever committed.
- Eval paths are store paths; the CLI writes ciphertexts at
  `$fleet_root` + repo-relative subpath (working-tree resolution).
  Only the fleet's own source store path is re-rooted: a layout
  path into another flake input is a hard CLI error and a lint
  violation.
- `secret edit`/`rekey` refuse a recipient set that omits any
  operator recipient or `keys/fleet.pub`. Every ciphertext the CLI
  writes goes to **every** line of `layout.ageRecipient`, so a
  fleet with two routes never has a file only one of them opens,
  and to the fleet key, so no host is ever short of one.
  `$VISUAL`/`$EDITOR` are honored as command lines
  (`code --wait`).
- Every file the CLI writes into the fleet — ciphertexts included
  — is staged (`git add --intent-to-add`) the moment it is written:
  an untracked file is invisible to a dirty-flake eval, so a secret
  provisioned and not staged would still read as missing to the
  build that follows. Committing is the verb's last step (see CLI).

**Getting the fleet key onto a host.** Three verbs install it,
all through one helper. `host install` decrypts
`keys/fleet.key.age` over the operator route — already open, the
clone needed it — and writes `/etc/nixhold/fleet.key` +
`fleet.pub` into `/mnt` before `nixos-install`, so the machine can
decrypt on its first boot; on darwin it writes them in place with
sudo. `deploy` checks before every build: it reads
`/etc/nixhold/fleet.pub` over `ssh -t` + sudo and, when it is
missing or differs from `keys/fleet.pub`, installs the current key
first. That check is what makes `secret rotate` a two-step
operation the operator cannot get half-done — rotate writes the
new key into the repo, the next deploy carries it to each machine
— and what makes a host that missed a rotation self-correct rather
than fail to activate. `host key` runs the same check for a
machine the operator is already correcting for other reasons.

**Host ssh keys are ordinary.** A machine's ssh host key decrypts
nothing; it identifies the machine. The fleet commits only its
public half, at `keys/hosts/<host>.pub`, for `known_hosts` pinning
(see "Host-key trust"). `host install` generates the keypair on
the operator's machine so the pubkey is known and committed before
the target's first boot, writes the private half into the target's
`/etc/ssh`, and keeps no copy; a reinstall mints a fresh one and
rewrites the `.pub`. Nothing is escrowed and nothing is cached, so
a machine whose key the fleet does not recognise is a one-line
correction rather than a recovery: `host key <name>` reads the
machine's live pubkey (in place, or `--remote`) and records it.
The verb is adoption only — the machine is authoritative about its
own ssh identity, the repo is authoritative about everything that
decrypts — and it doubles as the fleet-key check, (re)installing
`/etc/nixhold/fleet.key` when `/etc/nixhold/fleet.pub` disagrees
with `keys/fleet.pub`. On the ISO everything that can fail or
prompt (the operator route, secret provisioning) still runs before
the disk is wiped.

**The clone credential is the `identity` key.** The installer ISO
must clone a typically private fleet repo before any checkout
exists to read, and the fleet already owns an ssh key registered
on the forge for auth and signing: `secrets/identity.age`. The ISO
bakes that ciphertext and exports `$NIXHOLD_CLONE_KEY_FILE`. Every
network-facing git call (clone, pull, push) goes through one
helper: with the variable set it opens the ciphertext over the
operator route into the process scratch root and runs git with it,
otherwise it runs git on the host's own ssh config — which, on
every fleet host, names the same key for the fleet repo's forge
(see Repositories: the `layout.repoUrl` block). The decrypted
key is never persisted into the clone. This is what keeps the
passphrase route a *complete* seat — a passphrase, or a touch, and
the repo is reachable — without a second ssh credential to mint,
register, escrow and rotate.

**Operator routes.** The operator's age identity is reached by one
of two routes, and a fleet may commit either or both. There is no
mode option: the committed files say what exists.

- **Passphrase.** `keys/operator.age` — the private key wrapped
  with a passphrase — plus its recipient line. Unwrapped once per
  process, so one prompt covers every ciphertext a verb touches.
- **Token.** A FIDO2 hardware key, through `age-plugin-fido2-hmac`
  in its no-separate-identity mode (`age-plugin-fido2-hmac -g`,
  PIN required), which mints a recipient of the form
  `age1fido2-hmac1…` and needs no identity file at all: the token
  *is* the identity, and the recipient line is the only thing to
  commit.

`layout.ageRecipient` (default `keys/operator.pub`) is therefore a
**list**: one age recipient per line, any number of token lines
plus, when `keys/operator.age` exists, the wrapped identity's
recipient. Every ciphertext the CLI writes — every secret, and
`keys/fleet.key.age` itself — is encrypted to **every** line, so
any route opens any of them.
`layout.ageIdentityWrapped` is `nullOr path`,
defaulting to `keys/operator.age` when that file exists and to null
when it does not.

**Identity resolution.** One decrypt helper in the CLI picks the
route from what is at hand; no flag chooses, because a flag would
only ever restate what the recipients file and the USB port
already say:

1. the recipient file has a token line, the plugin is installed and
   `fido2-token -L` lists a device → `age -d -j fido2-hmac`: a
   touch, and the PIN, per ciphertext;
2. else a wrapped identity exists → unwrap it once for the process
   with the passphrase (`$NIXHOLD_IDENTITY_FILE` when set — the ISO
   bakes it — else the committed copy), nothing persisted outside
   the fleet;
3. else a hard error naming both routes, since the fleet has none.

The asymmetry is worth stating plainly rather than discovering
mid-verb: a full `nixhold secret rekey` over the token route is one
touch per ciphertext, where the passphrase route is one prompt for
the whole run. So a **bulk** caller — `secret rekey`, `secret
rotate`, anything that opens the whole fleet's ciphertexts in one
pass — asks the picker for the passphrase route first when the
fleet commits both, and single-file opens keep the token-first
order. It is an argument to the route picker, not a flag the
operator passes: which route is cheaper is a property of how many
files the verb touches, and the CLI knows that without being told.
Encrypt-only steps need no route at all — provisioning a secret
that has no ciphertext yet, minting the fleet key, and any other
write that only *adds* a ciphertext run off the recipient list
alone.

**Three fleets, one code path.** Passphrase only (the shape every
fleet starts as), token only, or both. Adding or removing an
operator recipient is an edit to the recipients file plus one
`nixhold secret rekey` — there is no enrollment verb because there
is nothing for it to do. With both routes committed, the security
boundary for whoever holds both stays "repo + passphrase": the
token adds a route, not a wall, and it is worth having for the
machines where the operator would rather touch a key than type a
passphrase, and as a second way in when the passphrase is not to
hand. A token-only fleet narrows the boundary to "repo + a token"
and trades "passphrase lost" for "every token lost" in L10 — so it
enrolls two tokens, kept apart.

A fleet with no identity yet gets one from the first verb that
needs the recipient — the first `host add`, minting the fleet key:
with no recipient line committed it generates a keypair, wraps it
with a passphrase and writes both files under `keysDir`; with a
token line already committed it generates nothing, because the
fleet already has a route. The fleet key follows in the same step,
generated and encrypted to those lines. Either way the files it
wrote are staged. There is no init verb. Losing every route is
catastrophic by design.

**Platform plumbing for the token.** Three things the framework
does unconditionally, since each costs nothing on a fleet that owns
no token:

- the `desktopLinux` profile and the installer ISO module add
  libfido2's udev rules (`services.udev.packages = [ pkgs.libfido2
  ]`), so the seat user reaches the device without root;
- the darwin baseline points the ssh client and agent at the
  Nix-built openssh, because Apple's build ships without sk-key
  support and would refuse an `ed25519-sk` login key outright;
- the CLI package carries `age-plugin-fido2-hmac` and `libfido2`,
  so `age -d -j fido2-hmac` and `fido2-token -L` are on the path
  wherever the CLI is.

`host install` preflights the route before it touches a disk: on a
fleet whose recipient list carries a token line and no wrapped
identity, a token must be visible or the verb stops. The
alternative is a wiped disk and a fleet key nothing present can
decrypt.

**Migrating a pre-fleet-key fleet.** A fleet laid out for per-host
recipients moves in four steps, once:

1. `git mv secrets/shared/<n>.age secrets/<n>.age` and
   `git mv secrets/hosts/<h> secrets/<h>`; `git rm` the
   `.recipients` sidecars, `keys/hosts/*/host.key.age`,
   `keys/repo.key.age` and `keys/identity.pub`;
   `git mv keys/hosts/<h>/host.pub keys/hosts/<h>.pub`.
2. `nixhold secret rekey` — it mints `keys/fleet.key.age` +
   `keys/fleet.pub` when they are missing, opens every ciphertext
   over one operator route, re-encrypts each to the operator lines
   + `fleet.pub`, and seeds `keys/login.pub` from the `identity`
   pubkey when that file is absent. Commit.
3. `nixhold deploy <host>` per host: deploy installs
   `/etc/nixhold/fleet.key` before it switches. Between steps 2
   and 3 a host cannot decrypt — its ssh key is no longer a
   recipient — so do not reboot one in that window.
4. `nixhold iso --flash` to rebuild the image around the clone
   credential, then delete the forge's deploy key.

Lint names the old layout rather than puzzling over it: a
`.recipients` file, a `secrets/shared/` or a `secrets/hosts/`
directory is an error pointing here.

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
| `backend` | required; names a listener the service declares — a key of `network.ports` or of `network.sockets`, never both — one endpoint = one (vhost, backend) pair |
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
`-Profile-Picture` headers are copied to the backend. They are
trustworthy because caddy deletes **every** client-supplied
`Tailscale-*` header on the way in, on every endpoint and before
`forward_auth` runs — so the set a backend sees is exactly what the
daemon returned, and an opted-out endpoint (which runs no daemon)
passes none at all. Stripping ahead of the auth call rather than
overwriting after it is what makes the guarantee independent of
which headers the daemon happens to emit: a header it stops
returning stops arriving, instead of falling through from the
client. The daemon activates from data, like caddy:
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
binding 127.0.0.1 or a unix socket, so the only ways in are caddy or
the box itself.
whois needs a live tailscaled, so the fixture check covers the
emitted config only; the runtime proof is one request from a tailnet
device and one from outside. Authentication, not authorization: any
non-tagged node of the tailnet passes; which devices may reach the
host is the Tailscale ACL's decision, per-user gating beyond that is
the backend's (the identity headers exist for it).

**Socket backends.** A backend is a loopback port or a unix
socket: `network.sockets.<name> = <absolute path>` sits beside
`network.ports`, `backend` names either, and caddy dials
`unix/<path>` instead of `http://127.0.0.1:<port>`. Nothing else in
the model — vhost, prefix, auth, firewall, `infra.url` — can tell the
two apart. The socket is the service's own listener exactly as a
port is: the module creates it (a `systemd.sockets` unit, or the
daemon itself) and the framework trusts the binding side as it does
for ports. What the module must do is make it admit the proxy and
nobody it does not mean: owned by the service's uid, group
`config.services.caddy.group`, mode `0660`, in a directory the
caddy uid can traverse (a `RuntimeDirectory` at its default mode
is one). No new group carries that flow — caddy's own primary group
already names exactly one uid, and the socket's owner holds the
other side. The reason a socket exists at all is what a loopback
port cannot do: 127.0.0.1 answers every local uid, so a host
carrying an untrusted local login (a kiosk session) can drive a
loopback backend without passing caddy's auth, and the backend has
only a kernel table to guess the caller from. A 0660 socket answers
the service, caddy and nobody else, and the backend reads the
calling uid off the connection (`SO_PEERCRED`). A service that
wants a second door for a local peer declares a second socket with
that peer's group — one socket per calling party, one group per
flow — rather than widening the proxy's.

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
annotated with its resolved backend (port or socket path), network
type and FQDN. Nothing is filtered silently — an unknown network, a
network lacking the field its type needs, a backend the service does
not declare (or declares as both a port and a socket), a
`subdomain` where the type forbids or requires it, a malformed
`pathPrefix` are assertions, so a typo cannot yield a service the
operator believes exposed that is simply not served. Multi-network
exposure works by declaring endpoints on different networks.

**Shipped HTTP services.** `vaultwarden` (Bitwarden backend, sqlite,
`/vault`), `taskchampion` (taskwarrior 3.x replication, `/task`) and
`syncthing` (GUI at `/sync`, sync protocol on the tailscale
interface) ship as `nixhold.modules.services.nixos.*` beside openssh
and tailscale, imported by the host that enables them. The three of
them and openssh are NixOS-only; tailscale is the one shipped service
with both platform implementations. Each one declares its endpoint
**whole except for `network`**: the backend port, the path prefix,
whether the prefix is stripped and the encoding are facts about the
application and belong to the module — vaultwarden 404s under a
stripped prefix, and that is not knowledge to hand an operator —
while the network is fleet data, so the host names it:

```nix
nixhold.services.vaultwarden = {
  enable = true;
  expose.web.network = "tailnet";
  backupDir = "/var/lib/backups/vaultwarden";
};
```

A host that enables one and names no network gets "option ... is
used but not defined", which is the honest failure: `network` is
required on the endpoint type, and auto-picking a shared network was
rejected (see Rejected, "addressOf").

**`backupDir` splits ownership at one directory.** The module owns
the directory itself: it creates it, hands it to group `backups`
(setgid, 2750) and makes every copy group-readable, so the one
service that carries backups off the box reads them by group
membership and nothing else on the box can. The consumer owns the
parent — the shared root several services write under, typically
closed to that same group — and the module does not assume it can
be entered: nixpkgs' backup unit runs as the service's own uid with
no supplementary groups, so the module appends an execute-only ACL
for that uid on the immediate parent (a tmpfiles `a+` line, which
may share a path with the consumer's `d` line and runs after it in
file order; the consumer's rule sorts before `10-<service>`). The
alternative, putting the writer in `backups`, was rejected: group
membership is per user, so the network-facing daemon would gain read
on every other service's copies for a bit only the oneshot needs on
one directory.

**An app that has to know its own origin** reads
`nixhold.infra.url.<service>.<endpoint>` — the resolved
`https://<fqdn><pathPrefix>` of one endpoint, derived in
`modules/infra/endpoints.nix` beside the endpoint list itself.
Vaultwarden's `DOMAIN` is the first consumer: with a path in DOMAIN
it mounts every route under it and generates absolute links from it,
so a service module that recomputed the FQDN from the network's
fields would be the second derivation of the answer caddy already
has — which is exactly how caddy and the firewall drifted before
`endpoints.nix` owned resolution. Unlike `endpoints` this option is
not internal, and its scope is narrow by construction: a module
reads back the URL of an endpoint it declared. Endpoints on
`localhost`, and any that fail to resolve, are absent — those are
assertions, not empty strings.

**Tailnet membership on the Mac is declarative too.**
`nixhold.services.tailscale` has a darwin implementation beside the
NixOS one, and `workstationDarwin` enables it by default, so a Mac
joins the fleet through the framework rather than through the
Tailscale app. It sets nix-darwin's `services.tailscale`, which runs
the open-source tailscaled as a root launchd daemon and writes
`/etc/resolver/ts.net` so MagicDNS names resolve; the Mac's own DNS
is left alone (`overrideLocalDns` stays false). That variant has no
GUI and no auth-key file, so joining is a one-time
`sudo tailscale up` and `authKeySecret` is asserted null on darwin.
No firewall knob either: the option the NixOS side sets is a NixOS
option, and macOS opens nothing for a client.

**sshd exposure follows the topology.**
`nixhold.services.openssh` (the hardened preset: key-only,
no password or keyboard-interactive auth, `prohibit-password` for
root) opens port 22 on every interface only when the host is on an
`internet`-typed network. Otherwise 22 is scoped to the tailscale
interface, the same interface rule tailnet HTTP endpoints get: a
box on a LAN and a tailnet is reachable over the tailnet and not
from the LAN. The scoping is `mkDefault` — a host that wants LAN
ssh opens 22 in its own module. fail2ban follows the same signal
rather than the profile: it is enabled whenever the fleet puts the
host on an internet network, so a desktop that acquires a public
address gets it and a server that never had one does not carry it
for nothing. **The recovery path is the console**, not the LAN:
if the tailnet join has not happened, the operator's password logs
in at the machine's own keyboard (which is why `password` is a
required secret). A headless host installed over a LAN is
installed by the ISO, whose sshd is its own.

**Single-gateway**: public services run on the host that has the
public IP; lint asserts at most one host declares a `publicIp`.

---

## Operator lifecycle

Prereq: Nix on whatever machine you start from. Once a fleet
exists, the installer ISO is itself a sufficient operator seat.

| Event | Flow |
|---|---|
| L1 fork | `nix flake init -t github:fcalell/nixhold` → fill identity (+ `layout.repoUrl`) → `nixhold host add`. The operator identity is generated on first need (see "Operator routes"); there is no init step. A fleet that wants the token route commits its `age1fido2-hmac1…` line into `keys/operator.pub` before that first `host add`, and then nothing is generated — the fleet already has a route |
| L2 first host | `nixhold host add [<name>]` — the walk: name, profile, arch (defaulted from the machine when it is the target), networks only when the fleet declares more than one, public address only when an internet network exists, stateVersion defaulted from the pinned inputs; entry written to `layout.hostsFile`, then the fleet's one-time artifacts: the operator identity when `keys/operator.pub` is empty, the fleet key when `keys/fleet.key.age` is missing, and the framework secrets minted (`identity` — its pubkey printed with every forge the fleet's repositories name, and seeded into `keys/login.pub` — and `password`) alongside any required-missing one. Everything generated is committed, then "install now?" — this machine (on the ISO, or a Mac), over ssh to an address, or later |
| L2b later host | The same walk, and that is all of it: nothing is minted and nothing is rekeyed. `identity` and `password` are fleet-scoped and already provisioned, the fleet key already opens every ciphertext, and the new machine gets that key at install. A host joins with no forge step, no new password and no route prompt |
| L3 NixOS host | On-prem: boot the fleet ISO on the target, `nixhold host install` → the operator route → "new host…" runs the add walk and installs in place. VPS / from another machine: `nixhold host add <name>` and answer "over ssh" with the address (scripted: `--install root@<ip>`); the fleet ISO makes the target reachable with zero typing, any installer works |
| L3d darwin host | On the Mac itself: name the account after `identity.username`, install Command Line Tools and vanilla multi-user Nix, then `nix run github:fcalell/nixhold#nixhold -- host install <mac>`. With no fleet checkout yet, `--repo <owner/repo> --keys <dir>` — the directory holding `identity.age`, and `operator.age` when the fleet keeps one, copied from any checkout or the safekeeping copy — clones with the `identity` key first, so a wiped Mac needs one operator route and nothing else. Preflight, `/etc/nixhold/fleet.key` written, the Mac's live ssh host pubkey recorded, first switch, secrets verified — one command (see CLI) |
| L4 add service | edit host/profile module → `nixhold deploy <name>` (provisions missing required secrets first) |
| L5 new service module | `nixhold service new <name>` → edit |
| L6 update inputs | `nixhold update` (from any directory): pull → flake update → the inputs that moved, from the lock diff → `deploy`'s host picker → deploy each picked host |
| L7 reinstall/reformat | Boot the ISO, `nixhold host install` → the operator route → pick the host (or `host install <name> --remote root@<ip>` from a fleet machine; the picker there asks for the address). The fleet key is installed from `keys/fleet.key.age` (the route is already open, the clone needed it) → a fresh ssh host key is minted and its pubkey rewritten at `keys/hosts/<name>.pub` → secrets still decrypt, because the recipient set never mentioned the machine → nothing else generated |
| L8 rename | manual: `git mv secrets/<old> secrets/<new>`, `git mv keys/hosts/<old>.pub keys/hosts/<new>.pub`, edit hostsFile, reinstall. No rekey — the recipients do not know the host's name |
| L9 remove | `nixhold host remove [<name>]` — deletes the fleet entry, `hosts/<n>`, `secrets/<n>/` and `keys/hosts/<n>.pub`. No rekey: nothing was encrypted to that machine. It still *holds* the fleet key, though, so the verb ends by naming the consequence — if the hardware is not being wiped, `nixhold secret rotate` — and decommissioning the machine is the operator's job |
| L10 recover | host died → L7. All operator machines lost → clone + any operator route anywhere (or the ISO) is a complete seat. Every route lost — the passphrase forgotten on a passphrase fleet, every enrolled token gone on a token-only one → catastrophic, regenerate everything (documented, no CLI). Which is the argument for two tokens on a token-only fleet, and for keeping the passphrase route alongside the token on every other |

Properties: one CLI; verb-first; an omitted argument opens a
picker; darwin auto-dispatch from arch; idempotent; repo + an
operator route is the whole source of truth; two install entry points
(local on the ISO by default, `--remote` from a fleet machine), one
phase sequence.

---

**Host-key trust.** The fleet commits every host's ssh pubkey as
`keys/hosts/<host>.pub`, so nothing that talks to a fleet host
over ssh accepts a key on first use when a committed one exists.
Every host renders `programs.ssh.knownHosts.<peer>` (bare name +
every derived address) from the committed pubkeys, and the framework
peer matchBlocks set `StrictHostKeyChecking yes` for pinned peers.
The CLI pins the same way (`nh_ssh … --host <name>`: a scratch
known_hosts under the process scratch root, strict checking).
Trust-on-first-use
survives only where there is nothing to pin to: a host the fleet
has never seen, and the installer ISO, whose key is random per boot
(`host install --remote` rides nixos-anywhere's own no-check ssh —
install over a LAN you control). A machine running a key the fleet
does not know is unreachable from the CLI by design; the fix is
`host key <name>`, which records the live pubkey after the
operator has checked the fingerprint out of band — the repo has no
copy of the private half to put back, and does not need one.

**The forge is pinned too.** Both baselines pin github.com's
published SSH host keys in `programs.ssh.knownHosts` — the same
keys the installer ISO bakes — so the repositories module's first
clone on a fresh host is a check against a committed key, not a
trust-on-first-use accept. Other forges are the operator's to pin.

**Plaintext staging.** Plaintext key material the CLI stages —
an unwrapped operator identity, the decrypted clone key, the fleet
key on its way to `/etc/nixhold`, a freshly minted ssh host key on
its way to `/mnt/etc/ssh` — lives only under the one 0700 scratch
root wiped on EXIT/INT/TERM/HUP; per-subshell traps are not used for
cleanup, since bash resets them inside `( … )`. The root is
`$XDG_RUNTIME_DIR/nixhold-$$` when `XDG_RUNTIME_DIR` is set — a
per-user tmpfs, so nothing reaches a disk and nothing outlives the
session — and `${TMPDIR:-/tmp}` otherwise (the ISO, a `sudo`
session, a Mac). The NixOS baseline sets
`boot.tmp.useTmpfs = mkDefault true` so the fallback is memory
too, and a crashed verb cannot leave a key in a directory that
survives a reboot. The token route stages nothing of its own: the
private half never leaves the device, so the only plaintext a
token-route verb handles is the secret it was asked to open.

---

## Fleet installer ISO

The no-other-machine install/reformat path. **Thin** live image:
`packages.<arch>.installerIso` from the fleet flake (nixpkgs
`installation-cd-minimal` + a small framework module); built or
flashed via `nixhold iso [--flash <device>]`.

Baked in — nothing *unencrypted* is secret; stick + a route
equals repo + a route, the same boundary as principle 16:

- the `nixhold` CLI + tool belt (git, gum, age, jq, disko,
  nixos-facter); no `gh`. `age-plugin-fido2-hmac` and libfido2's
  udev rules are baked **always**, whether or not this fleet owns a
  token: an image that cannot see a token is an image that cannot
  install, and the operator finds that out at the wiped disk;
- the fleet's login pubkeys (`derived.operatorAuthorizedKeys`, the
  lines of `keys/login.pub`, so a fleet that lists sk keys bakes
  those) authorized for root — the passive `--remote`
  path needs zero target-side typing. An empty list fails the
  build: that image boots to a seat nobody can reach;
- the ciphertexts: `secrets/identity.age` — the clone credential,
  exported as `$NIXHOLD_CLONE_KEY_FILE` — always, and
  `keys/operator.age` (wrapped operator identity) **only when
  the fleet commits one** — a token-only fleet bakes no identity
  file, because there is none to bake. Whichever route the operator
  brings unlocks clone, push, the fleet key and every secret. The
  fleet key itself is not baked: it is one `age -d` away in the
  checkout the ISO is about to clone. Each ciphertext
  is re-added *by content* (`builtins.path`) rather than coerced
  out of the fleet checkout, which would put the whole checkout —
  hosts, every ciphertext, the fleet key — in the squashfs. The ISO module
  asserts it: every `/etc/nixhold/keys/*` entry must be a store
  path of its own, and the `fixture-iso` check evaluates the
  fixture's image so a regression fails `nix flake check`. A second
  assertion refuses the build outright when the fleet holds
  neither a token recipient line nor a wrapped identity: that image
  would boot to a seat with no way in;
- `layout.repoUrl` (required to build the ISO), plus
  `$NIXHOLD_CLONE_KEY_FILE` and — when an identity was baked —
  `$NIXHOLD_IDENTITY_FILE` pointing the CLI at the ciphertexts,
  and github.com's published SSH
  host keys — the same set both baselines pin — so the first clone
  needs no fingerprint prompt;
- a console banner printing the DHCP address + the one command to
  run; avahi (`root@nixhold-installer.local`).

Not baked: repo contents, plaintext secrets, the fleet key, host
keys, build closures. The ISO goes stale only when the repo
location, login keys, operator recipients, or the `identity` key
change — flash once, reuse for years. Installs need network
(private repo clone + closure downloads).

Target-driven flow — the ISO boots to a root shell with the
banner; the operator runs one command:

```
nixhold host install          # operator route (passphrase, or a touch)
                              # → decrypt the identity key → clone repoUrl
                              # → host picker
```

With no `<name>`, a gum picker offers every fleet host (reformat)
plus "new host…" (runs the `host add` TUI, then installs). Local
mode then runs the remote path's phases in place: disk pick →
disko → stage the fleet key into `/mnt/etc/nixhold` and a fresh
ssh host key into `/mnt/etc/ssh` → local closure build →
`nixos-install` → facter written into the checkout. A reformat
commits + pushes the host's new `keys/hosts/<n>.pub`; a new host
also pushes its hosts-file entry with its `disk` and its
`facter.json`, over the same `identity`-key remote. Darwin is
untouched (ISO is NixOS-only).

---

## CLI

One bash CLI, 15 verbs. Access: bare `nixhold` post-install
(`programs.nixhold.enable`, default on) or `nix run .#nixhold --
<verb>` pre-install. No separate installer apps, no
per-subcommand flake apps.

**Fleet-root resolution — verbs work from anywhere.** Fleet
context resolves as: `$NIXHOLD_FLEET` → upward walk from `$PWD` to
the nearest `flake.nix` that calls `mkFleet` (wins inside any fleet
checkout, e.g. a second worktree; the framework checkout is a flake,
not a fleet) →
`programs.nixhold.fleetDir` (default `~/<repo-basename>` derived
from `layout.repoUrl`; the module bakes the value into the
wrapped CLI). When the resolved directory doesn't exist — a
fresh machine after an ISO install — the CLI offers to clone
`repoUrl` there, through the `identity` key either way: unwrapped
by the CLI on the installer, named by the host's ssh config on a
fleet machine (see "The clone credential is the `identity` key").

```
nixhold host add [<name>] [--install <user>@<ip>]
                                                    the walk: name, arch, profile, networks,
                                                    secrets, then "install now?"; the first host
                                                    also mints the operator identity + fleet key
nixhold host install [<name>] [--remote <user>@<ip>] [--disk <by-id>] [--yes]
                                [--repo <owner/repo> --keys <dir>]
                                                    reformat a host; the picker adds "new host…";
                                                    stages the fleet key + a fresh ssh host key;
                                                    --repo/--keys: darwin, no checkout yet
nixhold host key <name> [--remote <user>@<ip>] [--yes]
                                                    record the machine's live ssh host pubkey;
                                                    (re)install the fleet key when it differs
nixhold host remove [<name>] [--yes]
nixhold deploy [<name>…] [--mode switch|boot|test] [--dry-run] [--target <addr>] [--yes]
                                                    no name: pick the hosts; several: in order
nixhold update [--yes]                              git pull → nix flake update → moved inputs
                                                    → deploy's picker
nixhold status [<name>] [--fleet]
nixhold lint [--strict]
nixhold logs [<host>] [<service>] [--lines N] [--since <when>] [--follow]
nixhold secret list [<host>] [--fleet]              no host: the fleet inventory + the keys tree;
                                                    a host: its declared secrets by category
nixhold secret edit [<host>] [<name>]               missing: provision; present: edit; a lone
                                                    non-host argument resolves across the fleet
nixhold secret rekey                                re-encrypt everything to the current
                                                    operator lines + fleet key
nixhold secret rotate                               new fleet key → rekey → "next: nixhold deploy"
nixhold service new <name>
nixhold iso [--flash <device>]
```

Rule: each verb is a real operator action, not a flag-shaped
alias. Host listing is `status --fleet`, diffing is `deploy
--dry-run`, secret checking is `lint`, and putting a drifted
machine back on the map is `host key`. There is no `host
rotate-key`: rotating the key that decrypts is `secret rotate`,
and a machine's ssh key is replaced by reinstalling it or adopted
by `host key` — the dispatcher says so when the old name is typed.
`secret list` is the
one exception to "no listing verbs": once secrets are declared by
their consumers the operator no longer knows what exists, and the
answer is the plan `secret edit` will follow — grouping, optional
vs required, what the fleet holds. `status`'s secret line
stays the one-glance present/missing summary.

**Walkthrough shape.** The operator is walked, not quizzed:

- An omitted argument opens a picker built from the fleet view when
  a terminal is attached, and is a usage error when none is (scripts
  pass the arguments). Picking is the confirmation; `--yes` stands
  in for it in scripts.
- Every verb prints its plan before the first write, commits what
  it generated, and ends with the single next command.
- Prompts default from what is already known: the arch of the
  machine being installed, the fleet's only network, the pinned
  nixpkgs release (`lib.trivial.release`) or nix-darwin's
  `system.maxStateVersion` for `stateVersion`. A question whose
  answer the fleet cannot use — a public address in a fleet with
  no internet network — is not asked.
- One fleet-view eval per process: `nixhold.fleet` (hosts, arch,
  networks, derived addresses) is read once from any host into the
  scratch root; pickers, platform dispatch and address resolution
  read it. No per-verb roster probes. A verb that rewrites
  `hostsFile` drops the memo.
- Identity on first need (see "Operator routes"); required
  secrets on first deploy or install (see `secret edit`). A verb
  that must *read* a ciphertext opens the route the fleet has; one
  that only writes new ones never asks.

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
- **Generated files are committed by the verb that generated
  them, on every machine.** Roster entry and its `disk`, host
  pubkeys, the operator identity, the fleet key, `keys/login.pub`,
  ciphertexts,
  facter report: each verb `git add`s and commits exactly the paths
  it wrote, never a blanket commit, and hand-edited files stay the
  operator's. A generated header is a Conventional Commit of at
  most 60 characters (`host(<name>): pubkey`, `keys: fleet key`,
  `secrets: rekey to fleet key`); a batch whose names overflow the
  ceiling commits as a count. Pushing is the ISO's alone, since its
  checkout is ephemeral; everywhere else the push is the
  operator's. The
  scaffolded NixOS host module is the `stateVersion` line alone:
  hostname, platform, disko and the facter pointer are all
  framework-set.
- **Darwin install is fresh-machine complete.** Preflight before
  anything is written: the login account is `identity.username`
  (home, HM attachment and agenix ownership all key off it),
  Command Line Tools are present (`xcode-select -p`), and the Nix
  is vanilla (nix-darwin refuses activation when
  `/usr/local/bin/determinate-nixd` exists and `nix.enable` is on).
  The first switch's "Unexpected files in /etc" refusal is handled
  in place: the files nix-darwin names are moved to
  `<file>.before-nix-darwin`, the switch is retried once. After
  activation the verb waits (bounded) for `/run/agenix` to hold
  every active secret — agenix on darwin decrypts asynchronously
  under launchd — kickstarts `system/activate-agenix` once if it
  does not, then switches a second time so home-manager derives the
  `.pub` files. It writes `/etc/nixhold/fleet.key` + `fleet.pub`
  with sudo before the first switch, and records the Mac's live ssh
  host pubkey as `keys/hosts/<mac>.pub` — a Mac's key is the
  machine's own, never one the framework mints. On a machine with
  no fleet checkout, `--repo
  <owner/repo> --keys <dir>` — the directory holding
  `identity.age`, and `operator.age` when the fleet keeps one —
  clones with the `identity` key into `~/<repo>`
  before any of that, the same ciphertexts the ISO bakes, read
  through the same `$NIXHOLD_IDENTITY_FILE` / `$NIXHOLD_CLONE_KEY_FILE`
  path.
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
their expose endpoints, and each declared secret with its category,
scope, and ciphertext present or missing; `--fleet` = one line per
host.
Anything richer is `nix eval` / `nixos-option`. Never a
dashboard; never live systemctl.

### `nixhold deploy`

Daily verb; thin over `nixos-rebuild switch` / `darwin-rebuild
switch`. Local iff `$HOSTNAME == <name>` (reliable: the framework
owns host naming). Remote NixOS: `--target-host` **and**
`--build-host` point at the target — **each machine builds its own
closure**; the operator machine never builds foreign arches
(applies to install too via `--build-on-remote`). The connection is
the operator's, activation is `--elevate=sudo` on the target, and
sudo asks: the verb passes `--ask-sudo-password` where the
installed nixos-rebuild supports it and otherwise sets
`NIX_SSHOPTS=-t` so the prompt reaches the operator's terminal (see
"Sudo asks"). One prompt per host — deploying several hosts prompts
once each, and a deploy with no terminal is a usage error rather
than a hang. Remote darwin:
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
the build; then the target's fleet key is ensured — read
`/etc/nixhold/fleet.pub` over `ssh -t` + sudo, and when it is
missing or differs from `keys/fleet.pub`, decrypt
`keys/fleet.key.age` over one operator route and install it. No
rekey, ever: a host added to the fleet inherits `env` and every
shared repository env because it holds the key those ciphertexts
were already written to, so declaring the repository and deploying
is the whole flow. `--dry-run` runs `nixos-rebuild dry-build` (darwin:
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

### `nixhold secret list`

Two answers, chosen by the argument. With a `<host>`: what that
host wants and what it has got — every secret it declares, grouped
by `category` (framework / services / repositories / operator),
one row each: name, scope, status, description. Status is
`provisioned` (ciphertext present), `missing (required)` — the
only state that blocks a build — or `optional`, which is a
standing invitation, not a defect. There is no recipients column
any more: every ciphertext reaches every host, so the column had
one value.

With no host, the **fleet inventory**: one row per ciphertext
under `secrets/` — name, scope, the hosts that declare it, status,
category, description — so an orphan and a declared-but-missing
secret are both visible in one list. Under it, the keys tree: the
fleet key and its recipient line, the login keys, the committed
host pubkeys, and which operator routes the fleet holds. `--fleet`
is the per-host walk over every host. Declaration-side like
`status`; no host is contacted.

### `nixhold secret edit`

Provision-or-edit, decided by whether the ciphertext exists. Missing:
run `generator` (non-interactive) / open `$EDITOR` prefilled with
`template` / open an empty editor, encrypt to the one recipient
set — every operator line plus `keys/fleet.pub` — and
stage the ciphertext. Provisioning is encrypt-only, so it opens no
route and prompts for nothing. An `sshKey` secret has the
keygen generator by default; on a terminal the walk asks generate
or paste, so an existing key registered elsewhere is adopted rather
than replaced. Present: decrypt over the operator route (see "Identity
resolution"), edit, re-encrypt to the current recipients.

**Arguments resolve, they are not positions.** `secret edit` with
one argument that names a host is that host's walk; one that does
not is a *secret* name resolved across the fleet — a fleet-scoped
name goes straight to `secrets/<name>.age`, a host-scoped one
declared on exactly one host goes to that host, and several
declaring hosts open a picker. Editing `env` or a repository's
secret is `nixhold secret edit env`, with no host to pick, because
there is nothing per-host about it.

No name at all: the grouped walk, printed like `secret list` before the
first editor opens. It prompts only for **required and missing**
secrets; an optional one is listed with the command that would
provision it (`nixhold secret edit <host> <name>`) and never
opens an editor unasked — the fleet is full of optional secrets
now (`identity`, `env`, every repository's), and prompting for
each would make provisioning one a chore of skipping the rest. The
named form works for anything declared, optional included. When
nothing is required-missing, the existing secrets are offered to
edit.

A write to the `identity` secret seeds `keys/login.pub` from its
derived pubkey when that file is missing or empty — so a fleet
that never thinks about login keys still authorizes the one key it
has. A fleet that already lists keys there is left alone; the line
is appended by hand, and deployed.

Scope changes only the path (`secrets/<name>.age` for fleet,
`secrets/<host>/<name>.age` for host). The recipient set is the
same both ways and on every host, so nothing about editing a
secret depends on which hosts declare it.

The missing-required walk is what `deploy` and `host install` run
before building. `password` is required, so the walk alone covers
it; `host add` adds one thing on top: `identity` is minted there
too, optional though it is — it belongs to registering the FIRST
machine, not to running a service, and it is the fleet's clone
credential and login pubkey. Both are fleet-scoped, so a later
`host add` finds their ciphertexts already there, mints nothing
and rekeys nothing. Other fleet-scoped optional secrets
(`env`, every repository's) stay on demand: they are provisioned
once from any host. At ISO install time
the operator route is already open, so a new host first-boots with
every required secret decryptable, and a reformat picks up secrets
declared since the last deploy (generators run non-interactively;
templates open `$EDITOR` on the console).

### `nixhold secret rekey` and `secret rotate`

`rekey` is the same write over every ciphertext under `secrets/`,
plus `keys/fleet.key.age` back to the current operator lines. It
mints the fleet key first when `keys/fleet.key.age` is missing —
which is what makes it the migration path for a fleet laid out for
per-host recipients — and seeds `keys/login.pub` from the
`identity` pubkey when that file is absent. It is the verb an
operator-recipient change ends with: adding or dropping a line in
`keys/operator.pub` and rekeying is the whole enrollment story.
Nothing else calls for it — not a host joining, not one leaving.

`rotate` is rekey with a new fleet key in front: generate,
re-encrypt everything to it, and end with the one next command,
`nixhold deploy`, which is what carries the new key to each
machine. It is the answer to a host that left the fleet with the
old key still on its disk, and to any suspicion about the key
itself. `host rotate-key` was folded into it — the ssh host key it
used to rotate no longer decrypts anything.

Both are bulk callers, so on a fleet holding both routes they ask
for the passphrase one first: a whole-fleet rekey is one prompt
that way and one touch per ciphertext the other (see "Identity
resolution").

### `nixhold lint`

Dev mode warns; `--strict` is the CI gate (exit 3). Rules, one
script each under `cli/lint/rules/`:

- every host's `profile` resolves (a host eval smoke test)
- `derived.publicHosts` length ≤ 1 (single-gateway invariant)
- every `expose.<name>.backend` references a listener declared in
  the same service's `network.ports` or `network.sockets`
- `layout.ageRecipient` is tracked and non-empty, the fleet
  holds at least one operator route (a token recipient line, or a
  wrapped identity at `layout.ageIdentityWrapped`), and
  `keys/fleet.pub` and `keys/fleet.key.age` are both present.
  Recipients with no route is a fleet nobody can read; one half of
  the fleet-key pair without the other is a fleet whose hosts
  cannot be given a key that matches its ciphertexts
- no orphan `.age` file: every `secrets/<host>/<name>.age`
  has a matching host-scoped `nixhold.secrets.<name>` on that
  host, and every `secrets/<name>.age` is declared fleet-scoped by
  at least one host. A `.recipients` file, a `secrets/shared/` or a
  `secrets/hosts/` directory is the pre-fleet-key layout — an
  error naming the migration in ARCHITECTURE
- every `required` secret has ciphertext committed
- secret declaration invariants: `homePath` and `sshKey` only with
  `owner = "user"`; `unit` only on NixOS and never together with
  `homePath`/`sshKey`
- every roster host has a tracked `keys/hosts/<host>.pub` (warn
  dev / error strict — an unpinned host is reachable only
  trust-on-first-use), and a tracked `.pub` for a host the roster
  does not name is an error
- `keys/login.pub` is tracked and non-empty (warn dev / error
  strict): an empty list means no host authorizes anyone and an
  ISO built from it boots unreachable. A fleet mid-bootstrap, with
  no `identity` minted yet, is the one state where it is legitimately
  absent
- `10-service-user`: no `systemd.services.<unit>.serviceConfig.User`
  on a NixOS host equals `identity.username` — a service sharing the
  operator's uid (warn in both modes). Lint rather than an
  assertion: the framework cannot tell a deliberate one from an
  accident, and the rule is an opinion about module design (see
  "No service runs as the operator uid"), not an invariant the
  build depends on
- every layout path (defaulted or overridden) exists in the
  worktree — a null `layout.ageIdentityWrapped` is not a path and
  is not checked; `layout.repoUrl` set with `secrets/identity.age`
  missing is a warning ("the ISO cannot clone")

Enforced as assertions rather than lint (they block the build):
unknown network on an endpoint, a network missing the field its
type needs, a backend naming no declared listener or one declared
as both a port and a socket, `subdomain` where
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
passthrough flags, over `ssh -t` so the sudo prompt it elevates
through lands on the operator's terminal (see "Sudo asks").
Metrics/alerting/aggregation/dashboards are forker-composed from
standard NixOS modules. Foundation kept
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
  imported by convention); `readDir` in framework eval, and any
  `pathExists` beyond principle 14's named exceptions;
  `hosts/<n>/home.nix` auto-detect — all replaced by
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
  `nixhold.ssh.keys`** — names never carry behavior; the `sshKey`
  option instead.
- **An `sshIdentity` option (≤1 per host, marks the outbound
  key)** — the framework declares that key itself as `identity`,
  so the option only ever had one true setter and needed an
  assertion to keep it that way.
- **Per-forge ssh keys / `nixhold.forges`** — one identity key for
  the fleet, registered on each forge. Per-forge keys exist to
  carry per-forge users, and a forge that needs one puts it in the
  url (CodeCommit's grant user is the ssh username), which is why
  the derived matchBlock sets no `User`.
- **Per-host `identity` keys (and a per-host console password)** —
  fleet scope for both. Per-host keys buy per-host revocation, but
  for a solo operator at 1–10 hosts revocation is fleet-wide
  anyway: a machine compromised badly enough to leak its key has
  leaked the operator's session with it, and rotating one key on
  every forge is the same act either way. What per-host keys cost
  is paid every time: a manual forge registration in front of each
  new machine (the one step `host add` cannot automate), N pubkeys
  in `authorized_keys` on every host, and N ciphertexts to rotate.
  Fleet scope makes onboarding a machine `host add` and nothing
  else. The same reasoning gives one console password: it is what
  the operator types at a keyboard, and one per machine is a
  password manager entry per machine for no security the login key
  does not already provide.
- **Declaring env variable names in Nix** — env files are opaque
  `KEY=value` blobs sourced wholesale. Naming the keys in the
  module would commit half of every pair in cleartext, and the
  values change on a different clock than the closure.
- **`mkAgeSecret` builder function** — the options API derives
  name/host from context.
- **Per-host recipient sets (a host's ssh key as the decryption
  key, the fleet-scope `.recipients` sidecar, widen on join,
  shrink on remove)** — what it bought: a compromised host could
  not open another host's service secrets. What it cost, every
  day: a recipient union no single host's eval could compute
  (principle 13), a committed sidecar to record that union and a
  lint rule to keep it honest, a rekey of every shared ciphertext
  on `host add`, `host install` and `host remove`, and a route
  prompt in verbs that otherwise only write. The property was
  thinner than it looked — `identity`, `password` and `env` are
  fleet-scoped and reach every host by construction, so a
  compromised machine already held the fleet's outbound ssh key
  and console password. One operator, 1–10 machines they own: the
  fleet is the boundary, and one fleet key draws it. The accepted
  trade-off is stated where it belongs, under "One fleet key" —
  **any host can read every secret**.
- **Host-key escrow (`keys/hosts/<h>/host.key.age`, the ephemeral
  host-key cache, `host rotate-key`, the reconciliation decision
  procedure in `host key`)** — it bought a reinstall that
  reproduced the machine's previous ssh identity, which mattered
  only because that key was also the decryption key: losing it
  meant losing the host's secrets. Once the fleet key decrypts,
  an ssh host key is just an identifier, and reproducing it buys
  nothing a one-line `keys/hosts/<h>.pub` rewrite does not. The
  cost was a private key committed per host, a single-writer
  invariant spanning four verbs, a plaintext cache with its own
  deletion discipline, a rotation window with `.prev` files on
  both sides, and two lint rules. `host install` now mints a fresh
  key and commits its pubkey; `host key` adopts a live one.
- **A repo deploy key (`keys/repo.key.age`,
  `$NIXHOLD_REPO_KEY_FILE`)** — it bought the ISO a way to clone
  and push a private fleet repo from an operator route alone,
  keeping the passphrase route a complete seat. The fleet already
  owned exactly such a credential: `identity`, registered on the
  forge for auth and signing. A second ssh key meant a second
  registration on the forge, a second thing to mint, escrow,
  rotate and lint, and a deploy key with write access sitting
  beside the one the operator already trusts. The ISO bakes
  `secrets/identity.age` and exports `$NIXHOLD_CLONE_KEY_FILE`
  instead.
- **An operator-identity `mode` option (passphrase / token /
  both), and a flag choosing the decrypt route** — the committed
  files already answer both questions: a recipient line per route,
  a wrapped identity when there is one, a token in the port or
  not. A mode would be a third thing to keep in step with the two
  that decide anyway, and a flag would only let the operator ask
  for a route that is not there.
- **A separate operator recipient list for login keys** —
  `keys/login.pub` is ssh, `keys/operator.pub` is age; the same
  hardware token backs both but the credentials are unrelated, and
  merging them would mean deriving one from the other.
- **A per-host login-key field (`hosts.<h>.loginPubkey`, and a
  `mkFleet { loginPubkeys }` argument overriding it)** — two ways
  to say one thing, one of them defaulting from a committed file
  the other could contradict. `keys/login.pub` is the single
  answer, read at eval like every other committed pubkey; a fleet
  that wants a machine to authorize something else writes it in
  that host's own module.
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
  power users declare `disko.devices` themselves.
- **Sub-disk install choices in the wizard** (dual-boot /
  install-into-free-space / root-size prompt) — disko and
  nixos-anywhere format the whole declared disk; adopting
  existing partitions is unsupported territory. One shape,
  whole disk; a second OS on the same disk is hand-partitioned
  outside the framework, custom layouts are a `disko.devices`
  declaration. A second OS on its own disk needs none of this —
  the framework formats only the declared disk.
- **A framework option for the second OS's boot entry** — the EFI
  device handle systemd-boot needs is readable only from the UEFI
  shell; `boot.loader.systemd-boot.windows` in the host module is
  the whole answer, and the picker prints it.
- **`--disko-from`** — a custom layout is a declaration, not a
  file copied into place; the placeholder `disko.nix` it replaced
  went with it.
- **VPS provisioning/lifecycle verbs** — provider tools do it.
- **`recover` verb** — DR is existing verbs + judgment,
  documented.
- **`CHANGE_ME` markers in generated files; facter stubs;
  placeholder disko files** — hardware is data: the disk in the
  roster, the report at its default path, both install-time
  outputs.
- **Prompt-to-commit; ISO-only auto-commit** — every verb commits
  exactly the files it generated, on every machine; `--amend` to
  override. Only the push is ISO-specific.
- **Hostname auto-detection for install; unguarded local install
  on fleet machines** — local install is the default *on the ISO*,
  guarded by the installer-environment marker; every other machine
  is driven with `--remote`.
- **`--here` / `--install-here` as explicit flags** — superseded
  by local-as-default + the environment guard + the no-name host
  picker; the flags added surface without adding meaning.
- **`gh` device-flow auth on the ISO** — the operator-encrypted
  `identity` key covers clone + push from an
  operator route alone: no second device, no `gh` in the tool belt.
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
  first need; provision-or-edit in `secret edit`; one adopting
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
