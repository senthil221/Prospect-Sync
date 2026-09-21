import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// The List workspace was 27 lines with no bulk action of any kind. Rather than
// build a second, smaller copy of the People/Company database's own bulk
// actions on top of it, See People / See Companies pivot the whole list into
// the real client databases, and Copy Domains resolves through the exact
// mechanism the Company DB's own Copy Domains already uses.
test("the List workspace pivots into the real client databases rather than duplicating their actions", async () => {
  const panel = await read("../app/components/ListsPanel.tsx");

  assert.match(panel, /onSeePeople: \(\) => void; onSeeCompanies: \(\) => void/);
  assert.match(panel, /<button className="secondary".*onClick=\{onSeePeople\}/);
  assert.match(panel, /<button className="secondary".*onClick=\{onSeeCompanies\}/);

  // Copy Domains reuses /api/companies/domains - the same route the Company
  // DB's own Copy Domains calls - scoped by a people-side __list_ids filter
  // rather than an explicit company selection. No new backend endpoint.
  assert.match(panel, /\/api\/companies\/domains/);
  assert.match(panel, /field: "__list_ids", operator: "contains", values: \[list\.id\]/);
  assert.match(panel, /await navigator\.clipboard\.writeText\(result\.domains\.join\("\\n"\)\)/);

  const domainsRoute = await read("../app/api/companies/domains/route.ts");
  assert.doesNotMatch(domainsRoute, /list_ids|list_memberships/, "the domains route must stay generic - list scoping belongs in the caller's peopleScope, not a special case in the route");
});

// Consumed exactly once: ListsPanel is a sibling of ClientDetail, not nested
// inside it, so requesting a pivot has to close the list AND tell the client
// workspace (once it remounts) which tab and scope to open with.
test("a list pivot is threaded from DashboardApp through ClientsPanel and consumed once by ClientDetail", async () => {
  const app = await read("../app/DashboardApp.tsx");
  const panel = await read("../app/components/ClientsPanel.tsx");

  assert.match(app, /const \[clientListPivot, setClientListPivot\] = useState/);
  assert.match(app, /onSeeListRecords=\{\(clientId, list, target\) => \{ setClientListPivot\(\{ clientId, listId: list\.id, listName: list\.name, target \}\); setSelectedList\(null\); \}\}/);

  // Only handed to ClientDetail when it matches the client actually open - a
  // pivot requested for one client must never seed another client's tabs.
  assert.match(panel, /listPivot && listPivot\.clientId === selectedClient\.id \? listPivot : null/);

  // Consumed once, at the mount the pivot causes - not kept reactive, which
  // would let it silently reopen after an ordinary later remount.
  assert.match(panel, /useEffect\(\(\) => \{ if \(listPivot\) onConsumeListPivot\(\); \}, \[\]\);/);

  // See Companies rides the exact peopleScope pivot mechanism a People→Company
  // pivot inside the client workspace already uses - a list is just another
  // people-side scope, so nothing downstream needs to know it came from one.
  assert.match(panel, /listPivot\?\.target === "companies"[\s\S]{0,200}field: "__list_ids"/);
  // See People seeds the People DB's own initialFilters, the same mechanism
  // the Leads and Contactable tabs already use to open pre-filtered - captured
  // into state at mount (peopleListPivot), not read from the listPivot prop
  // directly: that prop is cleared back to null by the one-shot effect above
  // right after mount, and a key/prop that kept reading it would remount
  // ClientMasterDatabase a tick later with initialFilters=[], silently dropping
  // the list filter (see the Copy Domains-adjacent regression this test guards).
  assert.match(panel, /const \[peopleListPivot\] = useState<\{ listId: string; filters: ProspectFilter\[\] \} \| null>\(\(\) =>\s*\n\s*listPivot\?\.target === "prospects"/);
  assert.match(panel, /key=\{`people:\$\{client\.prospect_count\}:\$\{client\.blocked_count \?\? 0\}:\$\{peopleListPivot\?\.listId \?\? ""\}`\}/);
  assert.match(panel, /initialFilters=\{peopleListPivot\?\.filters \?\? \[\]\}/);
});

// The persistent Lists filter, in both the client's People DB and its Company
// DB - not just the one-shot pivot from the List workspace.
test("Lists is offered as a persistent filter in both the client People DB and the client Company DB", async () => {
  const filterPanel = await read("../app/ApolloFilterPanel.tsx");
  const clientsPanel = await read("../app/components/ClientsPanel.tsx");

  // People DB: client-scoped only, same gating Client ICP already uses - it
  // needs a client to have lists to filter by in the first place.
  assert.match(filterPanel, /clientId && lists\.length && "lists"\.includes\(normalizedSearch\)/);
  assert.match(filterPanel, /<ClientMembershipFilter field="__list_ids" title="Lists"/);

  // Company DB: a dropdown that sets the same peopleScope pivot state the
  // one-shot "See Companies" action uses, so a list and a live People DB
  // search are interchangeable as far as the Company DB is concerned.
  assert.match(clientsPanel, /onSelectListScope: \(listId: string\) => void/);
  assert.match(clientsPanel, /<select aria-label="Filter companies by list"/);
});
