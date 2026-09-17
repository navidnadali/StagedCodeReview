# Normalize + validate raw reviewer output.
# Input: whatever JSON the reviewer produced.
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
def normline:
  if type == "number" then floor
  elif type == "string" then ((tonumber? // 0) | floor)
  else 0 end;
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

if type != "object" then
  {ok: false, out: null, notes: ["reviewer output is not a JSON object"]}
else
  . as $o
  | [ ($o.findings // [])[] | select(type == "object") ] as $rawf
  | ([ $rawf[]
      | { id: (if (.id | type) == "string" and ((.id | length) > 0) then .id else null end),
          file: (if (.file | type) == "string" then .file else "" end),
          line: (.line | normline),
          issue: (if (.issue | type) == "string" then .issue else "" end),
          fix: (if (.fix | type) == "string" then .fix else "" end),
          severity: (.severity | normsev),
          kind: (.kind | normkind) } ]) as $normf
  | ([ $normf[] | select((.file | length) > 0 and (.issue | length) > 0 and .severity != null and .kind != null) ]) as $goodf
  | (($normf | length) - ($goodf | length)) as $ndropped
  | [ ($o.still_open // [])[]? | select(type == "string") ] as $still
  | [ ($o.reraised // [])[]?
      | select(type == "object")
      | select((.id | type) == "string" and (.evidence | type) == "string" and ((.evidence | length) > 0))
      | {id, evidence} ] as $reraised
  | (if ($o.summary | type) == "string" then $o.summary else null end) as $summary
  | (($goodf | length) == 0 and ($still | length) == 0 and ($reraised | length) == 0
     and ($summary | summary_has_unrepresented_issue)) as $summary_conflict
  | (($o.refused // false) == true) as $refused
  | (if ($o.refusal_reason | type) == "string" and (($o.refusal_reason | length) > 0)
     then $o.refusal_reason else null end) as $refusal_reason
  | ($refused and ($refusal_reason == null)) as $refusal_unexplained
  | ($refused and (($goodf | length) > 0 or ($still | length) > 0 or ($reraised | length) > 0)) as $refusal_with_findings
  | { ok: ($ndropped == 0 and ($summary_conflict | not)
           and ($refusal_unexplained | not) and ($refusal_with_findings | not)),
      out: {
        findings: $goodf,
        resolved: [ ($o.resolved // [])[]? | select(type == "string") ],
        still_open: $still,
        reraised: $reraised,
        summary: $summary,
        refused: $refused,
        refusal_reason: $refusal_reason
      },
      notes: ((if $ndropped > 0 then ["reviewer output contained \($ndropped) malformed finding(s); refusing to drop them"] else [] end)
              + (if $summary_conflict then ["reviewer summary says issues remain but findings/still_open/reraised are empty"] else [] end)
              + (if $refusal_unexplained then ["reviewer refused without a refusal_reason"] else [] end)
              + (if $refusal_with_findings then ["reviewer refused but also reported findings; a refusal is not a partial review"] else [] end))
    }
end
