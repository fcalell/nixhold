# CLAUDE.md: framework repo context

This repo is **nixhold**, the framework. The personal fleet that
dogfoods it lives in a separate repo at `~/nix/`.

## Where things are

**`ARCHITECTURE.md` is the architecture spec**: the framework as
implemented, each decision the best shape known when it was
written, not a verdict. **`ROADMAP.md` is the plan**: only work
that is not implemented yet, each item with its
trigger. Before designing anything new, read the relevant
ARCHITECTURE section and check whether the ROADMAP already holds
the item. Before implementing anything, cross-reference both. When
a roadmap item lands, it moves into ARCHITECTURE and leaves the
ROADMAP.

## Standing directives

- The framework is opinionated. Fewer knobs, more "set one thing,
  the rest follows."
- Plain NixOS options are the API: a typed `nixhold.*` option is
  the publish, a `config` read is the subscribe.
- No filesystem discovery in the framework eval. `mkFleet`
  consumes Nix values; only the CLI writes to layout paths.
- Thin operator glue: a verb reads declared options, computes
  arguments, and invokes an underlying tool.
- One operator, 1 to 10 hosts target scale. No multi-operator, no
  per-secret ACLs, no observability stack, no LUKS.
- A commit the CLI writes obeys the fleet's commit contract:
  Conventional Commits, header at most 60 characters. A hook
  rejects the rest, mid-verb.
- Architectural changes go through ARCHITECTURE first. Draft the
  section, surface 2 to 4 decisions for the user, then edit
  ARCHITECTURE. Implementation follows the agreed design. A
  better shape found while working goes the same route: propose
  it with its cost, build it once agreed.

## Repo layout

```
flake.nix              library + apps + templates + profiles.* + modules.* outputs
lib/                   framework helpers (mkFleet, …)
modules/               kind-organized module bundles, exposed via flake outputs
  ├─ identity/         baseline: nixhold.identity
  ├─ secrets/          baseline: nixhold.secrets + agenix wiring
  ├─ fleet/            baseline: nixhold.fleet (read-only view)
  ├─ types/            baseline: shared option types (expose, network, …)
  ├─ layout/           baseline: nixhold.layout
  ├─ home/             baseline: home-manager wiring
  ├─ services/         service modules, exposed as nixhold.modules.services.*
  └─ infra/            infra modules, exposed as nixhold.modules.infra.*
profiles/              shipped profiles (server, workstationDarwin, desktopLinux)
                       exposed as nixhold.profiles.*
cli/                   one writeShellApplication; subcommand sources
template/              scaffold for `nix flake init -t .#`
checks/                synthetic fleet fixture mkFleet is run against in CI
```

## Verify

`nix flake check` is the gate: it evaluates the synthetic fleet in
`checks/` against every module and profile, and builds the CLI,
whose `writeShellApplication` runs shellcheck over each verb.
`nixfmt` is the formatter. Behaviour a fixture cannot reach is
verified on the dogfood fleet, which needs that repo to point at
this checkout and `--allow-dirty-locks`.

## Companion repo

`/Users/fcalell/nix/` is fcalell's fleet. It consumes
`inputs.nixhold` from this repo. Use it as the dogfood target
when iterating on the framework.
