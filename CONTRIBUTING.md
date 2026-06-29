# Contributing

Thanks for your interest. This is a GitOps-managed reference platform: everything is declared in
this repo and reconciled by Argo CD. Contributions should preserve that property: declarative,
pinned, and documented.

## Ground rules

- **Declarative only.** No imperative cluster mutations as the source of truth. If it isn't in git,
  it doesn't exist. Argo CD reconciles from this repo.
- **Pin everything.** Chart versions, image tags, and CRD versions are pinned. Never `:latest`.
- **One capability per change.** Each PR adds one capability and ships proof: manifests +
  an ADR (if a decision was made) + a runbook (if there's an operational path) + a benchmark or
  smoke result where relevant.
- **Match existing style.** Follow the layout and conventions already in the tree; don't refactor
  unrelated code.

## Repo layout

See [README.md](./README.md#repo-layout). New components go under the matching top-level dir
(`platform/`, `serving/`, `routing/`, `workloads/`) with a child Argo `Application` in the matching
catalog group `clusters/ai-dev/catalog/<group>/`; enable the group via `config.yaml` `features:` (see
[ADR-0031](./docs/public/decisions/0031-config-driven-feature-selection.md)).

## Decisions and docs

- **ADRs**: record non-trivial decisions under `docs/public/decisions/` (see existing ADRs for format).
- **Guides**: operational procedures go under `docs/public/guides/` (the site's Guides section).
- **Benchmarks**: method under `docs/public/benchmarks.md`; recorded runs under `benchmarks/`.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `chore:`,
`docs:`, scoped where useful (e.g. `fix(kserve): …`). Keep messages concise.

## Pull requests

1. Branch from `main` with a typed prefix: `feat/`, `fix/`, `chore/`, `docs/`.
2. Keep the change surgical — every changed line should trace to the stated goal.
3. Validate before opening: manifests apply cleanly and the relevant `make` smoke target passes.
4. Describe what you changed and how you verified it.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](./LICENSE).
