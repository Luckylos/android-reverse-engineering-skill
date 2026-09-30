# tests/ — development test harness

Dev-only: nothing here ships with the plugin (the plugin lives under `plugins/`).
It guards the "registry as single source of truth" work: registry lint, golden
byte-identity of the neutralizer outputs, the consumed-registry snapshot, and (as the
features land) reader/audit unit tests, sh/ps1 parity and corpus ground truth.

```bash
tests/run.sh                  # quick: lint + unit (+ parity on fixtures when PowerShell is available)
tests/run.sh full             # + golden, snapshot, corpus, bash 3.2, perf (10-15 min)
tests/run.sh lint golden      # selected suites; single tests by name: tests/run.sh t_lint
tests/run.sh --expect-pass lint golden snapshot   # SKIP counts as FAIL for these
```

One line per test: `PASS`, `FAIL`, `SKIP` (tool or corpus missing) or `SKIP(requires)`
(the feature the test covers is not in the tree yet: see the `# requires:` header of each
test). A suite with no test script yet prints `SKIP <suite> no tests found`. Under
`--expect-pass` every SKIP, SKIP(requires) and empty suite of the named suites/tests is a
FAIL. Exit 0 = nothing failed.

Suite discovery: `unit/t_*.sh`, `parity/t_*.sh`; `corpus` = every `corpus/*.sh` (the
DESIGN names `groundtruth.sh`, `exclusions-superset.sh`, `marker-verify.sh`) except the
helper `prepare-pristine.sh` and `perf*.sh` (suite `perf`); `bash32` = `bash32/*.sh` and
any `<dir>/bash32.sh`. A single script also runs by name (`tests/run.sh marker-verify`).

| Path | What |
|---|---|
| `run.sh`, `lib/common.sh` | runner and shared helpers (env: `ARE_CORPUS`, `ARE_JADX`, `ARE_GOLD`, `ARE_PS`, `BASH32`, `ARE_PRISTINE`, ...; defaults derive from the checkout's parent directory) |
| `lint/lint-registry.sh` | registry lint (rules L1-L4 today, plus JSON-schema validation when python `jsonschema` is installed) |
| `golden/capture.sh`, `golden/compare.sh`, `golden/t_golden.sh` | registry-scan (8 apps x depth 1-3 x ads/trackers/all + synth48) and detect-adwrapper (sh with/without `--registry`, ps1) must stay byte-identical to the frozen baseline `$ARE_GOLD/before` |
| `golden/synth48.before/` | G-synth: registry-scan outputs on the synth48 fixture, captured with the product of 4c166fe |
| `golden/snapshot.sh`, `golden/snapshot.before.jsonl`, `golden/t_snapshot.sh` | the registry fields today's consumers read must not change for the 48 original entries |
| `fixtures/` | generators of synthetic trees (synth48, adwrapper fixture, pitfalls) and expected outputs; no proprietary code |
| `shims/` | `nojq`, `jq15` (fake jq 1.5), `nosudo`, `awk-{gawk-posix,mawk,busybox}` for the portability paths |
| `parity/ps.sh` | runs a `.ps1` with Windows PowerShell 5.1 from WSL (`-File`, Windows paths) |
| `parity/t_parity.sh` | sh/ps1 byte parity (`--only <section>`; today: `registry-query`, incl. the in-process case) |
| `fixtures/registry-{mini,edge,bad}/`, `fixtures/expected/registry-query/` | registry-query fixtures (clean; BOM + case-colliding keys; every integrity error) and their expected outputs |
| `unit/` | unit tests (`t_*.sh`; `t_runner.sh` covers run.sh itself; `t_reader`, `t_pkg_parity` (T-PKG-PARITY, always per awk shim), `t_categories` (T-CAT), `t_libroots` (T-LIBROOTS), `t_format` (T-FORMAT) cover registry-query and `_audit-shared.json`) |

Tests follow a tiny protocol (see `lib/common.sh`): exit 0 = PASS, 77 = SKIP, anything
else = FAIL. Each test can also be run on its own: `bash tests/unit/t_lint.sh`.
