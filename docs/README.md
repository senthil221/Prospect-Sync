# Plans

The two documents the recent work is written against, plus the drafts they
superseded. Neither is a specification the code must match forever; both are
records of what was decided and why, and both have been corrected by
measurement more than once.

## Current

**`prospect-sync-scalability-plan-v7-final.md`** — the scalability and
resilience blueprint. Drove migrations `20260902000040` through
`20260902000180` and the two background workers. Its numbered releases, not its
phases, are the unit of work. Releases 1A, 1B, 1C and all of Release 2 are
complete; Release 3 is next.

It "does not authorize implementation by itself", in its own words, so each
release needs a decision before it starts.

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

A third document now sits alongside them: **`prospect-sync-color-redesign-prompt.md`**,
the colour and background brief. Its palette is implemented in
`app/design-system.css` and gated by `tests/color-contrast.test.mjs`;
`color-contrast-matrix.md` is the generated evidence.

## Superseded

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
