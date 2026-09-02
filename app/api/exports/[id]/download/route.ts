import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth";
import { companyExportColumns } from "../../../../../lib/company-export";
import { buildExportColumns, csvHeaderLine, csvRowsBody, type ExportColumn, type ProspectRow } from "../../../../../lib/prospect-export";
import { ownerIdentity } from "../../../../../lib/result-sets";
import { createAdminClient } from "../../../../../lib/supabase/admin";

export const runtime = "nodejs";
export const maxDuration = 300;

// Collect a finished background export.
//
// The worker stored rows, not CSV. That is what keeps a single renderer in the
// product: this route runs the same lib/prospect-export.ts columns the direct
// download runs, so a file that was too big to stream is byte-for-byte the file
// a smaller one would have been. Rendering here also means the expensive half -
// the filtered scan over 1.5 M rows - was paid once, in the background, and
// what is left is string work over rows that are already chosen and ordered.
//
// It is still a stream. Parts are fetched one at a time and dropped as soon as
// they are written, so a 250,000-row file passes through this process a few
// megabytes at a time and never sits in it whole.

const BOM = "﻿";
const CRLF = "\r\n";

type StatusRow = {
  status?: string;
  part_count?: number;
  row_count?: number;
  entity_type?: string;
  file_base_name?: string;
  fields?: string[] | null;
  download_token?: string;
  error?: string | null;
};

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const owner = ownerIdentity(await getAuthorizedUser());
  if (!owner) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const { id } = await context.params;
  const jobId = String(id ?? "").trim();
  const token = (new URL(request.url).searchParams.get("token") ?? "").trim();
  if (!jobId || !token) return Response.json({ error: "That download link is not valid." }, { status: 400 });

  const supabase = createAdminClient();
  const status = await supabase.rpc("export_status_v1", { p_job_id: jobId, p_owner_id: owner });
  if (status.error) {
    if (status.error.code === "P0002") return Response.json({ error: "That export is no longer available." }, { status: 404 });
    return Response.json({ error: status.error.message }, { status: 500 });
  }
  const job = (Array.isArray(status.data) ? status.data[0] : status.data) as StatusRow | null;
  if (!job) return Response.json({ error: "That export is no longer available." }, { status: 404 });
  // part_v1 checks the token too, but a refusal from inside the stream can only
  // be a truncated file. Checking here means a bad link is a 403 with a message.
  if (job.download_token !== token) return Response.json({ error: "That download link is not valid." }, { status: 403 });
  if (job.status === "failed") {
    return Response.json({ error: job.error || "That export failed. Ask for it again." }, { status: 409 });
  }
  if (job.status !== "ready") {
    return Response.json({ error: "That export is not finished yet." }, { status: 409 });
  }

  // UNLOGGED storage means a database crash empties job_parts while the job
  // still says 'ready'. Serving that would be a file quietly missing rows,
  // which is worse than no file at all.
  const present = await supabase.rpc("export_parts_present_v1", { p_job_id: jobId });
  if (present.error) return Response.json({ error: present.error.message }, { status: 500 });
  if (present.data !== true) {
    return Response.json({
      error: "This export's rows are no longer stored - the database restarted since it was written. Ask for the export again.",
    }, { status: 410 });
  }

  let columns: ExportColumn[];
  if (job.entity_type === "company") {
    columns = companyExportColumns;
  } else {
    const fieldRows = await supabase.from("prospect_fields").select("field_name").order("field_name").limit(500);
    if (fieldRows.error) return Response.json({ error: fieldRows.error.message }, { status: 500 });
    const customFieldNames = (fieldRows.data ?? []).map((field) => String(field.field_name ?? "")).filter(Boolean);
    const fields = Array.isArray(job.fields) ? job.fields.map((field) => String(field)) : [];
    columns = buildExportColumns(customFieldNames, fields.length ? fields : undefined);
  }
  if (!columns.length) return Response.json({ error: "That export has no columns." }, { status: 500 });

  const parts = Math.max(0, Number(job.part_count ?? 0));
  const fileBaseName = String(job.file_base_name ?? "export").replace(/[^a-zA-Z0-9._-]+/g, "-") || "export";

  let nextPart = 1;
  let written = 0;
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (nextPart > parts) {
        // An export with no rows is still a valid file: one header line.
        if (written === 0) controller.enqueue(encoder.encode(BOM + csvHeaderLine(columns) + CRLF));
        controller.close();
        return;
      }
      const part = await supabase.rpc("export_part_v1", {
        p_job_id: jobId, p_owner_id: owner, p_token: token, p_part_index: nextPart,
      });
      if (part.error) throw new Error(part.error.message);
      const row = Array.isArray(part.data) ? part.data[0] : part.data;
      const rows = Array.isArray(row?.rows) ? row.rows as ProspectRow[] : [];
      nextPart += 1;

      const head = written === 0 ? BOM + csvHeaderLine(columns) + CRLF : "";
      const body = rows.length ? (written === 0 ? "" : CRLF) + csvRowsBody(rows, columns) : "";
      written += rows.length;
      if (head || body) controller.enqueue(encoder.encode(head + body));
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${fileBaseName}.csv"`,
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    },
  });
}
