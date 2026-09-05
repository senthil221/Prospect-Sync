# Plans

The current implementation plans, plus the drafts they
superseded. None is a specification the code must match forever; they are
records of what was decided and why, and have been corrected by
measurement more than once.

## Current

**[Scalability and reliability v8](prospect-sync-scalability-plan-v8-systemwide.md)** —
the current forward implementation plan, based on repository `417f67c` and
the measured description-search release. Covers all query consumers, fair
background work, cache/storage budgets, snapshot correctness and capacity
certification. Implementation is in progress; see the
[verification ledger](v8-implementation-status.md) for implemented work and gaps.
Mobile validation remains last. A plan is not production-change authorization.

**[Company-description performance report](company-description-search-performance.md)** —
the measured targeted fix preceding v8. It is not whole-system capacity proof.

**`prospect-sync-ui-audit-redesign-plan.md`** — the UI audit and redesign.
Section H is the roadmap; the IDs it defines (`PEOPLE-01`, `CLIENT-03`,
`COMP-AC-04` and so on) are quoted in commit messages, so this file is what
makes that history legible. All 13 work packages are done, including the mobile
phase in section K — `MOBILE-01` through `MOBILE-04`.

`MOBILE-05` is device and orientation QA on real hardware and is **UNVERIFIED**.
So is every screenshot gate in section I. Nothing in this repository has been
seen rendered: the app is behind a login the implementing session could not
reach, so the evidence is source assertions and computed contrast, not pixels.
`tests/mobile-shell.test.mjs` says which of the two it is standing in for.

Also current: **`prospect-sync-color-redesign-prompt.md`**,
the colour and background brief. Its palette is implemented in
`app/design-system.css` and gated by `tests/color-contrast.test.mjs`;
`color-contrast-matrix.md` is the generated evidence.

## Superseded

`prospect-sync-scalability-plan-v7-final.md` remains the historical rationale
for earlier migrations and workers. Its release-status and capacity statements
must not be read as fresh certification; v8 supersedes its forward roadmap.

`prospect-sync-scalability-plan.md`, `-v3`, and `-final-fixed` are earlier
drafts. They are kept because the v7 document argues against several of their
conclusions and the reasoning only makes sense with both halves present.

## Why these are in the repository

They were not, until 2026-09-03. Eleven migrations and eight UI work packages
had been written against documents that existed only as loose files on one
laptop, while three superseded drafts sat in `docs/`. Losing either would have
left the remaining work without a specification and the git history pointing at
identifiers nothing defined.

Several of both plans' predictions did not survive measurement, and where that
happened the migration or the script that measured it records the correction:
the dynamic `CASE ORDER BY` constant-folds, `(sort column, id)` composite
indexes buy nothing over Incremental Sort, deep `OFFSET` was inside budget, and
the Boolean vector experiment was closed by
`scripts/boolean-term-study.sql` rather than adopted. Read the plans with that
in mind - they are the argument, not the answer.
