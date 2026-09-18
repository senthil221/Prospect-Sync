# ProspectSync UI Redesign — Phase 1 Audit and Plan

Baseline: `main` at `b943366` (2026-09-18). Scope: presentation, responsive behavior, client-side interaction, and accessibility only. This document is the sole Phase 1 deliverable requested by the redesign brief (`ProspectSync_Claude_UI_Master_Brief.md` / the equivalent `ProspectSync_Lean_Claude_UI_Kit`). No application code was changed to produce it.

**Evidence sources:** full-repository source read of `app/**` (all workspace components, all four CSS layers, hooks, routes), `git log` on the style files, the existing `tests/` inventory, and a live check of the unauthenticated `/login` route in a real browser at desktop and 1024×768. The authenticated workspace (Overview/People/Companies/etc.) was **not** rendered live in this session: doing so requires a Supabase password, and entering credentials into a form is outside what I will do even when a password is offered in chat. Every finding about those pages therefore comes from source inspection, and anything that can only be confirmed by looking at rendered pixels is explicitly marked **UNVERIFIED** below rather than assumed.

---

## 0. A note on scope: this is not a neglected app

Before auditing, I checked whether this brief was arriving at a UI that had never been touched. It hasn't. `docs/prospect-sync-ui-audit-redesign-plan.md` records a prior, completed redesign (13 work packages including a full mobile phase; `docs/README.md` marks all of them done), and I verified — by reading current source, not by trusting either document — that its central claims hold: URL-backed workspace state, a real focus-trapping dialog primitive, accessible tabs, grouped command bars, staged Import/Coverage flows, and a contrast-tested color system are all genuinely present in the code today (evidence throughout this document, particularly §2, §6, §9).

Per your direction, this plan is a **fresh audit against the new, more specific brief**, but it calls out where the prior work already satisfies a requirement rather than re-describing it as a new problem. The practical result: this is a smaller, more surgical set of findings than a first-time audit would produce. There are no P0 (broken/dangerous/inaccessible) findings. The highest-value work is (a) one nav destination the prior efforts never reached, (b) a CSS ownership conflict that works today only by accident of load order, and (c) several small, isolated inconsistencies inside otherwise well-built surfaces.

---

## 1. Executive assessment

ProspectSync's UI is materially more mature than the brief's framing ("capable internal tool" needing an upgrade to "mature, restrained, professional SaaS") assumes. The design-token system (`app/design-system.css`), the dialog/focus primitive (`app/components/use-dialog.ts`), the accessible tabs component (`app/components/Tabs.tsx`), the accessible filter combobox (`ApolloFilterPanel.tsx`'s `TokenValuePicker`), and the state-classification helper (`lib/workspace-states.ts`) are all reference-quality work that a redesign should build on, not replace.

What remains is not a redesign — it is a cleanup-and-consistency pass:

1. **Integrations** (`app/components/IntegrationsPanel.tsx`) was never touched by the prior UI or color work. It is plain unstyled HTML with two native `window.confirm` dialogs, one of which gates an irreversible action (transferring leads to a campaign).
2. **`workspace.css` and `components.css` both fully declare the same table/toolbar/menu selectors**, with different values in places (row hover color, `.outline-button`, `.results-toolbar`, `.filter-panel-head`). Today's correct-looking result depends entirely on CSS load order, not on either file actually owning what it claims to own. This is a latent regression risk for every future table/toolbar edit.
3. A handful of small, isolated inconsistencies sit inside otherwise well-built pages: native `title` tooltips in People's table (not reachable by keyboard focus), one emoji glyph where every other icon is an SVG, Companies' row-open control not matching People's, two hand-rolled tab-like widgets that don't use the shared `Tabs` component, and stale color-named CSS classes that no longer apply color.

None of this requires new dependencies, a new visual language, or touching protected behavior (routes, APIs, schema, auth, search/filter/sort semantics, selection, calculations, URL state, or destructive-action logic). It requires disciplined application of the system the product already has.

---

## 2. Strengths worth preserving

These should be treated as load-bearing and left alone except where a specific finding below asks for a targeted change:

- **`use-dialog.ts`'s focus lifecycle** (`app/components/use-dialog.ts`, 115 lines): stores the launcher, focuses `[data-autofocus]`, marks background siblings `inert` (not just `aria-hidden`), traps Tab, ignores Escape while busy, restores focus to the launcher (falling back to `main` if the launcher was removed, e.g. a deleted row) on close. Better than most production React dialog handling.
- **`Tabs.tsx`**: a complete WAI-ARIA tabs implementation — roving tabindex, Arrow/Home/End, real `role="tablist"/"tab"`, an animated indicator computed from actual DOM geometry via `ResizeObserver`. Used correctly in `ClientsPanel.tsx`, `ImportsPanel.tsx` (×3), and `DashboardUi.tsx`'s `ProspectDrawer`.
- **URL-backed workspace state** (`lib/workspace-url.ts`, wired at `app/DashboardApp.tsx:106-178`): section, search, filters, sort, page, client/list id, and cross-navigation "pivot" scope are all serialized into the URL with correct push-vs-replace semantics. Refresh and Back/Forward genuinely restore state.
- **The color/token system** (`app/design-system.css`) and its automated gate: `tests/color-contrast.test.mjs` checks 62 token pairs per theme against `docs/color-contrast-matrix.md`, all passing. A design system with a build-time regression test tied directly to the token file is rare and should not be re-derived.
- **`DuplicatesPanel.tsx`'s differences-first merge UI** — identity-based labels ("Keep Vijay at …") instead of positional "Keep left/right," a "Show all fields" disclosure, differences highlighted by default.
- **`MenuButton.tsx`** — a single disclosure-button component (with a documented rationale for `role="group"` over `role="menu"`) used consistently for the View/Actions command menus in People and Companies.
- **`WorkspaceEmpty` / `lib/workspace-states.ts`** — the *reason* a view is empty (true-empty, search-only, filter, client-scope) is computed once as pure logic and rendered generically. This already satisfies the brief's empty/no-result/error-state expectations for People and Companies.
- **The measured, comment-documented product decisions inside `ApolloFilterPanel.tsx`** (e.g. lines 795-813 explain, with production timing numbers, why People's and Companies' keyword filters default to different search scopes). These are business-logic decisions, not styling, and must not be second-guessed by a visual pass.
- **`app/error.tsx`** — a genuinely thoughtful route-level error boundary (explains the rest of the database is unaffected, shows `error.digest` for support, offers both a soft "Try again" and a hard "Start fresh" that clears specific localStorage keys).
- **`MobileNav.tsx`** — replaced the old 7-item scrolling bottom nav with a proper 4-destination bar + "More" sheet, and documents the before/after reasoning directly in a header comment.

---

## 3. Route inventory

The application is not a multi-route app in the conventional sense:

| URL | File | Notes |
|---|---|---|
| `/login` | `app/login/page.tsx` | Real route, unauthenticated. Verified live at desktop and 1024×768 (see §9). |
| `/` | `app/page.tsx` → `app/DashboardApp.tsx` | Single real authenticated route. All of the following are **client-side `section` states inside this one route**, not separate URLs, though each is fully represented in the query string via `lib/workspace-url.ts`: `overview`, `prospects` (People), `companies`, `clients` (Clients & Lists, including client workspace / client People / Uploaded Lists as sub-states), `coverage`, `data-quality`, `imports`, `integrations`, and (admin-only) `logs`. |
| N/A (boundaries) | `app/error.tsx`, `app/global-error.tsx` | App Router error boundaries, not navigable routes. |

This structure is unchanged from the prior audit's finding and is itself protected behavior (routes/URL state are explicitly called out as not-to-change in the brief).

---

## 4. Shared-component and style inventory

**Style layers** (load order: `design-system.css` → `workspace.css` → `components.css` → `typography.css`, plus `globals.css` for Tailwind + a small Integrations-only block):

| File | Lines | Role |
|---|---|---|
| `app/design-system.css` | 504 | The actual design system: color ramps, type scale, spacing (4px scale), two control heights (32/40px), radius scale, elevation, motion, dark theme, global focus ring, `prefers-reduced-motion`. Single source of truth — well documented. |
| `app/typography.css` | 140 | A deliberate "patch layer... loaded after component styles so older 11px-era overrides cannot shrink important information" (its own header comment) — but it re-declares font sizing for selectors `workspace.css` also styles (see §7 finding TYPE-01). |
| `app/workspace.css` | 1,645 | Page-specific layout for every workspace section, all responsive breakpoints, and — despite `components.css`'s stated ownership — a large set of duplicate component rules (§7, CSS-01). |
| `app/components.css` | 789 | Declared as the sole owner of hand-built primitives ("no literal colours, sizes, radii... permitted," header comment), but several of the selectors it owns are also fully declared in `workspace.css` (§7, CSS-01). |
| `app/globals.css` | 28 | Tailwind import + box-sizing reset + an orphaned hand-written block for `.integrations-workspace`/`.integration-card`/`.integration-preview` using literal px values instead of design tokens — the only styling Integrations has (§6, Integrations). |

**Shared components** (file → consistency verdict):

| Component | File(s) | Verdict |
|---|---|---|
| Buttons | CSS split `workspace.css:108-113` / `components.css:326-347` | One visual language; one raw emoji breaks it (`ProspectTable.tsx:715`, see §7 COMP-ICON-01). |
| Icons | `app/components/DashboardUi.tsx:13-47` (`AppIcon`) | Single hand-drawn SVG icon system, explicitly built so "no surface has to fall back to a unicode glyph" — makes the emoji exception notable. |
| Tabs | `app/components/Tabs.tsx` | Single correct implementation, but two smaller mode-switchers in `ApolloFilterPanel.tsx` don't use it (§7, TABS-01). |
| Dropdown/menu | `app/components/MenuButton.tsx` | Single implementation, reused for View/Actions everywhere. |
| Filter controls | `app/ApolloFilterPanel.tsx` (856 lines), `app/CompanyFilterPanel.tsx` (263 lines) | Companies genuinely imports and reuses People's filter primitives (`ClientMembershipFilter`, `RangeFilter`, `IncludeExcludeFilter`, etc.) rather than duplicating them. |
| Table + row | `ProspectTable.tsx` (740), `ProspectTableRow.tsx` (42), `CompanyTableRow.tsx` (17) | Shared `.master-data-table` class, but the two row components diverge on row-open affordance (§7, ROW-01), and the shared CSS class has the ownership conflict from CSS-01. |
| Dialogs/drawers | `DashboardUi.tsx` (`ExportDialogShell`, `FormDialog`, `ConfirmDialog`, `DeleteConfirmation`, `ProspectDrawer`) on `use-dialog.ts` | One focus lifecycle for every dialog/drawer found in the audited code. |
| Menu/filter dismiss | `app/use-dismiss.ts` | Deliberately separate, lighter hook for non-modal floating elements — correctly not conflated with the dialog hook. |
| Toast/inline feedback | `StatusMessage`, `ProgressBar` in `DashboardUi.tsx:103-137` | Correct `role="status"`/`role="alert"` split; real `role="progressbar"` including an indeterminate state. |
| Applied-filter chips | `.filter-chip` (`workspace.css:200-208`), rendered from `ProspectTable.tsx:716-721` | Single implementation, reused by Companies unchanged. |
| Pagination | `.table-footer` (`workspace.css:233-236`) | Consistent Prev/Next + "Page X of Y" across People/Companies/client-scoped People. |
| Loading/empty/error/permission states | `LoadingState`, `WorkspaceEmpty`, `EmptyState`, `EmptyCompact` (`DashboardUi.tsx`) driven by `lib/workspace-states.ts` | Genuinely shared, well-factored. |
| Theme toggle | `app/components/ThemeToggle.tsx` | Single 3-way control, reused identically in the sidebar and inside `MobileNav`'s "More" sheet. |

---

## 5. System-wide UI and UX problems

1. **CSS ownership is split and silently conflicting** between `workspace.css` and `components.css` for table rows, toolbars, filter-panel heads, and outline buttons. See §7 CSS-01 — this is the single highest-value system-wide fix.
2. **Two-tier tooltip strategy**: menus/buttons/accordions use accessible ARIA-described controls, but People's table cells fall back to the native `title` attribute (hover-only, not reliably announced on keyboard focus). See §7 TOOLTIP-01.
3. **Integrations sits outside the design system entirely** — no shared button/menu/panel classes, literal-pixel CSS, native `window.confirm`. See §6.
4. **Row-open affordance is inconsistent** between People (name text is the button) and Companies (only a small trailing icon is focusable). See §7 ROW-01.
5. Everything else found is page-local (§6) or small/isolated (§7) rather than systemic.

---

## 6. Page-specific findings

### Overview (`app/components/OverviewWorkspace.tsx`, 43 lines)
Matches the mature target shape already: hero, 4-card metric grid, then Recent imports + a reuse-savings panel. Hover/lift has already been removed from inert metric cards (`workspace.css:1031`, `.metric-card, .welcome { box-shadow: none; }`). Reuse-share formatting uses `formatShare` (`lib/quality-issues.ts:89`) specifically so a non-zero ratio never displays as "0%." One gap: there is no visible health/degraded indicator on this page itself (that concept now lives in Data Quality instead) — not a defect, but worth a conscious decision rather than an assumption, since the original 2024 plan asked for health language specifically on Overview.

### People database (`app/components/ProspectTable.tsx`, `ApolloFilterPanel.tsx`)
The command bar already matches the brief's "group secondary actions, one primary action" model: `View` menu groups Saved view/Save/Density/Columns; `Actions` holds Detect ESPs; Export and Filters stand alone. Row identity is a real focusable `<button className="row-open">` (`ProspectTableRow.tsx:36`). The bulk-selection bar only renders on selection, with destructive bulk-delete visually isolated (`ProspectTable.tsx:698,715`). The filter value combobox (`TokenValuePicker`, `ApolloFilterPanel.tsx:382-545`) is a fully correct accessible combobox. `Save view` uses a real dialog, not `window.prompt`. The two remaining gaps here (native `title` tooltips, one emoji icon, two non-`Tabs` mode switchers) are listed in §7 since they're isolated, reusable fixes rather than page redesigns.

### Companies (`app/components/CompaniesWorkspace.tsx`, `CompanyTableRow.tsx`, `CompanyFilterPanel.tsx`)
Command row matches the same model as People (single primary "Add from CSV," Actions menu, standalone Filters toggle). The three summary tiles use classes named `summary-violet`/`summary-blue`/`summary-green` whose actual CSS has been neutralized to the same neutral surface color (`workspace.css:303-305`) — harmless today, but the names imply a per-KPI color scheme the brief explicitly asks to avoid re-introducing, and a future edit could "restore" the color the name implies. **`CompanyTableRow.tsx:10`: the company name itself is not the interactive control** — only a small icon-only button next to it is focusable, unlike People's name-as-button pattern (§7, ROW-01). Coverage badges appear to already use neutral (not danger-red) styling for "no coverage" per the color brief's rule, but the specific token was not independently contrast-checked in this pass — flagged as **UNVERIFIED** at the pixel level.

### Clients & Lists / client workspace / Uploaded Lists (`ClientsPanel.tsx`, `ListsPanel.tsx`, `BlocklistPanel.tsx`, `ClientIcpPanel.tsx`)
Directory rows are compact (not oversized cards), client-detail tabs use real `TabPanel`/`role="tabpanel"` elements, and client deletion already uses `ConfirmDialog` with an explicit code comment explaining why `window.confirm` was removed ("window.confirm freezes the tab," `ClientsPanel.tsx:233`). `ListsPanel.tsx` (27 lines) and the internals of `BlocklistPanel.tsx`/`ClientIcpPanel.tsx` were confirmed to compose correctly into `ClientsPanel` but were not read line-by-line in this pass — if the golden-page phase later touches client-scoped People, a quick follow-up read of these three files is worth doing first.

### Coverage checker (`app/components/CoveragePanel.tsx`, 234 lines)
Already implements the brief's progressive-disclosure model via an explicit `stage` state machine (`upload` → `mapping` → `results`, line 43) with a step indicator using `aria-current="step"`. The upload stage is explicitly documented as showing only one control on screen. "Change mapping" remains available after results without re-uploading.

### Data Quality (`app/components/DataQualityPanel.tsx`, `DuplicatesPanel.tsx`)
Non-zero ratios never round to 0% (shared `formatShare` helper). Duplicate resolution already uses the differences-first, identity-labeled UI described in §2. Index health is a compact labelled status, not a page-wide tint.

### Import CSV (`app/components/ImportsPanel.tsx`, `ImportStepper.tsx`)
Uses the shared `Tabs` component correctly at three separate points, including the People/Company file-vs-paste switch — useful proof the product already knows how to build this correctly everywhere it chose to (making the two exceptions in `ApolloFilterPanel.tsx` easier to justify fixing). Progress uses a documented "real progressbar" (`ImportsPanel.tsx:647`).

### Login and system errors (`app/login/page.tsx`, `app/error.tsx`, `app/global-error.tsx`)
Verified live (see §9): single-column form, visible labels, correct input types/`autoComplete`, disabled+busy submit state, inline `role="alert"` error text, same design tokens as the rest of the shell (not a separate visual system). `error.tsx` is a strong, worth-preserving recovery screen (see §2).

### Integrations (`app/components/IntegrationsPanel.tsx`, 155 lines) — the one route neither prior effort reached
This page was excluded from both the original UI audit and the color redesign (neither document mentions it) and it shows: almost entirely bare `<button>`/`<input>`/`<ul><li>` markup with no `AppIcon`, no shared table/menu/panel classes beyond a bare `className="primary"` on two buttons, and layout CSS confined to `globals.css:19-27` using literal pixel values instead of `--space-*` tokens. It also contains **the only two remaining `window.confirm` calls in the application**:
- `IntegrationsPanel.tsx:101` — removing a saved credential.
- `IntegrationsPanel.tsx:147` — "Transfer this frozen draft of {n} leads to campaign {id}?" — a native, unstyleable confirmation gating an irreversible external send, on the one page that never received the rest of the product's dialog treatment.

This is a real, concrete gap the new brief's fresh pass should catch that a page-by-page plan enumerating only Overview/People/Companies/Clients/Coverage/Data-Quality/Import would miss.

---

## 7. Duplicate or inconsistent components and patterns

| ID | Finding | Evidence |
|---|---|---|
| CSS-01 | `workspace.css` and `components.css` both fully declare `.master-data-table th/td/tbody tr:hover/.selected`, `.filter-panel-head`, `.apollo-filter-summary`, `.results-toolbar`, and `.outline-button`, with different values in places (e.g. row hover: `workspace.css:216-219` sets an accent-tinted hover, `components.css:376-380` sets a neutral hover — `components.css` loads later so it currently wins, but `workspace.css` was never pruned). | `workspace.css:211-236,957-958,1041-1044,168-171,240-246,770-773,177-179`; `components.css:358-441,314-322,121-151,193-226,326-347` |
| TYPE-01 | `typography.css` re-declares font sizing for selectors (`.primary`, `.secondary`, `.panel-head button`, etc.) that `workspace.css` already styles inline. Works via load order, not single ownership. | `typography.css:8-23` vs `workspace.css:108-112` |
| TOOLTIP-01 | People's table cells use native `title` for full-value access (membership count, name/email/ESP, contact date/blocked reason) — hover-only, not reliably exposed on keyboard focus — while the rest of the product (menus, accordions, comboboxes) uses accessible ARIA description. | `ProspectTableRow.tsx:20,36,38` |
| TABS-01 | Two hand-rolled button-pair "tabs" in `ApolloFilterPanel.tsx` (Simple/Advanced mode, Search/Paste-list mode) don't use the shared, fully-accessible `Tabs` component that three other surfaces use correctly. | `ApolloFilterPanel.tsx:311-336,493-519` |
| ROW-01 | Company row-open control is a small trailing icon-only button; People's is the name text itself with hover-underline. Two near-identical row components, two different "how do I open this" affordances. | `CompanyTableRow.tsx:10` vs `ProspectTableRow.tsx:36` |
| COMP-ICON-01 | One raw emoji glyph (`🗑 Delete...`) where every other action uses the shared `AppIcon` SVG system, contradicting that system's own documented purpose. | `ProspectTable.tsx:715` vs `DashboardUi.tsx:27-28` |
| NAME-01 | `.summary-violet`/`.summary-blue`/`.summary-green` classes on Companies' summary tiles no longer render distinct colors (all neutralized to the same surface color) — vestigial, misleading naming. | `CompaniesWorkspace.tsx:497`; CSS at `workspace.css:303-305` |

---

## 8. Table and filter weaknesses

**Tables** (`ProspectTable.tsx`, row components, `.master-data-table` CSS):
- Sticky header present (`workspace.css:212`). Sort is a single `<select>`, not per-column sort indicators — a deliberate, reasonable choice given there's exactly one sort control to keep consistent, not a gap.
- Hover/selected states exist but are declared twice with different values (CSS-01 above) — currently resolves correctly by cascade order only.
- Destructive row actions are an isolated `.row-danger` text link in a trailing column, not an overflow menu — calm and matches the brief's "avoid excessive... pills" instinct, though there's no established per-row overflow-menu pattern if one is needed later.
- Bulk actions only appear after selection (no persistent disabled toolbar).
- Numeric columns get `font-variant-numeric: tabular-nums` and right-alignment only where genuinely numeric (`typography.css:105-109`), not applied blanket to every cell — correct.
- Truncation uses ellipsis + native `title` fallback (TOOLTIP-01 above is the one real gap here).
- Horizontal scroll uses a synced dual-scrollbar pattern (a thin always-visible top scrollbar kept in sync with the table's own scroll) — a genuinely good, non-generic solution, not something to replace.

**Filters** (`ApolloFilterPanel.tsx`, `CompanyFilterPanel.tsx`):
- 320px rail, collapses to full-width-above-results at ≤1000px rather than disappearing.
- Field/operator/value are structurally separated per filter kind (accordions with `aria-expanded`/`aria-controls`/`role="region"`), grouped into named sections (Main filters / From job title / Company / More filters / Client / Client ICP).
- Chip removal supports both single-value and whole-filter removal, plus Clear all.
- The value combobox has full keyboard support; the accordion triggers are real buttons; the two exceptions are the TABS-01 mode-switchers noted above.
- No generic field/operator/value query builder — purpose-built controls per field kind instead, backed by measured production comments explaining several default-scope decisions. This should not be replaced with a generic builder.
- At 1024px (`workspace.css:888-892`) the filter column narrows and one label hides; no command-bar overflow was found in source. **Rendered confirmation at 1024×768 is UNVERIFIED** (requires authenticated access).

---

## 9. Accessibility and responsive findings

- **Dialogs**: `use-dialog.ts` is best-practice (§2) — nothing to fix.
- **Remaining native dialogs**: a full-repo grep found `window.confirm` only in `IntegrationsPanel.tsx:101,147`; zero `window.prompt` calls anywhere in `app/` (retrospective comments at `ClientsPanel.tsx:233` and elsewhere confirm People/Clients were migrated off native dialogs already).
- **Responsive breakpoints** (from `app/workspace.css`, exact px values): `1400px` (toolbar stacking), `1240px` (People filter column narrows), `1080px` (company filter fields to 1 column), `1000px` (sidebar narrows, Overview/Clients grids reflow, People filter moves above results), `900px`, `860px`, `760px` (major mobile breakpoint — sidebar fully replaced by `MobileNav`'s bottom bar, not just hidden), `720px`, `560px`. The 760px breakpoint is confirmed to be a genuine replacement of the old scrolling-nav pattern (`MobileNav.tsx:14-27` documents the before/after), not a patch.
- **`prefers-reduced-motion`** is honored globally (`design-system.css:497-504`) with a harmless duplicate local rule in `workspace.css:991-993,1192`.
- **Color contrast**: `docs/color-contrast-matrix.md` records 62 token pairs per theme, computed from `design-system.css`'s resolved values, enforced by `tests/color-contrast.test.mjs`, all passing at last generation. Treated here as settled, measured evidence — not re-litigated.
- **Live check performed this session**: `/login` at desktop width and at 1024×768 — single-column form on the right, brand panel on the left, no overflow or clipping at either size, console shows no application errors. (One console message — `eval() is not supported in this environment` — is a known artifact of React DevTools running inside this session's sandboxed preview iframe, not an application defect; it does not occur in a normal browser.)
- **Not verified live** (requires authenticated access, blocked by this session's credential-entry policy): actual rendered spacing/contrast in the authenticated workspace, real 1024×768 and 1440×900 behavior for People/Companies/Clients/Coverage/Data-Quality/Import/Integrations, keyboard-only end-to-end walkthroughs, and screen-reader behavior. These should be the first checks performed once Phase 2 begins with real credentials in hand.

---

## 10. Proposed visual and interaction system

No new visual language is proposed — the brief explicitly rules that out, and the audit found nothing that would justify it. The existing `design-system.css` token set (color, 8-step type scale, 4px spacing scale, two control heights, 4-step radius, 4-level elevation, single motion/easing system) already matches the brief's "restrained, professional, data-dense" direction and is contrast-verified. The interaction system to standardize on going forward is the one already used correctly in People/Import/Clients:

- **Command bar**: one primary action + a `View` menu for display/persistence options + an `Actions` menu for secondary/batch operations + a standalone `Filters N` toggle + standalone `Export`, using `MenuButton.tsx`.
- **Tabs**: always `Tabs.tsx`, never a hand-rolled button pair (closes TABS-01).
- **Row identity**: the primary field's text is itself the focusable open-control, styled consistently with People's `.row-open` (closes ROW-01 for Companies).
- **Tooltips/full-value access**: a real focusable tooltip (or the existing detail-drawer pattern) rather than native `title`, for any cell where truncation currently hides information (closes TOOLTIP-01).
- **Dialogs/confirmations**: always `use-dialog.ts`-based components (`ConfirmDialog`/`FormDialog`/drawers), never `window.confirm`/`window.prompt` (closes the two remaining Integrations cases).
- **CSS ownership**: one file owns each selector. Recommend `components.css` as the sole owner of shared primitive rules (table, toolbar, menu, filter-panel-head, outline-button), with the now-redundant declarations removed from `workspace.css`, and `typography.css`'s overlapping selectors folded back into whichever file legitimately owns them (closes CSS-01/TYPE-01).

---

## 11. Shared components to reuse, consolidate, improve, create, or retire

- **Reuse as-is**: `use-dialog.ts`, `Tabs.tsx`, `MenuButton.tsx`, `use-dismiss.ts`, `DashboardUi.tsx`'s `StatusMessage`/`ProgressBar`/`WorkspaceEmpty`/`LoadingState`, `lib/workspace-states.ts`, `AppIcon`.
- **Consolidate**: the duplicate rule sets in `workspace.css` vs `components.css` (CSS-01) into single-owner declarations; `typography.css`'s overlapping font-size rules (TYPE-01) into their true owner file.
- **Improve**: `ApolloFilterPanel.tsx`'s two mode-switchers to use `Tabs.tsx` instead of hand-rolled buttons (TABS-01); `ProspectTableRow.tsx`'s truncated-value cells to use a real focusable tooltip instead of `title` (TOOLTIP-01); `CompanyTableRow.tsx`'s row-open control to match `ProspectTableRow.tsx`'s pattern (ROW-01); `ProspectTable.tsx:715`'s emoji to `AppIcon` (COMP-ICON-01).
- **Create**: a real design-system treatment for `IntegrationsPanel.tsx` (reuse existing `.panel`, table, `MenuButton`, and `ConfirmDialog`/`FormDialog` primitives — no new component class needed) and, if the tooltip fix above needs more than a CSS-only affordance, a small shared `Tooltip` primitive (check first whether the existing `ProspectDrawer` detail view can serve this need without a new component, per the brief's "recommend new patterns only when they solve a demonstrated need" instruction).
- **Retire**: the `.summary-violet`/`.summary-blue`/`.summary-green` class names on Companies' summary tiles (NAME-01) — rename to a neutral name or delete if unused elsewhere.

---

## 12. People Database golden-page recommendation and rationale

**Recommendation: keep People as the golden page**, per the brief's default, and the audit found no evidence to override it. People is the highest-traffic daily surface, and — importantly — it is already the page that best demonstrates the target system (grouped command bar, accessible combobox, real row-open buttons, dialog-based confirmations, computed empty states). Using it as the golden reference means the "golden page" work is a **finishing pass**, not a redesign: fix the two isolated gaps that exist specifically in People's own files (TOOLTIP-01, TABS-01's Search/Paste-list switch, COMP-ICON-01), and — because People's table/toolbar CSS is exactly where CSS-01's ownership conflict lives — resolve that conflict as part of this phase so the "golden" system People ends up demonstrating is the same one every later page will copy from a single, unambiguous source.

This keeps Phase 2 small and low-risk, which matters because People also carries the most protected behavior (across-page selection, exclusions, exact/estimated counts, saved views, export scope) — the smaller the visual diff, the easier it is to verify none of that regressed.

---

## 13. Exact golden-page scope

In scope for the People golden-page phase:
- Fix TOOLTIP-01: replace native `title` on truncated cells in `ProspectTableRow.tsx` with an accessible, focus-and-hover tooltip (or route to the existing prospect-drawer detail view where that's a better fit).
- Fix TABS-01 for People's own filter panel: convert `ApolloFilterPanel.tsx`'s Search/Paste-list switch (lines 493-519) to `Tabs.tsx`. (The Simple/Advanced switch, lines 311-336, is shared with Companies — see below.)
- Fix COMP-ICON-01: replace the emoji in `ProspectTable.tsx:715` with `AppIcon`.
- Resolve CSS-01 for the selectors People's own surfaces depend on: `.master-data-table` (rows/hover/selected), `.results-toolbar`, `.filter-panel-head`, `.outline-button` — pick one owning file (recommend `components.css`) and delete the now-redundant rules from `workspace.css`.
- Resolve TYPE-01 for the selectors People uses (buttons, panel-head controls) as part of the same pass, since it's the same root cause.
- Verify (with authenticated access) People at 1440×900 and 1024×768: search, filters, sort, pagination, selection, bulk actions, saved views, export, and the prospect drawer.

Out of scope for this phase (tracked separately below): `ApolloFilterPanel.tsx`'s Simple/Advanced switch (shared with Companies — fix once, during the Companies rollout, so it isn't touched twice), ROW-01 (Companies-specific), NAME-01 (Companies-specific), Integrations (its own rollout item).

---

## 14. Exact files likely to change

**Golden-page phase (People):**
- `app/components/ProspectTableRow.tsx` (tooltip fix)
- `app/ApolloFilterPanel.tsx` (Search/Paste-list tabs only, lines ~493-519)
- `app/components/ProspectTable.tsx` (emoji → `AppIcon`, line 715)
- `app/components.css` (become sole owner of the shared selectors listed in §13)
- `app/workspace.css` (remove the now-redundant duplicate declarations)
- `app/typography.css` (remove/relocate the overlapping font-size rules for the same selectors)

No `.tsx` file's business logic, data fetching, or event handlers beyond the three named UI fixes above should change. No file outside `app/` should change.

---

## 15. Files and behavior explicitly out of scope

- Anything under `app/api/**`, `lib/**` (except reading, not editing, `lib/workspace-states.ts`/`lib/workspace-url.ts`/`lib/quality-issues.ts` for reference), `db/**`, `drizzle/**`, `supabase/**`, `worker/**`, `scripts/**`.
- `package.json` / dependency changes of any kind.
- Any route, API contract, schema, auth/permission, import/export, search/filter/sort semantics, selection/bulk-action logic, calculation/formatting rule, URL-state shape, caching behavior, or destructive-action behavior.
- `CompanyTableRow.tsx` (ROW-01), `CompaniesWorkspace.tsx` (NAME-01), and `IntegrationsPanel.tsx`/`globals.css` (Integrations rebuild) — all real findings, all deferred to their own rollout items (§18) rather than bundled into the golden-page phase.
- Mobile-specific work — the prior redesign's mobile phase (`MOBILE-01`–`MOBILE-04`) is done; only `MOBILE-05` (device QA) remains open, which belongs in Phase 4, not here.

---

## 16. Protected functionality and regression risks

Everything the brief lists as protected (routes, APIs, schema, auth, imports/exports, search/filter/sort semantics, selection/bulk-action behavior, calculations/formatting, URL state, caching, destructive-action behavior) is confirmed **not implicated** by any finding in this document — every finding is CSS, markup structure, or component-boundary (which shared component a page uses), not business logic.

Specific regression risks for the golden-page phase:
- **CSS-01 resolution is the main risk.** Deleting rules from `workspace.css` that `components.css` was supposed to already override could change rendered appearance anywhere else those same selectors are used (i.e., Companies' table, since `.master-data-table` is shared) if the two files' values differ in a way not yet cataloged. Mitigation: after resolving, visually check both People and Companies tables, not just People, even though only People is "in scope" for this phase.
- **Tooltip replacement risk**: native `title` currently carries genuinely useful content (full membership list, full email, MX records, contact-date detail). The replacement must preserve every one of those values, not simplify them.
- **`ApolloFilterPanel.tsx` is shared with Companies** (`CompanyFilterPanel.tsx` imports from it) — changing the Search/Paste-list tabs must not affect the Simple/Advanced switch or any prop contract `CompanyFilterPanel.tsx` depends on.

---

## 17. Acceptance criteria

- `GOLDEN-AC-01`: Every truncated/full-value cell in People's table exposes its full value on both hover and keyboard focus, and the replacement uses `role`/`aria-*` correctly (not a second native `title`).
- `GOLDEN-AC-02`: People's Search/Paste-list switch has `role="tablist"`/`role="tab"` semantics and supports Arrow/Home/End, matching `Tabs.tsx`'s existing contract.
- `GOLDEN-AC-03`: No emoji or unicode glyph remains in `ProspectTable.tsx`; the delete action uses `AppIcon`.
- `GOLDEN-AC-04`: `.master-data-table`, `.results-toolbar`, `.filter-panel-head`, and `.outline-button` are each declared in exactly one CSS file; grep confirms no duplicate selector declarations remain across `workspace.css`/`components.css`/`typography.css`.
- `GOLDEN-AC-05`: People's table renders identically (pixel-equivalent) before and after the CSS consolidation, verified by direct comparison, not assumption — and Companies' table is spot-checked for the same reason.
- `GOLDEN-AC-06`: All existing People-related tests (`tests/apollo-filters.test.mjs`, `tests/color-contrast.test.mjs`, `tests/command-bars.test.mjs`, `tests/dialog-primitives.test.mjs`, `tests/workspace-states.test.mjs`) and `npm run build`/`npm run lint` pass unchanged.
- `GOLDEN-AC-07`: Search, filters, sort, pagination, across-page selection/exclusions, saved views, export, and the prospect drawer are manually verified against the authenticated app at 1440×900 and 1024×768 with no behavior change from before the phase.

---

## 18. Recommended rollout order

1. **Golden page: People** (§13) — includes the CSS-01/TYPE-01 consolidation, since People's own surfaces depend on it.
2. **Companies** — apply the consolidated CSS system; fix ROW-01 (row-open parity with People) and NAME-01 (rename/retire stale summary classes); fix the remaining `ApolloFilterPanel.tsx` Simple/Advanced tab switch (shared, so do it here rather than twice).
3. ~~**Integrations**~~ — **skipped at the user's request (2026-09-18): the feature isn't in current use, so its two `window.confirm` calls and unstyled markup are left as-is.** If Integrations comes back into use, revisit this item: apply shared panel/table/menu classes, replace both `window.confirm` calls with `ConfirmDialog`, move its layout CSS out of `globals.css` and onto design tokens.
4. **Client People Database / Uploaded Lists / Clients & Lists / client workspace header** — per the audit these already meet the bar; treat as a verification pass (confirm the shared system renders correctly in these client-scoped contexts) rather than expecting new findings.
5. **Data Quality** — verification pass only; no findings in this audit.
6. **Overview** — verification pass; optionally decide (per §6) whether Overview should regain its own health/degraded language or explicitly defer that concept to Data Quality permanently.
7. **Remaining admin routes** (Server logs) — not audited in this pass; quick verification pass recommended before calling Phase 3 complete.

---

## 19. P0, P1, and P2 findings

**P0 (broken, dangerous, inaccessible, or likely to cause an incorrect/destructive action): none found.**

**P1 (substantial usability, consistency, responsive, or workflow problem):**
- CSS-01 — duplicate/conflicting CSS ownership between `workspace.css` and `components.css` (§7).
- Integrations' overall lack of design-system treatment, including two native `window.confirm` dialogs, one gating an irreversible campaign-send (§6, Integrations). **Deferred at the user's request (2026-09-18) — not in current use.**
- TOOLTIP-01 — native `title`-only full-value access in People's table, a genuine keyboard-accessibility gap (§7).
- ROW-01 — Companies' row-open control is inconsistent with, and weaker than, People's pattern (§7).

**P2 (lower-impact refinement or visual polish):**
- TYPE-01 — `typography.css`/`workspace.css` font-size overlap (works today, fragile) (§7).
- TABS-01 — two hand-rolled tab-like widgets in `ApolloFilterPanel.tsx` (§7).
- COMP-ICON-01 — one emoji glyph (§7).
- NAME-01 — stale `summary-violet/blue/green` class names (§7).
- Overview's missing on-page health language, now handled elsewhere (§6).

---

## 20. Ten highest-impact improvements

1. Resolve the `workspace.css`/`components.css` CSS ownership conflict (CSS-01) — the single highest-leverage fix, since it protects every future table/toolbar/menu edit, not just current rendering.
2. ~~Bring Integrations up to the design system and remove its two `window.confirm` calls, especially the one gating an irreversible campaign send.~~ Skipped at the user's request (2026-09-18) — feature not in current use.
3. Replace native `title` tooltips in People's table with an accessible, focus-and-hover alternative (TOOLTIP-01).
4. Align Companies' row-open affordance with People's (ROW-01).
5. Fold `ApolloFilterPanel.tsx`'s two hand-rolled mode-switchers into the shared `Tabs` component (TABS-01).
6. Replace the one emoji icon with `AppIcon` (COMP-ICON-01) — trivial effort, closes a real consistency gap.
7. Rename or retire the stale `summary-violet/blue/green` classes before they collide with a future color decision (NAME-01).
8. Fold `typography.css`'s overlapping declarations back into single ownership alongside the CSS-01 fix (TYPE-01).
9. Once authenticated access is available, run the full viewport/keyboard verification matrix (1440×900, 1024×768, plus 1920×1080 for Phase 4) against People, Companies, and Integrations specifically — the three surfaces this plan touches — since nothing in the audited pages was rendered live this session.
10. Decide explicitly whether Overview should regain page-level health/degraded language or formally defer that concept to Data Quality, so it isn't accidentally rebuilt in both places later.

---

## Phase 1 close-out

**Ten highest-impact improvements:** see §20.

**Recommended golden-page scope:** People database, limited to the finishing-pass items in §13 (tooltip accessibility, one tab-widget fix, one icon fix, and the CSS-ownership consolidation that People's own surfaces require) — not a visual redesign of the page.

**Files likely to be touched during the golden-page phase:** `app/components/ProspectTableRow.tsx`, `app/ApolloFilterPanel.tsx` (Search/Paste-list tabs section only), `app/components/ProspectTable.tsx` (one line), `app/components.css`, `app/workspace.css`, `app/typography.css`. No files outside `app/`.

**Existing behavior most at risk:** the rendered appearance of `.master-data-table`/`.results-toolbar`/`.filter-panel-head`/`.outline-button` wherever else they're used (chiefly Companies, since the table class is shared) — mitigated by explicitly checking Companies too, even though it's not in scope for edits this phase (§16).

**Decisions requiring your approval:**
1. Confirm People as the golden page, scoped as narrowly as §13 describes (a finishing pass, not a visual redesign) — given how much of the target system People already demonstrates.
2. Confirm Integrations should be promoted ahead of Client People DB/Uploaded Lists/Clients & Lists in the rollout order (§18), since it's the one route with a real, unaddressed gap rather than a verification pass.
3. Confirm the CSS-ownership consolidation (recommend `components.css` as sole owner of the shared primitive selectors) happens during the golden-page phase rather than being deferred — deferring it means Companies would still be building on the same unstable foundation when its turn comes.
4. Decide the Overview health-language question in §6/§20 whenever Overview's rollout turn comes, not now.
5. Note the standing limitation: this session cannot authenticate into the app, so every "verify at 1440×900/1024×768" step in Phase 2 onward needs either credentials made available in a way that doesn't require me to type a password, or someone else performing that specific verification step and reporting results back.

**Confirmation: no application code, styles, configuration, package manifests, tests, backend files, database files, or dependencies were changed to produce this document.** The only file created is `docs/UI_REDESIGN_PLAN.md` itself.
