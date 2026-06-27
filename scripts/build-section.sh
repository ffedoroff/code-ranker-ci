#!/usr/bin/env bash
# Builds one language's <details> section for the PR comment / job summary.
# Reads (cwd): snap.json (current), baseline/snap.json (optional), viol.json.
# Env: LANGUAGE, N (violation count), URL (report url), VERIFY (activation url),
#      REPORT_KIND ("diff report" | "report").
# Writes: ck-comment/<LANGUAGE>.md
#
# The stat-diff mirrors the HTML report's summary: a "sum always" section of
# structural counts followed by per-metric avg sections, with a green/red colour
# (inline math \color) driven by each metric's direction. Labels/groups/directions
# are read from the snapshot — nothing about the metric set is hardcoded here (see
# difftable.jq). Schema-major compatibility is checked by the workflow's ver_check
# step before this runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LANGUAGE="${LANGUAGE:-report}"
N="${N:-0}"
mkdir -p ck-comment

# ISO8601 -> "YYYY-MM-DD HH:MM UTC"
fmtdate() { local s="$1"; if [ "${#s}" -ge 16 ]; then echo "${s:0:10} ${s:11:5} UTC"; else echo "$s"; fi; }

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

CDATE="$(fmtdate "$(jq -r '.generated_at // ""' snap.json 2>/dev/null)")"
CORIGIN="$(jq -r '.git.origin // ""' snap.json 2>/dev/null)"
CCOMMIT="$(jq -r '.git.commit // ""' snap.json 2>/dev/null)"

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
  # "baseline <ref> @<sha> <date> · updated <date>" line, shown under the button.
  BREF="$(jq -r '.git.branch // "baseline"' baseline/snap.json)"
  BCOMMIT="$(jq -r '.git.commit // ""' baseline/snap.json)"
  BORIGIN="$(jq -r '.git.origin // ""' baseline/snap.json)"
  BDATE="$(fmtdate "$(jq -r '.generated_at // ""' baseline/snap.json)")"
  if [ -n "$BORIGIN" ] && [ -n "$BCOMMIT" ]; then
    BLINK="[${BREF} @${BCOMMIT:0:7}](${BORIGIN}/commit/${BCOMMIT})"
  else
    BLINK="${BREF} @${BCOMMIT:0:7}"
  fi
  INFO="baseline ${BLINK} ${BDATE} · updated ${CDATE}"
else
  DIFF="_No baseline yet._"
  INFO="updated ${CDATE}"
fi

if [ "${N}" -gt 0 ] 2>/dev/null; then
  W=errors; [ "${N}" -eq 1 ] && W=error
  SUMMARY="${LANGUAGE}: ${N} ${W} ❌"
else
  SUMMARY="${LANGUAGE}: ok"
fi

KIND="${REPORT_KIND:-report}"

{
  echo "<details><summary>${SUMMARY}</summary>"
  echo
  # Violations in a spoiler. Each is a link to the file at the current commit
  # (+ line anchor when known).
  if [ "${N}" -gt 0 ] 2>/dev/null; then
    echo "<details><summary>Violations: ${N}</summary>"
    echo
    jq -r --arg origin "$CORIGIN" --arg sha "$CCOMMIT" '
      (($origin != "") and ($sha != "")) as $havelink
      | (if type=="array" then . else .violations end)[]
      | (.location | sub("^\\{target\\}/";"")) as $loc
      | (if .line then ":"+(.line|tostring) else "" end) as $ln
      | (if .line then "#L"+(.line|tostring) else "" end) as $anchor
      # location -> link to the file at this commit
      | (if $havelink then "[\($loc)\($ln)](\($origin)/blob/\($sha)/\($loc)\($anchor))"
         else "`\($loc)\($ln)`" end) as $loclink
      # message -> linkify every {target}/<file> token it mentions
      | (.message
         | if $havelink
           then gsub("\\{target\\}/(?<p>[^\\s]+)"; "[\(.p)](" + $origin + "/blob/" + $sha + "/" + .p + ")")
           else gsub("\\{target\\}/"; "") end) as $msg
      | "- \($loclink) — \($msg)"' viol.json 2>/dev/null | head -20
    echo
    echo "</details>"
    echo
  fi
  # Bigger text "button" as an <h3> link, with target=_blank to open the report in
  # a new tab (GitHub may strip target on sanitize; then it opens in the same tab).
  if [ -n "${URL:-}" ]; then
    echo "<h3><a href=\"${URL}\" target=\"_blank\" rel=\"noopener noreferrer\">⬇ View ${LANGUAGE} ${KIND}</a></h3>"
  elif [ -n "${VERIFY:-}" ]; then
    echo "🔒 [Activate to publish reports](${VERIFY})"
  fi
  echo
  echo "<sub>${INFO}</sub>"
  echo
  echo "$DIFF"
  echo
  echo "</details>"
} > "ck-comment/${LANGUAGE}.md"

# Violation count for the aggregator's header total (code-ranker: ok / N errors).
echo "${N}" > "ck-comment/${LANGUAGE}.n"
