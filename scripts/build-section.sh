#!/usr/bin/env bash
# Builds one language's <details> section for the PR comment / job summary, plus a
# small meta file the aggregator uses for the single footer line.
# Reads (cwd): snap.json (current), baseline/snap.json (optional), viol.json.
# Env: LANGUAGE, N (violation count), URL (report url), VERIFY (activation url).
# Writes: ck-comment/<LANGUAGE>.md  and  ck-comment/<LANGUAGE>.meta.json
#
# The stat-diff mirrors the HTML report's summary: a "sum always" section of
# structural counts followed by per-metric avg sections, with a green/red colour
# (inline math \color) driven by each metric's direction. Labels/groups/directions
# are read from the snapshot — nothing about the metric set is hardcoded here (see
# difftable.jq). The "avg · vs <ref>" caption + timestamp is written ONCE by the
# aggregator (comment.yml) from the meta file, not per language.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LANGUAGE="${LANGUAGE:-report}"
N="${N:-0}"

statsof() { jq -c '(.graphs | to_entries[0].value).stats // {}' "$1"; }
metaof()  { jq -c '(.graphs | to_entries[0].value).node_attributes // {}' "$1"; }
groupsof(){ jq -c '(.graphs | to_entries[0].value).attribute_groups // {}' "$1"; }

# Structural counts over INTERNAL nodes (external library nodes excluded).
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

countrows() { # $1 baseline $2 current -> [{label,b,c,dir}]
  jq -nc --argjson b "$(countsof "$1")" --argjson c "$(countsof "$2")" '
    [ {label:"Files",           b:$b.Files,   c:$c.Files,   dir:null},
      {label:"Folders",         b:$b.Folders, c:$c.Folders, dir:null},
      {label:"Crates",          b:$b.Crates,  c:$c.Crates,  dir:null},
      {label:"Edges",           b:$b.Edges,   c:$c.Edges,   dir:null},
      {label:"Nodes in cycles", b:$b.cycles,  c:$c.cycles,  dir:true} ]
    | map(select(.b != null and .c != null)) '
}

mkdir -p ck-comment
CDATE="$(jq -r '.generated_at // ""' snap.json 2>/dev/null)"

branchlink() { # $1 snapshot $2 fallback-label -> "[label](origin/tree/branch)" or label
  local origin branch
  origin="$(jq -r '.git.origin // ""' "$1")"
  branch="$(jq -r '.git.branch // ""' "$1")"
  if [ -n "$origin" ] && [ -n "$branch" ]; then
    printf '[%s](%s/tree/%s)' "$2" "$origin" "$branch"
  else
    printf '%s' "$2"
  fi
}

if [ -f baseline/snap.json ]; then
  DIFF="$(jq -rn \
    --argjson counts "$(countrows baseline/snap.json snap.json)" \
    --argjson bstats "$(statsof baseline/snap.json)" \
    --argjson cstats "$(statsof snap.json)" \
    --argjson meta   "$(metaof snap.json)" \
    --argjson groups "$(groupsof snap.json)" \
    --arg     bhdr   "$(branchlink baseline/snap.json Baseline)" \
    --arg     chdr   "$(branchlink snap.json Current)" \
    -f "$HERE/difftable.jq")"
  # meta for the single footer (all languages share the same baseline commit)
  jq -n \
    --arg ref    "$(jq -r '.git.branch // "baseline"' baseline/snap.json)" \
    --arg sha    "$(jq -r '(.git.commit // "")' baseline/snap.json)" \
    --arg origin "$(jq -r '.git.origin // ""' baseline/snap.json)" \
    --arg bdate  "$(jq -r '.generated_at // ""' baseline/snap.json)" \
    --arg cdate  "$CDATE" \
    '{ref:$ref, sha:$sha, origin:$origin, bdate:$bdate, cdate:$cdate}' \
    > "ck-comment/${LANGUAGE}.meta.json" 2>/dev/null || true
else
  DIFF="_No baseline yet._"
  mkdir -p ck-comment
  jq -n --arg cdate "$CDATE" '{ref:"", sha:"", origin:"", bdate:"", cdate:$cdate}' \
    > "ck-comment/${LANGUAGE}.meta.json" 2>/dev/null || true
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
           | "- `\(.location | sub("^\\{target\\}/";""))\(if .line then ":"+(.line|tostring) else "" end)` — \(.message | gsub("\\{target\\}/";""))"' \
       viol.json 2>/dev/null | head -20
    echo
  fi
  if [ -n "${URL:-}" ]; then
    # Big dark "button" via a shields.io badge image wrapped in a link (CodeRabbit
    # style). Label says the language and whether it's a diff or plain report.
    KIND="${REPORT_KIND:-report}"
    LBL="⬇ Download ${LANGUAGE} ${KIND}"
    ENC="$(printf '%s' "$LBL" | sed 's/ /%20/g')"
    echo "[![${LBL}](https://img.shields.io/badge/${ENC}-1f2328?style=for-the-badge)](${URL})"
  elif [ -n "${VERIFY:-}" ]; then
    echo "🔒 [Activate to publish reports](${VERIFY})"
  fi
  echo
  echo "$DIFF"
  # When there are violations, add a nested collapsed "Prompt for fix" section.
  # Basic placeholder prompt for now (to be refined later).
  if [ "${N}" -gt 0 ] 2>/dev/null; then
    echo
    echo "<details><summary>🤖 Prompt for fix all with AI</summary>"
    echo
    echo "Run \`code-ranker check --top 1\` and follow instructions to fix error. Loop until no errors left."
    echo
    echo "</details>"
  fi
  echo
  echo "</details>"
} > "ck-comment/${LANGUAGE}.md"
