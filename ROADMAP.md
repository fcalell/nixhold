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
| sshd scoped to the tailnet interface when the host is on no internet network | **decision** — trades LAN recovery for LAN closure | derive from `derived.self.networks`; today `openFirewall` opens 22 on every interface, key-only + fail2ban, and LAN ssh is the recovery path if the tailnet join fails |
| Per-service loopback boundary (unix sockets / network namespaces) | first host that wants a local uid isolated from its services | backends on 127.0.0.1 are reachable by every local uid, so a host running an untrusted local user (a kiosk) can drive them without passing caddy's auth |
| Cross-host routing (service on A, gateway on B) | real consumer | the single-gateway rule holds the door open |

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
- a `tailscale`-typed network with no `magicDnsSuffix` — dev warning.
- localhost endpoints actually binding 127.0.0.1. Obstacle: there is
  no uniform NixOS "bound ports" property to check against, so this
  needs a per-service convention or a runtime probe.

---

## Secrets & keys

| Item | Trigger | Intended shape |
|---|---|---|
| ISO prints its ssh host-key fingerprint on the console, and `host install --remote` shows the one it connects to | install over a LAN the operator does not control | the ISO key is random per boot, so this is the only way to verify it |
| `status` compares each reachable host's live `/etc/ssh/ssh_host_ed25519_key.pub` with the committed `host.pub` | first drift incident | lint cannot do it (needs the network); `status` already talks to hosts nowhere else, so this is its first network read |
| Proving escrow ↔ `host.pub` equality | **decision** | age stanzas carry no recipient fingerprint, so this needs the operator passphrase — possibly a `--verify` flag on `host escrow`, which lint must never call |
| Operator key recovery beyond the passphrase | use case surfaces | Shamir split, or a hardware key as a second recipient |
| Passphrase rotation verb | use case surfaces | manual rekey covers it today |
| A separate private-secrets flake input | **decision** | it would need its own write root; today only the fleet's own source store path is re-rooted to the worktree, and a layout path into another input is a hard error |

---

## CLI & deploy

| Item | Trigger | Intended shape |
|---|---|---|
| `nixhold.deploy.network` option | operator wants a fleet-wide deploy path other than the tailnet | today the address is the tailnet entry of `derived.address.<host>` when it resolves, else the first non-null one; `--target` overrides |
| Mass deploy (`--fleet`, host patterns) | additive whenever wanted | today `deploy` takes one named host |
| `host rename` verb | the manual flow (L8) becomes a real pain | `git mv` + hostsFile edit + `secret rekey` + reinstall, in one verb |
| Framework-managed remote builders | a consumer informs the design | `fleet.builders.<system>` — reserved, unclaimed |
| A repo-wide `nix fmt` | formatting drift | `formatter` is bare `nixfmt` on stdin today; a tree formatter would need a wrapper |
| `nix flake check --no-build` | the no-build form is wanted in CI | it trips over the fixture's `builtins.path` self (an unrealised store path once a check forces `readFile` under it); the builds-allowed check is the smoke test today |

Lint rules named in the design but not written (trigger: the first
violation that reaches a host):

- every shipped service module declares `nixhold.services.<name>`.
- every NixOS host imports disko and sets the facter report (warn
  dev / error strict).
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

## Foundations

| Item | Trigger | Intended shape |
|---|---|---|
| Plugin architecture (third-party modules / CLI verbs) | external forks, or "how do I add my service" issues | the seams are already open: the services namespace, the flake-output tables, the secrets manifest |
| Build + VM test layers beyond lint; a test-helper API | first external PR, or a regression lint missed | the fixture fleet is the only check today |
| Additional shared option types (`data`, `health`, `metrics`, `logs`, `schedule`) | designed alongside their first consumer module | siblings of `nixhold.types.network` / `.expose` |
| Backup as a framework concern; state migration (`service move`) | not foreseeable | — |
| Tags / CHANGELOG / SemVer | first external consumer | pinning by SHA is the contract until then |
