#!/usr/bin/env bash
# sdk-audit.sh -- the SDK audit engine behind find-trackers.sh and find-ads.sh
# (tracker-analysis / ad-analysis skills). The SDK registry (../registry/*.json, read
# with registry-query.sh) is the only source of SDK knowledge: identity packages,
# marker classes, APIs, manifest names, domains, id prefixes; _audit-shared.json holds
# the cross-SDK tables (groups, legacy flags, role labels, ad formats, library roots,
# hints). PowerShell twin: sdk-audit.ps1 (same algorithm and output).
#
# Usage: sdk-audit.sh --tool find-trackers|find-ads <input-dir> [options]
#   (normally through the wrappers find-trackers.sh / find-ads.sh; run with -h for the
#   options of each tool)
#
# Algorithm (DESIGN 5.4), all under LC_ALL=C, counting in POSIX awk:
#   1. plan: registry rows + shared tables -> ownership roots (identity = packages +
#      detection.extra_packages, in-house, namespace, adapter, exclude, library_roots)
#   2. input layout (apktool / jadx / jadx-sources / jadx-xapk / tree), jadx package
#      aliases ("JADX INFO: renamed from:" votes), one inventory of the code files: each
#      file belongs to the longest root that contains it (excludes applied); files of no
#      root, of an in-house root or under the app's manifest package are app code
#   3. one prefiltered grep over the app code: class references (import / FQCN / smali
#      token), API calls (exact, or import-scoped instance calls), hints
#   4. one grep over all code for domains and id prefixes
#   5. AndroidManifest.xml state machine (attributes on one line or on several)
#   6. verdict per SDK: HIGH (code under an identity root + a declared marker class when
#      there are markers), MEDIUM (code without its markers = partial, or manifest only),
#      LOW (app-code references, endpoints, id prefixes only), NONE
#
# Exit: 0 done (also with no findings; -h); 1 bad option, missing input, --sdk outside
# the tool group, registry error; 2 jq missing or older than 1.6 (INSTALL_REQUIRED:jq on
# stdout, the install command on stderr).
# Portability: bash 3.2, POSIX awk (gawk --posix, mawk, busybox, BWK), grep -F, find,
# xargs -0, sort; jq >= 1.6 (through registry-query.sh, and for --json).
set -uo pipefail
export LC_ALL=C

# Same jq lookup as registry-query.sh / install-dep.sh: the static jq of
# `install-dep.sh jq` lives in ~/.local/bin, which may be missing from the caller's PATH.
if [ -n "${HOME:-}" ] && [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RQ=$SCRIPT_DIR/registry-query.sh
TAB=$(printf '\t')
BASH_BIN=${BASH:-bash}

TOOL=""
if [ "${1:-}" = "--tool" ] && [ $# -ge 2 ]; then TOOL=$2; shift 2; fi
case "$TOOL" in
  find-trackers) TOOL_TITLE=Tracker; ASPECTS="generic endpoints manifest entrypoints"; WRAPPER=find-trackers.sh ;;
  find-ads)      TOOL_TITLE=Ad;      ASPECTS="formats mediation consent manifest entrypoints"; WRAPPER=find-ads.sh ;;
  *) echo "sdk-audit: internal error: the first arguments must be --tool find-trackers|find-ads" >&2; exit 1 ;;
esac

usage() {
  if [ "$TOOL" = find-trackers ]; then
    cat <<'EOF'
Usage: find-trackers.sh <input-dir> [options]

Audit a decoded/decompiled Android app for tracker and analytics SDKs (every tracker
entry of the SDK registry: analytics, attribution, crash_reporting, social).

<input-dir>: an apktool decode dir (AndroidManifest.xml + smali*/), a jadx output dir
(sources/ + resources/), its sources/ dir, a jadx XAPK dir (<split>/sources/), or any
source tree (then pass --manifest-path).

SDK filters (combinable):
  --firebase --adjust --appsflyer --mixpanel --amplitude --segment --braze
  --clevertap --flurry
  --sdk <sdk_id>      any tracker entry of the registry (repeatable; see --list-sdks)
Aspects:
  --generic           generic cross-SDK calls (hints, never evidence)
  --endpoints         known tracker endpoints (registry domains)
  --manifest          AndroidManifest.xml services, receivers, permissions, meta-data
  --entrypoints       tracker SDK calls and references from app code only
  --all               everything (default; also after filters)
Output:
  (default)           text sections: ==== <Section> ====, rows path:line:text
  --summary           one row per SDK with confidence (legacy SDKs + detected tracker entries)
  --tsv               machine-readable rows (one SDK row for every one of the tracker entries)
  --json              JSON report v2 (detected tracker entries only)
                      (--json > --tsv > --summary; they ignore the filters)
Other:
  --manifest-path F   AndroidManifest.xml to use
  --registry DIR      SDK registry directory (default: sdk-neutralizer/registry)
  --list-sdks         list the tracker entries of the registry (TSV) and exit
                      (packages = neutralized by registry-scan; audit_only_packages = never neutralized)
  --full              no 50-row limit on the "<SDK> — References" sections
  --no-hints          leave out the generic hints
  -h, --help          this help
Options are case-insensitive and may use one or two dashes (--sdk:x and --sdk=x work).

Confidence: HIGH = SDK code present (+ its marker class when declared); MEDIUM = code
without the declared marker class (partial), or AndroidManifest only; LOW = app-code
references / endpoints only; NONE = not detected. Rows ending in [sdk_id/role]
name the SDK; role "ref" = class reference, a trailing "?" = import-scoped instance call.
Exit: 0 done, 1 error, 2 jq >= 1.6 missing (INSTALL_REQUIRED:jq).
EOF
  else
    cat <<'EOF'
Usage: find-ads.sh <input-dir> [options]

Audit a decoded/decompiled Android app for advertising SDKs and consent frameworks
(every ads, ads_mediation and consent entry of the SDK registry).

<input-dir>: an apktool decode dir (AndroidManifest.xml + smali*/), a jadx output dir
(sources/ + resources/), its sources/ dir, a jadx XAPK dir (<split>/sources/), or any
source tree (then pass --manifest-path).

SDK filters (combinable):
  --admob --unity --ironsource --applovin --facebook (Meta Audience Network)
  --vungle --inmobi --chartboost --pangle --mintegral
  --sdk <sdk_id>      any ads/consent entry of the registry (repeatable; see --list-sdks)
Aspects:
  --formats           ad formats (banner, interstitial, rewarded, native, ...) and
                      ad unit / placement ids
  --mediation         mediation adapters, adapter classes, waterfall configuration
  --consent           UMP, IAB TCF, COPPA, SDK-specific opt-out calls
  --manifest          AndroidManifest.xml ad activities, permissions, meta-data
  --entrypoints       ad SDK calls and references from app code only
  --all               everything (default; also after filters)
Output:
  (default)           text sections: ==== <Section> ====, rows path:line:text
  --summary           one row per SDK with confidence (legacy SDKs + detected ads/consent entries)
  --tsv               machine-readable rows (one SDK row for every one of the ads/consent entries)
  --json              JSON report v2 (detected ads/consent entries only)
                      (--json > --tsv > --summary; they ignore the filters)
Other:
  --manifest-path F   AndroidManifest.xml to use
  --registry DIR      SDK registry directory (default: sdk-neutralizer/registry)
  --list-sdks         list the ads/consent entries of the registry (TSV) and exit
                      (packages = neutralized by registry-scan; audit_only_packages = never neutralized)
  --full              no 50-row limit on the "<SDK> — References" sections
  --no-hints          leave out the hint rows (informational token matches)
  -h, --help          this help
Options are case-insensitive and may use one or two dashes (--sdk:x and --sdk=x work).

Confidence: HIGH = SDK code present (+ its marker class when declared); MEDIUM = code
without the declared marker class (partial), or AndroidManifest only; LOW = app-code
references / endpoints / ad unit ids only; NONE = not detected. Rows ending in
[sdk_id/role] name the SDK; role "ref" = class reference, a trailing "?" =
import-scoped instance call.
Exit: 0 done, 1 error, 2 jq >= 1.6 missing (INSTALL_REQUIRED:jq).
EOF
  fi
}
die() { echo "Error: $1" >&2; exit 1; }
die_usage() { echo "Error: $1" >&2; echo >&2; usage >&2; exit 1; }
info() { echo "[INFO] $*" >&2; }

# ---- arguments -------------------------------------------------------------------------
# An option token loses all its dashes and is lowercased (--manifest-path, -ManifestPath
# -> manifestpath). --name:value / --name=value in one token only for valued options.
SEL_ALL=1; SEL_FLAGS=""; SEL_SDKS=""; SEL_ASPECTS=""; FILTERS=0
OUT_SUMMARY=0; OUT_TSV=0; OUT_JSON=0
INPUT=""; MANIFEST_PATH=""; REGISTRY=""; LIST=0; FULL=0; NOHINTS=0
endopts=0
while [ $# -gt 0 ]; do
  a=$1; shift
  if [ "$endopts" = 1 ]; then INPUT=$a; continue; fi
  case "$a" in
    --) endopts=1; continue ;;
    -*) ;;
    *) INPUT=$a; continue ;;
  esac
  name=$a; val=""; hasval=0
  case "$a" in *[:=]*) name=${a%%[:=]*}; val=${a#*[:=]}; hasval=1 ;; esac
  n=$(printf '%s' "$name" | tr -d '-' | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
  case "$n" in
    sdk|manifestpath|registry)
      if [ "$hasval" = 0 ]; then
        [ $# -gt 0 ] || die_usage "option $name requires a value"
        val=$1; shift
      fi
      [ -n "$val" ] || die_usage "option $name requires a value"
      case "$n" in
        sdk) SEL_SDKS="$SEL_SDKS $val"; SEL_ALL=0; FILTERS=1 ;;
        manifestpath) MANIFEST_PATH=$val ;;
        registry) REGISTRY=$val ;;
      esac ;;
    *)
      [ "$hasval" = 0 ] || die_usage "option $name takes no value"
      case "$n" in
        h|help) usage; exit 0 ;;
        all) SEL_ALL=1 ;;
        summary) OUT_SUMMARY=1 ;;
        tsv) OUT_TSV=1 ;;
        json) OUT_JSON=1 ;;
        listsdks) LIST=1 ;;
        full) FULL=1 ;;
        nohints) NOHINTS=1 ;;
        '') die_usage "unknown option: $a" ;;
        *)
          case " $ASPECTS " in
            *" $n "*) SEL_ASPECTS="$SEL_ASPECTS $n"; SEL_ALL=0; FILTERS=1 ;;
            *) case "$n" in
                 *[!a-z0-9]*) die_usage "unknown option: $a" ;;
               esac
               # an SDK flag of the tool (legacy_flags of _audit-shared.json): checked
               # once the registry is read
               SEL_FLAGS="$SEL_FLAGS $n"; SEL_ALL=0; FILTERS=1 ;;
          esac ;;
      esac ;;
  esac
done

if [ "$LIST" = 0 ]; then
  [ -n "$INPUT" ] || die_usage "no input directory specified"
  [ -d "$INPUT" ] || die "Directory not found: $INPUT"
fi
if [ -n "$MANIFEST_PATH" ] && [ ! -f "$MANIFEST_PATH" ]; then die "manifest not found: $MANIFEST_PATH"; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sdkaudit.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

# ---- registry ----------------------------------------------------------------------------
rq() { # rq <verb> > file: registry-query with the --registry of the command line
  if [ -n "$REGISTRY" ]; then "$BASH_BIN" "$RQ" --registry "$REGISTRY" "$1"
  else "$BASH_BIN" "$RQ" "$1"; fi
}
[ -f "$RQ" ] || die "registry-query.sh not found at $RQ (install the whole android-reverse-engineering plugin)"
for verb in rows shared; do
  rq "$verb" >"$TMP/$verb.tsv" 2>"$TMP/rq.err"
  rc=$?
  if [ "$rc" = 2 ]; then cat "$TMP/$verb.tsv"; cat "$TMP/rq.err" >&2; exit 2; fi
  if [ "$rc" != 0 ]; then cat "$TMP/rq.err" >&2; die "cannot read the SDK registry"; fi
  cat "$TMP/rq.err" >&2
done
command -v jq >/dev/null 2>&1 || { echo "INSTALL_REQUIRED:jq"; exit 2; }

# ---- plan: derived tables ---------------------------------------------------------------
cat >"$TMP/plan.awk" <<'AWK'
# rows.tsv (sdk category field value) + shared.tsv (kind key value) -> plan tables
BEGIN { FS = "\t"; OFS = "\t"; O = ENVIRON["SA_TMP"]; tool = ENVIRON["SA_TOOL"] }
kind == "shared" {
  if ($1 == "tool_group" && $2 == tool) ingroup[$3] = 1
  else if ($1 == "category_group") catgroup[$3] = $2
  else if ($1 == "legacy_flag" && $2 == tool) {
    n = split($3, a, " "); pre = ""
    for (i = 4; i <= n; i++) pre = pre "" (i > 4 ? " " : "") a[i]
    nl++; print a[1], a[2], a[3], pre, nl > (O "/legacy.tsv")
    lrank[a[2]] = nl; lflag[a[2]] = a[1]; llabel[a[2]] = a[3]; lpre[a[2]] = pre
  }
  else if ($1 == "role_label") print $2, $3 > (O "/roles.tsv")
  else if ($1 == "section_separator") sep = $3
  else if ($1 == "format_token") { n = split($3, a, " "); print $2, a[1], a[2] > (O "/fmt.tsv") }
  else if ($1 == "library_root") print $3, "lib", "-" > (O "/roots.tsv")
  else if ($1 == "hint_meta") {
    split($3, a, " ")   # id tool flag scope match
    hn++; hid[hn] = a[1]; htool[a[1]] = a[2]; hflag[a[1]] = a[3]; hscope[a[1]] = a[4]; hmatch[a[1]] = a[5]
  }
  else if ($1 == "hint_title") htitle[$2] = $3
  else if ($1 == "hint_token") { tn++; tid[tn] = $2; ttok[tn] = $3 }
  next
}
kind == "rows" {
  s = $1; f = $3; v = $4
  if (!(s in cat)) { ns++; ids[ns] = s; cat[s] = $2 }
  if (f == "display_name") disp[s] = v
  else if (f == "group") grp[s] = v
  else if (f == "in_house_wrapper") inh[s] = (v == "true")
  else if (f == "has_targets") tgt[s] = v
  else if (f == "package" || f == "extra_package") {
    if (f == "package") pk[s] = pk[s] "" (pk[s] == "" ? "" : " ") v
    else xp[s] = xp[s] "" (xp[s] == "" ? "" : " ") v
    npk++; pks[npk] = s; pkv[npk] = v; pkf[npk] = f
  }
  else if (f == "exclude_package") print v, "ex", s > (O "/roots.tsv")
  else if (f == "namespace_root") print v, "ns", s > (O "/roots.tsv")
  else if (f == "adapter_package") print v, "ad", s > (O "/roots.tsv")
  else if (f == "marker_class") print s, v > (O "/markers.tsv")
  else if (f == "manifest_component") print s, v > (O "/mcomps.tsv")
  else if (f == "manifest_name") print s, v > (O "/mnames.tsv")
  else if (f == "domain") print s, v > (O "/domains.tsv")
  else if (f == "id_prefix") { split(v, a, " "); print s, a[1], a[2] > (O "/idpfx.tsv") }
  else if (f == "target_api" || f == "api") {
    split(v, a, " ")
    role = a[3]
    if (f == "target_api") role = (a[3] == "entry_point") ? "init" : "ad_operation"
    k = a[1] SUBSEP a[2] SUBSEP role SUBSEP s
    if (!(k in seenapi)) { seenapi[k] = 1; print a[1], a[2], role, s > (O "/api.tsv") }
  }
  next
}
END {
  for (i = 1; i <= npk; i++) print pkv[i], (inh[pks[i]] ? "inh" : "id"), pks[i] > (O "/roots.tsv")
  for (i = 1; i <= ns; i++) {
    s = ids[i]
    g = grp[s]
    print s, cat[s], g, disp[s], (inh[s] ? "true" : "false"), tgt[s], ((g in ingroup) ? 1 : 0),
          ((s in lrank) ? lrank[s] : 1000), ((s in lflag) ? lflag[s] : "-"), ((s in llabel) ? llabel[s] : "-"),
          ((s in lpre) ? lpre[s] : disp[s]), (pk[s] == "" ? "-" : pk[s]), (xp[s] == "" ? "-" : xp[s]) > (O "/ent0.tsv")
  }
  for (i = 1; i <= hn; i++) {
    id = hid[i]
    if (htool[id] != tool) continue
    print i, id, hflag[id], hscope[id], hmatch[id], htitle[id] > (O "/hints.tsv")
  }
  for (i = 1; i <= tn; i++) if (htool[tid[i]] == tool) print tid[i], ttok[i], hmatch[tid[i]], hscope[tid[i]] > (O "/htok.tsv")
  print sep > (O "/sep.txt")
  g = ""; for (k in ingroup) g = g " " k
  print g " " > (O "/groups.txt")
}
AWK
for f in legacy roles fmt roots markers mcomps mnames domains idpfx api ent0 hints htok; do : >"$TMP/$f.tsv"; done
SA_TMP=$TMP SA_TOOL=$TOOL awk -f "$TMP/plan.awk" kind=shared "$TMP/shared.tsv" kind=rows "$TMP/rows.tsv" ||
  die "cannot build the audit plan from the registry"
# entries: legacy rows first (legacy_flags order), then sdk_id (ordinal)
sort -t "$TAB" -k8,8n -k1,1 "$TMP/ent0.tsv" >"$TMP/ent.tsv"
SEP=$(cat "$TMP/sep.txt")

# ---- SDK flags / --sdk ---------------------------------------------------------------------
SEL_IDS=""
for f in $SEL_FLAGS; do
  id=$(awk -F '\t' -v f="$f" '$1 == f { print $2; exit }' "$TMP/legacy.tsv")
  [ -n "$id" ] || die_usage "unknown option: --$f"
  SEL_IDS="$SEL_IDS $id"
done
for id in $SEL_SDKS; do
  line=$(awk -F '\t' -v s="$id" '$1 == s { print; exit }' "$TMP/ent.tsv")
  [ -n "$line" ] || die "unknown SDK '$id' (see $WRAPPER --list-sdks)"
  case "$(printf '%s\n' "$line" | cut -f7)" in
    1) SEL_IDS="$SEL_IDS $id" ;;
    *) g=$(printf '%s\n' "$line" | cut -f3)
       case "$g" in
         trackers) die "'$id' is a find-trackers SDK" ;;
         ads|consent) die "'$id' is a find-ads SDK" ;;
         *) die "'$id' is not a $TOOL SDK (group $g)" ;;
       esac ;;
  esac
done

if [ "$LIST" = 1 ]; then
  # packages = the entry's .packages (what registry-scan / neutralize cover when neutralizable=yes);
  # audit_only_packages = detection.extra_packages (identity for the audit only, NEVER neutralized)
  printf 'sdk_id\tcategory\tlegacy_flag\tneutralizable\tpackages\taudit_only_packages\n'
  awk -F '\t' '$7 == 1 { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, ($9 == "-" ? "-" : "--" $9), ($6 == "true" ? "yes" : "no"), $12, $13 }' "$TMP/ent.tsv" |
    sort -t "$TAB" -k1,1
  exit 0
fi

MODE=text
if [ "$OUT_JSON" = 1 ]; then MODE=json
elif [ "$OUT_TSV" = 1 ]; then MODE=tsv
elif [ "$OUT_SUMMARY" = 1 ]; then MODE=summary; fi
if [ "$MODE" != text ] && [ "$FILTERS" = 1 ]; then
  info "--$MODE reports the whole $TOOL group of the registry: SDK and aspect filters are ignored"
fi

# ---- input layout (DESIGN 5.3) ------------------------------------------------------------
D=$INPUT
while :; do case "$D" in */) [ "$D" = / ] && break; D=${D%/} ;; *) break ;; esac; done
DISP=$D                  # the input as passed (printed); D is used for I/O
# "./" keeps relative paths from being read as options (-x) or, by awk, as var=value assignments
case "$D" in /*|.*) ;; *) D=./$D ;; esac
: >"$TMP/coderoots"      # rootrel (relative to D; "" = D itself), ordinal order
MAN=""                   # manifest path as used for reading
MANDISP=""               # manifest path as printed
LAYOUT=""
smali_dirs() { for _d in "$D"/smali*; do [ -d "$_d" ] && basename "$_d"; done | grep -vx 'smali_assets' | sort; }
if [ -f "$D/AndroidManifest.xml" ] && [ -n "$(smali_dirs)" ]; then
  LAYOUT=apktool
  smali_dirs >"$TMP/coderoots"
  MAN=$D/AndroidManifest.xml; MANDISP=$DISP/AndroidManifest.xml
elif [ -d "$D/sources" ]; then
  LAYOUT=jadx
  echo sources >"$TMP/coderoots"
  if [ -f "$D/resources/AndroidManifest.xml" ]; then MAN=$D/resources/AndroidManifest.xml; MANDISP=$DISP/resources/AndroidManifest.xml; fi
elif [ "$(basename "$(CDPATH='' cd -- "$D" && pwd)")" = sources ] && [ -f "$D/../resources/AndroidManifest.xml" ]; then
  # basename of the absolute (logical) path, as the ps1 twin: "." inside <out>/sources is jadx-sources
  LAYOUT=jadx-sources
  echo "" >"$TMP/coderoots"
  MAN=$D/../resources/AndroidManifest.xml; MANDISP=$DISP/../resources/AndroidManifest.xml
else
  for _d in "$D"/*/sources; do [ -d "$_d" ] && basename "$(dirname "$_d")"; done | sort >"$TMP/splits"
  if [ -s "$TMP/splits" ]; then
    LAYOUT=jadx-xapk
    sed 's#$#/sources#' "$TMP/splits" >"$TMP/coderoots"
    first=""; base=""
    while IFS= read -r sp; do
      m=$D/$sp/resources/AndroidManifest.xml
      [ -f "$m" ] || continue
      [ -n "$first" ] || first=$sp
      if ! awk '/<manifest/ { on = 1 } on && /split=/ { f = 1 } on && />/ { exit } END { exit !f }' "$m"; then
        base=$sp; break
      fi
    done <"$TMP/splits"
    [ -n "$base" ] || base=$first
    if [ -n "$base" ]; then MAN=$D/$base/resources/AndroidManifest.xml; MANDISP=$DISP/$base/resources/AndroidManifest.xml; fi
  else
    LAYOUT=tree
    echo "" >"$TMP/coderoots"
    if [ -f "$D/AndroidManifest.xml" ]; then MAN=$D/AndroidManifest.xml; MANDISP=$DISP/AndroidManifest.xml; fi
  fi
fi
if [ -n "$MANIFEST_PATH" ]; then
  MAN=$MANIFEST_PATH; MANDISP=$MANIFEST_PATH
  case "$MAN" in /*|.*) ;; *) MAN=./$MAN ;; esac
fi
info "layout: $LAYOUT"
while IFS= read -r r; do info "code root: $DISP${r:+/$r}"; done <"$TMP/coderoots"
if [ -n "$MAN" ]; then info "manifest: $MANDISP"; else info "# manifest: not found (use --manifest-path)"; fi
case "$LAYOUT" in jadx*) JADX=1 ;; *) JADX=0 ;; esac

# ---- manifest (DESIGN 5.4 step 6) -------------------------------------------------------------
cat >"$TMP/man.awk" <<'AWK'
# AndroidManifest.xml -> PKG <pkg> / N <line> <tag> <name> / L <line> <text>. Remembers the
# last opened tag, so jadx's one-attribute-per-line layout works like apktool's. Only tags that
# declare something in the APK name an SDK: components, permissions, meta-data and intent actions.
# <queries><package> (another app the host wants to see), uses-library, uses-feature, category,
# property and application are never evidence.
BEGIN {
  OFS = "\t"; tag = ""
  n = split("activity activity-alias service receiver provider meta-data uses-permission permission action", a, " ")
  for (i = 1; i <= n; i++) DECL[a[i]] = 1
}
{
  sub(/\r$/, "")
  s = $0; off = 0; named = 0
  while (1) {
    lt = index(s, "<"); nm = index(s, "android:name=\""); pk = (tag == "manifest" || index(s, "<manifest")) ? index(s, "package=\"") : 0
    nxt = 0; what = ""
    if (lt > 0) { nxt = lt; what = "tag" }
    if (nm > 0 && (nxt == 0 || nm < nxt)) { nxt = nm; what = "name" }
    if (pk > 0 && (nxt == 0 || pk < nxt)) { nxt = pk; what = "pkg" }
    if (nxt == 0) break
    if (what == "tag") {
      r = substr(s, lt + 1)
      if (match(r, /^[A-Za-z][A-Za-z0-9_.:-]*/)) tag = substr(r, 1, RLENGTH)
      else tag = ""
      s = substr(s, lt + 1); continue
    }
    if (what == "pkg") {
      r = substr(s, pk + 9); e = index(r, "\"")
      if (e > 0 && tag == "manifest" && pkgname == "") { pkgname = substr(r, 1, e - 1); print "PKG", pkgname }
      s = (e > 0) ? substr(r, e + 1) : ""; continue
    }
    r = substr(s, nm + 14); e = index(r, "\"")
    if (e == 0) break
    v = substr(r, 1, e - 1)
    if (substr(v, 1, 1) == "." && pkgname != "") v = pkgname v
    if ((tag in DECL) && v != "") { print "N", NR, tag, v; named = 1 }
    s = substr(r, e + 1)
  }
  if (named) print "L", NR, $0
}
AWK
: >"$TMP/man.tsv"
if [ -n "$MAN" ]; then awk -f "$TMP/man.awk" "$MAN" >"$TMP/man.tsv" || die "cannot read the manifest: $MANDISP"; fi
APPPKG=$(awk -F '\t' '$1 == "PKG" { print $2; exit }' "$TMP/man.tsv")

# ---- jadx package aliases (DESIGN 5.4 step 2) ---------------------------------------------------
: >"$TMP/aliases.tsv"; : >"$TMP/renamed.txt"
if [ "$JADX" = 1 ]; then
  : >"$TMP/votes0"
  while IFS= read -r r; do
    (cd "$D${r:+/$r}" && grep -rnF --include='*.java' 'JADX INFO: renamed from: ' . 2>/dev/null) |
      SA_RR=$r awk '
        BEGIN { rr = ENVIRON["SA_RR"]; OFS = "\t" }
        {
          if (!match($0, /\.java:[0-9]+:/)) next
          path = substr($0, 1, RSTART + 4); text = substr($0, RSTART + RLENGTH)
          sub(/^\.\//, "", path)
          if (substr(text, 1, 28) != "/* JADX INFO: renamed from: ") next
          nm = substr(text, 29); sub(/[ ,*].*$/, "", nm)
          dir = path; sub(/\/[^\/]*$/, "", dir); if (dir == path) dir = ""
          gsub(/\//, ".", dir)
          print "RN", (rr == "" ? path : rr "/" path)
          q = nm; if (!sub(/\.[^.]*$/, "", q)) q = ""
          if (dir != "" && q != "" && q != dir) print "V", dir, q
        }'
  done <"$TMP/coderoots" >"$TMP/votes0"
  awk -F '\t' '$1 == "RN" { print $2 }' "$TMP/votes0" | sort -u >"$TMP/renamed.txt"
  awk -F '\t' '$1 == "V" { print $2 "\t" $3 }' "$TMP/votes0" | sort | uniq -c |
    awk '{ n = $1; sub(/^ *[0-9]+ /, ""); split($0, a, "\t"); print a[1] "\t" a[2] "\t" n }' >"$TMP/votes"
  # P -> Q accepted with >= 2 agreeing votes and no other Q for P, or 1 vote confirmed by a
  # Kotlin @Metadata d2 entry "L<Q>/ in a file of P
  awk -F '\t' '{ c[$1]++; q[$1] = $2; v[$1] = $3 } END { for (p in c) if (c[p] == 1) print p "\t" q[p] "\t" v[p] }' "$TMP/votes" |
    sort >"$TMP/cand"
  while IFS="$TAB" read -r p q v; do
    ok=0
    if [ "$v" -ge 2 ]; then ok=1
    else
      pd=$(printf '%s' "$p" | tr . /); qd=$(printf '%s' "$q" | tr . /)
      while IFS= read -r r; do
        dir="$D${r:+/$r}/$pd"
        [ -d "$dir" ] || continue
        if find "$dir" -maxdepth 1 -name '*.java' -type f -print 2>/dev/null | tr '\n' '\0' |
           xargs -0 grep -lF "\"L$qd/" /dev/null 2>/dev/null | grep -q .; then ok=1; break; fi
      done <"$TMP/coderoots"
    fi
    [ "$ok" = 1 ] && printf '%s\t%s\t%s\n' "$p" "$q" "$v" >>"$TMP/aliases.tsv"
  done <"$TMP/cand"
  # a sub-package alias P.x -> Q.x (same last segment) implies P -> Q when P has no vote for
  # another package (jadx renames a package, its sub-packages follow); to a fixpoint
  awk -F '\t' '
    function par(p) { if (match(p, /\.[^.]*$/)) return substr(p, 1, RSTART - 1); return "" }
    function last(p) { sub(/^.*\./, "", p); return p }
    FNR == NR { nv[$1]++; vq[$1] = $2; next }
    { n++; P[n] = $1; Q[n] = $2; V[n] = $3; acc[$1] = $2 }
    END {
      ch = 1
      while (ch) {
        ch = 0
        for (i = 1; i <= n; i++) {
          p = par(P[i]); q = par(Q[i])
          if (p == "" || q == "" || p == q || last(P[i]) != last(Q[i]) || (p in acc)) continue
          if ((p in nv) && (nv[p] > 1 || vq[p] != q)) continue
          n++; P[n] = p; Q[n] = q; V[n] = 0; acc[p] = q; ch = 1
        }
      }
      for (i = 1; i <= n; i++) print P[i] "\t" Q[i] "\t" V[i]
    }' "$TMP/votes" "$TMP/aliases.tsv" | sort >"$TMP/aliases2.tsv"
  mv "$TMP/aliases2.tsv" "$TMP/aliases.tsv"
  # log at most 20 aliases (a jadx run with package renaming yields hundreds)
  awk -F '\t' 'NR <= 20 { p = $1; gsub(/\./, "/", p); print "[INFO] jadx package alias: " p " -> " $2 " (" ($3 == 0 ? "implied by a sub-package alias" : $3 " votes") ")" }
    END { if (NR > 20) print "[INFO] ... and " (NR - 20) " more jadx package aliases (see --json input.aliases)" }' "$TMP/aliases.tsv" >&2
fi

# ---- shared awk library: ownership by longest root, jadx aliases ---------------------------------
cat >"$TMP/lib.awk" <<'AWK'
function parent(p) { if (match(p, /\.[^.]*$/)) return substr(p, 1, RSTART - 1); return "" }
function addroot(r, t, s,   k) { k = ++RT_N[r]; RT_T[r, k] = t; RT_S[r, k] = s }
# owner(name): the records of the longest root that contains the dotted name, after the
# exclude_packages of the deeper (or equal) levels; sets OWN_ROOT, OWN_N, OWN_T[], OWN_S[]
function owner(name,    p, ex, i, n, t, s) {
  OWN_N = 0; OWN_ROOT = ""; ex = " "; p = name
  while (p != "") {
    if (p in RT_N) {
      n = RT_N[p]
      for (i = 1; i <= n; i++) if (RT_T[p, i] == "ex") ex = ex RT_S[p, i] " "
      for (i = 1; i <= n; i++) {
        t = RT_T[p, i]; s = RT_S[p, i]
        if (t == "ex") continue
        if (t != "lib" && index(ex, " " s " ") > 0) continue
        OWN_N++; OWN_T[OWN_N] = t; OWN_S[OWN_N] = s
      }
      if (OWN_N > 0) { OWN_ROOT = p; return 1 }
    }
    p = parent(p)
  }
  return 0
}
# owner_sdks(name, self): space-separated SDK ids owning the name (not library roots), without self
function owner_sdks(name, self,   i, out, s) {
  out = ""
  if (!owner(name)) return ""
  for (i = 1; i <= OWN_N; i++) {
    if (OWN_T[i] == "lib") continue
    s = OWN_S[i]
    if (s == self) continue
    if (index(" " out " ", " " s " ") == 0) out = (out == "" ? s : out " " s)
  }
  return out
}
function aliasnorm(pkg,   p) {
  if (NAL == 0) return pkg
  p = pkg
  while (p != "") { if (p in AL_Q) return AL_Q[p] substr(pkg, length(p) + 1); p = parent(p) }
  return pkg
}
# arewrite(tok): a dotted token under an aliased package P is rewritten to Q only when a
# prefix of it is a class file of the aliased tree that jadx did not rename itself
function arewrite(tok,   p, c) {
  if (NAL == 0) return tok
  p = tok
  while (p != "") { if (p in AL_Q) break; p = parent(p) }
  if (p == "") return tok
  c = tok
  while (length(c) > length(p)) {
    if ((c in AC) && AC[c] == 0) return AL_Q[p] substr(tok, length(p) + 1)
    c = parent(c)
  }
  return tok
}
function loadroot() { addroot($1, $2, $3) }
function loadalias() { AL_Q[$1] = $2; NAL++ }
AWK

# ---- inventory + ownership ---------------------------------------------------------------------
: >"$TMP/list0"
: >"$TMP/find.err"
while IFS= read -r r; do
  # find reports an unreadable directory and goes on (the ps1 twin does the same)
  (cd "$D${r:+/$r}" && find . -type f \( -name '*.java' -o -name '*.kt' -o -name '*.smali' \) -print 2>>"$TMP/find.err") |
    SA_RR=$r awk 'BEGIN { rr = ENVIRON["SA_RR"] } { sub(/^\.\//, ""); print (rr == "" ? $0 : rr "/" $0) "\t" rr "\t" $0 }'
done <"$TMP/coderoots" >"$TMP/list0"
sort -t "$TAB" -k1,1 "$TMP/list0" >"$TMP/list.tsv"
NFILES=$(wc -l <"$TMP/list.tsv" | tr -d ' ')
[ -s "$TMP/find.err" ] && info "# unreadable directories skipped (check the permissions)"
info "code files: $NFILES"

cat >"$TMP/inv.awk" <<'AWK'
# list.tsv (relD rootrel relInRoot), sorted -> files.tsv + agg.tsv
BEGIN { FS = "\t"; OFS = "\t"; O = ENVIRON["SA_TMP"]; app = ENVIRON["SA_APPPKG"]; jadx = ENVIRON["SA_JADX"] }
kind == "roots" { loadroot(); if ($2 == "ad") { ADR[$1] = ADR[$1] " " $3 }; next }
kind == "alias" { loadalias(); next }
kind == "markers" { MK[$2] = MK[$2] " " $1; next }
kind == "renamed" { RN[$0] = 1; next }
kind == "list" {
  rel = $1; rr = $2; rin = $3
  n = split(rin, seg, "/")
  base = seg[n]; ext = base; sub(/^.*\./, "", ext); sub(/\.[^.]*$/, "", base)
  dir = ""; for (i = 1; i < n; i++) dir = dir "" (i > 1 ? "." : "") seg[i]
  np = (jadx == 1) ? aliasnorm(dir) : dir
  ncls = (np == "") ? base : np "." base
  if (np != dir) AC[dir == "" ? base : dir "." base] = ((rel in RN) ? 1 : 0)
  kd = "app"; owners = ""; self = "-"
  if (app != "" && (np == app || index(np, app ".") == 1)) kd = "app"
  else if (owner(np)) {
    # best record type per SDK: id > inh > ns > ad
    split("", best); nb = 0; lib = 0
    for (i = 1; i <= OWN_N; i++) {
      t = OWN_T[i]; s = OWN_S[i]
      if (t == "lib") { lib = 1; continue }
      if (!(s in best)) { nb++; bl[nb] = s; best[s] = t }
      else if (rank(t) < rank(best[s])) best[s] = t
    }
    if (nb == 0) kd = "lib"
    else {
      kd = "sdk"
      for (i = 1; i <= nb; i++) {
        s = bl[i]; t = best[s]
        if (t == "inh") { kd = "inh"; self = s }
        owners = owners "" (owners == "" ? "" : " ") s
        files[s]++
        if (t == "id" || t == "inh") idfiles[s]++
        k = s SUBSEP t SUBSEP OWN_ROOT
        if (!(k in rc)) { nrc++; rck[nrc] = k; rcdir[k] = rootdir(rel, rr, np, OWN_ROOT) }
        rc[k]++
      }
    }
  }
  print rel, kd, (owners == "" ? "-" : owners), self, np, ncls, ext > (O "/files.tsv")
  if (ncls in MK) {
    m = split(MK[ncls], ms, " ")
    for (i = 1; i <= m; i++) if (!((ms[i], ncls) in mkf)) { mkf[ms[i], ncls] = rel; print "MK", ms[i], ncls, rel > (O "/agg.tsv") }
  }
  # mediation adapters: <adapter root>.<network>...
  p = np; child = ""
  while (p != "") {
    if ((p in ADR) && child != "") {
      net = substr(child, length(p) + 2)
      m = split(ADR[p], ms, " ")
      for (i = 1; i <= m; i++) {
        k = ms[i] SUBSEP net
        if (!(k in adc)) { nad++; adk[nad] = k; addir[k] = rootdir(rel, rr, np, child) }
        adc[k]++
      }
      break
    }
    child = p; p = parent(p)
  }
  next
}
function rank(t) { return (t == "id") ? 1 : (t == "inh") ? 2 : (t == "ns") ? 3 : 4 }
function nseg(s,   c) { if (s == "") return 0; c = s; return gsub(/\./, ".", c) + 1 }
# rootdir: the directory (relative to D) of root r, from a file of package np under it
function rootdir(rel, rr, np, r,   d, k, i) {
  d = rel; sub(/\/[^\/]*$/, "", d); if (d == rel) d = ""
  k = nseg(np) - nseg(r)
  for (i = 0; i < k; i++) { if (!sub(/\/[^\/]*$/, "", d)) { d = ""; break } }
  return d
}
END {
  for (s in files) print "F", s, files[s], (s in idfiles) ? idfiles[s] : 0 > (O "/agg.tsv")
  for (i = 1; i <= nrc; i++) { k = rck[i]; split(k, a, SUBSEP); print "RC", a[1], a[2], a[3], rc[k], rcdir[k] > (O "/agg.tsv") }
  for (i = 1; i <= nad; i++) { k = adk[i]; split(k, a, SUBSEP); print "AD", a[1], a[2], adc[k], addir[k] > (O "/agg.tsv") }
  for (c in AC) print c, AC[c] > (O "/aliascls.tsv")
}
AWK
: >"$TMP/files.tsv"; : >"$TMP/agg.tsv"; : >"$TMP/aliascls.tsv"
SA_TMP=$TMP SA_APPPKG=$APPPKG SA_JADX=$JADX awk -f "$TMP/lib.awk" -f "$TMP/inv.awk" \
  kind=roots "$TMP/roots.tsv" kind=alias "$TMP/aliases.tsv" kind=markers "$TMP/markers.tsv" \
  kind=renamed "$TMP/renamed.txt" kind=list "$TMP/list.tsv" || die "inventory failed"

# grepf <list> <patterns>: grep -nF of the patterns over the listed files (paths relative to
# D, "./"-prefixed), one pass with xargs -0; no match is not an error
grepf() {
  (cd "$D" && tr '\n' '\0' <"$1" | xargs -0 grep -nF -f "$2" /dev/null 2>/dev/null) || true
}

# ---- app code: references, calls, hints (DESIGN 5.4 steps 3-4) ------------------------------------
awk -F '\t' '$2 == "app" || $2 == "inh" { print "./" $1 }' "$TMP/files.tsv" >"$TMP/applist"
grep -E '\.(java|kt)$' "$TMP/applist" >"$TMP/applist.java" || true
info "app code files: $(wc -l <"$TMP/applist" | tr -d ' ')"

# base patterns: roots (dotted + smali), alias packages, simple names of API and marker
# classes, ".method(" of every API method, app_code hint tokens
awk -F '\t' '$2 != "lib" && $2 != "ex" { print $1; r = $1; gsub(/\./, "/", r); print "L" r "/" }' "$TMP/roots.tsv" >"$TMP/pats.roots"
cut -f1 "$TMP/aliases.tsv" >>"$TMP/pats.roots"
{
  cat "$TMP/pats.roots"
  awk -F '\t' '{ c = $1; sub(/^.*\./, "", c); sub(/\$.*$/, "", c); print c; m = $2; if (m != "<init>") print "." m "(" }' "$TMP/api.tsv"
  awk -F '\t' '{ c = $2; sub(/^.*\./, "", c); print c }' "$TMP/markers.tsv"
  awk -F '\t' '$4 == "app_code" { print $2 }' "$TMP/htok.tsv"
} | awk 'length($0) > 0' | sort -u >"$TMP/pats"

cat >"$TMP/imp.awk" <<'AWK'
# pass 1 over the app Java/Kotlin code: simple names of the imported SDK classes (they join the
# prefilter) and the SDK packages imported with a wildcard
BEGIN { FS = "\t" }
kind == "roots" { loadroot(); next }
kind == "alias" { loadalias(); next }
kind == "acls" { AC[$1] = $2; next }
{
  if (!match($0, /\.(java|kt):[0-9]+:/)) next
  s = substr($0, RSTART + RLENGTH); sub(/\r$/, "", s)
  if (s !~ /^[ \t]*import[ \t]/) next
  sub(/^[ \t]*import[ \t]+/, "", s); sub(/^static[ \t]+/, "", s); sub(/[ \t]*;.*$/, "", s)
  asn = ""; if (match(s, /[ \t]+as[ \t]+/)) { asn = substr(s, RSTART + RLENGTH); s = substr(s, 1, RSTART - 1) }
  gsub(/[ \t]/, "", s)
  if (s ~ /\.\*$/) { p = substr(s, 1, length(s) - 2); p = arewrite(p); if (owner_sdks(p, "") != "") print "W\t" p; next }
  s = arewrite(s)
  if (owner_sdks(s, "") == "") next
  c = s; sub(/^.*\./, "", c); print "S\t" c
  if (asn != "") print "S\t" asn
}
AWK
: >"$TMP/imp.out"
if [ -s "$TMP/applist.java" ]; then
  grepf "$TMP/applist.java" "$TMP/pats.roots" >"$TMP/imp.grep"
  awk -f "$TMP/lib.awk" -f "$TMP/imp.awk" kind=roots "$TMP/roots.tsv" kind=alias "$TMP/aliases.tsv" \
    kind=acls "$TMP/aliascls.tsv" kind=grep "$TMP/imp.grep" >"$TMP/imp.out0" || die "import scan failed"
  sort -u "$TMP/imp.out0" >"$TMP/imp.out"
fi
awk -F '\t' '$1 == "S" { print $2 }' "$TMP/imp.out" >>"$TMP/pats"
awk -F '\t' '$1 == "W" { print $2 }' "$TMP/imp.out" >"$TMP/wild.txt"
if [ -s "$TMP/wild.txt" ]; then
  awk -F '\t' 'NR == FNR { w[$1] = 1; next } { p = $6; sub(/\.[^.]*$/, "", p); if (p in w) { c = $6; sub(/^.*\./, "", c); print c } }' \
    "$TMP/wild.txt" "$TMP/files.tsv" >>"$TMP/pats"
fi
sort -u "$TMP/pats" -o "$TMP/pats"

cat >"$TMP/app.awk" <<'AWK'
# grep -nF output over the app code -> events:
#   R rel line sdk classes       class reference (classes: API-style keys, or -)
#   C rel line sdk role api conf  API call (conf: exact | import-scoped)
#   H rel line hint_id            hint token match
#   T rel line text               the line text (once per line with an event)
BEGIN { FS = "\t"; OFS = "\t"; RE_SMALI = "L[A-Za-z0-9_$/]+;"; cur = "" }
kind == "roots" { loadroot(); next }
kind == "alias" { loadalias(); next }
kind == "acls" { AC[$1] = $2; next }
kind == "api" {
  # an API fact of an SDK whose class that SDK does not own (e.g. under its own
  # exclude_packages, owned by another entry) is not attributed to it
  k = $1
  if (owner(k)) { okk = 0; for (i = 1; i <= OWN_N; i++) if (OWN_S[i] == $4) okk = 1; if (!okk) next }
  APIC[k] = 1; APIM[$2] = 1
  if (!((k, $2) in APIR)) APIR[k, $2] = ""
  APIR[k, $2] = APIR[k, $2] " " $3 ":" $4
  o = k; sub(/\$.*$/, "", o)
  if (index(" " OUTERS[o] " ", " " k " ") == 0) OUTERS[o] = OUTERS[o] " " k
  pk = k; sub(/\.[^.]*$/, "", pk); if (index(" " APIPKG[pk] " ", " " k " ") == 0) APIPKG[pk] = APIPKG[pk] " " k
  next
}
kind == "files" { FPKG[$1] = $5; FSELF[$1] = $4; if (NWILD > 0) { p = $6; sub(/\.[^.]*$/, "", p); if (p in WILD) CLS[$6] = 1 }; next }
kind == "wild" { WILD[$1] = 1; NWILD++; next }
kind == "htok" { if ($4 != "app_code") next; NHT++; HT_ID[NHT] = $1; HT_TOK[NHT] = $2; HT_M[NHT] = $3; next }
{
  if (!match($0, /\.(java|kt|smali):[0-9]+:/)) next
  rel = substr($0, 1, RSTART + RLENGTH - 1)
  s = substr($0, RSTART + RLENGTH); sub(/\r$/, "", s)
  ln = rel; sub(/:$/, "", ln); sub(/^.*:/, "", ln)
  rel = substr(rel, 1, length(rel) - length(ln) - 2); sub(/^\.\//, "", rel)
  ext = rel; sub(/^.*\./, "", ext)
  if (rel != cur) newfile(rel)
  EVN = 0
  # comment-only lines (jadx "/* JADX INFO: ... */", "// ...", smali "# ...") are no evidence
  if (ext == "smali") { if (s ~ /^[ \t]*#/) next } else if (s ~ /^[ \t]*(\/\/|\/\*|\*)/) next
  if (ext == "smali") smali_line(s); else java_line(s, ext)
  hints(s)
  if (EVN > 0) print "T", rel, ln, s
}
function newfile(r,   n, i, a, pk) {
  cur = r; SELF = FSELF[r]; if (SELF == "-") SELF = ""
  split("", VIS); split("", VSD); VLIST = ""; split("", FW); NFW = 0
  pk = FPKG[r]
  if (pk in APIPKG) {
    n = split(APIPKG[pk], a, " ")
    for (i = 1; i <= n; i++) vis_add(simpleof(a[i]), javaof(a[i]), owner_sdks(javaof(a[i]), SELF))
  }
}
function simpleof(c) { sub(/^.*\./, "", c); return c }
function javaof(k) { gsub(/\$/, ".", k); return k }
# keyof: Java dotted FQCN -> API key (inner classes after the first Uppercase segment joined by $)
function keyof(j,   n, a, i, out, inner) {
  n = split(j, a, "."); out = ""; inner = 0
  for (i = 1; i <= n; i++) {
    if (i == 1) out = a[i]
    else if (inner) out = out "$" a[i]
    else out = out "." a[i]
    if (a[i] ~ /^[A-Z]/) inner = 1
  }
  return out
}
# clsof: the class part of a dotted token (up to its first Uppercase segment), "" if none
function clsof(t,   n, a, i, out) {
  n = split(t, a, "."); out = ""
  for (i = 1; i <= n; i++) { out = out "" (i > 1 ? "." : "") a[i]; if (i > 1 && a[i] ~ /^[A-Z]/) return out }
  return ""
}
function vis_add(simple, jfq, sd) {
  if (simple == "" || sd == "") return
  if (!(simple in VIS)) VLIST = VLIST " " simple
  VIS[simple] = jfq; VSD[simple] = sd
}
function emit_r(sd, cls,   n, a, i, k) {
  n = split(sd, a, " ")
  for (i = 1; i <= n; i++) { print "R", cur, ln, a[i], cls; EVN++ }
}
function emit_c(k, m, conf,   n, a, i, rs) {
  n = split(APIR[k, m], a, " ")
  for (i = 1; i <= n; i++) {
    split(a[i], rs, ":")
    print "C", cur, ln, rs[2], rs[1], k "#" m, conf; EVN++
  }
}
function java_line(s, ext,   rest, off, st, tok, t2, sd, cls, pc, w, m, dpos, chain, k, i, n, a, seg, nn) {
  if (s ~ /^[ \t]*import[ \t]/) { java_import(s); return }
  if (s ~ /^[ \t]*package[ \t]/) return
  # dotted tokens: FQCN references (and inline FQCNs become visible)
  rest = s; off = 0
  while (match(rest, /[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)+/)) {
    st = off + RSTART; tok = substr(rest, RSTART, RLENGTH)
    off = st + RLENGTH - 1; rest = substr(s, off + 1)
    pc = (st > 1) ? substr(s, st - 1, 1) : ""
    if (pc == ".") continue
    t2 = arewrite(tok)
    sd = owner_sdks(t2, SELF)
    if (sd == "") continue
    cls = clsof(t2)
    if (cls != "") { vis_add(simpleof(cls), cls, sd); emit_r(sd, keyof(cls)) } else emit_r(sd, "-")
  }
  # simple names of visible SDK classes (whole words)
  rest = s; off = 0
  while (match(rest, /[A-Za-z_$][A-Za-z0-9_$]*/)) {
    st = off + RSTART; w = substr(rest, RSTART, RLENGTH)
    off = st + RLENGTH - 1; rest = substr(s, off + 1)
    if (w in VIS) emit_r(VSD[w], keyof(VIS[w]))
    else if (NFW > 0 && w ~ /^[A-Z]/) wild_ref(w)
  }
  # calls: .method(
  rest = s; off = 0
  while (match(rest, /\.[A-Za-z_$][A-Za-z0-9_$]*\(/)) {
    dpos = off + RSTART; m = substr(rest, RSTART + 1, RLENGTH - 2)
    off = dpos + RLENGTH - 1; rest = substr(s, off + 1)
    if (!(m in APIM)) continue
    chain = chainbefore(s, dpos)
    if (chain != "") {
      k = resolve(chain)
      if (k != "" && ((k, m) in APIR)) { emit_c(k, m, "exact"); continue }
      if (RESOLVED) continue
    }
    pc = (dpos > 1) ? substr(s, dpos - 1, 1) : ""
    if (pc ~ /[]A-Za-z0-9_$)]/) instance(m)
  }
  # constructors: new X( / new Outer.Inner(  (Kotlin: X( without new)
  rest = s; off = 0
  while (match(rest, /new[ \t]+[A-Za-z_$][A-Za-z0-9_$.]*[ \t]*[(<]/)) {
    st = off + RSTART; seg = substr(rest, RSTART, RLENGTH)
    off = st + RLENGTH - 1; rest = substr(s, off + 1)
    pc = (st > 1) ? substr(s, st - 1, 1) : ""
    if (pc ~ /[A-Za-z0-9_$.]/) continue
    sub(/^new[ \t]+/, "", seg); sub(/[ \t]*[(<]$/, "", seg)
    k = resolve(seg)
    if (k != "" && ((k, "<init>") in APIR)) emit_c(k, "<init>", "exact")
  }
  if (ext == "kt") {
    rest = s; off = 0
    while (match(rest, /[A-Za-z_$][A-Za-z0-9_$.]*\(/)) {
      st = off + RSTART; seg = substr(rest, RSTART, RLENGTH - 1)
      off = st + RLENGTH - 1; rest = substr(s, off + 1)
      pc = (st > 1) ? substr(s, st - 1, 1) : ""
      if (pc ~ /[A-Za-z0-9_$.]/) continue
      nn = seg; sub(/^.*\./, "", nn)
      if (nn !~ /^[A-Z]/) continue
      k = resolve(seg)
      if (k != "" && ((k, "<init>") in APIR)) emit_c(k, "<init>", "exact")
    }
  }
}
# wild_ref(w): a simple name of a class in an SDK package this file imports with a wildcard
# (a class of the tree, or the outer class of an API fact) becomes visible like an explicit import
function wild_ref(w,   p, c, sd) {
  for (p in FW) {
    c = p "." w
    if (!((c in CLS) || (c in OUTERS))) continue
    sd = owner_sdks(c, SELF)
    if (sd == "") continue
    vis_add(w, c, sd); emit_r(sd, keyof(c)); return
  }
}
function java_import(s,   asn, sd, c, p) {
  sub(/^[ \t]*import[ \t]+/, "", s); sub(/^static[ \t]+/, "", s); sub(/[ \t]*;.*$/, "", s)
  asn = ""; if (match(s, /[ \t]+as[ \t]+/)) { asn = substr(s, RSTART + RLENGTH); s = substr(s, 1, RSTART - 1) }
  gsub(/[ \t]/, "", s)
  if (s ~ /\.\*$/) {
    s = arewrite(substr(s, 1, length(s) - 2))
    if ((s in WILD) && !(s in FW)) { FW[s] = 1; NFW++ }
    return
  }
  s = arewrite(s)
  sd = owner_sdks(s, SELF)
  if (sd == "") return
  c = clsof(s); if (c == "") c = s
  vis_add(simpleof(c), c, sd)
  if (asn != "") vis_add(asn, c, sd)
}
# chainbefore(s, dpos): the dotted identifier chain that ends right before position dpos
function chainbefore(s, dpos,   i, c) {
  i = dpos - 1
  while (i >= 1) { c = substr(s, i, 1); if (c ~ /[A-Za-z0-9_$.]/) i--; else break }
  c = substr(s, i + 1, dpos - i - 1)
  if (c == "" || c ~ /^[.0-9]/) return ""
  return c
}
# resolve(chain): API key of the class the chain names (FQCN, or a visible simple name
# followed by inner class names); RESOLVED = 1 when the chain names an SDK class at all
function resolve(chain,   c, k, f, rest) {
  RESOLVED = 0
  f = chain; rest = ""
  if (index(chain, ".") > 0) { f = substr(chain, 1, index(chain, ".") - 1); rest = substr(chain, index(chain, ".") + 1) }
  if (f in VIS) {
    RESOLVED = 1
    k = keyof(VIS[f])
    if (rest != "") { gsub(/\./, "$", rest); k = k "$" rest }
    return (k in APIC) ? k : ""
  }
  if (rest != "" && f ~ /^[a-z]/) {
    c = arewrite(chain)
    k = keyof(c)
    if (k in APIC) { RESOLVED = 1; return k }
    if (owner_sdks(c, "") != "" && clsof(c) != "") RESOLVED = 1
  }
  return ""
}
function instance(m,   n, a, i, ok, kk, nk, b, j) {
  n = split(VLIST, a, " ")
  for (i = 1; i <= n; i++) {
    ok = keyof(VIS[a[i]])
    if (!(ok in OUTERS)) continue   # no OUTERS[ok] autovivification: wild_ref tests (c in OUTERS)
    nk = split(OUTERS[ok], b, " ")
    for (j = 1; j <= nk; j++) {
      kk = b[j]
      if ((kk, m) in APIR) emit_c(kk, m, "import-scoped")
    }
  }
}
function smali_line(s,   rest, off, st, tok, cls, sd, after, m, e) {
  rest = s; off = 0
  while (match(rest, RE_SMALI)) {
    st = off + RSTART; tok = substr(rest, RSTART + 1, RLENGTH - 2)
    off = st + RLENGTH - 1; rest = substr(s, off + 1)
    cls = tok; gsub(/\//, ".", cls)
    sd = owner_sdks(cls, SELF)
    if (sd != "") emit_r(sd, cls)
    if (substr(rest, 1, 2) == "->") {
      e = index(rest, "(")
      if (e > 3) { m = substr(rest, 3, e - 3); if ((cls, m) in APIR) emit_c(cls, m, "exact") }
    }
  }
}
function hints(s,   i, id, t, done) {
  split("", done)
  for (i = 1; i <= NHT; i++) {
    id = HT_ID[i]
    if (id in done) continue
    t = HT_TOK[i]
    if (index(s, t) == 0) continue
    if (HT_M[i] == "literal" || tokmatch(s, t, HT_M[i])) { done[id] = 1; print "H", cur, ln, id; EVN++ }
  }
}
# method: token + "(" with a non-identifier char before; word: non-identifier chars around
function tokmatch(s, t, mt,   rest, off, p, st, b, a) {
  rest = s; off = 0
  while ((p = index(rest, t)) > 0) {
    st = off + p
    b = (st > 1) ? substr(s, st - 1, 1) : ""
    a = substr(s, st + length(t), 1)
    if (b !~ /[A-Za-z0-9_$]/) {
      if (mt == "method" && a == "(") return 1
      if (mt == "word" && a !~ /[A-Za-z0-9_$]/) return 1
      if (mt == "exact" && s == t) return 1
    }
    off = st; rest = substr(s, st + 1)
  }
  return 0
}
AWK
: >"$TMP/ev.tsv"
if [ -s "$TMP/applist" ]; then
  grepf "$TMP/applist" "$TMP/pats" >"$TMP/app.grep"
  awk -f "$TMP/lib.awk" -f "$TMP/app.awk" kind=roots "$TMP/roots.tsv" kind=alias "$TMP/aliases.tsv" \
      kind=acls "$TMP/aliascls.tsv" kind=api "$TMP/api.tsv" kind=wild "$TMP/wild.txt" kind=files "$TMP/files.tsv" \
      kind=htok "$TMP/htok.tsv" kind=grep "$TMP/app.grep" >"$TMP/ev.tsv" || die "app code analysis failed"
fi

# ---- domains and id prefixes over all code (DESIGN 5.4 step 5) --------------------------------
awk -F '\t' 'NR == FNR { if ($7 == 1) g[$1] = 1; next } ($1 in g) { print $2 }' "$TMP/ent.tsv" "$TMP/domains.tsv" >"$TMP/dpats"
awk -F '\t' 'NR == FNR { if ($7 == 1) g[$1] = 1; next } ($1 in g) { print $2 }' "$TMP/ent.tsv" "$TMP/idpfx.tsv" >>"$TMP/dpats"
sort -u "$TMP/dpats" -o "$TMP/dpats"
cat >"$TMP/dom.awk" <<'AWK'
# grep output over all code -> E rel line sdk domain eligible / I rel line sdk prefix eligible / T
# eligible = the file is app code, unowned, or code of that SDK (else a library/other-SDK hit)
BEGIN { FS = "\t"; OFS = "\t" }
kind == "ent" { if ($7 == 1) G[$1] = 1; next }
kind == "dom" { if ($1 in G) { ND++; DS[ND] = $1; DD[ND] = $2 }; next }
kind == "idp" { if ($1 in G) { NP++; PS[NP] = $1; PP[NP] = $2 }; next }
kind == "files" { FK[$1] = $2; FO[$1] = " " $3 " "; next }
{
  if (!match($0, /\.(java|kt|smali):[0-9]+:/)) next
  rel = substr($0, 1, RSTART + RLENGTH - 1)
  s = substr($0, RSTART + RLENGTH); sub(/\r$/, "", s)
  ln = rel; sub(/:$/, "", ln); sub(/^.*:/, "", ln)
  rel = substr(rel, 1, length(rel) - length(ln) - 2); sub(/^\.\//, "", rel)
  any = 0
  for (i = 1; i <= ND; i++) if (index(s, DD[i]) > 0 && hostmatch(s, DD[i])) {
    el = elig(rel, DS[i]); print "E", rel, ln, DS[i], DD[i], el; if (el) any = 1
  }
  for (i = 1; i <= NP; i++) if (index(s, PP[i]) > 0) {
    el = elig(rel, PS[i]); print "I", rel, ln, PS[i], PP[i], el; if (el) any = 1
  }
  if (any) print "T", rel, ln, s
}
function elig(rel, sdk,   k) { k = FK[rel]; return (k == "app" || k == "inh" || index(FO[rel], " " sdk " ") > 0) ? 1 : 0 }
# a host or a registrable suffix: no host character before it ("." allowed: a subdomain), and
# no host character after it
function hostmatch(s, d,   rest, off, p, st, b, a, a2) {
  rest = s; off = 0
  while ((p = index(rest, d)) > 0) {
    st = off + p
    b = (st > 1) ? substr(s, st - 1, 1) : ""
    a = substr(s, st + length(d), 1); a2 = substr(s, st + length(d) + 1, 1)
    if (b !~ /[A-Za-z0-9-]/ && a !~ /[A-Za-z0-9-]/ && !(a == "." && a2 ~ /[A-Za-z0-9]/)) return 1
    off = st; rest = substr(s, st + 1)
  }
  return 0
}
AWK
: >"$TMP/dom.tsv"
if [ -s "$TMP/dpats" ]; then
  awk -F '\t' '{ print "./" $1 }' "$TMP/files.tsv" >"$TMP/alllist"
  grepf "$TMP/alllist" "$TMP/dpats" >"$TMP/dom.grep"
  awk -f "$TMP/dom.awk" kind=ent "$TMP/ent.tsv" kind=dom "$TMP/domains.tsv" kind=idp "$TMP/idpfx.tsv" \
    kind=files "$TMP/files.tsv" kind=grep "$TMP/dom.grep" >"$TMP/dom.tsv" || die "domain scan failed"
fi

# ---- verdict and report ---------------------------------------------------------------------------
cat >"$TMP/rep.awk" <<'AWK'
BEGIN {
  FS = "\t"; OFS = "\t"
  MODE = ENVIRON["SA_MODE"]; TOOL = ENVIRON["SA_TOOL"]; DD = ENVIRON["SA_D"]; MANDISP = ENVIRON["SA_MANDISP"]
  LAYOUT = ENVIRON["SA_LAYOUT"]; FULL = ENVIRON["SA_FULL"] + 0; NOHINTS = ENVIRON["SA_NOHINTS"] + 0
  SELALL = ENVIRON["SA_SELALL"] + 0; SELIDS = " " ENVIRON["SA_SELIDS"] " "; SELASP = " " ENVIRON["SA_SELASP"] " "
  SEP = ENVIRON["SA_SEP"]; O = ENVIRON["SA_TMP"]; TTL = ENVIRON["SA_TITLE"]
  CALLS = O "/calls.out"; ROWS = O "/rows.out"
  # ownership record types (RC rows) in print order, and their --tsv EV kind
  TT[1] = "id"; TT[2] = "inh"; TT[3] = "ns"; TT[4] = "ad"
  KW[1] = "package"; KW[2] = "package"; KW[3] = "namespace"; KW[4] = "adapter"
}
kind == "ent" {
  ne++; E[ne] = $1; CAT[$1] = $2; GRP[$1] = $3; DISP[$1] = $4; INH[$1] = ($5 == "true"); TGT[$1] = ($6 == "true")
  ING[$1] = ($7 == 1); LRANK[$1] = $8 + 0; LFLAG[$1] = $9; LLAB[$1] = $10; PRE[$1] = $11; next
}
kind == "roots" { loadroot(); if ($2 == "ns" || $2 == "id" || $2 == "inh") NSR[$3] = NSR[$3] " " $1; next }
kind == "roles" { nro++; RO[nro] = $1; ROL[$1] = $2; next }
kind == "fmt" {
  if ($1 == "by_class") FBC[$2] = $3
  else if ($1 == "by_class_token") { nfc++; FCT[nfc] = $2; FCF[nfc] = $3 }
  else if ($1 == "by_method_token") { nfm++; FMT_[nfm] = $2; FMF[nfm] = $3 }
  next
}
kind == "markers" { NMK[$1]++; MKL[$1, NMK[$1]] = $2; next }
kind == "mnames" { MN[$2] = MN[$2] " " $1; next }
kind == "mcomps" { MC[$2] = MC[$2] " " $1; next }
kind == "idpfx" { IPL[$1, $2] = $3; next }
kind == "hints" { nh++; H[nh] = $2; HFLAG[$2] = $3; HSCOPE[$2] = $4; HMATCH[$2] = $5; HTITLE[$2] = $6; next }
kind == "htok" { nht++; HTI[nht] = $1; HTT[nht] = $2; HTM[nht] = $3; HTS[nht] = $4; next }
kind == "alias" { nal++; ALP[nal] = $1; ALQ[nal] = $2; ALV[nal] = $3; next }
kind == "coderoots" { ncr++; CR[ncr] = $0; next }
kind == "agg" {
  if ($1 == "F") { FILES[$2] = $3; IDF[$2] = $4 }
  else if ($1 == "RC") { nrc++; RCS[nrc] = $2; RCT[nrc] = $3; RCR[nrc] = $4; RCN[nrc] = $5; RCD[nrc] = $6 }
  else if ($1 == "MK") { MKF[$2, $3] = $4 }
  else if ($1 == "AD") { nad++; ADS[nad] = $2; ADN[nad] = $3; ADC[nad] = $4; ADD[nad] = $5 }
  next
}
kind == "man" {
  if ($1 == "L") MTXT[$2] = rest_from(3)
  else if ($1 == "N") { nmn++; MNL[nmn] = $2; MNT[nmn] = $3; MNV[nmn] = $4 }
  next
}
kind == "ev" {
  if ($1 == "T") { TXT[$2, $3] = rest_from(4); next }
  if ($1 == "R") {
    k = $2 SUBSEP $3 SUBSEP $4
    if (!(k in RSEEN)) { RSEEN[k] = 1; nr++; RR[nr] = $2; RL[nr] = $3; RSD[nr] = $4; RK[nr] = $5; RIDX[k] = nr }
    else if (index(" " RK[RIDX[k]] " ", " " $5 " ") == 0) RK[RIDX[k]] = RK[RIDX[k]] " " $5
    next
  }
  if ($1 == "C") {
    k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6
    if (k in CSEEN) { if ($7 == "exact") CF[CSEEN[k]] = "exact"; next }
    nc++; CSEEN[k] = nc; CRl[nc] = $2; CLn[nc] = $3; CS[nc] = $4; CRo[nc] = $5; CA[nc] = $6; CF[nc] = $7
    next
  }
  if ($1 == "H") { nhe++; HER[nhe] = $2; HEL[nhe] = $3; HEI[nhe] = $4; next }
  next
}
kind == "dom" {
  if ($1 == "T") { TXT[$2, $3] = rest_from(4); next }
  k = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
  if (k in DSEEN) next
  DSEEN[k] = 1; nd++; DK[nd] = $1; DR[nd] = $2; DL[nd] = $3; DS_[nd] = $4; DV[nd] = $5; DE[nd] = $6
  next
}
END { analyse(); if (MODE == "tsv") out_tsv(); else if (MODE == "summary") out_summary(); else if (MODE == "json") out_json(); else out_text() }

# ---------------------------------------------------------------------------------------------
function analyse(   i, s, n, a, j, k, t, nm, tag, line, sd, lv) {
  for (i = 1; i <= nr; i++) { s = RSD[i]; k = RR[i] SUBSEP RL[i]; APPREF[s]++; if (!((s, RR[i]) in AFILE)) AFILE[s, RR[i]] = 1 }
  for (i = 1; i <= nc; i++) CALLN[CS[i]]++
  for (i = 1; i <= nd; i++) {
    s = DS_[i]
    if (DK[i] == "E") { if (DE[i]) ENDP[s]++; else LIBDOM[s]++ }
    else { if (DE[i]) IDP[s]++ }
  }
  # manifest attribution
  for (i = 1; i <= nmn; i++) {
    nm = MNV[i]; sd = " "
    if (owner(nm)) for (j = 1; j <= OWN_N; j++) if (OWN_T[j] == "id" || OWN_T[j] == "inh") sd = addw(sd, OWN_S[j])
    if (nm in MN) { n = split(MN[nm], a, " "); for (j = 1; j <= n; j++) sd = addw(sd, a[j]) }
    if (nm in MC) {
      n = split(MC[nm], a, " ")
      if (owner(nm)) for (j = 1; j <= n; j++) for (k = 1; k <= OWN_N; k++)
        if (OWN_S[k] == a[j] && (OWN_T[k] == "id" || OWN_T[k] == "inh" || OWN_T[k] == "ns")) sd = addw(sd, a[j])
    }
    MSD[i] = sd
    n = split(sd, a, " ")
    for (j = 1; j <= n; j++) MANIF[a[j]]++
  }
  for (i = 1; i <= ne; i++) {
    s = E[i]
    nf = 0; for (j = 1; j <= NMK[s]; j++) if ((s, MKL[s, j]) in MKF) nf++
    MKFOUND[s] = nf
    if (IDF[s] > 0) {
      if (NMK[s] == 0 || nf > 0) { LV[s] = "HIGH"; DET[s] = "-" } else { LV[s] = "MEDIUM"; DET[s] = "partial" }
    } else if (MANIF[s] > 0) { LV[s] = "MEDIUM"; DET[s] = "manifest-only" }
    else if (APPREF[s] > 0 || ENDP[s] > 0 || IDP[s] > 0) {
      LV[s] = "LOW"; DET[s] = ""
      if (APPREF[s] > 0) DET[s] = "app-refs"
      if (ENDP[s] > 0) DET[s] = DET[s] "" (DET[s] == "" ? "" : "+") "endpoints"
      if (IDP[s] > 0) DET[s] = DET[s] "" (DET[s] == "" ? "" : "+") "id-prefix"
    } else { LV[s] = "NONE"; DET[s] = "-" }
    ST[s] = (LV[s] == "HIGH") ? "DETECTED" : (LV[s] == "MEDIUM") ? "LIKELY" : (LV[s] == "LOW") ? "POSSIBLE" : "NOT FOUND"
    LVN[s] = (LV[s] == "HIGH") ? 3 : (LV[s] == "MEDIUM") ? 2 : (LV[s] == "LOW") ? 1 : 0
    ACT[s] = (APPREF[s] + CALLN[s] > 0) ? "true" : "false"
  }
}
function rest_from(n,   t, k) { t = $0; for (k = 1; k < n; k++) sub(/^[^\t]*\t/, "", t); return t }
function addw(list, w) { return (index(list, " " w " ") > 0) ? list : list w " " }
function n0(x) { return x + 0 }
function lab(s) { return (LFLAG[s] != "-") ? LLAB[s] : DISP[s] }
function simple(c) { sub(/^.*\./, "", c); return c }
function fmtc(c,   i, sc) {
  sc = simple(c)
  if (sc in FBC) return (FBC[sc] == "-") ? "" : FBC[sc]
  for (i = 1; i <= nfc; i++) if (index(sc, FCT[i]) > 0) return FCF[i]
  return ""
}
function fmtcm(c, m,   i, sc) {
  sc = simple(c)
  if (sc in FBC) return (FBC[sc] == "-") ? "" : FBC[sc]
  for (i = 1; i <= nfc; i++) if (index(sc, FCT[i]) > 0) return FCF[i]
  for (i = 1; i <= nfm; i++) if (index(m, FMT_[i]) > 0) return FMF[i]
  return ""
}
function path(rel) { return (rel == "") ? DD : DD "/" rel }

# ---------------------------------------------------------------------------------------------
function out_tsv(   i, s, j, t, n, a, k) {
  print "#sdk-audit", 2, "tool=" TOOL, "layout=" LAYOUT
  for (i = 1; i <= nal; i++) { t = ALP[i]; gsub(/\./, "/", t); print "#alias", t, ALQ[i], ALV[i] }
  for (i = 1; i <= ne; i++) {
    s = E[i]; if (!ING[s]) continue
    print "SDK", s, CAT[s], LV[s], ST[s], DET[s], (TGT[s] ? "true" : "false"), "files=" n0(FILES[s]), "manifest=" n0(MANIF[s]),
          "endpoints=" n0(ENDP[s]), "app_refs=" n0(APPREF[s]), "calls=" n0(CALLN[s]), "active=" ACT[s]
  }
  for (i = 1; i <= ne; i++) {
    s = E[i]; if (!ING[s]) continue
    for (t = 1; t <= 4; t++) for (j = 1; j <= nrc; j++) if (RCS[j] == s && RCT[j] == TT[t]) print "EV", s, KW[t], RCR[j], RCN[j]
    if (IDF[s] > 0) for (j = 1; j <= NMK[s]; j++) print "EV", s, "marker", MKL[s, j], (((s, MKL[s, j]) in MKF) ? 1 : 0)
    for (j = 1; j <= nmn; j++) if (index(MSD[j], " " s " ") > 0 && !((s, MNT[j], MNV[j]) in EVM)) { EVM[s, MNT[j], MNV[j]] = 1; print "EV", s, "manifest", MNT[j], MNV[j] }
    split("", cnt); split("", ord); no = 0
    for (j = 1; j <= nd; j++) if (DS_[j] == s && DE[j]) { k = DK[j] SUBSEP DV[j]; if (!(k in cnt)) { no++; ord[no] = k }; cnt[k]++ }
    for (j = 1; j <= no; j++) { split(ord[j], a, SUBSEP); print "EV", s, (a[1] == "E" ? "domain" : "id_prefix"), a[2], cnt[ord[j]] }
    if (n0(LIBDOM[s]) > 0) print "EV", s, "lib_domain_hits", "-", LIBDOM[s]
  }
  for (i = 1; i <= nc; i++) if (ING[CS[i]]) print CRl[i], CLn[i], "CALL", CS[i], CRo[i], CA[i], CRl[i] ":" CLn[i], CF[i] > CALLS
  close(CALLS)
  if (!NOHINTS) {
    hint_counts()
    for (i = 1; i <= nh; i++) if (HCL[H[i]] > 0) print "HINT", H[i], HCF[H[i]], HCL[H[i]] > (O "/hints.out")
  }
  if (TOOL == "find-ads") for (i = 1; i <= nad; i++) print "ADAPTER", ADS[i], ADN[i], ADC[i] > (O "/adapters.out")
}
function hint_counts(   i, id, k, f) {
  for (i = 1; i <= nhe; i++) {
    id = HEI[i]; k = HER[i] SUBSEP HEL[i] SUBSEP id
    if (k in HSN) continue
    HSN[k] = 1; HCL[id]++
    f = HER[i] SUBSEP id; if (!(f in HSF)) { HSF[f] = 1; HCF[id]++ }
  }
  for (i = 1; i <= nmn; i++) mhints(i, 1)
}
# manifest hints on name i (count = 1: tally; 0: just report). Literal manifest hints only
# match names no entry claims.
function mhints(i, count,   j, id, t, ok, out) {
  out = ""
  for (j = 1; j <= nht; j++) {
    if (HTS[j] != "manifest") continue
    id = HTI[j]; t = HTT[j]
    if (index(" " out " ", " " id " ") > 0) continue
    ok = 0
    if (HTM[j] == "exact") ok = (MNV[i] == t)
    else if (HTM[j] == "literal") ok = (index(MNV[i], t) > 0 && MSD[i] == " ")
    if (ok) {
      out = out " " id
      if (count && !((MNL[i], id) in MHS)) { MHS[MNL[i], id] = 1; HCL[id]++; HCF[id] = 1 }
    }
  }
  return out
}

# ---------------------------------------------------------------------------------------------
function out_summary(   i, s, n, a, lst, k, mm, hs, cons) {
  print ""
  print "=== " (TOOL == "find-trackers" ? "Tracker Detection Summary" : "Ad SDK Detection Summary") " ==="
  print ""
  F = "%-22s | %-20s | %5s | %5s | %4s | %6s | %-6s | %-9s | %s\n"
  printf F, "SDK", "SDK_ID", "FILES", "MANIF", "ENDP", "APPREF", "CONF", "STATUS", "NEUTRALIZE"
  for (i = 1; i <= ne; i++) {
    s = E[i]; if (!ING[s]) continue
    if (LRANK[s] >= 1000 && LVN[s] == 0) continue
    printf F, lab(s), s, n0(FILES[s]), n0(MANIF[s]), n0(ENDP[s]), n0(APPREF[s]), LV[s], ST[s], (TGT[s] ? "yes" : "no (detection-only)")
  }
  ep_collect()
  print ""
  print "Entry points in app code: " n0(NEPL) " call site(s) in " n0(NEPF) " file(s)"
  mm = 0; for (i = 1; i <= nmn; i++) { n = split(MSD[i], a, " "); for (k = 1; k <= n; k++) if (ING[a[k]]) { mm++; break } }
  print "Manifest markers: " mm " match(es)"
  if (TOOL == "find-ads") {
    print "Mediation adapters: " n0(nad)
    cons = ""
    for (i = 1; i <= ne; i++) { s = E[i]; if (ING[s] && GRP[s] == "consent" && LVN[s] > 0) cons = cons "" (cons == "" ? "" : ", ") s " " LV[s] }
    print "Consent framework: " (cons == "" ? "none" : cons)
  }
  lst = ""
  for (i = 1; i <= ne; i++) { s = E[i]; if (ING[s] && !TGT[s] && LVN[s] >= 2) lst = lst "" (lst == "" ? "" : " ") s }
  if (lst != "") print "Detected but NOT neutralized by sdk-neutralizer (no registry targets): " lst
  if (!NOHINTS) {
    hint_counts(); hs = ""
    for (i = 1; i <= nh; i++) if (HCL[H[i]] > 0) hs = hs " " H[i] "=" HCL[H[i]]
    print "Hints (informational, never counted):" (hs == "" ? " none" : hs)
  }
  print "Confidence: HIGH = SDK code present (+ marker class when declared); MEDIUM = code without declared marker, or AndroidManifest only; LOW = app-code references / endpoints only; NONE = not detected"
}
# entry points: every R and C line of the tool group (app code)
function ep_collect(   i, k, f) {
  if (EPDONE) return
  EPDONE = 1
  for (i = 1; i <= nr; i++) if (ING[RSD[i]]) ep_add(RR[i], RL[i], RSD[i] "/ref")
  for (i = 1; i <= nc; i++) if (ING[CS[i]]) ep_add(CRl[i], CLn[i], CS[i] "/" CRo[i] "" (CF[i] == "exact" ? "" : "?"))
}
function ep_add(rel, ln, ann,   k) {
  k = rel SUBSEP ln
  if (!(k in EPA)) { EPA[k] = ""; NEPL++; EPR[NEPL] = rel; EPL[NEPL] = ln; if (!(rel in EPFS)) { EPFS[rel] = 1; NEPF++ } }
  if (index(" " EPA[k] " ", " " ann " ") == 0) EPA[k] = EPA[k] "" (EPA[k] == "" ? "" : " ") ann
}

# ---------------------------------------------------------------------------------------------
# text: sections are declared in print order; rows go to rows.out with sort keys, printed by
# the caller after `sort` (path ordinal, then line)
function sec(title, mode, cap, hintonly) { nsec++; SECT[nsec] = title; SECM[nsec] = mode; SECC[nsec] = cap; SECH[nsec] = hintonly; return nsec }
function row(sx, rel, ln, text, ann,   k) {
  k = sx SUBSEP rel SUBSEP ln
  if (!(k in ROWT)) { nrow++; ROWK[nrow] = k; ROWT[k] = text; ROWA[k] = "" }
  if (ann != "" && index(" " ROWA[k] " ", " " ann " ") == 0) ROWA[k] = ROWA[k] "" (ROWA[k] == "" ? "" : " ") ann
}
function crow(sx, i, ann) { row(sx, CRl[i], CLn[i], path(CRl[i]) ":" CLn[i] ":" TXT[CRl[i], CLn[i]], ann) }
function rrow(sx, i, ann) { row(sx, RR[i], RL[i], path(RR[i]) ":" RL[i] ":" TXT[RR[i], RL[i]], ann) }
function mrow(sx, i, ann) { row(sx, "\001", MNL[i], MANDISP ":" MNL[i] ":" MTXT[MNL[i]], ann) }
function drow(sx, i, ann) { row(sx, DR[i], DL[i], path(DR[i]) ":" DL[i] ":" TXT[DR[i], DL[i]], ann) }
function hrow(sx, i) { row(sx, HER[i], HEL[i], path(HER[i]) ":" HEL[i] ":" TXT[HER[i], HEL[i]], "") }
function selected(s) { return index(SELIDS, " " s " ") > 0 }
function aspect(a) { return SELALL || index(SELASP, " " a " ") > 0 }
function out_text(   i, s, j, sx, r, t, n, a, k, f, fs, ttl, x, m, cop, low, fsx) {
  for (i = 1; i <= ne; i++) {
    s = E[i]; if (!ING[s]) continue
    if (!(selected(s) || (SELALL && LVN[s] > 0))) continue
    P = PRE[s]
    sx = sec(P SEP "Identity", "always", 0, 0)
    row(sx, "", 0, "# confidence=" LV[s] " status=" ST[s] " neutralizable=" (TGT[s] ? "yes" : "no (detection-only)") " detail=" DET[s] mkmiss(s), "")
    for (j = 1; j <= nrc; j++) if (RCS[j] == s) {
      t = (RCT[j] == "ns") ? "namespace: package " : (RCT[j] == "ad") ? "adapter: package " : "identity: package "
      row(sx, RCD[j], 0, path(RCD[j]) ":0:" t RCR[j] " (" RCN[j] " files)", "")
    }
    for (j = 1; j <= NMK[s]; j++) if ((s, MKL[s, j]) in MKF) row(sx, MKF[s, MKL[s, j]], 0, path(MKF[s, MKL[s, j]]) ":0:identity: marker class " MKL[s, j], "")
    for (r = 1; r <= nro; r++) {
      sx = sec(P SEP ROL[RO[r]], "nonempty", 0, 0)
      for (j = 1; j <= nc; j++) if (CS[j] == s && CRo[j] == RO[r]) crow(sx, j, simple(CA[j]) (CF[j] == "exact" ? "" : "?"))
    }
    sx = sec(P SEP "Manifest", "nonempty", 0, 0)
    for (j = 1; j <= nmn; j++) if (index(MSD[j], " " s " ") > 0) mrow(sx, j, "")
    sx = sec(P SEP "Endpoints", "nonempty", 0, 0)
    for (j = 1; j <= nd; j++) if (DS_[j] == s && DK[j] == "E" && DE[j]) drow(sx, j, DV[j])
    sx = sec(P SEP "Ad Unit IDs", "nonempty", 0, 0)
    for (j = 1; j <= nd; j++) if (DS_[j] == s && DK[j] == "I" && DE[j]) drow(sx, j, IPL[s, DV[j]])
    sx = sec(P SEP "References", "nonempty", FULL ? 0 : 50, 0)
    for (j = 1; j <= nr; j++) if (RSD[j] == s) rrow(sx, j, "")
    for (j = 1; j <= nc; j++) if (CS[j] == s) crow(sx, j, "")
  }
  if (TOOL == "find-trackers") {
    if (aspect("generic")) hint_sections("generic", "")
    if (aspect("endpoints")) {
      sx = sec("Known Tracker Endpoints", "always", 0, 0)
      for (j = 1; j <= nd; j++) if (ING[DS_[j]] && DK[j] == "E" && DE[j]) drow(sx, j, DS_[j])
      hint_rows("endpoints", "Known Tracker Endpoints", sx)
      hint_sections("endpoints", " Known Tracker Endpoints ")
    }
    if (aspect("manifest")) man_sections("Tracker Services & Receivers", "Tracker Permissions", "Tracker Meta-data")
  } else {
    if (aspect("formats")) {
      split("banner interstitial rewarded native rewarded_interstitial app_open", fs, " ")
      split("Banner|Interstitial|Rewarded|Native|Rewarded Interstitial|App Open", ttl, "|")
      for (f = 1; f <= 6; f++) {
        fsx[fs[f]] = sec("Cross-SDK" SEP "All " ttl[f] " Patterns", "always", 0, 0)
      }
      for (j = 1; j <= nc; j++) if (GRP[CS[j]] == "ads") { x = fmtcm(CA[j], mname(CA[j])); if (x != "") crow(fsx[x], j, CS[j]) }
      for (j = 1; j <= nr; j++) if (GRP[RSD[j]] == "ads") {
        n = split(RK[j], a, " ")
        for (k = 1; k <= n; k++) if (a[k] != "-") { x = fmtc(a[k]); if (x != "") rrow(fsx[x], j, RSD[j]) }
      }
      sx = sec("Cross-SDK" SEP "Ad Unit / Placement IDs", "always", 0, 0)
      for (j = 1; j <= nd; j++) if (ING[DS_[j]] && DK[j] == "I" && DE[j]) drow(sx, j, DS_[j])
      hint_rows("formats", "Cross-SDK" SEP "Ad Unit / Placement IDs", sx)
      hint_sections("formats", " Cross-SDK" SEP "Ad Unit / Placement IDs ")
    }
    if (aspect("mediation")) {
      for (i = 1; i <= ne; i++) {
        s = E[i]; m = 0
        for (j = 1; j <= nrc; j++) if (RCS[j] == s && RCT[j] == "ad") m = 1
        if (!m && !hasadroot(s)) continue
        sx = sec("Mediation" SEP DISP[s] " Mediation Adapters", "always", 0, 0)
        for (j = 1; j <= nad; j++) if (ADS[j] == s) row(sx, ADD[j], 0, path(ADD[j]) ":0:adapter: " ADN[j] " (" ADC[j] " files)", "")
      }
      hint_sections("mediation", "")
    }
    if (aspect("consent")) {
      sx = sec("Consent" SEP "Google UMP / Funding Choices", "always", 0, 0)
      for (i = 1; i <= ne; i++) {
        s = E[i]; if (GRP[s] != "consent") continue
        for (j = 1; j <= nrc; j++) if (RCS[j] == s) row(sx, RCD[j], 0, path(RCD[j]) ":0:identity: package " RCR[j] " (" RCN[j] " files) [" s "]", "")
        for (j = 1; j <= NMK[s]; j++) if ((s, MKL[s, j]) in MKF) row(sx, MKF[s, MKL[s, j]], 0, path(MKF[s, MKL[s, j]]) ":0:identity: marker class " MKL[s, j], "")
        for (j = 1; j <= nr; j++) if (RSD[j] == s) rrow(sx, j, s "/ref")
        for (j = 1; j <= nc; j++) if (CS[j] == s && (CRo[j] == "consent" || CRo[j] == "config")) crow(sx, j, s "/" CRo[j] "" (CF[j] == "exact" ? "" : "?"))
      }
      sx = sec("Consent" SEP "IAB TCF v2", "always", 0, 0)
      hint_rows("consent", "Consent" SEP "IAB TCF v2", sx)
      sx = sec("Consent" SEP "COPPA / Child-Directed", "always", 0, 0)
      cop = hint_rows("consent", "Consent" SEP "COPPA / Child-Directed", sx)
      n = split(cop, a, " ")
      for (j = 1; j <= nc; j++) if (CRo[j] == "consent") {
        low = tolower(mname(CA[j]))
        for (k = 1; k <= n; k++) if (index(low, a[k]) > 0) { crow(sx, j, CS[j] "/" GRP[CS[j]]); break }
      }
      sx = sec("Consent" SEP "SDK-specific Opt-out", "always", 0, 0)
      for (j = 1; j <= nc; j++) if (CRo[j] == "consent" && GRP[CS[j]] != "consent") crow(sx, j, CS[j] "/" GRP[CS[j]])
      hint_rows("consent", "Consent" SEP "SDK-specific Opt-out", sx)
      hint_sections("consent", " Consent" SEP "IAB TCF v2 Consent" SEP "COPPA / Child-Directed Consent" SEP "SDK-specific Opt-out ")
    }
    if (aspect("manifest")) man_sections("Ad Activities & Services", "Ad Permissions", "Ad Meta-data")
  }
  if (aspect("entrypoints")) {
    sx = sec("Entry Points" SEP TTL " SDK calls from app code (library packages excluded)", "always", 0, 0)
    SECF[sx] = 1
    ep_collect()
    for (i = 1; i <= NEPL; i++) { k = EPR[i] SUBSEP EPL[i]; row(sx, EPR[i], EPL[i], path(EPR[i]) ":" EPL[i] ":" TXT[EPR[i], EPL[i]], EPA[k]) }
  }
  for (i = 1; i <= nsec; i++) {
    if (SECH[i] && NOHINTS) continue
    print i, 0, "", 0, "H", SECM[i], SECC[i] + 0, SECF[i] + 0, SECT[i] > ROWS
  }
  for (i = 1; i <= nrow; i++) {
    split(ROWK[i], a, SUBSEP)
    if (SECH[a[1]] && NOHINTS) continue
    t = ROWT[ROWK[i]]
    if (ROWA[ROWK[i]] != "") t = t "  [" ROWA[ROWK[i]] "]"
    print a[1], 1, a[2], a[3], "R", t > ROWS
  }
  close(ROWS)
}
function mname(api) { sub(/^.*#/, "", api); return api }
function mkmiss(s,   j, out) {
  out = ""
  if (IDF[s] > 0) for (j = 1; j <= NMK[s]; j++) if (!((s, MKL[s, j]) in MKF)) out = out "" (out == "" ? "" : ",") MKL[s, j]
  return (out == "") ? "" : " (marker class missing: " out ")"
}
function hasadroot(s,   r, i) { for (r in RT_N) for (i = 1; i <= RT_N[r]; i++) if (RT_T[r, i] == "ad" && RT_S[r, i] == s) return 1; return 0 }
# hint_rows(flag, title, sx): app-code and manifest hint rows of the hints with that flag and
# title; returns the lowercased tokens (underscores removed) of those hints
function hint_rows(flag, title, sx,   i, id, j, toks, t) {
  toks = ""
  for (i = 1; i <= nh; i++) {
    id = H[i]
    if (HFLAG[id] != flag || HTITLE[id] != title) continue
    for (j = 1; j <= nht; j++) if (HTI[j] == id) { t = tolower(HTT[j]); gsub(/_/, "", t); toks = toks " " t }
    if (NOHINTS) continue
    for (j = 1; j <= nhe; j++) if (HEI[j] == id) hrow(sx, j)
    for (j = 1; j <= nmn; j++) if (index(mhints(j, 0) " ", " " id " ") > 0) mrow(sx, j, "")
  }
  return toks
}
# hint_sections(flag, skip): one section per hint title of that flag, unless listed in skip
function hint_sections(flag, skip,   i, id, sx, seen) {
  for (i = 1; i <= nh; i++) {
    id = H[i]
    if (HFLAG[id] != flag) continue
    if (index(skip, " " HTITLE[id] " ") > 0 || (HTITLE[id] in seen)) continue
    seen[HTITLE[id]] = 1
    sx = sec(HTITLE[id], "always", 0, 1)
    hint_rows(flag, HTITLE[id], sx)
  }
}
function man_sections(tc, tp, tm,   sx, j, n, a, k, ok, tag, i) {
  for (k = 1; k <= 3; k++) {
    if (k == 1) { sx = sec("AndroidManifest" SEP tc, "always", 0, 0) }
    else if (k == 2) { sx = sec("AndroidManifest" SEP tp, "always", 0, 0) }
    else { sx = sec("AndroidManifest" SEP tm, "always", 0, 0) }
    for (j = 1; j <= nmn; j++) {
      tag = MNT[j]
      ok = (k == 1) ? (tag == "activity" || tag == "activity-alias" || tag == "service" || tag == "receiver" || tag == "provider" || tag == "action") \
         : (k == 2) ? (tag == "uses-permission" || tag == "permission") : (tag == "meta-data")
      if (!ok) continue
      n = split(MSD[j], a, " ")
      for (i = 1; i <= n; i++) if (ING[a[i]]) mrow(sx, j, a[i])
    }
    hint_rows("manifest", "AndroidManifest" SEP "" (k == 1 ? tc : k == 2 ? tp : tm), sx)
  }
}

# ---------------------------------------------------------------------------------------------
# json: tab-separated records for jq (sdk-audit.sh builds the document)
function jt(s) { gsub(/\t/, " ", s); return s }
function out_json(   i, s, j, k, n, a, t) {
  print "IN", "path", DD; print "IN", "layout", LAYOUT; print "IN", "tool", TOOL
  for (i = 1; i <= ncr; i++) print "CR", path(CR[i])
  if (MANDISP != "") print "MF", MANDISP
  for (i = 1; i <= nal; i++) { t = ALP[i]; gsub(/\./, "/", t); print "AL", t, ALQ[i], ALV[i] }
  for (i = 1; i <= ne; i++) {
    s = E[i]; if (!ING[s] || LVN[s] == 0) continue
    print "S", s, ((LFLAG[s] != "-") ? LLAB[s] : s), DISP[s], CAT[s], GRP[s], LV[s], ST[s], DET[s], (TGT[s] ? "true" : "false"), ACT[s], n0(FILES[s]), n0(APPREF[s]), n0(LIBDOM[s])
    for (j = 1; j <= nrc; j++) if (RCS[j] == s && (RCT[j] == "id" || RCT[j] == "inh")) print "P", s, RCR[j]
    for (j = 1; j <= NMK[s]; j++) print "MK", s, MKL[s, j], (((s, MKL[s, j]) in MKF) ? 1 : 0)
    for (j = 1; j <= nmn; j++) if (index(MSD[j], " " s " ") > 0) print "MN", s, MNT[j], MNV[j], MNL[j]
    split("", cnt); split("", ord); no = 0
    for (j = 1; j <= nd; j++) if (DS_[j] == s && DE[j] && DK[j] == "E") { k = DV[j]; if (!(k in cnt)) { no++; ord[no] = k }; cnt[k]++ }
    for (j = 1; j <= no; j++) print "DM", s, ord[j], cnt[ord[j]]
    for (j = 1; j <= nc; j++) if (CS[j] == s) print "CL", s, CRo[j], CA[j], path(CRl[j]), CLn[j], CF[j]
    if (!TGT[s] && LVN[s] >= 2) print "NN", s
  }
  ep_collect()
  for (i = 1; i <= NEPL; i++) { k = EPR[i] SUBSEP EPL[i]; print "EP", path(EPR[i]), EPL[i], EPA[k], jt(TXT[EPR[i], EPL[i]]) }
  if (!NOHINTS) { hint_counts(); for (i = 1; i <= nh; i++) if (HCL[H[i]] > 0) print "HN", H[i], HCF[H[i]], HCL[H[i]] }
  if (TOOL == "find-ads") for (i = 1; i <= nad; i++) print "AD", ADS[i], ADN[i], ADC[i]
}
AWK
: >"$TMP/calls.out"; : >"$TMP/rows.out"; : >"$TMP/hints.out"; : >"$TMP/adapters.out"
SA_MODE=$MODE SA_TOOL=$TOOL SA_D=$DISP SA_MANDISP=$MANDISP SA_LAYOUT=$LAYOUT SA_FULL=$FULL SA_NOHINTS=$NOHINTS \
SA_SELALL=$SEL_ALL SA_SELIDS="$SEL_IDS" SA_SELASP="$SEL_ASPECTS" SA_SEP="$SEP" SA_TMP=$TMP SA_TITLE=$TOOL_TITLE \
  awk -f "$TMP/lib.awk" -f "$TMP/rep.awk" kind=ent "$TMP/ent.tsv" kind=roots "$TMP/roots.tsv" \
    kind=roles "$TMP/roles.tsv" kind=fmt "$TMP/fmt.tsv" kind=markers "$TMP/markers.tsv" kind=mnames "$TMP/mnames.tsv" \
    kind=mcomps "$TMP/mcomps.tsv" kind=idpfx "$TMP/idpfx.tsv" kind=hints "$TMP/hints.tsv" kind=htok "$TMP/htok.tsv" \
    kind=alias "$TMP/aliases.tsv" kind=coderoots "$TMP/coderoots" kind=agg "$TMP/agg.tsv" kind=man "$TMP/man.tsv" \
    kind=ev "$TMP/ev.tsv" kind=dom "$TMP/dom.tsv" >"$TMP/rep.out" || die "report failed"

case "$MODE" in
  tsv)
    cat "$TMP/rep.out"
    sort -t "$TAB" -k1,1 -k2,2n -k4,4 -k5,5 -k6,6 -u "$TMP/calls.out" | cut -f3-
    cat "$TMP/hints.out" "$TMP/adapters.out" ;;
  summary)
    cat "$TMP/rep.out" ;;
  json)
    jq -nR --arg tool "$TOOL" '
      [inputs | split("\t")] as $L
      | def recs($k): [$L[] | select(.[0] == $k)];
        def num: tonumber;
        def by($k): reduce (recs($k)[]) as $r ({}; .[$r[1]] += [$r]);
        (recs("IN") | map({(.[1]): .[2]}) | add) as $in
      | by("P") as $P | by("MK") as $MK | by("MN") as $MN | by("DM") as $DM | by("CL") as $CL
      | (recs("S") | map(. as $s | {
          sdk: $s[2], sdk_id: $s[1], display_name: $s[3], category: $s[4], group: $s[5],
          confidence: $s[6], status: $s[7], detail: $s[8], neutralizable: ($s[9] == "true"), active: ($s[10] == "true"),
          evidence: {
            files: ($s[11] | num),
            packages_present: [($P[$s[1]] // [])[] | .[2]],
            markers_found: [($MK[$s[1]] // [])[] | select(.[3] == "1") | .[2]],
            markers_missing: [($MK[$s[1]] // [])[] | select(.[3] == "0") | .[2]],
            manifest: [($MN[$s[1]] // [])[] | {tag: .[2], name: .[3], line: (.[4] | num)}],
            domains: [($DM[$s[1]] // [])[] | {domain: .[2], hits: (.[3] | num)}],
            app_refs: ($s[12] | num),
            calls: [($CL[$s[1]] // [])[] | {role: .[2], api: .[3], path: .[4], line: (.[5] | num), confidence: .[6]}],
            lib_domain_hits: ($s[13] | num)
          } })) as $sdks
      | {schema_version: 2, tool: $tool,
         input: {path: $in.path, layout: $in.layout, code_roots: [recs("CR")[] | .[1]], manifests: [recs("MF")[] | .[1]],
                 aliases: [recs("AL")[] | {from: .[1], to: .[2], votes: (.[3] | num)}]}}
      + (if $tool == "find-ads"
         then {ad_sdks: [$sdks[] | select(.group == "ads") | del(.group)],
               consent_sdks: [$sdks[] | select(.group == "consent") | del(.group)]}
         else {trackers: [$sdks[] | del(.group)]} end)
      + {entry_points: [recs("EP")[] | {path: .[1], line: (.[2] | num), sdks: (.[3] | split(" ")), text: .[4]}],
         hints: ((recs("HN") | map({(.[1]): {files: (.[2] | num), lines: (.[3] | num)}}) | add) // {}),
         not_neutralizable: [recs("NN")[] | .[1]]}
      + (if $tool == "find-ads" then {mediation: {adapters: [recs("AD")[] | {mediator: .[1], network: .[2], files: (.[3] | num)}]}} else {} end)
    ' <"$TMP/rep.out" || die "jq failed while writing the JSON report" ;;
  text)
    if [ "$TOOL" = find-trackers ]; then
      SA_NOTE="If no results appear, tracker SDKs may only be initialized internally (e.g., via ContentProvider)."
    else
      SA_NOTE="If no results appear, ad SDKs may only be invoked internally via mediation adapters."
    fi
    export SA_NOTE
    sort -t "$TAB" -k1,1n -k2,2n -k3,3 -k4,4n "$TMP/rows.out" | awk -F '\t' '
      function flush() {
        if (cur == 0) return
        if (n == 0 && mode == "nonempty") return
        print ""; print "==== " title " ===="; print ""
        if (n == 0) print ""
        for (i = 1; i <= n; i++) { if (cap > 0 && i > cap) { print "... " (n - cap) " more row(s) (use --full)"; break }; print rows[i] }
        if (foot) {
          print ""
          print "NOTE: Only calls from app code are shown above. Library-internal calls are excluded."
          print ENVIRON["SA_NOTE"]
        }
      }
      $5 == "H" { flush(); cur = $1; n = 0; mode = $6; cap = $7 + 0; foot = $8 + 0; title = $9; next }
      $5 == "R" { if ($1 != cur) next; t = $0; for (k = 1; k <= 5; k++) sub(/^[^\t]*\t/, "", t); rows[++n] = t }
      END { flush(); print ""; print "=== Search complete ===" }' ;;
esac
exit 0
