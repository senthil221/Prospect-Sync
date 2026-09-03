// Why a table is empty, and what to do about it.
//
// STATE-01 and PEOPLE-05: an empty table has at least six causes and the
// product named one of them. People checked whether filters were applied and
// nothing else, so a search that matched nothing said "Import a CSV and your
// unique prospects will appear here" - advice to import 681,000 rows you
// already have, because you typed a name with a typo in it. Companies did not
// check at all: every empty result said "No known companies yet", including
// when you were looking at a filtered subset of 418,000 known companies.
//
// The rule this encodes: name the constraint that is actually hiding the rows,
// and offer the action that removes THAT constraint. An empty state whose
// button does not undo the thing causing the emptiness is worse than no button.

export type EmptyIntent = "clear-search" | "clear-filters" | "clear-both" | "clear-scope" | "import" | "none";

export type WorkspaceEmptyState = {
  title: string;
  text: string;
  action: string;
  intent: EmptyIntent;
};

export function emptyWorkspaceState(input: {
  entity: "people" | "companies";
  search: string;
  filterCount: number;
  /** A Company DB or People DB pivot is narrowing this view. */
  scoped?: boolean;
  /** We are inside one client's workspace rather than the master database. */
  clientScoped?: boolean;
}): WorkspaceEmptyState {
  const term = input.search.trim();
  const noun = input.entity === "people" ? "people" : "companies";
  const Noun = input.entity === "people" ? "People" : "Companies";
  const filters = input.filterCount;

  // Most specific first. A pivot is the narrowing people forget they applied,
  // because it was set on a different screen.
  if (input.scoped) {
    return {
      title: `No ${noun} inside that scope`,
      text: input.entity === "people"
        ? "This view is limited to the companies from your last Company DB search. Clearing the scope searches every company again."
        : "This view is limited to the companies represented in your last People DB search. Clearing the scope searches every company again.",
      action: "Clear scope",
      intent: "clear-scope",
    };
  }

  if (term && filters) {
    return {
      title: `No ${noun} match “${term}” with those filters`,
      text: `Both a search term and ${filters} filter${filters === 1 ? "" : "s"} are narrowing this view. Removing either may be enough.`,
      action: "Clear search and filters",
      intent: "clear-both",
    };
  }

  if (term) {
    // PEOPLE-AC-02: a search-only miss offers Clear search, never Import.
    return {
      title: `No ${noun} match “${term}”`,
      text: "Nothing in the database matches that search. Check the spelling, or try a shorter term.",
      action: "Clear search",
      intent: "clear-search",
    };
  }

  if (filters) {
    return {
      title: `No ${noun} match those filters`,
      text: `${filters} filter${filters === 1 ? " is" : "s are"} applied. Widen or remove them to see more records.`,
      action: filters === 1 ? "Clear filter" : "Clear filters",
      intent: "clear-filters",
    };
  }

  if (input.clientScoped) {
    return {
      title: `No ${noun} in this client workspace`,
      text: input.entity === "people"
        ? "Nothing has been pushed to this client yet. Push people to it from the master database, or import a list for it."
        : "No companies are linked to this client yet. They appear as soon as people from those companies are pushed here.",
      action: "Import CSV",
      intent: "import",
    };
  }

  // Genuinely empty: nothing applied, nothing there.
  return {
    title: input.entity === "people" ? "No prospects yet" : "No companies yet",
    text: input.entity === "people"
      ? "Import a CSV and your unique prospects will appear here."
      : `${Noun} found in imported lists appear here automatically.`,
    action: "Import CSV",
    intent: "import",
  };
}
