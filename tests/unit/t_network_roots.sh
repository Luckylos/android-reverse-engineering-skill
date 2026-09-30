#!/usr/bin/env bash
# t_network_roots.sh -- T-NETROOTS (DESIGN 6): the FROZEN legacy tables NETWORK_ROOTS
# (25 "root|label") and COMMON_ROOTS (56 roots) of detect-adwrapper are identical, in
# the same order, in detect-adwrapper.sh and detect-adwrapper.ps1 (both marked
# "FROZEN legacy table"), and every NETWORK_ROOTS root is covered by a registry entry:
# some package / extra_package / namespace_root of an entry is equal to the root, above
# it or below it. Allowlist (no single entry owns the root): com/unity3d (shared by
# unity-ads and ironsource's com.unity3d.mediation), com/google/ads (legacy AdMob
# namespace) and com/mopub (no entry). The tables go away in step 2 (derived from the
# registry, DESIGN Q3); until then this test keeps the two copies from drifting.
# requires: NS/detect-adwrapper.sh NS/detect-adwrapper.ps1 NS/registry-query.sh
# requires: cmd: have_jq16
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
export LC_ALL=C

SH=$NS/detect-adwrapper.sh
PS=$NS/detect-adwrapper.ps1
ALLOW="com/unity3d com/google/ads com/mopub"
mktemp_dir tmp

# sh: the lines of NAME='...' (multi-line single-quoted string)
sh_table() {
  awk -v name="$1" '
    !on && index($0, name "=\047") == 1 { on = 1; sub(/^[^\047]*\047/, "") }
    on { end = (index($0, "\047") > 0); sub(/\047.*$/, ""); if ($0 != "") print; if (end) exit }' "$SH"
}
# ps1: every '...' string between `$name = @(` and the closing `)`
ps_table() {
  tr -d '\r' <"$PS" | awk -v name="$1" '
    !on && index($0, "$" name " = @(") == 1 { on = 1; next }
    on && /^\)/ { exit }
    on { s = $0
         while ((i = index(s, "\047")) > 0) { s = substr(s, i + 1); j = index(s, "\047")
           if (j == 0) break; print substr(s, 1, j - 1); s = substr(s, j + 1) } }'
}
sh_table NETWORK_ROOTS >"$tmp/net.sh"
sh_table COMMON_ROOTS >"$tmp/common.sh"
ps_table networkRoots >"$tmp/net.ps"
ps_table commonRoots >"$tmp/common.ps"
assert_eq 25 "$(wc -l <"$tmp/net.sh" | tr -d ' ')" "sh NETWORK_ROOTS has 25 rows"
assert_eq 56 "$(wc -l <"$tmp/common.sh" | tr -d ' ')" "sh COMMON_ROOTS has 56 rows"
assert_files_eq "$tmp/net.sh" "$tmp/net.ps" "NETWORK_ROOTS: sh == ps1 (same rows, same order)"
assert_files_eq "$tmp/common.sh" "$tmp/common.ps" "COMMON_ROOTS: sh == ps1 (same rows, same order)"
assert_eq "" "$(grep -v '^[a-z0-9_$]*\(/[a-z0-9_]*\)*|[a-z0-9]*$' "$tmp/net.sh")" "NETWORK_ROOTS rows are root|label"
assert_eq 2 "$(grep -c 'FROZEN legacy table' "$SH")" "sh: both tables marked FROZEN"
assert_eq 2 "$(grep -c 'FROZEN legacy table' "$PS")" "ps1: both tables marked FROZEN"

# coverage by the registry (identity packages, extra packages, namespace roots)
run_bash "$NS/registry-query.sh" --registry "$REG" rows 2>"$tmp/rq.err" |
  awk -F '\t' '$3 == "package" || $3 == "extra_package" || $3 == "namespace_root" { p = $4; gsub(/\./, "/", p); print $1 "\t" p }' \
  >"$tmp/pk.tsv"
assert_true "registry-query rows produced packages" test -s "$tmp/pk.tsv"
while IFS='|' read -r root label; do
  [ -n "$root" ] || continue
  owners=$(awk -F '\t' -v r="$root" '$2 == r || index($2, r "/") == 1 || index(r, $2 "/") == 1 { print $1 }' "$tmp/pk.tsv" | sort -u | tr '\n' ' ')
  case " $ALLOW " in
    *" $root "*) echo "note: $root ($label) allowlisted; entries: ${owners:-none}" ;;
    *) _T_CHECKS=$((_T_CHECKS + 1))
       if [ -n "$owners" ]; then pass_check "$root covered"; else fail_check "NETWORK_ROOTS $root ($label) is not covered by any registry entry"; fi ;;
  esac
done <"$tmp/net.sh"
for a in $ALLOW; do assert_true "allowlisted $a is a NETWORK_ROOTS root" grep -q "^$a|" "$tmp/net.sh"; done
t_done
