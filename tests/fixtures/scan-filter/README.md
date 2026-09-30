# scan-filter fixtures (t_scan_filter.sh, DESIGN 9.1 I4)

A detection-only registry entry (no `targets`) for a synthetic package
`com.stencyl.extension`, copied from the contract experiments
(`registry-unification/scratch/contract/tol/regA1` and `regA2`, which are the
registry of 4c166fe plus this one file):

- `regA1/stencyl-ext.json`: `targets` absent (a well-formed detection-only entry).
- `regA2/stencyl-ext.json`: `targets` absent but `manifest_components` present.
  The schema (`if`/`then`) and lint L4 reject it; registry-scan.py must still ignore
  it, so none of its components reaches `registry-manifest.txt`.

`t_scan_filter.sh` adds each file to a copy of the registry under test and requires
registry-scan.py to produce byte-identical stdout, stderr, exit code and output files
with and without it.
