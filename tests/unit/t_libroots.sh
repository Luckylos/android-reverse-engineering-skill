#!/usr/bin/env bash
# t_libroots.sh -- T-LIBROOTS (DESIGN 2.3): library_roots of REG/_audit-shared.json plus
# the registry roots (identity: package + extra_package; namespace_root; adapter_package,
# as printed by `registry-query.sh rows`) cover every KNOWN_LIBRARY_PACKAGES entry of
# registry-scan.py, converted to dotted form: each one equals a root or lies under one.
# One-way check: registry-scan.py is never modified (I1, I23).
# Also: library_roots has no duplicates and every root is a dotted package.
# requires: NS/registry-query.sh REG/_audit-shared.json
# requires: cmd: have_jq16
# requires: cmd: command -v python3 >/dev/null
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

mktemp_dir tmp
python3 - "$NS/registry-scan.py" >"$tmp/known" <<'PY' || die "cannot read KNOWN_LIBRARY_PACKAGES"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", None) == "KNOWN_LIBRARY_PACKAGES":
        for v in sorted(ast.literal_eval(node.value)):
            print(v.replace("/", "."))
PY
[ -s "$tmp/known" ] || die "KNOWN_LIBRARY_PACKAGES not found in registry-scan.py"

run_bash "$NS/registry-query.sh" --registry "$REG" shared >"$tmp/shared" 2>&1 || die "registry-query shared failed: $(head -n 3 "$tmp/shared")"
run_bash "$NS/registry-query.sh" --registry "$REG" rows >"$tmp/rows" 2>&1 || die "registry-query rows failed: $(head -n 3 "$tmp/rows")"
awk -F '\t' '$1 == "library_root" { print $3 }' "$tmp/shared" >"$tmp/libroots"
assert_eq "" "$(sort "$tmp/libroots" | uniq -d)" "library_roots has no duplicates"
assert_eq "" "$(grep -vE '^[a-z][a-z0-9_]*[$]?([.][A-Za-z0-9_]+)*$' "$tmp/libroots")" "library_roots are dotted packages"
{
  cat "$tmp/libroots"
  awk -F '\t' '$3 == "package" || $3 == "extra_package" || $3 == "namespace_root" || $3 == "adapter_package" { print $4 }' "$tmp/rows"
} | sort -u >"$tmp/roots"

awk 'NR == FNR { root[$0] = 1; next }
  { p = $0; ok = 0
    while (p != "") {
      if (p in root) { ok = 1; break }
      if (index(p, ".") == 0) break
      sub(/[.][^.]*$/, "", p)
    }
    if (!ok) print $0 }' "$tmp/roots" "$tmp/known" >"$tmp/uncovered"
assert_eq "" "$(cat "$tmp/uncovered")" "every KNOWN_LIBRARY_PACKAGES entry is covered by library_roots or a registry root"
echo "KNOWN_LIBRARY_PACKAGES: $(wc -l <"$tmp/known" | tr -d ' ') checked against $(wc -l <"$tmp/roots" | tr -d ' ') roots"
t_done
