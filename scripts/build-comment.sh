#!/usr/bin/env bash
# Builds the WHOLE PR comment (v5: one report/check over all languages) from a
# single snapshot. Reads (cwd): snap.json, baseline/snap.json (optional),
# viol.json. Env: URL (report url), VERIFY (activation url), REPORT_KIND
# ("diff report"|"report"). Writes: comment.md  and  errors.n (total violations).
#
# v5 snapshot nests each plugin under .languages.<lang>.graphs.<level>; violations
# carry a .language field. The comment is one header (ok / N errors), one "View
# report" button, a <details> per language (its violations + stat-diff), one
# baseline line, and one AI fix prompt. Metric labels/groups/directions are read
# from the snapshot — nothing hardcoded (see difftable.jq).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

fmtdate() { local s="$1"; if [ "${#s}" -ge 16 ]; then echo "${s:0:10} ${s:11:5} UTC"; else echo "$s"; fi; }

# Per-language accessors into the v5 snapshot ($1=lang $2=file).
lstats()  { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).stats // {}' "$2"; }
lmeta()   { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).node_attributes // {}' "$2"; }
lgroups() { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).attribute_groups // {}' "$2"; }
lcounts() {
  jq -c --arg l "$1" '
    ((.languages[$l].graphs // {}) | to_entries[0].value) as $g
    | ($g.node_kinds // {}) as $nk
    | [ $g.nodes[]? | select((.external != true) and (($nk[.kind].external // false) != true)) ] as $int
    | ($int | map(.id)) as $ids
    | { Files: ($int | length),
        Folders: ($ids | map(sub("/[^/]*$"; "")) | unique | length),
        Crates: (($g.ui.grouping.key // null) as $gk | if $gk == null then null
                 else ($int | map(.[$gk]) | map(select(. != null and . != "")) | unique | length) end),
        Edges: ([ $g.edges[]? | select((.source | IN($ids[])) and (.target | IN($ids[]))) ] | length),
        cycles: ([ $g.cycles[]?.nodes[]? ] | unique | length) }' "$2"
}
countrows() { # $1 lang -> [{label,b,c,dir}] (baseline vs current for that language)
  jq -nc --argjson b "$(lcounts "$1" baseline/snap.json)" --argjson c "$(lcounts "$1" snap.json)" '
    [ {label:"Files",b:$b.Files,c:$c.Files,dir:null},
      {label:"Folders",b:$b.Folders,c:$c.Folders,dir:null},
      {label:"Crates",b:$b.Crates,c:$c.Crates,dir:null},
      {label:"Edges",b:$b.Edges,c:$c.Edges,dir:null},
      {label:"Nodes in cycles",b:$b.cycles,c:$c.cycles,dir:true} ]
    | map(select(.b != null and .c != null)) '
}

CDATE="$(fmtdate "$(jq -r '.generated_at // ""' snap.json 2>/dev/null)")"
CORIGIN="$(jq -r '.git.origin // ""' snap.json 2>/dev/null)"
CCOMMIT="$(jq -r '.git.commit // ""' snap.json 2>/dev/null)"
KIND="${REPORT_KIND:-report}"

# Normalize violations to a flat array once.
jq 'if type=="array" then . else (.violations // []) end' viol.json > _viol.json 2>/dev/null || echo '[]' > _viol.json
TOTAL="$(jq 'length' _viol.json 2>/dev/null || echo 0)"

# Languages present in current (or baseline) snapshot, sorted.
langs="$(jq -rn --slurpfile a snap.json --slurpfile b baseline/snap.json \
  '([($a[0].languages // {}|keys[]), ($b[0].languages // {}|keys[])] | add | unique)[]' 2>/dev/null \
  || jq -r '.languages // {} | keys[]' snap.json)"

# Header. With a baseline, $VERDICT (improved/degraded/neutral) drives it and
# TOTAL is the count of NEW violations; without a baseline it's a review (ok/N).
case "${VERDICT:-}" in
  improved) VE="🟢 improved" ;;
  degraded) VE="🔴 degraded" ;;
  neutral)  VE="➖ neutral" ;;
  *)        VE="" ;;
esac
if [ -n "$VE" ]; then
  if [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    W=new; HEAD="code-ranker: ${VE} · ${TOTAL} ${W} ❌"
  else
    HEAD="code-ranker: ${VE}"
  fi
elif [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null; then
  W=errors; [ "$TOTAL" -eq 1 ] && W=error
  HEAD="code-ranker: ${TOTAL} ${W} ❌"
else
  HEAD="code-ranker: ok"
fi

# Baseline line (one snapshot).
if [ -f baseline/snap.json ]; then
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
  bbranch="$(jq -r '.git.branch // ""' baseline/snap.json)"
  cbranch="$(jq -r '.git.branch // ""' snap.json)"
else
  INFO="updated ${CDATE}"
fi

{
  echo "## ${HEAD}"
  echo
  # One report button (covers all languages).
  if [ -n "${URL:-}" ]; then
    echo "<h3><a href=\"${URL}\" target=\"_blank\" rel=\"noopener noreferrer\">View ${KIND} ↗</a></h3>"
  elif [ -n "${VERIFY:-}" ]; then
    echo "🔒 [Activate to publish reports](${VERIFY})"
  fi
  echo

  for lang in $langs; do
    n="$(jq --arg l "$lang" '[.[] | select(.language == $l)] | length' _viol.json 2>/dev/null || echo 0)"
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      w=errors; [ "$n" -eq 1 ] && w=error
      sum="${lang}: ${n} ${w} ❌"
    else
      sum="${lang}: ok"
    fi
    echo "<details><summary>${sum}</summary>"
    echo
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      echo "<details><summary>Violations: ${n}</summary>"
      echo
      jq -r --arg l "$lang" --arg origin "$CORIGIN" --arg sha "$CCOMMIT" '
        (($origin != "") and ($sha != "")) as $hl
        | [.[] | select(.language == $l)][]
        | (.location | sub("^\\{target\\}/";"")) as $loc
        | (if .line then ":"+(.line|tostring) else "" end) as $ln
        | (if .line then "#L"+(.line|tostring) else "" end) as $anchor
        | (if $hl then "[\($loc)\($ln)](\($origin)/blob/\($sha)/\($loc)\($anchor))" else "`\($loc)\($ln)`" end) as $loclink
        | (.message | if $hl then gsub("\\{target\\}/(?<p>[^\\s]+)"; "[\(.p)](" + $origin + "/blob/" + $sha + "/" + .p + ")") else gsub("\\{target\\}/"; "") end) as $msg
        | "- \($loclink) — \($msg)"' _viol.json 2>/dev/null | head -20
      echo
      echo "</details>"
      echo
    fi
    # stat-diff for this language
    if [ -f baseline/snap.json ]; then
      DIFF="$(jq -rn \
        --argjson counts "$(countrows "$lang")" \
        --argjson bstats "$(lstats "$lang" baseline/snap.json)" \
        --argjson cstats "$(lstats "$lang" snap.json)" \
        --argjson meta   "$(lmeta "$lang" snap.json)" \
        --argjson groups "$(lgroups "$lang" snap.json)" \
        --arg bhdr "$( [ -n "${CORIGIN}" ] && [ -n "${bbranch:-}" ] && printf '[Baseline](%s/tree/%s)' "$CORIGIN" "$bbranch" || printf 'Baseline')" \
        --arg chdr "$( [ -n "${CORIGIN}" ] && [ -n "${cbranch:-}" ] && printf '[Current](%s/tree/%s)' "$CORIGIN" "$cbranch" || printf 'Current')" \
        -f "$HERE/difftable.jq")"
    else
      DIFF="_No baseline yet._"
    fi
    echo "$DIFF"
    echo
    echo "</details>"
    echo
  done

  echo "<sub>${INFO}</sub>"

  if [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    echo
    echo "<details>"
    echo "<summary>🤖 Prompt for fix all with AI</summary>"
    echo
    echo '```'
    echo "Run code-ranker check --top 1 and follow instructions to fix error. Loop until no errors left."
    echo '```'
    echo
    echo "</details>"
  fi
} > comment.md

echo "${TOTAL:-0}" > errors.n
