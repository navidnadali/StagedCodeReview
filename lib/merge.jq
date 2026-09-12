# Merge one validated review pass into the state ledger.
# Input: state.json
# Args:  $out (validated output.out), $vnotes (validation notes array),
#        $stage ("sol"), $pass (number), $now (iso), $prefix ("SOL")
# Output: {state: <new state>, summary: <per-pass summary>}
. as $S
| ($S.findings // []) as $L
| ([ $L[] | select(.status == "open") | .id ]) as $openids
| ([ $L[] | select(.status == "dismissed") | .id ]) as $dismissedids
# Candidates claiming a real open id count as still-open references, not new.
| ([ $out.findings[] | select(.id != null) | .id | select(. as $i | $openids | index($i) != null) ]) as $claimed_still
| ([ $out.findings[] | select(.id == null or ((.id as $i | $openids | index($i)) == null)) | .id = null ]) as $newcands
# Duplicate guard first: a "new" candidate identical to an open item is a still-open ref.
| ($L | map(select(.status == "open"))) as $openitems
| ([ $newcands[] | . as $c
     | (($openitems | map(select(.file == $c.file and .line == $c.line and .severity == $c.severity and .kind == $c.kind and .issue == $c.issue)) | first) // null) as $dup
     | if $dup != null then {dup: $dup.id} else {cand: $c} end ]) as $split
| ([ $split[] | select(has("dup")) | .dup ]) as $dup_still
| ([ $split[] | select(has("cand")) | .cand ]) as $fresh
| ([ ($out.still_open + $claimed_still + $dup_still)[] | select(. as $i | $openids | index($i) != null) ] | unique) as $still_all
# still-open (in any form, incl. a re-reported duplicate) wins over resolved.
| ([ $out.resolved[] | select(. as $i | $openids | index($i) != null) | select(. as $i | ($still_all | index($i)) == null) ] | unique) as $resolved_ids
# Re-raises: dismissed + non-empty evidence only.
| ([ $out.reraised[] | select(.id as $i | $dismissedids | index($i) != null) ]) as $reraises
| (($S.next_finding_seq[$stage]) // 1) as $seq0
| ([ range(0; ($fresh | length)) as $i
     | $fresh[$i]
       | del(.id)
       | . + { id: ($prefix + "-" + (($seq0 + $i) | tostring)),
               stage: $stage, pass: $pass, status: "open", raised_at: $now } ]) as $new
# Apply re-raises (back to open, record evidence), then resolutions.
| (reduce $reraises[] as $r ($L;
     map(if .id == $r.id
         then (.status = "open" | .reraised = ((.reraised // []) + [{stage: $stage, pass: $pass, evidence: $r.evidence}]))
         else . end))) as $Lr
| ($Lr | map(if (.status == "open") and ((.id as $i | $resolved_ids | index($i)) != null)
             then . + {status: "resolved", status_stage: $stage, status_pass: $pass}
             else . end)) as $L1
| ($L1 + $new) as $L2
# Open ids the reviewer mentioned nowhere: stay open, flagged unconfirmed.
| ([ $openids[]
     | select(. as $i | ($resolved_ids | index($i)) == null)
     | select(. as $i | ($still_all | index($i)) == null) ]) as $unconfirmed
| ($L2 | map(select(.status == "open"))) as $openpost
| { state: ($S
      | .findings = $L2
      | .next_finding_seq[$stage] = ($seq0 + ($new | length))
      | .updated_at = $now),
    summary: {
      schema: "staged-review-summary/1",
      stage: $stage, pass: $pass,
      counts: {
        new: ($new | length),
        resolved: ($resolved_ids | length),
        still_open: ($still_all | length),
        unconfirmed: ($unconfirmed | length),
        reraised: ($reraises | length),
        open_critical: ([ $openpost[] | select(.severity == "critical") ] | length),
        open_major: ([ $openpost[] | select(.severity == "major") ] | length),
        open_minor: ([ $openpost[] | select(.severity == "minor") ] | length)
      },
      new: $new,
      resolved: $resolved_ids,
      still_open: $still_all,
      unconfirmed: $unconfirmed,
      reraised: $reraises,
      open: $openpost,
      reviewer_summary: $out.summary,
      validation_notes: $vnotes
    } }
