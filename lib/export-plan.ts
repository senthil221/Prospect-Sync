import { availableExportFieldIds } from "./prospect-export.ts";

// Which way an export should run: straight down the response, or in the
// background with a file to collect afterwards.
//
// Section 9.4 asks for that choice to be made on "estimated bytes as well as
// rows", and the "as well as" is the point. Rows alone are a bad proxy: 250,000
// people exported as name and email is about 13 MB and streams in seconds,
// while the same 250,000 rows with keywords, tag lists, client lists and thirty
// custom columns is closer to 200 MB. Those two need different machinery, and a
// row count cannot tell them apart.
//
// What actually hurts is bytes. Bytes are how long the connection stays open,
// how long an interactive slot is in use, how much the browser holds when the
// File System Access API is not available, and how much is lost when a download
// dies at 90 %.

// Average bytes a column contributes to a rendered CSV row, including quoting
// and the separator. These are estimates and are meant to be: the decision they
// feed is "roughly which order of magnitude is this", and being wrong by a third
// moves nothing across a 25 MB line. They come from the shape of the data rather
// than from measurement, which is why the thresholds below leave a wide margin.
const wideColumnBytes: Record<string, number> = {
  __keywords: 140,
  __lists: 60,
  __clients: 60,
  __tags: 60,
  __mx_records: 60,
  __linkedin: 48,
  __title: 40,
  __person_location: 40,
  __company_location: 40,
  __website: 34,
  __created_at: 34,
  __updated_at: 34,
  __mx_checked_at: 34,
  __last_contacted: 34,
  __company: 32,
  __work_email: 32,
  __personal_email: 32,
};

// Custom columns are uploaded free text with no schema behind them, so they get
// a wide default rather than a narrow one.
const customColumnBytes = 48;
const defaultColumnBytes = 20;

// A direct stream is bounded by these two, whichever is reached first. 50,000
// rows is twice the largest page the export function will return, and 25 MB is
// small enough to survive the Blob fallback in a browser without the File System
// Access API - which is the real constraint, because that path holds the whole
// document in memory before it writes a byte.
export const directRowLimit = Number(process.env.EXPORT_DIRECT_ROW_LIMIT ?? 50_000);
export const directByteLimit = Number(process.env.EXPORT_DIRECT_BYTE_LIMIT ?? 25 * 1024 * 1024);

// Sum of the per-column estimates for the columns this export actually asks for.
export function estimatedBytesPerRow(customFieldNames: string[], requestedFields?: string[]) {
  const available = availableExportFieldIds(customFieldNames);
  const selected = requestedFields ? requestedFields.filter((field) => available.has(field)) : [...available];
  return selected.reduce((total, field) => total + (
    wideColumnBytes[field] ?? (field.startsWith("custom:") ? customColumnBytes : defaultColumnBytes)
  ), 0);
}

export type ExportPlan = {
  mode: "direct" | "background";
  rows: number | null;
  bytesPerRow: number;
  bytes: number | null;
  reason: string;
};

// Grouped with commas explicitly rather than through toLocaleString, which
// answers with the server's locale and would put "2,50,000" in front of a user
// who has never asked for lakhs.
function grouped(value: number) {
  return value.toLocaleString("en-US");
}

export function megabytes(bytes: number) {
  return Math.max(1, Math.round(bytes / (1024 * 1024)));
}

// `rows` is the count the grid already has. Null means it does not have one -
// either nothing counted it, or the count came back capped, in which case the
// honest answer is that the size is unknown rather than that it is the cap.
export function planExport(input: {
  customFieldNames: string[];
  requestedFields?: string[];
  rows: number | null;
}): ExportPlan {
  const bytesPerRow = estimatedBytesPerRow(input.customFieldNames, input.requestedFields);
  const rows = input.rows == null || !Number.isFinite(input.rows) ? null : Math.max(0, Math.round(input.rows));
  if (rows == null) {
    return {
      mode: "background", rows: null, bytesPerRow, bytes: null,
      reason: "The number of matching rows is not known, so this runs in the background rather than assuming it is small.",
    };
  }
  const bytes = rows * bytesPerRow;
  if (rows > directRowLimit) {
    return {
      mode: "background", rows, bytesPerRow, bytes,
      reason: `${grouped(rows)} rows is past the ${grouped(directRowLimit)} a single download handles.`,
    };
  }
  if (bytes > directByteLimit) {
    return {
      mode: "background", rows, bytesPerRow, bytes,
      reason: `Those columns come to roughly ${megabytes(bytes)} MB, past the ${megabytes(directByteLimit)} MB a single download handles.`,
    };
  }
  return { mode: "direct", rows, bytesPerRow, bytes, reason: "Small enough to download directly." };
}
