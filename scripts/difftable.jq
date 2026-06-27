# Dynamic stat-diff -> markdown table, styled after the HTML report's summary.
# Inputs via --argjson:
#   $counts : [ {label, b, c, dir} ]  structural "sum always" rows (Files/Folders/
#             Crates/Edges/Nodes in cycles); dir null = neutral, true = lower_better.
#   $bstats : baseline stats object   { metric: value }   (per-metric avg)
#   $cstats : current  stats object
#   $meta   : node_attributes object  { metric: { name, label, group, direction } }
#   $groups : attribute_groups object { group: { label } }  (drives section order)
#
# Nothing about the metric set is hardcoded: metric rows are every numeric stat
# field that changed, grouped by $meta[k].group, labelled from $meta, ordered by
# $groups. Direction drives a 🟢 (good) / 🔴 (bad) / none (neutral) marker on Δ —
# GitHub markdown has no cell colour, so the marker stands in for the HTML's
# green/red/black.
def fmt(n):
  (n|fabs) as $a
  | if   $a >= 1000000 then ((n/1000000*10|round)/10|tostring)+"M"
    elif $a >= 10000   then ((n/1000*10|round)/10|tostring)+"K"
    elif $a >= 100     then (n|round|tostring)
    elif $a >= 1       then ((n*10|round)/10|tostring)
    elif $a == 0       then "0"
    else ((n*1000|round)/1000|tostring) end;
def sgn(d): if d > 0 then "+"+fmt(d) elif d < 0 then "−"+fmt(-d) else "0" end;
# 🟢 when the change is in the good direction, 🔴 when bad, "" when neutral.
def mark(d; dir):
  if (dir|type) == "boolean"
  then (if (if dir then d < 0 else d > 0 end) then "🟢 "
        elif (if dir then d > 0 else d < 0 end) then "🔴 "
        else "" end)
  else "" end;
def rowline(lbl; b; c; dir):
  (c - b) as $d | "| \(lbl) | \(fmt(b)) | \(fmt(c)) | \(mark($d; dir))\(sgn($d)) |";
def sechead(title): "| **\(title)** |  |  |  |";
def normdir(x): if x == "lower_better" then true elif x == "higher_better" then false else null end;

# sum-always: only changed rows
([ $counts[] | select((.c - .b) != 0) | rowline(.label; .b; .c; .dir) ]) as $sumrows

# metric records (changed only), in node_attributes order
| ([ ($meta | keys_unsorted)[] as $k
     | (($bstats[$k]) // 0) as $bv | (($cstats[$k]) // 0) as $cv
     | select(($bv|type) == "number" and ($cv|type) == "number" and ($cv - $bv) != 0)
     | { k: $k, bv: $bv, cv: $cv,
         group: ($meta[$k].group // "other"),
         name:  ($meta[$k].name // $meta[$k].label // $k),
         dir:   normdir($meta[$k].direction) } ]) as $recs

# section order: groups as declared in $groups, then any leftover groups
| ([ ($groups | keys_unsorted), ($recs | map(.group) | unique | map(select(. as $g | ($groups | has($g)) | not))) ] | add) as $order
| ([ $order[] as $g
     | ($recs | map(select(.group == $g))) as $gr
     | select(($gr | length) > 0)
     | [ sechead(($groups[$g].label // $g)) ]
       + ($gr | map(rowline(.k + " — " + .name; .bv; .cv; .dir))) ]
   | add // []) as $metarows

| ((if ($sumrows | length) > 0 then [sechead("sum always")] + $sumrows else [] end) + $metarows) as $body
| if ($body | length) == 0 then "_No metric changes._"
  else (["| Metric | Baseline | Current | Δ |", "| --- | ---: | ---: | ---: |"] + $body) | join("\n")
  end
