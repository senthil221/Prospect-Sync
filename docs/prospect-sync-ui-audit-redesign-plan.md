# Prospect Sync UI Audit and 10/10 Redesign Plan

> **Implementation-grade UI specification**  
> Baseline: `main` at `bfbe71529a20e04db7516d26fb0408b8568f353a`  
> Scope: presentation, responsive behavior, client-side interaction, accessibility, and UI state only  
> Target: a verifiable 10/10 interface—not a claim that the current implementation is already 10/10

## A. Executive verdict

### Current score: 6.7/10

Prospect Sync already has coherent tokens, good safety copy, capable large-dataset controls, and a strong Overview. Its remaining problems are interaction-system problems, not branding problems.

The 10/10 direction is a **calm, high-density operations workstation**:

- one obvious primary action per screen;
- compact, predictable command bars;
- preserved search, filters, scope, page, and return position;
- accessible tables, dialogs, drawers, tabs, filters, and progress;
- task-led Import, Coverage, Clients, and Data Quality experiences;
- restrained elevation and motion used only where they communicate behavior.

### Best existing qualities

1. `app/design-system.css:16-326` already centralizes color, type, spacing, radius, density, focus, themes, and motion.
2. Delete/cancellation dialogs explain scope well: `ProspectTable.tsx:574`, `CompaniesWorkspace.tsx:292`, and `ImportsPanel.tsx:86`.
3. People exposes across-page selection, exclusions, capped counts, export scope, density, and columns instead of hiding scale.
4. Overview has the clearest sequence—health → actions → KPIs → activity—while Import exposes validation, resume, progress, rollback, and source-row preservation.

### Release blockers for a premium result

| ID | Blocker | Evidence | 10/10 condition |
|---|---|---|---|
| A11Y-01 | Dialogs/drawers lack a shared focus lifecycle. | `DashboardUi.tsx:62-73`; `ProspectTable.tsx:572-574`; `CompaniesWorkspace.tsx:292-305` | Initial focus, Tab containment, Escape, background isolation, and focus return work consistently. |
| A11Y-02 | Several table rows are pointer-first. | `ProspectTableRow.tsx:32`; `CompanyTableRow.tsx:8`; `ListsPanel.tsx:25` | Primary row navigation uses a link/button or supports Enter/Space with visible focus. |
| A11Y-03 | Custom tabs and token pickers have incomplete semantics. | `Tabs.tsx:101`; `DashboardUi.tsx:62`; `ImportsPanel.tsx:79`; `ApolloFilterPanel.tsx:328-332` | Tabs reference real tabpanels; combobox/listbox behavior works by keyboard and screen reader. |
| SHELL-01 | Workspace state is transient. | `DashboardApp.tsx:106-111` | Refresh, Back/Forward, and shared URLs restore the same workspace state. |
| DATA-01 | People and Companies expose too many equal-weight actions. | `ProspectTable.tsx:541-568`; `CompaniesWorkspace.tsx:262-290` | One primary action, grouped utilities, contextual bulk actions, separated danger actions. |
| STATE-01 | Some loading and empty states are ambiguous or unannounced. | `DashboardUi.tsx:46-48`; `DashboardApp.tsx:154`; `ProspectTable.tsx:568`; `CompaniesWorkspace.tsx:287` | Each state names its cause, scope, and recovery; asynchronous changes are announced. |
| VIS-01 | Inert panels receive interactive hover/elevation. | `workspace.css:971`; `OverviewWorkspace.tsx:16` | Only actionable cards and floating surfaces react to hover. |
| CONTRAST-01 | Boolean Apply uses warning text on warning background. | `workspace.css:737` | Control contrast passes WCAG AA in every theme and state. |

### What “10/10” means here

The redesign is complete only when every acceptance criterion passes against the authenticated application, including viewport, keyboard, screen-reader, visual-regression, lint, build, unit, and end-to-end gates, without altering existing data behavior unless separately authorized.

---

## B. Evidence coverage and confidence

### Repository evidence

- Branch: `main`
- Commit: `bfbe71529a20e04db7516d26fb0408b8568f353a`
- Framework: Next.js `^16.3.0`, React `19.2.6`
- Actual frontend routes:
  - `/login` → `app/login/page.tsx`
  - `/` → `app/page.tsx` → `app/DashboardApp.tsx`
- Overview, People, Companies, Clients & lists, Coverage, Data quality, and Import are client-side workspace states—not separate routes.
- Pre-existing untracked `docs/` was excluded from the audit.

### Visual evidence

Desktop static evidence: Import #1 (1893×857), Overview #2 (1900×837), People #3 (1911×870), Companies #4, Clients #6, Coverage #7, and Data quality #8. Company filter #5 is a 301×782 crop, not a viewport test. Client detail, Coverage results, Login, errors, drawers, modals, and dark theme are source-only and **UNVERIFIED visually**.

### Verification limitation

The application was not started because the original audit required strict read-only operation and Next.js development/build commands can write `.next`. The supplied captures were reviewed, but runtime behavior at 1440, 1280, 1024, 768, and 390px remains **UNVERIFIED**. This plan converts that gap into an explicit release gate rather than treating it as a pass.

---

## C. Scorecard and target gates

| Category | Current | Target | Evidence required for target |
|---|---:|---:|---|
| Visual hierarchy | 7.5 | 10 | One primary action; inert/actionable surfaces differ. |
| Layout and spacing | 7.0 | 10 | No sparse canvases or crowded command zones. |
| Consistency | 7.0 | 10 | Shared commands, dialogs, tabs, fields, states, and sizing. |
| Interaction clarity | 6.0 | 10 | Scope, outcome, disabled reason, progress, and recovery are visible. |
| Accessibility | 4.5 | 10 | Keyboard, focus, semantics, announcements, contrast, zoom, and motion pass. |
| State quality | 7.0 | 10 | Initial, loading, empty variants, error, partial, success, and retry verified. |
| Perceived speed | 7.0 | 10 | Preserve loaded content; immediate input acknowledgement. |
| Product confidence | 7.0 | 10 | Counts, scope, selection, export, and destructive consequences agree. |

---

## D. Design-system implementation contract

Do not rebrand the application. Consolidate the existing system and remove local exceptions.

### Token mapping

| Role | Existing source | Target rule |
|---|---|---|
| Typography | `design-system.css:69-76` | `34` hero only; `26` metric/display; `20` page title; `16` panel title; `14` body; `13` controls/tables; `12` metadata; `11` eyebrows only. |
| Spacing | `design-system.css:97-106` | Use only the existing 4–64px scale. Page 32; section 24–32; panel 16–24; dense control 8–12. |
| Radius | `design-system.css:109-113` | 6px fields, 10px controls/cards, 14px hero/dialog, pill only for statuses/chips. |
| Color | `design-system.css:137-189` | Accent for primary/focus/selection; green/amber/red only for semantic states; never rely on color alone. |
| Density | `design-system.css:188`, `303-304` | 44px default row; 36px compact; 56px comfortable. Persist the user choice. |
| Focus | `design-system.css:311-315` | Every interactive element keeps the global 2px ring plus offset; no local outline removal. |
| Motion | `design-system.css:319-326` | 120–180ms for menu/drawer/state transitions; no animation for routine content mounting. |
| Elevation | `workspace.css:971-983` | Border-only default panels; shadow level 1 for popovers; level 2 for drawers/modals; hover shadow only on actionable cards. |

### Component contracts

**Buttons**

- Dense: 32px; standard: 40px; mobile sizing is defined last.
- Primary: one per page region/modal footer; secondary for safe alternatives; ghost for utilities; danger only for irreversible actions.
- Disabled buttons expose the unmet requirement in adjacent text; `title` alone is insufficient.

**Fields**

- Use a visible label, optional helper, and non-empty Search clear action.
- Validate after blur or attempted progression—not on untouched initial state.
- Invalid fields use `aria-invalid` and an `aria-describedby` error.

**Tables**

- 40px header; 44px row; sticky header and leading identity column when horizontal scroll remains.
- Identity is the primary link; selection never triggers navigation.
- Truncated values use a focusable tooltip/details view, not native `title` alone.
- Pagination, total, scope, and across-page selection remain visible together.

**Status and feedback**

- `role="status"` for noncritical async updates; `role="alert"` for blocking errors.
- Progress with a known total uses `role="progressbar"`, `aria-valuemin`, `aria-valuemax`, and `aria-valuenow`.
- Success states name what changed, affected count, and undoability; non-zero ratios below 1% display `<1%`.

---

## E. Global shell and navigation specification

### Current → target

| ID | Current | Target | Evidence |
|---|---|---|---|
| SHELL-01 | Navigation changes local `section` and resets context. | Serialize workspace, query, filters, sort, page, client, list, and active tab into the URL. Preserve scroll separately. | `DashboardApp.tsx:106-111` |
| SHELL-02 | Topbar title plus workspace header can duplicate hierarchy. | Topbar owns global identity/account; page header owns title, purpose, scope, and actions. | `DashboardApp.tsx:148-153` |
| SHELL-03 | Search appears only for two sections and shares topbar space with Import. | Keep a single contextual search location and do not repeat it inside the workspace. | `DashboardApp.tsx:153` |
| SHELL-04 | Global error is visually styled but not an alert. | Shared dismissible alert with severity icon, text, optional retry, and `role="alert"`. | `DashboardApp.tsx:154` |

### Desktop/tablet anatomy

```text
┌ Sidebar 240 ┐ ┌ Global topbar: product context · account ──────────────┐
│ Workspace   │ ├ Page header: title · purpose · active scope · primary  │
│ Navigation  │ ├ Optional status/recovery strip                         │
│ Utilities   │ ├ Command bar: search · sort · filter · view utilities   │
│ Account     │ ├ Main task surface ───────────────────┬ Context rail     │
└─────────────┘ └──────────────────────────────────────┴──────────────────┘
```

Show the context rail only when it advances the task; collapsing it must not clear filters.

### Shell acceptance tests

- `SHELL-AC-01`: Reload preserves active workspace, query, filters, sort, page, client/list, and tab.
- `SHELL-AC-02`: Browser Back returns to the previous state and scroll position.
- `SHELL-AC-03`: Exactly one page-level primary action is visible before contextual selection.
- `SHELL-AC-04`: Every global error is announced and can be dismissed; retry appears when recovery exists.
- `SHELL-AC-05`: No desktop/tablet page header shifts vertically when status or validation appears.

---

## F. Page-by-page redesign specifications

### F1. Overview — `OV-*`

**Evidence:** Screenshot #2; `OverviewWorkspace.tsx:15-18`; `workspace.css:119-167`.

**Problems:** The information hierarchy is strong, but inert metric cards inherit an arrow and hover elevation, implying navigation. Health language has no visible degraded/retry counterpart in the captured state.

**Target anatomy**

```text
[Health + database purpose]                       [Import list] [Open People]
[Unique prospects] [Companies] [Client lists] [Cross-client overlaps]
[Recent imports: status · rows · overlaps · undo] [Reuse insight]
```

**Required changes**

- `OV-01`: Remove arrows/hover lift from metrics unless each card receives a real destination.
- `OV-02`: Make Recent imports the dominant operational surface.
- `OV-03`: Define loading, no-imports, import-failed, health-degraded, and retry states.
- `OV-04`: Announce Undo success/failure and restore the affected activity state deterministically.

**Acceptance:** `OV-AC-01` inert cards never present pointer/hover affordance; `OV-AC-02` latest import status and recovery are visible without opening another view; `OV-AC-03` health never communicates by color alone.

### F2. People database — `PEOPLE-*`

**Evidence:** Screenshot #3; `ProspectTable.tsx:509-574`; `ProspectTableRow.tsx:20-38`; `ApolloFilterPanel.tsx:120-332`.

**Problems:** The command area gives Saved views, Save, Export, Detect ESPs, sort, Filters, Rows, Columns, selection, and destructive actions similar weight. Rows are pointer-first; native `title` carries hidden values; the empty state checks filters but not a search-only query; token picker keyboard semantics are incomplete.

**Target anatomy**

```text
[6,80,983 people] [Search────────────────] [Sort] [Filters 3]
[Scope] [active filter chips────────────────────] [View ▾] [Export]
[selection bar appears only after selection; Delete separated]
[sticky table header + identity link + bounded horizontal scroll]
[showing range · exact/estimated total]                  [pagination]
```

**Required changes**

- `PEOPLE-01`: Group Saved views, Save view, Columns, and Density under View; keep Export separate; move Detect ESPs under Actions.
- `PEOPLE-02`: Use the name as a real Open prospect control; row click becomes optional enhancement only.
- `PEOPLE-03`: Convert the filter token picker to a labelled combobox/listbox with Arrow, Enter, Escape, active descendant, loading, and no-options states.
- `PEOPLE-04`: Keep all-across-pages selection, exclusions, exact-count request, and query-match safety unchanged.
- `PEOPLE-05`: Distinguish initial-empty, search-empty, filter-empty, client-scope-empty, error, and permission states.
- `PEOPLE-06`: Replace `window.prompt` for Save view and Tag with application dialogs.
- `PEOPLE-07`: Tooltips work on focus and hover; full values remain available in the detail drawer.

**Acceptance:** `PEOPLE-AC-01` every record opens without a pointer; `PEOPLE-AC-02` search-only no-results offers Clear search, not Import; `PEOPLE-AC-03` applied filters, count, export, and selection use the same visible scope; `PEOPLE-AC-04` command bar fits at 1024px without losing actions; `PEOPLE-AC-05` focus returns to the row after closing details.

### F3. Companies — `COMP-*`

**Evidence:** Screenshots #4–#5; `CompaniesWorkspace.tsx:262-316`; `CompanyFilterPanel.tsx:143-192`; `CompanyTableRow.tsx:8-13`.

**Problems:** Export scope, Export, Filters, Bulk domains, client selection, See People, and Add from CSV compete in one row. The filter panel nests many controls with weak grouping. Empty copy always says no companies, even when search/filter scope causes the result.

**Target anatomy**

```text
[Companies] [Search────────────────] [Sort] [Filters 33] [Add from CSV]
[92 total · 55 covered · 2,233 prospects] [scope] [Actions ▾]
[active filter chips]
[company identity link | website | prospects | coverage | added | status]
```

**Required changes**

- `COMP-01`: Add from CSV remains primary; Bulk domains and Export move under Actions; See People becomes contextual navigation.
- `COMP-02`: Replace three large metric cards with one compact summary strip.
- `COMP-03`: Simplify Company keywords to Include, Exclude, and an optional Search descriptions control; preserve Simple/Advanced capability behind a correctly labelled segmented control.
- `COMP-04`: Add accordion `aria-controls`; provide keyboard navigation and stable focus.
- `COMP-05`: Company name is the primary link; Delete remains isolated in Actions.
- `COMP-06`: Define initial, query-empty, filter-empty, scoped-empty, loading, refreshing, error/retry, and success states.

**Acceptance:** `COMP-AC-01` one dominant action; `COMP-AC-02` no command overflow at 1024px; `COMP-AC-03` expanded filters do not hide the results count or Apply/Clear actions; `COMP-AC-04` empty copy names the active constraint; `COMP-AC-05` closing a company drawer restores focus and table position.

### F4. Clients & lists — `CLIENT-*`

**Evidence:** Screenshot #6; `ClientsPanel.tsx:42-77`; `ClientsPanel.tsx:128`; `workspace.css:383-435`.

**Problems:** Three oversized cards produce a sparse canvas and do not scale to many clients. In detail, identity, cooldown editing, import, and deletion share one hero. Client tabs reference shared tab behavior but their content does not complete the tabpanel relationship. Removal uses native `window.confirm`.

**Target anatomy**

```text
[Clients & lists] [Search clients]                         [New client]
[Client | status | prospects | lists | last import | Open]

Client detail:
[← Clients] [Client identity + totals]               [Import list] [More ▾]
[Overview] [People] [Companies] [Lists] [Blocklist]
[active tabpanel; danger zone only in Settings/More]
```

**Required changes**

- `CLIENT-01`: Replace oversized cards with compact directory rows/cards containing status, counts, last activity, and Open.
- `CLIENT-02`: Separate edit, import, and destructive actions; Delete belongs in a danger zone.
- `CLIENT-03`: Render real `role="tabpanel"` elements with matching IDs and labels.
- `CLIENT-04`: Replace native confirmation with the shared dialog contract.
- `CLIENT-05`: Preserve active client, tab, search, list, page, and return scroll in the URL/session UI state.

**Acceptance:** `CLIENT-AC-01` layout remains efficient from 3 to 100+ clients; `CLIENT-AC-02` deleting a client cannot be confused with routine maintenance; `CLIENT-AC-03` returning from a client/list restores the directory exactly; `CLIENT-AC-04` tabs pass Arrow/Home/End and screen-reader checks.

### F5. Coverage checker — `COVERAGE-*`

**Evidence:** Screenshot #7; `CoveragePanel.tsx:49-52`; `workspace.css:438-457`.

**Problems:** Before upload, a small left card and large empty bordered result canvas create poor task focus. File selection, mapping, checking, results, and export should be progressive rather than simultaneously framed.

**Target anatomy**

```text
Initial:  [Upload companies] → [Map name/domain] → [Check coverage]
Results:  [file summary + Replace] [Known] [Net new] [Prospects] [Export net-new]
          [result table: company · domain · match · prospects · clients]
```

**Required changes**

- `COVERAGE-01`: Use one centered task panel before a valid file exists.
- `COVERAGE-02`: Reveal mapping only after headers are parsed; reveal results only after checking.
- `COVERAGE-03`: Validate type, size, empty file, missing mapping, and server failure with exact recovery.
- `COVERAGE-04`: Progress and result totals are announced; Replace file is always available after a result.

**Acceptance:** `COVERAGE-AC-01` initial state has one next action; `COVERAGE-AC-02` each validation error names the cause and remedy; `COVERAGE-AC-03` export clearly states it contains net-new companies only; `COVERAGE-AC-04` retry does not require reselecting a still-valid file.

### F6. Data quality — `QUALITY-*`

**Evidence:** Screenshot #8; `DataQualityPanel.tsx:83-87`; `workspace.css:458-473`.

**Problems:** The enrichment banner overexposes example chips; non-zero ratios can round to 0%; duplicate resolution uses positional Keep left/right language and lacks a separate review contract.

**Target anatomy**

```text
[Search index health + recovery]
[Prioritized issues: severity · affected · explanation · action]
[Duplicate review 1/25]
[Candidate A] [differences only] [Candidate B]
[Keep Vijay at …] [Keep Vijay at …] [Skip]
```

**Required changes**

- `QUALITY-01`: Convert metrics into a prioritized task queue while retaining master totals.
- `QUALITY-02`: Collapse company samples behind View affected companies.
- `QUALITY-03`: Display `<1%` for non-zero values below 1%.
- `QUALITY-04`: Show identical fields collapsed and conflicting fields emphasized.
- `QUALITY-05`: Replace positional merge labels with identity-based labels and a confirmation summary; expose per-row busy/success/error states.

**Acceptance:** `QUALITY-AC-01` every issue explains impact and next action; `QUALITY-AC-02` non-zero values never appear as 0%; `QUALITY-AC-03` duplicate decisions can be completed or skipped by keyboard; `QUALITY-AC-04` a failed merge leaves both candidates visible and retryable.

### F7. Import CSV — `IMPORT-*`

**Evidence:** Screenshot #1; `ImportsPanel.tsx:74-87`, `251-265`, `420-437`; `workspace.css:476-513`, `1037-1073`.

**Problems:** Setup, explanatory copy, destination, upload, mapping, validation, and submission compete across several regions. The required source error appears before interaction. Import-type controls are custom tabs. Progress lacks a complete progressbar contract.

**Target anatomy**

```text
[1 Source]—[2 Upload]—[3 Map & validate]—[4 Destination & review]
[active step content────────────────────] [readiness summary]
[Back]                         [Continue / Start import & sync]

Progress: [file · rows completed · current phase · Cancel safely]
Success:  [created · matched · skipped · unlinked · Undo/next action]
```

**Required changes**

- `IMPORT-01`: Stage the existing workflow without changing endpoints or import semantics.
- `IMPORT-02`: Do not display errors on untouched fields; after Continue/Submit, focus the first invalid field and show a readiness summary near the CTA.
- `IMPORT-03`: Use the shared Tabs contract for People/Companies and file/paste choices.
- `IMPORT-04`: Preserve parsed file, mapping, destination, client/list/date, and override decisions between steps.
- `IMPORT-05`: Known-total progress uses progressbar semantics; interrupted/resume/cancel states retain current safety copy.
- `IMPORT-06`: Success reports created, matched, skipped, unlinked, and rollback availability using the actual response values.

**Acceptance:** `IMPORT-AC-01` no initial false-error state; `IMPORT-AC-02` Back/Continue never loses entered data; `IMPORT-AC-03` invalid submission moves focus to an actionable explanation; `IMPORT-AC-04` retry/resume does not duplicate rows or memberships; `IMPORT-AC-05` cancellation wording continues to distinguish committed records from session/list cleanup.

### F8. Login and system errors — `AUTH-*` — visually UNVERIFIED

**Evidence:** `login/page.tsx:29`; `error.tsx:31-47`; `global-error.tsx`.

- `AUTH-01`: Keep explicit labels, busy state, alert semantics, and retry.
- `AUTH-02`: Define invalid credentials, expired session, setup required, offline/network, and unexpected failure presentation.
- `AUTH-03`: Use the same tokens as the workspace; emergency global error may remain deliberately minimal.

**Acceptance:** `AUTH-AC-01` invalid submission focuses or links to the error; `AUTH-AC-02` busy state prevents duplicate submission; `AUTH-AC-03` recovery works at 200% zoom and without layout shift.

---

## G. Cross-cutting interaction, state, and safety contracts

### Dialog and drawer contract

1. Store the launcher; label title/description; focus the safest meaningful control.
2. Keep Tab/Shift+Tab inside and make the background inert.
3. Escape closes unless a non-interruptible committed operation is running.
4. Close restores focus to the launcher/nearest surviving row; async failure remains inside and is announced.

### Tabs contract

- One tab stop; Arrow/Home/End behavior; consistent activation.
- Stable tab IDs control real labelled tabpanels; hidden panels do not discard necessary form state.

### Filter/selection contract

- Scope is always visible; chips support individual and Clear all removal; result counts announce politely.
- Search, filters, count, table, across-page selection, and export share one query definition.
- Query changes reconcile all-matching selection; destructive confirmation repeats count and scope.

### State matrix

| Surface | Loading | True empty | Query/filter empty | Error/retry | Success/working |
|---|---|---|---|---|---|
| Overview | KPI/activity skeleton | No imports; Import CTA | N/A | Failed/degraded card + retry | Undo status |
| People | Preserve previous rows + busy indicator | Import CTA | Name constraint + Clear | Inline retry without clearing query | Selection/export/ESP status |
| Companies | Preserve previous rows | Add from CSV | Name constraint + Clear | Inline retry | Bulk/add/delete status |
| Clients | Directory skeleton | Create client | Clear client search | Retry directory/detail | Created/deleted/imported notice |
| Coverage | File parsing/checking state | Initial upload task | No matches with export explanation | Keep valid file + retry | Summary + net-new export |
| Data quality | Metric/task skeleton | Healthy/no issues | N/A | Per-task retry | Per-task progress/result |
| Import | Per-step parse/map/upload progress | Initial source selection | N/A | Preserve step data + retry/resume | Exact result summary |

### Protected behavior: do not change in this UI project

- No database schema, Supabase policy, API contract, authentication, deployment, or infrastructure change.
- Do not change canonical prospect/company identity or duplicate rules.
- Do not collapse client/list membership into canonical records.
- Preserve multi-list membership display and cross-client overlap behavior.
- Preserve server-side query scope before pagination and agreement among visible results, totals, filter options, and exports.
- Preserve across-page selection and exclusion semantics.
- Preserve import idempotency, resume, cancellation, rollback, original-row storage, and mapping behavior.
- Preserve deletion scope: UI copy must continue matching what is actually removed or retained.
- Do not introduce optimistic success for destructive/import operations unless the existing response guarantees it.

---

## H. Dependency-aware implementation roadmap

Effort: **S** ≤1 day, **M** 2–4 days, **L** 5–8 days. Estimates assume one engineer familiar with the codebase and include UI tests, not backend changes.

| Order | Priority | Work package | Depends on | Files | Exit gate | Effort |
|---:|---|---|---|---|---|---:|
| 1 | P0 | `FOUNDATION-01`: shared dialog/drawer, tooltip, alert/status, progress primitives | None | DashboardUi, Tabs, components.css | A11Y-01/03 and STATE-01 contracts pass component tests. | L |
| 2 | P0 | `FOUNDATION-02`: fix contrast, focus, motion, control-height exceptions | None | design-system.css, workspace.css, components.css | WCAG AA contrast; no focus suppression; reduced motion verified. | S |
| 3 | P0 | `DATA-ACCESS-01`: links/buttons for People, Companies, and Lists rows | Foundation 01 | Row components, ListsPanel | Keyboard open/close/focus-return tests pass. | M |
| 4 | P1 | `SHELL-STATE-01`: URL-backed section/query/filter/sort/page/client/list/tab state | Foundation 01 | DashboardApp and workspace controllers | Refresh and Back/Forward restoration tests pass. | L |
| 5 | P1 | `COMMANDS-01`: shared data command and contextual selection bars | Foundation 02 | ProspectTable, CompaniesWorkspace, components.css | PEOPLE-01 and COMP-01 acceptance passes at 1440/1280/1024. | M |
| 6 | P1 | `FILTERS-01`: accessible rail, accordion, segmented control, combobox | Foundation 01, Commands 01 | ApolloFilterPanel, CompanyFilterPanel, use-dismiss | Full keyboard/filter-count tests pass. | L |
| 7 | P1 | `STATES-01`: state-specific empty/loading/error/retry library | Foundation 01 | DashboardUi and all workspaces | State matrix has screenshot and interaction coverage. | M |
| 8 | P2 | `CLIENTS-01`: scalable directory and restructured detail | Shell state, States | ClientsPanel, ListsPanel, BlocklistPanel | CLIENT acceptance suite passes. | M |
| 9 | P2 | `COVERAGE-01`: progressive upload → mapping → results | States | CoveragePanel, workspace.css | COVERAGE acceptance suite passes. | M |
| 10 | P2 | `QUALITY-01`: task queue and safe duplicate resolution | Foundation 01, States | DataQualityPanel, DuplicatesPanel | QUALITY acceptance suite passes. | M |
| 11 | P2 | `IMPORT-01`: staged import presentation | Foundation 01, States | ImportsPanel, workspace.css | IMPORT acceptance suite and existing import tests pass. | L |
| 12 | P3 | `POLISH-01`: remove false affordances and excess elevation/motion | All desktop work | workspace.css, Overview | Visual regression and theme review pass. | S |
| 13 | Final | Mobile implementation phase | Desktop primitives stable | See final section | Mobile acceptance suite passes. | L |

### Implementation rule

Do not redesign all pages simultaneously. Land the shared primitives first, then one representative data screen—People—before applying the proven system to Companies and client-scoped variants.

---

## I. Verification and definition of done

### Required automated gates

Run after implementation, not during this read-only audit:

```text
npm run lint
npm run test:unit
npm run build
npm run test:e2e
```

Add targeted Playwright coverage for:

- `shell-state.spec.ts`: refresh and Back/Forward restoration;
- `keyboard-data-grid.spec.ts`: row open, selection, drawer close/focus return;
- `filters-accessibility.spec.ts`: accordion and token combobox behavior;
- `dialog-focus.spec.ts`: modal/drawer focus lifecycle;
- `workspace-states.spec.ts`: state matrix;
- `import-presentation.spec.ts`: staged flow, error focus, resume/cancel/success;
- `visual-workspaces.spec.ts`: light/dark screenshots at required widths.

Use an automated accessibility runner only if adding its dependency is separately approved; automated checks do not replace manual keyboard and screen-reader verification.

### Desktop/tablet viewport gate

- 1440×900
- 1280×800
- 1024×768
- 768×1024
- 200% browser zoom at 1280×800

At each size verify:

- no clipped or inaccessible actions;
- no page-level horizontal overflow;
- tables remain bounded and their horizontal scroll is discoverable;
- sticky headers/bars do not overlap content;
- dialogs fit and scroll internally;
- focus remains visible inside tables, rails, menus, drawers, and dialogs;
- light/dark and reduced-motion behavior;
- long names, zero data, maximum visible counts, and narrow content.

### Manual journey gate

1. Overview → People → filter → open prospect → close → Back: state and position preserved.
2. People → select page → select all matching → exclude one → export: counts and scope agree.
3. Companies → keyword filter → company drawer → See People: visible scope remains explicit.
4. Clients → client → list → prospect → return: client/list/search/page preserved.
5. Coverage → invalid file → valid file → mapping → result → export → replace file.
6. Data quality → compare → skip → merge → simulated error → retry.
7. Import → People/Company → file/paste → mapping error → correction → progress → interrupted resume → success/cancel.
8. Session expiry and recoverable API failure from every material workspace.

### Final sign-off checklist

- [ ] All issue IDs have passing acceptance evidence.
- [ ] All `UNVERIFIED` items are either verified or explicitly deferred.
- [ ] No UI change alters API/database/auth behavior.
- [ ] Existing domain and import tests remain green.
- [ ] New UI tests pass in light and dark themes.
- [ ] No native prompt/confirm remains in primary workflows.
- [ ] No clickable `<tr>` is the only way to open a record.
- [ ] No known-total visual progress lacks progressbar semantics.
- [ ] No initial untouched field displays an error.
- [ ] Final diff contains no unrelated changes, secrets, or permission expansion.

---

## J. Final verdict

This is the strongest responsible 10/10 plan that can be produced from the supplied repository and screenshots without inventing runtime evidence.

The product does **not** need a new brand or broad rewrite. It needs shared accessible primitives, keyboard-safe data interaction, URL-backed state, simplified commands/filters, task-flow restructuring, restrained polish, and finally mobile implementation after the desktop interaction system stabilizes.

The outcome may be called 10/10 only after Section I and the mobile gates below pass against the authenticated runtime.

---

## K. Mobile redesign — final implementation phase

This section is intentionally last. Implement it after the shared desktop/tablet primitives are stable.

### Verified source risks

- At `≤760px`, `workspace.css:826-840` converts seven destinations into a horizontally scrolling 72px bottom bar.
- The same rule hides `.profile`, removing the visible sign-out entry.
- `.search` is hidden without a replacement.
- At `≤1000px`, `workspace.css:804-822` retains a 210px sidebar while data layouts begin stacking, producing an awkward 768–1000px transition.
- These source findings are visually **UNVERIFIED** at device sizes.

### Mobile shell contract

```text
┌ Current workspace ─────────────── [Search] [Primary] ┐
│ Page title + active scope                              │
│ Task content                                           │
│                                                       │
└ [Overview] [People] [Companies] [More] ───────────────┘
```

- Four fixed destinations only: Overview, People, Companies, More.
- More opens a labelled full-height sheet containing Clients, Coverage, Data quality, Import, theme, account, and Sign out.
- Search remains available in People and Companies.
- Use 16px page gutters, safe-area padding, and minimum 44×44px targets.
- Opening the software keyboard must not cover the active input or the dialog/sheet action.

### Mobile data contract

- People and Companies use compact rows: identity, essential secondary value, status/count, and selection.
- Secondary fields open in full-screen detail.
- Filters use a full-screen sheet with active count, Clear, and sticky Show results.
- Bulk selection creates a sticky contextual bar with the destructive action separated.
- No primary workflow depends on horizontal scrolling.

### Page adaptations

| Page | Mobile target |
|---|---|
| Overview | Two-column KPI grid; recent imports become compact activity cards. |
| People | Record list, full-screen detail, full-screen filter sheet, sticky selection bar. |
| Companies | Record list, compact summary, detail view, full-screen filters/actions. |
| Clients | One-column directory; client/list content becomes a full-screen hierarchy with a clear Back path. |
| Coverage | Upload, mapping, summary, and results stack sequentially. |
| Data quality | Issue cards; duplicate candidates stack with differences and actions below. |
| Import | One active stage at a time with sticky Back/Continue footer and persistent progress. |
| Dialogs | Bottom sheet for short choices; full-screen dialog for long forms/reviews. |

### Mobile issue plan

| ID | Priority | Change | Files | Acceptance | Effort |
|---|---|---|---|---|---:|
| MOBILE-01 | P0 | Replace scrolling navigation and restore search/account access. | DashboardApp, workspace.css, ThemeToggle | Every workspace and Sign out is reachable at 390px without horizontal nav scrolling. | M |
| MOBILE-02 | P1 | Add compact People/Company record views and full-screen details. | ProspectTable, CompaniesWorkspace, row/drawer components | Primary database work requires no desktop table interaction. | L |
| MOBILE-03 | P1 | Convert filters and long dialogs to accessible sheets. | Filter panels, DashboardUi, modal CSS | Filters and confirmation remain usable with the software keyboard open. | L |
| MOBILE-04 | P2 | Adapt Overview, Clients, Coverage, Quality, and Import. | Corresponding workspaces | Each task has a deliberate single-column hierarchy and preserved state. | L |
| MOBILE-05 | P3 | Complete device/orientation/safe-area/touch/theme QA. | UI tests and styles | All mobile gates pass. | M |

### Mobile verification gate

Test at:

- 390×844
- 360×800
- 430×932
- portrait and landscape where practical
- 200% zoom
- light, dark, and reduced-motion modes

Pass conditions:

- [ ] Every workspace, search, import, account, and Sign out action is reachable.
- [ ] No primary action requires horizontal scrolling.
- [ ] Fixed navigation and sticky bars never obscure content.
- [ ] All targets are at least 44×44px.
- [ ] Rotation does not lose form, mapping, filter, or selection state.
- [ ] Software keyboard does not cover the active field or completion action.
- [ ] Sheets/dialogs trap focus, close with Escape where applicable, and restore focus.
- [ ] People/Company scanning works without opening every record.
- [ ] Loading, empty, query-empty, error, retry, progress, and success states are verified.
- [ ] Mobile screenshots pass visual regression after intentional baselines are approved.
