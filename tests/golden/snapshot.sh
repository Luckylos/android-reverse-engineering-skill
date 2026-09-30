#!/usr/bin/env bash
# tests/golden/snapshot.sh <registry-dir> -- print the CONSUMED projection of every
# registry entry (what registry-scan.py and detect-adwrapper read today), in file-name
# order, one JSON line per file. Two registries with identical snapshots are
# indistinguishable to today's consumers, whatever else changed (formatting, key order,
# new `detection` facts, notes...). Invariant I3 / rule R1 (DESIGN 3.1, 9.1):
#   bash tests/golden/snapshot.sh "$REG" | diff - tests/golden/snapshot.before.jsonl
# snapshot.before.jsonl was taken on the registry of 4c166fe (copy of
# registry-unification/scratch/contract/gold/registry-snapshot.before.jsonl).
# Exit: 0 ok, 1 unreadable/non-object file or bad usage.
set -uo pipefail
R="${1:?usage: snapshot.sh <registry-dir>}"
[ -d "$R" ] || { echo "snapshot.sh: not a directory: $R" >&2; exit 1; }
export LC_ALL=C
rc=0
for f in "$R"/*.json; do
  [ -e "$f" ] || continue
  b=$(basename "$f"); case "$b" in _*) continue ;; esac
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    echo "snapshot.sh: $b: not a JSON object" >&2; rc=1; continue
  fi
  jq -c --arg file "$b" '{
      file: $file,
      sdk_id, display_name, category,
      packages,
      has_targets: has("targets"),
      entry_points:  [.targets.entry_points[]?  | {class, methods: [.methods[] | {name, inject}]}],
      ad_operations: [.targets.ad_operations[]? | {class, methods: [.methods[] | {name, inject}]}],
      deep_patterns: [.targets.deep_patterns[]? | {package_glob, rule}],
      manifest_classes: [.manifest_components[]? | .class],
      protected_method_names: [.protected_patterns[]? | .pattern | capture("\\*\\.(?<m>[A-Za-z0-9_]+)\\(")? | .m],
      in_house_wrapper: (.in_house_wrapper // false)
    }' "$f" || rc=1
done
exit $rc
