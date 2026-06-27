# Dynamic stat-diff -> markdown table. Inputs via --argjson:
#   $b    : baseline stats object   { metric: value, ... }
#   $c    : current  stats object
#   $meta : node_attributes object  { metric: { name, label, group, direction, ... } }
#
# Nothing about the metric set is hardcoded: rows are every numeric field present
# in either stats object whose value changed, and each row's label/group comes
# straight from $meta. New metrics the tool adds later appear automatically.
def fmt(n):
  (n|fabs) as $a
  | if   $a >= 1000000 then ((n/1000000*10|round)/10|tostring)+"M"
    elif $a >= 10000   then ((n/1000*10|round)/10|tostring)+"K"
    elif $a >= 100     then (n|round|tostring)
    elif $a >= 1       then ((n*10|round)/10|tostring)
    elif $a == 0       then "0"
    else ((n*1000|round)/1000|tostring) end;
def delta(d): if d>0 then "+"+fmt(d) elif d<0 then "−"+fmt(-d) else "0" end;

([$b, $c] | add | keys) as $keys
| [ $keys[]
    | . as $k
    | (($b[$k]) // 0) as $bv | (($c[$k]) // 0) as $cv | ($cv - $bv) as $d
    | select(($bv|type) == "number" and ($cv|type) == "number" and $d != 0)
    | { k: $k, bv: $bv, cv: $cv, d: $d,
        group: ($meta[$k].group // "~"),
        name:  ($meta[$k].name // $meta[$k].label // $k) } ]
| sort_by(.group, .name)
| if length == 0 then "_No metric changes._"
  else (["| Metric | Baseline | Current | Δ |", "| --- | ---: | ---: | ---: |"]
        + (map("| \(.k) — \(.name) | \(fmt(.bv)) | \(fmt(.cv)) | \(delta(.d)) |")))
       | join("\n")
  end
