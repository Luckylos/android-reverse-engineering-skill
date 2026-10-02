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
test). Directives (`# requires:`, `# awk-matrix`) are read only from the leading comment
block of a test (up to the first line that does not start with `#`); `t_runner` fails
when one sits further down, where it would be ignored. A suite with no test script yet prints `SKIP <suite> no tests found`. Under
`--expect-pass` every SKIP, SKIP(requires) and empty suite of the named suites/tests is a
FAIL. Exit 0 = nothing failed.

Suite discovery: `unit/t_*.sh`, `parity/t_*.sh`; `corpus` = every `corpus/*.sh` (the
DESIGN names `groundtruth.sh`, `exclusions-superset.sh`, `marker-verify.sh`) except the
helper `prepare-pristine.sh` and `perf*.sh` (suite `perf`); `bash32` = `bash32/*.sh` and
any `<dir>/bash32.sh`. A single script also runs by name (`tests/run.sh marker-verify`).

| Path | What |
|---|---|
| `run.sh`, `lib/common.sh` | runner and shared helpers (env: `ARE_CORPUS`, `ARE_JADX`, `ARE_GOLD`, `ARE_PS`, `BASH32`, `ARE_PRISTINE`, ...; defaults derive from the checkout's parent directory) |
| `lint/lint-registry.sh` | registry lint, rules L1-L15 of DESIGN 4.6 (`--help` lists them; L11 is a WARN, L14 an INFO report on the FROZEN detect-adwrapper tables; L5/L7 read the allowed keys and patterns from `_schema.json`), plus JSON-schema validation when python `jsonschema` is installed (`--no-schema` skips it) |
| `golden/capture.sh`, `golden/compare.sh`, `golden/t_golden.sh` | registry-scan (8 apps x depth 1-3 x ads/trackers/all + synth48) and detect-adwrapper (sh with/without `--registry`, ps1) must stay byte-identical to the frozen baseline `$ARE_GOLD/before` |
| `golden/synth48.before/` | G-synth: registry-scan outputs on the synth48 fixture, captured with the product of 4c166fe |
| `golden/snapshot.sh`, `golden/snapshot.before.jsonl`, `golden/t_snapshot.sh` | the registry fields today's consumers read must not change for the 48 original entries |
| `fixtures/` | generators of synthetic trees (synth48, adwrapper fixture, pitfalls) and expected outputs; no proprietary code |
| `shims/` | `nojq`, `jq15` (fake jq 1.5), `nosudo`, `awk-{gawk-posix,mawk,busybox}` for the portability paths (`with_shim` with `nojq` or `jq15` also sets `HOME` to a missing dir, so a real `~/.local/bin/jq` cannot beat the shim) |
| `parity/ps.sh` | runs a `.ps1` with Windows PowerShell 5.1 from WSL (`-File`, Windows paths) |
| `parity/t_parity.sh` | sh/ps1 byte parity (`--only <section>`: `registry-query`, `adwrapper`, `find`, each incl. the in-process case; the 8-app corpus part of `adwrapper`, and the badpiggies + pitfall part of `find`, run when the section is named with `--only` or under `run.sh full`, which exports `ARE_FULL=1`; `find` compares `find-*.ps1` with `find-*.sh`: `--tsv`/`--summary` byte-identical, text normalized, `--json` semantic, on the five layouts, a drive-letter copy (also as a subst drive root), trees with an unreadable directory or symlinks, `.` inside `sources/` and HeartStar; PowerShell runs go in parallel, `ARE_PS_JOBS`, default 4) |
| `fixtures/registry-{mini,edge,bad}/`, `fixtures/expected/registry-query/` | registry-query fixtures (clean; BOM + case-colliding keys; every integrity error) and their expected outputs |
| `unit/` | unit tests (`t_*.sh`; `t_runner.sh` covers run.sh itself; `t_reader`, `t_pkg_parity` (T-PKG-PARITY, always per awk shim), `t_categories` (T-CAT), `t_libroots` (T-LIBROOTS), `t_format` (T-FORMAT) cover registry-query and `_audit-shared.json`; `t_adwrapper` (fixture, jq/nojq/jq15, malformed registries, `--dump-exclusions`, decode-apk.sh exit code; per awk shim) and `t_network_roots` (T-NETROOTS: the frozen NETWORK_ROOTS/COMMON_ROOTS tables, sh == ps1, covered by the registry) cover detect-adwrapper; `t_deps` covers jq as a dependency: `install-dep.sh jq` (package manager only with sudo, else the pinned static binary via the test-only `ARE_JQ_URL`/`ARE_JQ_SHA256` hooks), the `neutralize-all` soft-fail, `INSTALL_OPTIONAL:jq` of the bash checkers with unchanged exit codes, every `INSTALL_*` name being an install-dep target, and the `.ps1` checkers never asking for jq) |
| `corpus/exclusions-superset.sh` | I11: the `.packages`-based exclusions cover the legacy ones (legacy script of `$ARE_BASE_COMMIT` patched at test time to dump them), in the jq/nojq/jq15 modes; nojq/jq15 detect-adwrapper output on the 8 apps == G |
| `corpus/marker-verify.sh`, `corpus/marker-allowlist.tsv` | T-MARKER (DESIGN 3.1 R4): every `detection.marker_classes` item has its class file in the main smali dirs of at least one corpus app where the ground truth (`$ARE_GROUND_TRUTH`, default `registry-unification/ground-truth.json`) has that SDK, else a reviewed allowlist row with a reason; corpus tree per app = `$ARE_PRISTINE/<app>`, else `$ARE_CORPUS/<app>-decoded`, else the ground truth's `decoded_dir` |
| `unit/t_cli.sh`, `unit/t_layouts.sh`, `unit/t_pitfalls.sh`, `unit/t_tokens.sh` | the audit engine `sdk-audit.sh` behind `find-trackers.sh` / `find-ads.sh`: every historical flag, option normalization, exit codes 0/1/2 (`t_cli`); the five input layouts and their expected outputs `fixtures/expected/layouts/` (`t_layouts`, fixture `fixtures/make-layouts.sh`; also the PowerShell twins `find-*.ps1` on the same expected files, through `\\wsl.localhost` and a drive-letter copy, when PowerShell is reachable); the legacy false positives/negatives (`t_pitfalls`); T-TOKENS: every regex alternative of the legacy scripts has a resolvable home in `fixtures/legacy-tokens.tsv` (`t_tokens`) |
| `corpus/groundtruth.sh`, `corpus/expected-sdkids.json`, `corpus/known-deviations.tsv`, `corpus/ep-allowlist.tsv` | the corpus gates of the audit on the pristine apktool decodes and the jadx corpus: G-PREC (HIGH precision 1.0), G-REC (recall, jadx package aliases), G-HS (HeartStar), G-NEW, G-FP-KNOWN (`known-deviations.tsv`), G-EP (Entry Points only under the reviewed `ep-allowlist.tsv` prefixes); `ARE_JADX_EXTRA` names the HeartStar / Water Sort jadx dirs |
| `corpus/find-golden.sh`, `golden/find/` | `--tsv` goldens of both tools on the 9 pristine decodes (`ARE_UPDATE_EXPECTED=1` rewrites them) |
| `corpus/perf.sh` (suite `perf`), `corpus/prepare-pristine.sh` | engine time budgets, WARN only (the PowerShell twin is timed too: logged, Subway beyond 60 s is a WARN); the helper that decodes the corpus originals into `$ARE_PRISTINE` (not a test) |

Tests follow a tiny protocol (see `lib/common.sh`): exit 0 = PASS, 77 = SKIP, anything
else = FAIL. Each test can also be run on its own: `bash tests/unit/t_lint.sh`.
