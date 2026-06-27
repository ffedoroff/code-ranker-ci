#!/usr/bin/env bash
# Builds one language's <details> section for the PR comment / job summary.
# Reads (cwd): snap.json (current), baseline/snap.json (optional), viol.json.
# Env: LANGUAGE, N (violation count), URL (report url), VERIFY (activation url).
# Writes: ck-comment/<LANGUAGE>.md
#
# The stat-diff is computed from the snapshots' `stats` blocks; labels/groups are
# read from the snapshot's node_attributes — nothing about the metric set is
# hardcoded here (see difftable.jq).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LANGUAGE="${LANGUAGE:-report}"
N="${N:-0}"

statsof() { jq -c '(.graphs | to_entries[0].value).stats // {}' "$1"; }
metaof()  { jq -c '(.graphs | to_entries[0].value).node_attributes // {}' "$1"; }

# Schema-major compatibility is checked by the workflow's ver_check step before
# this script runs (it writes its own note and skips us on mismatch), so here we
# only handle "baseline present" vs "no baseline".
if [ -f baseline/snap.json ]; then
  BREF="$(jq -r '.git.branch // "baseline"' baseline/snap.json)"
  BSHA="$(jq -r '(.git.commit // "")[0:7]' baseline/snap.json)"
  DIFFHDR="**Stat diff** · avg · vs \`${BREF}\` @${BSHA}"
  DIFF="$(jq -rn \
    --argjson b "$(statsof baseline/snap.json)" \
    --argjson c "$(statsof snap.json)" \
    --argjson meta "$(metaof snap.json)" \
    -f "$HERE/difftable.jq")"
else
  DIFF="_No baseline yet._"
  DIFFHDR="**Stat diff** · avg"
fi

if [ "${N}" -gt 0 ] 2>/dev/null; then
  W=errors; [ "${N}" -eq 1 ] && W=error
  SUMMARY="${LANGUAGE} ${N} ${W} ❌"
else
  SUMMARY="${LANGUAGE}"
fi

mkdir -p ck-comment
{
  echo "<details><summary>${SUMMARY}</summary>"
  echo
  if [ "${N}" -gt 0 ] 2>/dev/null; then
    echo "**Violations**"
    jq -r '(if type=="array" then . else .violations end)[]
           | "- `\(.location | sub("^\\{target\\}/";""))\(if .line then ":"+(.line|tostring) else "" end)` — \(.message)"' \
       viol.json 2>/dev/null | head -20
    echo
  fi
  if [ -n "${URL:-}" ]; then
    echo "[report](${URL})"
  elif [ -n "${VERIFY:-}" ]; then
    echo "🔒 [activate](${VERIFY})"
  fi
  echo
  echo "$DIFFHDR"
  echo
  echo "$DIFF"
  echo
  echo "</details>"
} > "ck-comment/${LANGUAGE}.md"
