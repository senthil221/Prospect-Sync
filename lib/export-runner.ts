import { csvStreamError, readCsvStream } from "./csv-download.ts";
import { planExport, type ExportPlan } from "./export-plan.ts";
import { buildExportColumns, csvHeaderLine, csvRowsBody, type ProspectRow } from "./prospect-export.ts";
import type { ProspectFilter } from "./prospect-filters.ts";
import type { CompanyScope } from "./workspace-scopes.ts";

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

async function writeToHandle(handle: FileHandleLike, text: string) {
  const writable = await handle.createWritable();
  await writable.write(text);
  await writable.close();
}

function downloadBlob(name: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
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

async function createSink(options: ExportOptions, canFs: boolean): Promise<Sink> {
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
    let buffered = "";
    let started = false;
    const emit = async (text: string) => {
      if (writable) await writable.write(text);
      else buffered += text;
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
    const text = header + CRLF + bucket.join(CRLF);
    if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, files), { create: true }), text);
    else downloadBlob(partName(options.fileBaseName, files), text);
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
        if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, 1), { create: true }), header + CRLF);
        else downloadBlob(partName(options.fileBaseName, 1), header + CRLF);
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
async function runBackgroundExport(options: ExportOptions, plan: ExportPlan): Promise<ExportResult> {
  const requestId = options.requestId;
  if (!requestId) throw new Error("This export needs a request id before it can run in the background.");

  const queued = await fetch("/api/exports", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: options.signal,
    body: JSON.stringify({
      entityType: "prospect",
      requestId,
      clientScope: options.clientId ?? "",
      search: options.search,
      filters: options.filters,
      companyScope: options.companyScope,
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
  return runBackgroundExport(options, plan);
}

// What to tell someone whose export just went to the background, in their own
// terms rather than in thresholds.
export function backgroundExportNotice(plan: ExportPlan, format: ExportFormat) {
  const parts = format === "parts"
    ? " It arrives as one file rather than several - splitting only applies to downloads small enough to write from this tab."
    : "";
  return `${plan.reason} It is being written in the background; the download starts on its own when it is ready, and the link stays valid for 24 hours.${parts}`;
}
