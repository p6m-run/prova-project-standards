# prova-project-standards

The p6m project standards, as proofs.

A standard nobody can run is a wiki page. This [Prova](https://prova-rs.github.io) package turns
each standard into a test, so `prova` and CI enforce it with no new tooling. A violation reads like
any other failure. A deliberate exception is a waiver with a reason, committed to the repo.

It works alongside the quality surface `prova init rust-project` renders: that gives a project its
legs (clippy at `-D warnings`, the unwrap/expect census, duplication, file sizes, unit tests,
coverage); these standards hold every project to keeping those legs wired, and to the hygiene
around them.

## Adopt it

1. Retrofit the quality surface, if the project doesn't have one yet:

   ```bash
   prova init rust-project
   ```

2. Pin the package in the manifest (`.prova/prova.toml` after a retrofit, else `prova.toml`):

   ```toml
   [dependencies]
   project-standards = { git = "https://github.com/p6m-run/prova-project-standards", tag = "v1" }
   ```

3. Add one proof file:

   ```lua
   -- proofs/standards.prova.lua
   require("project-standards").check {}
   ```

4. Run it, then do the first-run ritual the retrofit asks for:

   ```bash
   prova                                  # standards run with the rest of the suite
   prova run quality --update-baseline    # record the quality floors once, then commit .prova/baselines/
   ```

A fresh retrofit passes every rule except `cargo/quality-baseline` (and `repo/readme`, if the
project has no README); the ritual turns the baseline green.

## The bar

Profiles are detected from what is on disk. `profiles = { ... }` adds to the detected set; it
never removes one.

| Rule | Profile | Fails when |
|---|---|---|
| `repo/readme` | repo | no `README.md`, or an empty one |
| `repo/gitignore` | repo | no `.gitignore` |
| `prova-suite/manifest` | prova-suite | no prova manifest |
| `prova-suite/requires-floor` | prova-suite | `[requires] prova` missing, not a `>=` floor, or below the org floor (0.30) |
| `prova-suite/no-retired-surface` | prova-suite | `prova run --list` reports a deprecated key |
| `prova-suite/proof-naming` | prova-suite | a proof file named `*_test.lua` or `*.test.lua` |
| `prova-suite/dependencies-pinned` | prova-suite | a git dependency pinned to a branch or rev instead of a tag |
| `prova-suite/ci-profile` | prova-suite | no `[profiles.ci]` with `must_run` |
| `cargo/edition` | cargo | a crate below edition 2021, or with no edition (Rust 2015) |
| `cargo/resolver` | cargo | a virtual workspace with no resolver `"2"` or `"3"` |
| `cargo/ignores-target` | cargo | `.gitignore` does not cover `target/` |
| `cargo/quality-legs` | cargo | `[profiles.quality]`, `[profiles.ut]` or `[profiles.all]` missing |
| `cargo/clippy-gated` | cargo | no proof runs `cargo clippy ... -- -D warnings` |
| `cargo/no-blanket-allows` | cargo | `#![allow(warnings)]`, `allow(unused)`, `allow(clippy::all)` and similar in source |
| `cargo/quality-baseline` | cargo | no committed `.prova/baselines/quality.json` |
| `cargo/formatted` | cargo | `cargo fmt --all --check` fails (needs cargo) |

Every failure prints the rule's reason. `prova --tags standards` runs only these; `--tags static`
runs the ones that never compile.

## Waivers

```lua
require("project-standards").check {
  except = {
    ["cargo/formatted"] = { why = "one-time reformat lands with YP6M-1234", owner = "jdoe", ends = "2026-12-31" },
    ["cargo/edition"]   = "pinned to 2021 until the FFI crate drops its requirement",
  },
}
```

A waived rule reports as a skip with its reason on every run. A waiver whose `ends` has passed turns
red again, so debt carries a date instead of living forever.

## Raising the bar

Change a floor in `standards.defaults` or add a `rule{}` in `init.lua`, add a case to the self-test
that the new rule fails, release, and move the `v1` tag. Every adopting project answers on its next
run. Consumers that need to refresh a moved tag pass `-U` (tag pins are cached as immutable).

## Develop

```bash
prova                        # the self-test: hermetic, ~0.3s
prova package lint init.lua  # the namespacing grammar
```

The self-test runs every rule against a compliant synthetic project and against one broken in
exactly one way, and ends by holding this package to its own standards.

MIT licensed.
