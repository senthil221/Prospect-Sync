import type { ExportColumn, ProspectRow } from "./prospect-export.ts";

// The company CSV, in one place.
//
// There are two paths to it now - the direct keyset stream and, for a set too
// large for one download, the background file assembled from job parts - and
// they have to produce the same two columns with the same headers and the same
// bare-domain-to-URL rule. Two copies of that would be two copies to keep in
// step, which is the mistake search_prospect_export_v1 already made once with
// the filter CASE it carried privately.
//
// It uses the same ExportColumn shape as the prospect export, so csvHeaderLine
// and csvRowsBody render companies without knowing they are companies.

export function companyWebsiteUrl(value: unknown) {
  const domain = String(value ?? "").trim();
  if (!domain) return "";
  return /^https?:\/\//i.test(domain) ? domain : `https://${domain}`;
}

export const companyExportColumns: ExportColumn[] = [
  { header: "Company Name", value: (row: ProspectRow) => String(row.name ?? "").trim() || String(row.domain ?? "").trim() || "Unnamed company" },
  { header: "Website", value: (row: ProspectRow) => companyWebsiteUrl(row.domain) },
];

// What the query has to return for those columns. Short enough to write out,
// unlike the prospect list, which is derived by running the renderer.
export const companyExportKeys = ["id", "name", "domain"];
