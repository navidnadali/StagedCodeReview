# Normalize + validate raw reviewer output.
# Input: whatever JSON the reviewer produced.
# Named argument ledger: the current session findings array (defaults to empty).
# Output: {ok: bool, out: {findings, resolved, still_open, reraised, summary, refused, refusal_reason}, notes: [string]}
# A refusal ("I cannot review this bundle") is a valid answer and NOT a pass; the
# driver records it without advancing the pass counter. A refusal carries no
# findings -- half a verdict on an unusable bundle is worse than none.
def normsev:
  if type == "string" then (ascii_downcase | if IN("critical","major","minor") then . else null end)
  else null end;
def normkind:
  if type == "string" then (ascii_downcase | if IN("intent_gap","bug","quality") then . else null end)
  else null end;
def clause_resolves_issue:
  test("(^|[^a-z])(issues?|findings?|problems?|concerns?|blockers?)[^a-z]+((are|were)[^a-z]+|have[^a-z]+been[^a-z]+)(fixed|resolved|closed|addressed|cleared)([^a-z]|$)")
  or test("(^|[^a-z])(fixed|resolved|closed|addressed|cleared)[^a-z]{1,24}(issues?|findings?|problems?|concerns?|blockers?)([^a-z]|$)");
def summary_has_unrepresented_issue:
  if type != "string" then false
  else
    ([splits("[.!?;,]")
      | ascii_downcase
      | select(
          (test("(^|[^a-z])(issues?|findings?|problems?|concerns?|blockers?)[^a-z]{0,24}(remain|remaining|open|unresolved|actionable)([^a-z]|$)")
           or test("(^|[^a-z])(remaining|open|unresolved|actionable)[^a-z]{0,24}(issues?|findings?|problems?|concerns?|blockers?)([^a-z]|$)"))
          and
          (test("(^|[^a-z])(no|none|zero)([^a-z]+(new|remaining|open|unresolved|actionable|additional|other|critical|major|minor|blocking|and|or)){0,6}[^a-z]+(issues?|findings?|problems?|concerns?|blockers?)([^a-z]|$)") | not)
          and (clause_resolves_issue | not)
        )]
     | length) > 0
  end;

# Completeness is structural, not a claim that a machine can judge prose quality.
# Reject absent text, punctuation-only text and common empty-receipt placeholders.
def nonblank: type == "string" and test("\\S");
def substantive_text:
  if type != "string" then false
  else test("[[:alnum:]][^[:space:]]*[[:space:]]+[^[:space:]]*[[:alnum:]]") and
    (ascii_downcase | gsub("[[:punct:]]"; " ") | gsub("\\s+"; " ") |
      gsub("^ +| +$"; "") |
      (IN("n a", "na", "none", "null", "undefined", "ok", "okay", "done",
          "summary", "evidence", "tbd", "todo", "pending", "not applicable")
       or test("^((new|additional|actual|substantive|real|concrete) )?(summary|review|evidence)$")
       or test("^(not|never) (reviewed|examined|checked)( yet)?$")
       or test("^(no|missing|empty|placeholder|pending) ((new|additional|actual|substantive|real) )?(summary|review|evidence)( ((is|was|were|has been|had been) )?(provided|available|given|supplied|performed|done|found|exists|yet))?$")
       or test("^(summary|review|evidence) (not (provided|available|given|supplied|performed|done)|pending|missing|to follow)$")) | not)
  end;
def finding_shape:
  type == "object" and
  (has("id") and (.id == null or (.id | nonblank))) and
  (.file | nonblank) and (.issue | nonblank) and (.fix | nonblank) and
  ((.line | type) == "number" and .line >= 0 and .line == (.line | floor)) and
  ((.severity | normsev) != null) and ((.kind | normkind) != null);
def reraise_shape:
  type == "object" and (.id | nonblank) and (.evidence | substantive_text);
def array_or_empty: if type == "array" then . else [] end;

if type != "object" then
  {ok: false, out: null, notes: ["reviewer output is not a JSON object"]}
else
  . as $o
  | ($ARGS.named.ledger // []) as $ledger
  | [ $ledger[] | select(.status == "open") | .id ] as $openids
  | [ $ledger[] | select(.status == "dismissed") | .id ] as $dismissedids
  | [ $o.findings | array_or_empty | .[] | select(finding_shape) ] as $rawf
  | [ $rawf[] | .severity |= normsev | .kind |= normkind ] as $goodf
  | [ $o.resolved | array_or_empty | .[] | select(nonblank) ] as $resolved
  | [ $o.still_open | array_or_empty | .[] | select(nonblank) ] as $still
  | [ $o.reraised | array_or_empty | .[] | select(reraise_shape) | {id, evidence} ] as $reraised
  | ($o.summary // null) as $summary
  | ($o.refused == true) as $refused
  | (if ($o.refusal_reason | substantive_text) then $o.refusal_reason else null end) as $reason
  | ([ ["findings", "resolved", "still_open", "reraised"][] as $field
       | select(($o[$field] | type) != "array")
       | "reviewer output \($field) must be an array; refusing to drop malformed data" ]
     + [ $o.findings | array_or_empty | to_entries[] | select(.value | finding_shape | not)
         | "reviewer output contained malformed finding at index \(.key); refusing to drop it" ]
     + [ ["resolved", "still_open"][] as $field
         | $o[$field] | array_or_empty | to_entries[] | select(.value | nonblank | not)
         | "reviewer output \($field)[\(.key)] must be a nonempty ID" ]
     + [ $o.reraised | array_or_empty | to_entries[] | select(.value | reraise_shape | not)
         | "reviewer output reraised[\(.key)] needs an ID and concrete evidence" ]
     + [ if ($o | has("refused")) and (($o.refused | type) != "boolean")
         then "reviewer refused must be boolean" else empty end ]
     + [ if ($refused | not) and ($summary | substantive_text | not)
         then "reviewer summary must contain a substantive review, not null, blank or placeholder text"
         else empty end ]
     + [ if $refused and $reason == null then "reviewer refused without a refusal_reason" else empty end ]
     + [ if $refused and (($goodf + $resolved + $still + $reraised | length) > 0)
         then "reviewer refused but also reported ledger changes; a refusal is not a partial review" else empty end ]
     + [ ["resolved", "still_open"][] as $field
         | $o[$field] | array_or_empty | .[] | select(nonblank) | . as $id
         | select(($openids | index($id)) == null)
         | "reviewer \($field) ID \($id) is not in this session's open ledger" ]
     + [ $goodf[] | .id | select(. != null) | . as $id
         | select(($openids | index($id)) == null)
         | "reviewer finding ID \($id) is not in this session's open ledger; NEW findings need id null" ]
     + [ $reraised[] | .id as $id | select(($dismissedids | index($id)) == null)
         | "reviewer reraised ID \($id) is not in this session's dismissed ledger" ]
     + [ if ($goodf | length) == 0 and ($still | length) == 0 and ($reraised | length) == 0
            and ($summary | summary_has_unrepresented_issue)
         then "reviewer summary says issues remain but findings/still_open/reraised are empty"
         else empty end ]) as $notes
  | {ok: ($notes | length == 0),
     out: {findings: $goodf, resolved: $resolved, still_open: $still,
           reraised: $reraised, summary: $summary, refused: $refused, refusal_reason: $reason},
     notes: $notes}
end
