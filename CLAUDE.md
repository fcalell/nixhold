# CLAUDE.md — framework repo context

This repo is **nixhold**, the framework. The personal fleet that
dogfoods it lives in a separate repo at `~/nix/`.

## Source of truth

**`ROADMAP.md` is the architecture spec.** Every architectural
decision is locked there. Before designing anything new, read the
relevant section. Before implementing anything, cross-reference
it.

## Standing directives

- The framework is opinionated. Fewer knobs, more "set one thing,
  the rest follows."
- Options are the API — typed `nixhold.*` options are the
  publish/subscribe layer (Principle 10).
- No filesystem-based discovery in the framework eval — Nix
  values only, per Principle 14.
- Thin operator glue — every CLI verb is "configuration +
  invocation over an underlying tool," per Principle 15.
- One operator, 1–10 hosts target scale. No multi-operator, no
  per-secret ACLs, no observability stack, no LUKS.
- Architectural changes go through ROADMAP first. Draft the
  section, surface 2–4 decisions for the user to lock, then edit
  ROADMAP. Implementation follows the locked design.

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
  ├─ services/         service modules — exposed as nixhold.modules.services.*
  └─ infra/            infra modules — exposed as nixhold.modules.infra.*
profiles/              shipped profiles (server, workstationDarwin, desktopLinux)
                       exposed as nixhold.profiles.*
cli/                   one writeShellApplication; subcommand sources
template/              scaffold for `nix flake init -t .#`
checks/                synthetic fleet fixture mkFleet is run against in CI
```

## Companion repo

`/Users/fcalell/nix/` — fcalell's fleet. Consumes
`inputs.nixhold` from this repo. Use it as the dogfood target
when iterating on the framework.
