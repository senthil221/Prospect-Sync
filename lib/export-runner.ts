import { buildExportColumns, csvHeaderLine, csvRowsBody, type ProspectRow } from "./prospect-export";
import type { ProspectFilter } from "./prospect-filters";

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

export type ExportOptions = {
  search: string;
  filters: ProspectFilter[];
  clientId: string | null;
  fields: string[];               // requested export field ids
  customFieldNames: string[];     // available uploaded field names (for custom columns)
  mode: ExportMode;
  selectedRows?: ProspectRow[];   // full row objects when mode === "selected"
  excludedIds?: string[];         // ids to drop when mode === "all_matching"
  format: ExportFormat;
  rowsPerFile: number;            // parts mode
  fileBaseName: string;
  signal?: AbortSignal;
  onProgress?: (progress: { exported: number; total?: number; files: number }) => void;
};

export type ExportResult = { exported: number; files: number; canceled: boolean };

const requestPageSize = 25000;

// Pull keyset pages from the export endpoint until exhausted.
async function* streamMatchingPages(options: ExportOptions, pageSize: number): AsyncGenerator<{ header: string; rows: string; count: number; total?: number }> {
  let cursor: { createdAt: string; id: string } | null = null;
  let withTotal = true;
  for (;;) {
    if (options.signal?.aborted) return;
    const response = await fetch("/api/prospects/export", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: options.signal,
      body: JSON.stringify({
        search: options.search,
        filters: options.filters,
        clientId: options.clientId,
        fields: options.fields,
        excludedIds: options.excludedIds ?? [],
        cursor,
        limit: pageSize,
        withTotal,
      }),
    });
    const data = await response.json() as { header: string; rows: string; count: number; nextCursor: { createdAt: string; id: string } | null; done: boolean; total?: number; error?: string };
    if (!response.ok) throw new Error(data.error || "Export failed.");
    yield { header: data.header, rows: data.rows, count: data.count, total: data.total };
    if (data.done) return;
    cursor = data.nextCursor;
    withTotal = false;
  }
}

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

// mode "selected": rows already in memory — no server round-trips.
function selectedContent(options: ExportOptions) {
  const columns = buildExportColumns(options.customFieldNames, options.fields);
  const header = csvHeaderLine(columns);
  const rows = options.selectedRows ?? [];
  return { header, rows, columns };
}

export async function runProspectExport(options: ExportOptions): Promise<ExportResult> {
  const canFs = fileSystemAccessSupported();
  const single = options.format === "single";
  const rowsPerFile = Math.max(1000, options.rowsPerFile || 25000);

  // ---- Selected rows: build entirely client-side. ----
  if (options.mode === "selected") {
    const { header, rows, columns } = selectedContent(options);
    if (single) {
      const text = BOM + header + CRLF + csvRowsBody(rows, columns);
      if (canFs) {
        const handle = await fsApi().showSaveFilePicker!({ suggestedName: `${options.fileBaseName}.csv`, types: csvPickerTypes });
        await writeToHandle(handle, text);
      } else {
        downloadBlob(`${options.fileBaseName}.csv`, text);
      }
      options.onProgress?.({ exported: rows.length, total: rows.length, files: 1 });
      return { exported: rows.length, files: 1, canceled: false };
    }
    // parts
    const directory = canFs ? await fsApi().showDirectoryPicker!({ mode: "readwrite" }) : null;
    let files = 0;
    for (let start = 0; start < rows.length; start += rowsPerFile) {
      files += 1;
      const slice = rows.slice(start, start + rowsPerFile);
      const text = BOM + header + CRLF + csvRowsBody(slice, columns);
      if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, files), { create: true }), text);
      else downloadBlob(partName(options.fileBaseName, files), text);
      options.onProgress?.({ exported: Math.min(start + rowsPerFile, rows.length), total: rows.length, files });
    }
    return { exported: rows.length, files: Math.max(files, 0), canceled: false };
  }

  // ---- All matching: stream keyset pages to disk. ----
  if (single) {
    const pageSize = requestPageSize;
    let writable: WritableLike | null = null;
    let fallbackBuffer = "";
    let headerWritten = false;
    let exported = 0;
    let total: number | undefined;

    if (canFs) {
      const handle = await fsApi().showSaveFilePicker!({ suggestedName: `${options.fileBaseName}.csv`, types: csvPickerTypes });
      writable = await handle.createWritable();
    }
    try {
      for await (const chunk of streamMatchingPages(options, pageSize)) {
        total = chunk.total ?? total;
        const piece = (headerWritten ? "" : BOM + chunk.header + CRLF) + (chunk.rows ? (headerWritten ? CRLF : "") + chunk.rows : "");
        headerWritten = true;
        if (writable) await writable.write(piece);
        else fallbackBuffer += piece;
        exported += chunk.count;
        options.onProgress?.({ exported, total, files: 1 });
      }
    } finally {
      if (writable) await writable.close();
    }
    if (options.signal?.aborted) return { exported, files: writable ? 1 : 0, canceled: true };
    if (!writable) downloadBlob(`${options.fileBaseName}.csv`, fallbackBuffer);
    return { exported, files: 1, canceled: false };
  }

  // parts (all matching): accumulate pages until each file reaches rowsPerFile.
  const pageSize = Math.min(rowsPerFile, requestPageSize);
  const directory = canFs ? await fsApi().showDirectoryPicker!({ mode: "readwrite" }) : null;
  let header = "";
  let bucket: string[] = [];
  let bucketCount = 0;
  let files = 0;
  let exported = 0;
  let total: number | undefined;

  const flush = async () => {
    if (!bucketCount) return;
    files += 1;
    const text = BOM + header + CRLF + bucket.join(CRLF);
    if (directory) await writeToHandle(await directory.getFileHandle(partName(options.fileBaseName, files), { create: true }), text);
    else downloadBlob(partName(options.fileBaseName, files), text);
    bucket = [];
    bucketCount = 0;
  };

  for await (const chunk of streamMatchingPages(options, pageSize)) {
    total = chunk.total ?? total;
    header = header || chunk.header;
    if (chunk.rows) bucket.push(chunk.rows);
    bucketCount += chunk.count;
    exported += chunk.count;
    options.onProgress?.({ exported, total, files });
    if (bucketCount >= rowsPerFile) await flush();
  }
  await flush();
  if (options.signal?.aborted) return { exported, files, canceled: true };
  return { exported, files, canceled: false };
}
