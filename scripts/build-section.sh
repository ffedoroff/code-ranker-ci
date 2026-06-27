#!/usr/bin/env bash
# Builds one language's <details> section for the PR comment / job summary.
# Reads (cwd): snap.json (current), baseline/snap.json (optional), viol.json.
# Env: LANGUAGE, N (violation count), URL (report url), VERIFY (activation url).
# Writes: ck-comment/<LANGUAGE>.md
#
# The stat-diff mirrors the HTML report's summary: a "sum always" section of
# structural counts (Files/Folders/Crates/Edges/Nodes in cycles) followed by the
# per-metric avg sections, with a 🟢/🔴 marker driven by each metric's direction.
# Metric labels/groups/directions are read from the snapshot — nothing about the
# metric set is hardcoded here (see difftable.jq). Schema-major compatibility is
# checked by the workflow's ver_check step before this runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LANGUAGE="${LANGUAGE:-report}"
N="${N:-0}"

statsof() { jq -c '(.graphs | to_entries[0].value).stats // {}' "$1"; }
metaof()  { jq -c '(.graphs | to_entries[0].value).node_attributes // {}' "$1"; }
groupsof(){ jq -c '(.graphs | to_entries[0].value).attribute_groups // {}' "$1"; }

# Structural counts over INTERNAL nodes (external library nodes excluded, matching
# the HTML). Folders = distinct dirs; Crates = distinct grouping-key values (null
# when the level has no grouping); Nodes in cycles = distinct nodes across cycles.
countsof() {
  jq -c '
    (.graphs | to_entries[0].value) as $g
    | ($g.node_kinds // {}) as $nk
    | [ $g.nodes[]? | select((.external != true) and (($nk[.kind].external // false) != true)) ] as $int
    | ($int | map(.id)) as $ids
    | ($ids | map(sub("/[^/]*$"; "")) | unique | length) as $folders
    | ($g.ui.grouping.key // null) as $gk
    | (if $gk == null then null
       else ($int | map(.[$gk]) | map(select(. != null and . != "")) | unique | length) end) as $crates
    | ([ $g.edges[]? | select((.source | IN($ids[])) and (.target | IN($ids[]))) ] | length) as $edges
    | ([ $g.cycles[]?.nodes[]? ] | unique | length) as $cyc
    | { Files: ($int | length), Folders: $folders, Crates: $crates, Edges: $edges, cycles: $cyc }
  ' "$1"
}

countrows() { # $1 baseline.json $2 current.json -> JSON array [{label,b,c,dir}]
  jq -nc --argjson b "$(countsof "$1")" --argjson c "$(countsof "$2")" '
    [ {label:"Files",           b:$b.Files,   c:$c.Files,   dir:null},
      {label:"Folders",         b:$b.Folders, c:$c.Folders, dir:null},
      {label:"Crates",          b:$b.Crates,  c:$c.Crates,  dir:null},
      {label:"Edges",           b:$b.Edges,   c:$c.Edges,   dir:null},
      {label:"Nodes in cycles", b:$b.cycles,  c:$c.cycles,  dir:true} ]
    | map(select(.b != null and .c != null)) '
}

if [ -f baseline/snap.json ]; then
  BREF="$(jq -r '.git.branch // "baseline"' baseline/snap.json)"
  BSHA="$(jq -r '(.git.commit // "")[0:7]' baseline/snap.json)"
  DIFFHDR="**Stat diff** · avg · vs \`${BREF}\` @${BSHA}"
  DIFF="$(jq -rn \
    --argjson counts "$(countrows baseline/snap.json snap.json)" \
    --argjson bstats "$(statsof baseline/snap.json)" \
    --argjson cstats "$(statsof snap.json)" \
    --argjson meta   "$(metaof snap.json)" \
    --argjson groups "$(groupsof snap.json)" \
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
