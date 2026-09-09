// How the classifier taxonomy is presented, and in what order.
//
// The database returns tiers and departments as data - the raw values and their
// counts - because that is all it can honestly know. Two presentation decisions
// live here instead:
//
//   1. RANK. Seniority tiers are ordered, and the order is the classifier's own
//      (spec section 3, high to low). Alphabetical would put c_suite above
//      entry above manager above owner, which reads as noise; a picker whose
//      first row is Owner and whose last is Entry reads as a hierarchy.
//   2. LABELS. "c_suite" and "senior_ic" are column values, not words. Nobody
//      picking a filter should have to know the spelling the classifier stores.
//
// A tier the database returns that is not listed here still appears, labelled
// from its raw value: the CSVs are allowed to grow a tier without the UI having
// to be taught about it first, which is the same property that lets a new
// sub-department appear in the picker with no code change.

export type TaxonomyEntry = { value: string; count: number };
export type TaxonomyDepartment = { name: string; count: number; subs: Array<{ name: string; count: number }> };
export type TitleTaxonomy = {
  tiers: TaxonomyEntry[];
  departments: TaxonomyDepartment[];
  undefinedSeniority: number;
  undefinedDepartment: number;
};

// Highest first, matching the classifier's rank order.
const tierOrder = ["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry"];

const tierLabels: Record<string, string> = {
  owner: "Owner",
  c_suite: "C-Suite",
  vp: "VP",
  director: "Director",
  manager: "Manager",
  senior_ic: "Senior IC",
  entry: "Entry",
};

// Title case from a stored value, for anything the map above has not been taught.
function fallbackLabel(value: string) {
  return value.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function tierLabel(value: string) {
  return tierLabels[value] ?? fallbackLabel(value);
}

// Rank order first, then anything unrecognised, alphabetically, so a tier added
// to the CSVs is offered rather than silently dropped.
export function orderedTiers(tiers: TaxonomyEntry[]): TaxonomyEntry[] {
  const known = tierOrder
    .map((value) => tiers.find((tier) => tier.value === value))
    .filter((tier): tier is TaxonomyEntry => Boolean(tier));
  const rest = tiers
    .filter((tier) => !tierOrder.includes(tier.value))
    .sort((left, right) => left.value.localeCompare(right.value));
  return [...known, ...rest];
}

// Departments come back alphabetically, which is the right order for a list of
// eighteen a person is scanning for one name. The only change is that the ones
// with people in them come first: an empty department is still worth offering
// and is not worth the top of the list.
export function orderedDepartments(departments: TaxonomyDepartment[]): TaxonomyDepartment[] {
  return [...departments].sort((left, right) =>
    (right.count > 0 ? 1 : 0) - (left.count > 0 ? 1 : 0) || left.name.localeCompare(right.name));
}

export const emptyTaxonomy: TitleTaxonomy = { tiers: [], departments: [], undefinedSeniority: 0, undefinedDepartment: 0 };
