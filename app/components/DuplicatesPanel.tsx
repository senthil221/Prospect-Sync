"use client";

import { useMemo, useState } from "react";
import { compareProspects, describeProspect, matchCount } from "../../lib/duplicate-compare";
import type { DuplicateCandidate } from "../../lib/types";

/**
 * QUALITY-04: the differences, not the two full records.
 *
 * This was two cards side by side, each listing every populated field it had,
 * at identical weight. Twenty identical fields and two conflicting ones looked
 * the same, so deciding a pair meant scanning both columns by eye and holding
 * the result in your head. The comparison is the job, so the comparison is what
 * renders: conflicts first and by default, the matching fields folded away
 * behind their own count.
 */
export default function DuplicatesPanel({ candidate }: { candidate: DuplicateCandidate }) {
  const [showAll, setShowAll] = useState(false);
  const rows = useMemo(() => compareProspects(candidate.left, candidate.right), [candidate]);
  const matching = matchCount(rows);
  const differing = rows.length - matching;
  const visible = showAll ? rows : rows.filter((row) => row.state !== "same");

  return <div className="compare-diff">
    <div className="compare-diff-head">
      <strong>{differing} field{differing === 1 ? "" : "s"} differ</strong>
      <span>{matching} match{matching === 1 ? "es" : ""}</span>
      {matching ? <button
        type="button"
        className="link-button"
        aria-expanded={showAll}
        onClick={() => setShowAll((open) => !open)}
      >{showAll ? "Differences only" : `Show all ${rows.length} fields`}</button> : null}
    </div>
    <div className="table-wrap"><table className="compare-table">
      <thead><tr>
        <th scope="col">Field</th>
        <th scope="col">{describeProspect(candidate.left)}</th>
        <th scope="col">{describeProspect(candidate.right)}</th>
      </tr></thead>
      <tbody>{visible.map((row) => <tr key={row.field} className={`compare-${row.state}`}>
        <th scope="row">{row.field}</th>
        <td>{row.left || <span className="compare-blank">Not set</span>}</td>
        <td>{row.right || <span className="compare-blank">Not set</span>}</td>
      </tr>)}</tbody>
    </table></div>
    {visible.length ? null : <p className="compare-identical">Every populated field on these two records is identical.</p>}
  </div>;
}
