import { csvStreamError, readCsvStream } from "./csv-download.ts";
import { estimatedCompanyBytesPerRow } from "./company-export.ts";
import { planExport, type ExportPlan } from "./export-plan.ts";
import { buildExportColumns, csvHeaderLine, csvRowsBody, type ProspectRow } from "./prospect-export.ts";
import type { ProspectFilter } from "./prospect-filters.ts";
import type { CompanyScope, PeopleScope } from "./workspace-scopes.ts";

const BOM = "﻿";
const CRLF = "\r\n";

// Minimal File System Access API surface (Chromium). Absent elsewhere -> Blob fallback.
type WritableLike = { write: (data: string) => Promise<void>; close: () => Promise<void> };
type FileHandleLike = { createWritable: () => Promise<WritableLike> };
type DirectoryHandleLike = { getFileHandle: (name: string, options?: { create?: boolean }) => Promise<FileHandleLike> };
type WindowFs = {
  showSaveFilePicker?: (options?: { suggestedName?: string; types?: unknown }) => Promise<FileHandleLike>;
  showDirectoryPicker?: (options?: { mode?: string }) => Promise<DirectoryHandleLike>;
};

function fsApi(): WindowFs {
  return (typeof window === "undefined" ? {} : window) as unknown as WindowFs;
}

export function fileSystemAccessSupported() {
  const api = fsApi();
  return typeof api.showSaveFilePicker === "function" && typeof api.showDirectoryPicker === "function";
}

const csvPickerTypes = [{ description: "CSV file", accept: { "text/csv": [".csv"] } }];

export type ExportMode = "all_matching" | "selected";
export type ExportFormat = "single" | "parts";

// "listing" is the worker freezing the id list, "writing" is the worker turning
// it into a file, and "downloading" is the browser collecting it. They are three
// different waits and a bar that cannot tell them apart sits at zero through the
// longest one.
export type ExportPhase = "downloading" | "listing" | "writing";

export type ExportProgress = {
  exported: number;
  total?: number;
  files: number;
  phase: ExportPhase;
  note?: string;
};

export type ExportOptions = {
  search: string;
  filters: ProspectFilter[];
  clientId: string | null;
  companyScope?: CompanyScope | null;
  fields: string[];               // requested export field ids
  customFieldNames: string[];     // available uploaded field names (for custom columns)
  mode: ExportMode;
  selectedRows?: ProspectRow[];   // full row objects when mode === "selected"
  excludedIds?: string[];         // ids to drop when mode === "all_matching"
  format: ExportFormat;
  rowsPerFile: number;            // parts mode
  fileBaseName: string;
  // What the grid says matches. Null when nothing counted it or the count came
  // back capped - which is itself a reason to go to the background, because an
  // unknown size cannot be assumed to be small.
  totalRows?: number | null;
  // Section 9.2. Belongs to the user's intent, so retrying a whole export after
  // a dropped connection watches the file already being written instead of
  // starting a second one.
  requestId?: string;
  signal?: AbortSignal;
  onProgress?: (progress: ExportProgress) => void;
};

export type ExportResult = {
  exported: number;
  files: number;
  canceled: boolean;
  // Set when the file was built in the background and handed to the browser as
  // a link rather than written from this tab.
  handedOff?: boolean;
  plan?: ExportPlan;
};

async function writeToHandle(handle: FileHandleLike, pieces: string[]) {
  const writable = await handle.createWritable();
  for (const piece of pieces) await writable.write(piece);
  await writable.close();
}

// The pieces are handed to Blob() as an array rather than concatenated first.
//
// That is not a micro-optimisation, it is the difference between working and
// throwing: a JavaScript string cannot exceed about 512 MB in V8, so building
// the document as one string puts a hard ceiling on the export that has nothing
// to do with how much memory the machine has. lib/csv-download.ts always knew
// this - it kept an array and said so - and the ceiling arrived here when the
// company export moved onto this sink and the company CSV stopped being two
// narrow columns.
function downloadBlob(name: string, pieces: string[]) {
  const url = URL.createObjectURL(new Blob(pieces, { type: "text/csv;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = name;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function partName(base: string, index: number) {
  return `${base}-part-${String(index).padStart(2, "0")}.csv`;
}

// Where the CSV goes, once. Single file or parts, disk or blob - the readers
// above it hand it complete records and never see which.
type Sink = {
  setHeader(header: string): void;
  add(text: string, rows: number): Promise<void>;
  close(): Promise<{ files: number }>;
};

// Only the three fields that decide where bytes go. Narrowed from ExportOptions
// so the company export can use the same sink without inventing a search term
// and a custom field list it does not have.
type SinkOptions = { format: ExportFormat; rowsPerFile: number; fileBaseName: string };

async function createSink(options: SinkOptions, canFs: boolean): Promise<Sink> {
  const single = options.format === "single";
  const rowsPerFile = Math.max(1000, options.rowsPerFile || 25000);
  let header = "";

  if (single) {
    // The picker has to be opened while the click that started this is still
    // the browser's idea of a user gesture, which is why it happens before any
    // request rather than when the first bytes arrive.
    const writable = canFs
      ? await (await fsApi().showSaveFilePicker!({ suggestedName: `${options.fileBaseName}.csv`, types: csvPickerTypes })).createWritable()
      : null;
    const buffered: string[] = [];
    let started = false;
    const emit = async (text: string) => {
      if (writable) await writable.write(text);
      else buffered.push(text);
    };
    return {
      setHeader(value) { header = value; },
      async add(text) {
        await emit((started ? CRLF : header + CRLF) + text);
        started = true;
      },
      async close() {
        if (!started) await emit(header + CRLF);
        if (writable) await writable.close();
        else downloadBlob(`${options.fileBaseName}.csv`, buffered);
        return { files: 1 };
      },
    };
  }

  const directory = canFs ? await fsApi().showDirectoryPicker!({ mode: "readwrite" }) : null;
  let bucket: string[] = [];
  let bucketRows = 0;
  let files = 0;
  const flush = async () => {
    if (!bucketRows) return;
    files += 1;
    const pieces = [header, CRLF, bucket.join(CRLF)];
    if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, files), { create: true }), pieces);
    else downloadBlob(partName(options.fileBaseName, files), pieces);
    bucket = [];
    bucketRows = 0;
  };
  return {
    setHeader(value) { header = value; },
    async add(text, rows) {
      bucket.push(text);
      bucketRows += rows;
      if (bucketRows >= rowsPerFile) await flush();
    },
    async close() {
      await flush();
      if (!files) {
        // An empty result is still a file, and an empty folder is confusing.
        files = 1;
        if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, 1), { create: true }), [header, CRLF]);
        else downloadBlob(partName(options.fileBaseName, 1), [header, CRLF]);
      }
      return { files };
    },
  };
}

// mode "selected": rows already in memory - no server round-trips.
export async function runSelectedExport(options: ExportOptions): Promise<ExportResult> {
  const columns = buildExportColumns(options.customFieldNames, options.fields);
  const rows = options.selectedRows ?? [];
  const sink = await createSink(options, fileSystemAccessSupported());
  sink.setHeader(BOM + csvHeaderLine(columns));
  const chunk = Math.max(1000, options.format === "single" ? rows.length || 1 : options.rowsPerFile || 25000);
  for (let start = 0; start < rows.length; start += chunk) {
    const slice = rows.slice(start, start + chunk);
    await sink.add(csvRowsBody(slice, columns), slice.length);
    options.onProgress?.({ exported: Math.min(start + chunk, rows.length), total: rows.length, files: 0, phase: "downloading" });
  }
  const { files } = await sink.close();
  return { exported: rows.length, files, canceled: false };
}

// The direct path: one request, CSV coming back as the database produces it.
async function runDirectExport(options: ExportOptions, plan: ExportPlan): Promise<ExportResult> {
  const sink = await createSink(options, fileSystemAccessSupported());
  const response = await fetch("/api/prospects/export", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: options.signal,
    body: JSON.stringify({
      search: options.search,
      filters: options.filters,
      clientId: options.clientId,
      companyScope: options.companyScope,
      fields: options.fields,
      excludedIds: options.excludedIds ?? [],
      fileBaseName: options.fileBaseName,
    }),
  });
  if (!response.ok) throw await csvStreamError(response, "Export failed.");

  let exported = 0;
  await readCsvStream(response, {
    onHeader: (header) => sink.setHeader(header),
    onRows: async (text, rows) => {
      await sink.add(text, rows);
      exported += rows;
      options.onProgress?.({ exported, total: plan.rows ?? undefined, files: 0, phase: "downloading" });
    },
  });
  const { files } = await sink.close();
  if (options.signal?.aborted) return { exported, files, canceled: true, plan };
  return { exported, files, canceled: false, plan };
}

export type CompanyExportOptions = {
  search: string;
  filters: ProspectFilter[];
  peopleScope: PeopleScope | null;
  websitesOnly: boolean;
  fields: string[];
  customFieldNames: string[];
  format: ExportFormat;
  rowsPerFile: number;
  fileBaseName: string;
  totalRows?: number | null;
  requestId?: string;
  signal?: AbortSignal;
  onProgress?: (progress: ExportProgress) => void;
};

// "Only with websites", said as a filter.
//
// A background export is defined by a frozen result set, and a result set holds
// a search and a set of filters - there is nowhere in it to put a websitesOnly
// flag. Rather than widen the result set for one boolean, the flag is expressed
// in the filter language it was always expressible in: __website not_empty
// matches exactly the rows `btrim(coalesce(domain,'')) <> ''` matches, checked
// against production at 319,060 of 419,218 companies.
export function withWebsiteFilter(filters: ProspectFilter[], websitesOnly: boolean): ProspectFilter[] {
  if (!websitesOnly) return filters;
  if (filters.some((filter) => filter.field === "__website" && filter.operator === "not_empty")) return filters;
  return [...filters, { field: "__website", operator: "not_empty", values: [] }];
}

// A people-DB pivot cannot be frozen either, and unlike websitesOnly it has no
// equivalent in the filter language: it is a set of company ids derived from a
// prospect search. So an export carrying one stays on the direct path, and the
// dialog says so rather than starting a download that cannot finish.

// The company export, written the way the prospect one is.
//
// It used to collect the whole response into an array of strings and hand it to
// Blob(), which lib/csv-download.ts is explicit about being safe only "where
// the file is known to be small - two narrow columns". That stopped being true
// the moment Description became a checkbox: it averages about a kilobyte, so
// 400,000 companies is on the order of 400 MB, and the browser was being asked
// to hold all of it before writing a byte. The sink writes straight to disk
// wherever the File System Access API exists, and the Blob is only the fallback
// - the same trade the prospect export already makes.
//
// It POSTs rather than builds a query string because a bulk-domain filter can
// carry thousands of values, which is more than a request line survives; the
// companies route accepts the identical query either way.
export async function runCompanyExport(options: CompanyExportOptions): Promise<ExportResult> {
  // The choice companies never had. A company CSV was two narrow columns, so
  // the direct path was always right; once Description became a checkbox it
  // stopped being right - every field over 419,218 companies is about 1.36 GB,
  // which no tab is going to assemble. Same thresholds as the prospect export,
  // priced with the company catalogue.
  const plan = planExport({
    bytesPerRow: estimatedCompanyBytesPerRow(options.customFieldNames, options.fields),
    rows: options.totalRows ?? null,
  });
  if (plan.mode === "background" && !options.peopleScope) {
    return runBackgroundExport({
      entityType: "company",
      requestId: options.requestId,
      clientScope: "",
      search: options.search,
      filters: withWebsiteFilter(options.filters, options.websitesOnly),
      fields: options.fields,
      fileBaseName: options.fileBaseName,
      signal: options.signal,
      onProgress: options.onProgress,
    }, plan);
  }

  const sink = await createSink(options, fileSystemAccessSupported());
  const response = await fetch("/api/companies", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: options.signal,
    body: JSON.stringify({
      export: "csv",
      search: options.search,
      filters: options.filters,
      peopleScope: options.peopleScope,
      website: options.websitesOnly ? "required" : "",
      fields: options.fields,
    }),
  });
  if (!response.ok) throw await csvStreamError(response, "Unable to export companies.");

  let exported = 0;
  await readCsvStream(response, {
    onHeader: (header) => sink.setHeader(header),
    onRows: async (text, rows) => {
      await sink.add(text, rows);
      exported += rows;
      options.onProgress?.({ exported, total: options.totalRows ?? undefined, files: 0, phase: "downloading" });
    },
  });
  const { files } = await sink.close();
  return { exported, files, canceled: Boolean(options.signal?.aborted), plan };
}

type ExportJobStatus = {
  jobId: string;
  status: string;
  rowCount: number;
  partCount: number;
  setStatus: string | null;
  setRows: number;
  fileBaseName: string;
  error?: string | null;
};

const pollFirstMs = 800;
const pollMaxMs = 5000;
const pollDeadlineMs = 30 * 60_000;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// The background path: freeze the list, let the worker write the file, then
// hand the browser a link to it.
//
// Handing over a link rather than streaming it into this tab is the point. The
// file already exists on the server, the link carries its own token, and the
// browser downloads it the way it downloads anything else - with its own
// progress, its own resume behaviour, and none of it in the JavaScript heap. It
// also survives the tab being closed, which a streamed download does not.
// What a background job is made of, for either kind of row. Narrower than
// ExportOptions because none of the sink or selection machinery reaches the
// worker: the job is a question, and the worker answers it server-side.
type BackgroundExportInput = {
  entityType: "prospect" | "company";
  requestId?: string;
  clientScope: string;
  search: string;
  filters: ProspectFilter[];
  // Prospects only. /api/exports answers 400 for a company export carrying one,
  // because a company scope over a set OF companies is not a narrowing.
  companyScope?: CompanyScope | null;
  fields: string[];
  excludedIds?: string[];
  fileBaseName: string;
  signal?: AbortSignal;
  onProgress?: (progress: ExportProgress) => void;
};

async function runBackgroundExport(options: BackgroundExportInput, plan: ExportPlan): Promise<ExportResult> {
  const requestId = options.requestId;
  if (!requestId) throw new Error("This export needs a request id before it can run in the background.");

  const queued = await fetch("/api/exports", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: options.signal,
    body: JSON.stringify({
      entityType: options.entityType,
      requestId,
      clientScope: options.clientScope,
      search: options.search,
      filters: options.filters,
      companyScope: options.entityType === "company" ? null : options.companyScope,
      fields: options.fields,
      excludedIds: options.excludedIds ?? [],
      fileBaseName: options.fileBaseName,
    }),
  });
  const job = await queued.json().catch(() => null) as { jobId?: string; token?: string; error?: string } | null;
  if (!queued.ok || !job?.jobId || !job.token) {
    throw new Error(job?.error || "That export could not be queued.");
  }

  const until = Date.now() + pollDeadlineMs;
  let delay = pollFirstMs;
  let settled: ExportJobStatus | null = null;
  for (;;) {
    if (options.signal?.aborted) return { exported: 0, files: 0, canceled: true, plan };
    const response = await fetch(`/api/exports?id=${encodeURIComponent(job.jobId)}`, { cache: "no-store", signal: options.signal });
    const status = await response.json().catch(() => null) as (ExportJobStatus & { error?: string }) | null;
    if (!response.ok || !status) throw new Error(status?.error || "That export could not be checked.");
    if (status.status === "failed") throw new Error(status.error || "That export failed. Try it again.");
    if (status.status === "ready") { settled = status; break; }

    // Before the file can be written the id list has to exist, so the honest
    // report while that happens is the list growing, not a file at zero rows.
    if (status.setStatus !== "ready") {
      options.onProgress?.({ exported: status.setRows, total: plan.rows ?? undefined, files: 0, phase: "listing" });
    } else {
      options.onProgress?.({ exported: status.rowCount, total: status.setRows, files: 0, phase: "writing" });
    }

    if (Date.now() > until) {
      throw new Error("This export is taking longer than expected. It is still being written - come back and it will be waiting.");
    }
    await sleep(delay);
    delay = Math.min(pollMaxMs, Math.round(delay * 1.5));
  }

  const link = document.createElement("a");
  link.href = `/api/exports/${encodeURIComponent(job.jobId)}/download?token=${encodeURIComponent(job.token)}`;
  link.download = `${settled.fileBaseName || options.fileBaseName}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();

  options.onProgress?.({ exported: settled.rowCount, total: settled.rowCount, files: 1, phase: "writing" });
  return { exported: settled.rowCount, files: 1, canceled: false, handedOff: true, plan };
}

export async function runProspectExport(options: ExportOptions): Promise<ExportResult> {
  if (options.mode === "selected") return runSelectedExport(options);

  const plan = planExport({
    customFieldNames: options.customFieldNames,
    requestedFields: options.fields,
    rows: options.totalRows ?? null,
  });
  if (plan.mode === "direct") return runDirectExport(options, plan);
  return runBackgroundExport({
    entityType: "prospect",
    requestId: options.requestId,
    clientScope: options.clientId ?? "",
    search: options.search,
    filters: options.filters,
    companyScope: options.companyScope,
    fields: options.fields,
    excludedIds: options.excludedIds,
    fileBaseName: options.fileBaseName,
    signal: options.signal,
    onProgress: options.onProgress,
  }, plan);
}

// What to tell someone whose export just went to the background, in their own
// terms rather than in thresholds.
export function backgroundExportNotice(plan: ExportPlan, format: ExportFormat) {
  const parts = format === "parts"
    ? " It arrives as one file rather than several - splitting only applies to downloads small enough to write from this tab."
    : "";
  return `${plan.reason} It is being written in the background; the download starts on its own when it is ready, and the link stays valid for 24 hours.${parts}`;
}
