# nixhold — roadmap

Planned work for nixhold. Everything here is NOT implemented yet.
The implemented design lives in ARCHITECTURE.md; a roadmap item
graduates there when it lands. Items carry a trigger — the condition
under which they get picked up — or "decision" when the operator has
to choose first.

---

## Network exposure

| Item | Trigger | Intended shape |
|---|---|---|
| `lan` network type + identity for LAN clients | first LAN-only consumer | a LAN address carries no identity signal, so it needs an internal CA / mTLS to say who is calling |
| L4 protocols (`tcp` / `udp` / `grpc`) | first L4 consumer | the `protocol` enum gains non-HTTP members, and the module that terminates them is a new infra consumer of `nixhold.infra.endpoints` — the list gains a branch, never a silent omission |
| Identity on `internet` endpoints | first internet endpoint that wants framework auth rather than app auth | `forward_auth` against an IdP / OIDC, the internet counterpart of tailnet identity auth; until then `auth = false` stays required-explicit there |
| Per-interface caddy listeners | first host serving both internet and tailnet endpoints | `bind` to the tailnet address so a mixed-posture host no longer depends on the firewall rule; plus port 80 on the tailnet interface for the redirect vhost. Lifts the mixed-posture assertion |
| Cross-host routing (service on A, gateway on B) | real consumer | the single-gateway rule holds the door open |
| Node identity header | the first backend that must tell one operator node from another (the dogfood fleet's assistant, at the first second identity on its tailnet) | nginx-auth emits user-level headers only, so on a solo tailnet every node carries the same identity. caddy adds `Tailscale-Node-Addr` from `{remote_host}` to the stripped-and-copied identity set: on `tailscale0` the peer address is bound to the node key, so it is node identity, not an address to guess. The backend decides what a node may do; the framework stays authentication-only, no allow-list on `expose` (see Rejected). Tagged nodes stay 403 until the auth daemon is replaced by one that admits tags as principals; the first tagged node that needs through is that trigger (an Android host is logged in as the operator, so it is not one) |
| An endpoint on its own origin | an app that takes the page's origin as its API base, so a path prefix cannot carry it (the dogfood fleet's Remux: its dashboard is built for `/admin` at the root and its wizard asks the origin, so the fleet exposes `/admin` at the root as a named exception) | `expose.<x>.port` on `tailscale` networks: tailscale serve admits 443, 8443 and 10000, so a second port is a second origin on the node's own name with the same cert and the same identity gate, no subdomain needed. caddy binds the port on the tailnet interface, `infra.url` carries it, the firewall rule follows. Not a per-service vhost: that is the subdomain the type already rejects on tailnets |

**DNS declaration contract** (declare-only; trigger: first consumer
that wants records out of the fleet). Sources: `hosts.<n>.publicFqdn`
+ service-level public endpoints. Derived read-surface
`nixhold.fleet.derived.records`: a list of
`{ fqdn, type = "A", rdata, source }`, where `source` traces the
declaring option. Consumers: `status` renders it, lint validates it.
Shape decided: zones implicit (derived from record suffixes),
IPv4/A-only until a dual-stack host exists, no wildcards, A-vs-CNAME
is a provider-module concern. Validation: declared-but-unreachable
(no `publicIp` / not on an internet network) = lint strict-error;
FQDN collision = assertion in the derived evaluator; hostname syntax
= option type regex. Later, on a first real consumer or a dual-stack
host: DNS provider modules pushing `derived.records`, a zones option,
AAAA, wildcards, TTL, other record types.

Lint rules for exposure, none of which exist today (trigger:
alongside the work above, or the first misconfiguration that gets
through):

- `expose.<x>.network` membership — an endpoint on a network the
  host is not in; public endpoints on a non-gateway host.
- the same `subdomain` claimed twice on one network (across networks
  is fine).
- a `tailscale`-typed network with no `magicDnsSuffix` — dev
  warning that proposes the suffix read from `tailscale status
  --json` on the operator machine (a CLI read, never eval).
- localhost endpoints actually binding 127.0.0.1. Obstacle: there is
  no uniform NixOS "bound ports" property to check against, so this
  needs a per-service convention or a runtime probe.

---

## Secrets & keys

| Item | Trigger | Intended shape |
|---|---|---|
| ISO prints its ssh host-key fingerprint on the console, and `host install --remote` shows the one it connects to | install over a LAN the operator does not control | the ISO key is random per boot, so this is the only way to verify it |
| `status` compares each reachable host's live `/etc/ssh/ssh_host_ed25519_key.pub` with the committed `keys/hosts/<host>.pub`, and its `/etc/nixhold/fleet.pub` with `keys/fleet.pub` | first drift incident | lint cannot do it (needs the network); `status` already talks to hosts nowhere else, so this is its first network read. `host key` and `deploy` each fix one half today, but only for the host they were pointed at |
| `host install` checks the tailnet has MagicDNS + HTTPS certificates on before installing a host with tailnet endpoints | first server whose `tailscale cert` fails at first boot | `tailscale status --json` on the operator machine: `CertDomains` empty means caddy's cert unit will loop; the admin-console flip is the operator's, the check is the framework's |
| `nixhold key register` | the fleet identity is rotated, or a second forge is added — registering it once by hand is fine, doing it again is a verb | thin glue over `gh ssh-key add` (principle 15): reads the `identity` pubkey (and the entries of `keys/login.pub`, which is where that line also lives on a fleet with no token) and registers it on the forge for **both** auth and signing (`--type signing` is a second call), so the one manual step left in the repositories chain disappears for github. Other forges have no uniform CLI, and `identity-rsa` only ever meets one of those; the verb names what it cannot do rather than pretending |
| Per-forge git author email | a work forge needs a different email from `identity.email` | today `programs.git.userEmail` is one fleet-wide `mkDefault` from the identity. Shape: an `email` field on `nixhold.repositories.<name>`, rendered as a `programs.git.includes` conditional on `gitdir:<path>/` — per-repository rather than per-forge, since the checkout path is what git can condition on and a forge can host both kinds of work |
| Operator key recovery beyond the committed routes | use case surfaces | a Shamir split of the wrapped identity. The hardware-token half of this landed — see ARCHITECTURE "Operator routes" — and a second token is the cheap answer today |
| `nixhold secret recipient add\|remove\|check` | the first token enrolment | editing `keys/operator.pub` plus one `nixhold secret rekey` is the whole flow today, and it is exactly the flow that is easy to half-do: a line added and no rekey leaves a route the fleet advertises and no ciphertext opens. The verb family would validate the line, write it, rekey, and `check` would prove — over each route in turn — that every route opens `keys/fleet.key.age`. Naming still open between `secret recipient …` and a top-level `operator …`, which would also house the passphrase change |
| `nixhold secret set <name> KEY=value…` | the first env-shaped secret edited for one line | `secret edit` opens `$EDITOR` on the whole file, which is the wrong shape for adding one variable to `env` or a repository's env — and impossible without a terminal. Non-interactive: decrypt, merge the given keys, re-encrypt. Stays opaque (principle: env files are `KEY=value` blobs, never declared in Nix) |
| A separate private-secrets flake input | **decision** | it would need its own write root; today only the fleet's own source store path is re-rooted to the worktree, and a layout path into another input is a hard error |

---

## CLI & deploy

| Item | Trigger | Intended shape |
|---|---|---|
| APK pins move with `nixhold update` | the first Android host whose APK lags its release by more than one `update` | for each `environment.systemPackages` entry whose URL is a GitHub release asset, `update` reads the latest release, rewrites the URL and hash, and the eval gate covers the android plans it already evaluates; a pin that is not a release asset stays a hand edit |
| `nixhold.deploy.network` option | operator wants a fleet-wide deploy path other than the tailnet | today the address is the tailnet entry of `derived.address.<host>` when it resolves, else the first non-null one; `--target` overrides |
| `host rename` verb | the manual flow (L8) becomes a real pain | `git mv secrets/<old> secrets/<new>` + `git mv keys/hosts/<old>.pub …` + hostsFile edit + reinstall, in one verb. No rekey: recipients do not know the host's name |
| Framework-managed remote builders | a consumer informs the design | `fleet.builders.<system>` — reserved, unclaimed |
| A repo-wide `nix fmt` | formatting drift | `formatter` is bare `nixfmt` on stdin today; a tree formatter would need a wrapper |
| `nix flake check --no-build` | the no-build form is wanted in CI | it trips over the fixture's `builtins.path` self (an unrealised store path once a check forces `readFile` under it); the builds-allowed check is the smoke test today |
| Scheduled refresh of nixhold's own lock | the first `nixhold update` whose gate fails on an input nixhold's lock is more than a release behind on | a CI job on a cadence: `nix flake update`, the framework checks, push. The fleet's lock is what builds ("Inputs: who pins what"); nixhold's is the tested floor, and lint's "behind" rule measures against it, so a floor that rots measures nothing |

Lint rules named in the design but not written (trigger: the first
violation that reaches a host):

- every shipped service module declares `nixhold.services.<name>`.
- no manual `age.secrets` wiring outside the `nixhold.secrets`
  manifest; no undeclared `age.secrets` reads.
- kebab-case service names.

---

## Docs & template

Structure decided, prose pending. Trigger for all of it: the first
forker who is not the author.

- **Framework README** — decide-and-jump in 60 seconds: audience
  gate (non-audience: module-library authors; single-laptop users
  are welcome), what-you-get, `nix flake init -t` pointer, project
  status, concept links into `docs/`, a short comparison table.
- **Template README** — the 30-minute path: a time-bounded contract
  ending at one host deployed and `nixhold deploy` working;
  cross-host wiring demoed *after* the 30 minutes. Becomes the
  forker's own fleet README post-init.
- **Template scaffolds with commented examples** — flake.nix and
  hosts.nix carrying worked examples in comments; no disko, no
  wizards, no `CHANGE_ME` markers.
- **`docs/`** — filenames are stable (renames are breaking):
  `concepts.md`, `profiles.md`, `modules.md`, `verbs.md`,
  `discovery.md`.
- **Canonical invocation in walkthroughs**: `nix run .#nixhold --`;
  the PATH install is a next-step convenience.
- **Curated init templates, `init --from` migrations, walkthroughs**
  — trigger: forkers exist (~3), or a "how do I start" issue.

---

## Services

| Item | Trigger | Intended shape |
|---|---|---|

---

## Foundations

| Item | Trigger | Intended shape |
|---|---|---|
| Plugin architecture (third-party modules / CLI verbs) | external forks, or "how do I add my service" issues | the seams are already open: the services namespace, the flake-output tables, the secrets manifest |
| Build + VM test layers beyond lint; a test-helper API | first external PR, or a regression lint missed | the fixture fleet is the only check today |
| Additional shared option types (`data`, `health`, `metrics`, `logs`, `schedule`) | designed alongside their first consumer module | siblings of `nixhold.types.network` / `.expose` |
| Publishing a backup copy is duplicated | met: navidrome is the third consumer and spells publishing a third way (a tmpfiles default ACL, because its producer is the daemon itself); build at the next change to any of the three | Three roles hide in the shipped services: the **producer** (vaultwarden's belongs to nixpkgs, taskchampion's is ours, so the framework cannot own it uniformly), **publishing** the copy under a known root as group `backups`, setgid, group-read, no world bits, and the **transport** off the box (a fleet's syncthing folder today, restic tomorrow). Publishing is the identical half, and it is spelled twice in two languages: a `tmpfiles` override plus `UMask`/`ExecStartPost` for vaultwarden, `chown`/`chmod`/`g+s` inside the script for taskchampion. Shape: `modules/infra/backups.nix` activating from data like caddy, consuming `nixhold.services.<n>.backup = { dir; unit; }` and deriving the group, the directory entry and the publish step on the named unit. It owns neither the timer nor the copier nor the transport. A `nixhold.types.data` covering state + snapshot method saves no lines today (the nixpkgs producer can only be steered, so the type needs two branches) and is designed alongside its first real consumer, a restic-shaped module |
| State migration (`service move`) | not foreseeable | — |
| Tags / CHANGELOG / SemVer | first external consumer | the fleet's `flake.lock` is the contract until then |
