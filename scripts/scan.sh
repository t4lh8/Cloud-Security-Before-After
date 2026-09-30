#!/usr/bin/env bash
# Scans both stacks with Checkov and prints a before/after comparison.
#
# Exits with an error if:
#   - the secure stack has any failed check, or
#   - the insecure stack has none (the scanner stopped catching the planted issues).
#
# Usage: scripts/scan.sh            (needs `pip install checkov`)
#        CHECKOV="python /path/to/checkov" scripts/scan.sh

set -euo pipefail

cd "$(dirname "$0")/.."
export ANSI_COLORS_DISABLED=1 PYTHONUTF8=1
read -ra CHECKOV <<< "${CHECKOV:-checkov}"

# Prints "passed failed skipped", summed over the terraform and secrets scanners.
scan() {
  { "${CHECKOV[@]}" -d "$1" --framework terraform secrets --compact --quiet 2>/dev/null || true; } \
    | grep -oE 'Passed checks: [0-9]+, Failed checks: [0-9]+, Skipped checks: [0-9]+' \
    | awk -F'[:,] *' '{ p += $2; f += $4; s += $6 } END { print p + 0, f + 0, s + 0 }'
}

echo "Scanning insecure/ ..."
read -r insecure_passed insecure_failed insecure_skipped <<< "$(scan insecure)"
echo "Scanning secure/ ..."
read -r secure_passed secure_failed secure_skipped <<< "$(scan secure)"

echo
printf "%-12s %8s %8s %8s\n" "STACK" "PASSED" "FAILED" "SKIPPED"
printf "%-12s %8s %8s %8s\n" "insecure/" "$insecure_passed" "$insecure_failed" "$insecure_skipped"
printf "%-12s %8s %8s %8s\n" "secure/" "$secure_passed" "$secure_failed" "$secure_skipped"
echo

# On GitHub Actions, also write the table to the job summary page.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF
## ☁️ Cloud Security: Before vs After

| Stack | ✅ Passed | ❌ Failed | ⏭️ Skipped |
|---|---:|---:|---:|
| \`insecure/\` | $insecure_passed | **$insecure_failed** | $insecure_skipped |
| \`secure/\` | $secure_passed | **$secure_failed** | $secure_skipped |
EOF
fi

status=0
if (( insecure_failed == 0 )); then
  echo "ERROR: the insecure stack passed every check - the scanner is no longer detecting the planted issues."
  status=1
fi
if (( secure_failed > 0 )); then
  echo "ERROR: the secure stack has $secure_failed failed check(s). Run: checkov -d secure"
  status=1
fi
if (( status == 0 )); then
  echo "OK: $insecure_failed issues found in insecure/, all fixed in secure/."
fi
exit $status
