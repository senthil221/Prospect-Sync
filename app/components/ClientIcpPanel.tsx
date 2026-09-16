"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientIcpProfile, ClientRecord } from "../../lib/types";
import { AppIcon, EmptyCompact } from "./DashboardUi";

// Where a client's ICP briefs live.
//
// Several per client, not one: an agency routinely runs "UK mid-market SaaS"
// and "US enterprise fintech" for the same client, and those are two different
// briefs. Each has a name and a pasted description.
//
// A LIST AND ONE EDITOR, NOT A STACK OF CARDS. The screen used to render every
// ICP as a card with a 160px textarea in it, so five briefs meant a page metres
// long, no way to see the set at a glance, and five equally-loud Save buttons.
// The rail answers "what are we running, and is any of it being used"; the pane
// answers "what does this one say". Only one brief is editable at a time, which
// is also why there is only ever one unsaved draft to lose.
//
// Saving is explicit rather than on every keystroke. These are long pasted
// documents, and autosaving one would mean a PATCH per character and no way to
// abandon an edit. The dirty marker is what makes an unsaved change visible.
const maxDescription = 20_000;

function icpLabel(profile: ClientIcpProfile) {
  return profile.name.trim() || "Untitled ICP";
}

export default function ClientIcpPanel({ client }: { client: ClientRecord }) {
  const [profiles, setProfiles] = useState<ClientIcpProfile[]>([]);
  const [drafts, setDrafts] = useState<Record<string, { name: string; description: string }>>({});
  const [selectedId, setSelectedId] = useState("");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [pendingDelete, setPendingDelete] = useState<ClientIcpProfile | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const result = await api<{ profiles: ClientIcpProfile[] }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, { cache: "no-store" });
      setProfiles(result.profiles);
      setDrafts(Object.fromEntries(result.profiles.map((profile) => [profile.id, { name: profile.name, description: profile.description }])));
      // Keep whatever was open across a reload; otherwise open the first one so
      // the pane is never an empty frame beside a populated list.
      setSelectedId((current) => result.profiles.some((profile) => profile.id === current) ? current : result.profiles[0]?.id ?? "");
      setError("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load ICPs."); }
    finally { setLoading(false); }
  }, [client.id]);

  // Deferred rather than called in the effect body: load() sets loading state
  // synchronously, which inside an effect is a cascading render. Same shape as
  // BlocklistPanel's loader.
  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  const draftFor = useCallback((profile: ClientIcpProfile) => {
    return drafts[profile.id] ?? { name: profile.name, description: profile.description };
  }, [drafts]);

  const isDirty = useCallback((profile: ClientIcpProfile) => {
    const draft = draftFor(profile);
    return draft.name !== profile.name || draft.description !== profile.description;
  }, [draftFor]);

  function editDraft(id: string, patch: Partial<{ name: string; description: string }>) {
    setDrafts((current) => ({ ...current, [id]: { ...(current[id] ?? { name: "", description: "" }), ...patch } }));
  }

  const selected = useMemo(() => profiles.find((profile) => profile.id === selectedId) ?? null, [profiles, selectedId]);

  async function addProfile() {
    setBusyId("new"); setError(""); setNotice("");
    try {
      const result = await api<{ profile: ClientIcpProfile }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "", description: "" }),
      });
      setProfiles((current) => [...current, result.profile]);
      setDrafts((current) => ({ ...current, [result.profile.id]: { name: "", description: "" } }));
      // Opened straight away: a new ICP is created empty, so the only useful
      // next action is to name it.
      setSelectedId(result.profile.id);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to add an ICP."); }
    finally { setBusyId(""); }
  }

  async function saveProfile(profile: ClientIcpProfile) {
    const draft = draftFor(profile);
    setBusyId(profile.id); setError(""); setNotice("");
    try {
      const result = await api<{ profile: ClientIcpProfile }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, {
        method: "PATCH", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: profile.id, name: draft.name, description: draft.description }),
      });
      // The PATCH answers without counts; keeping the ones already loaded stops
      // a save from blanking the usage figures beside the name.
      setProfiles((current) => current.map((item) => item.id === profile.id
        ? { ...result.profile, prospect_count: item.prospect_count, company_count: item.company_count }
        : item));
      setNotice(`Saved ${result.profile.name || "this ICP"}.`);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to save this ICP."); }
    finally { setBusyId(""); }
  }

  async function confirmDelete() {
    if (!pendingDelete) return;
    setBusyId(pendingDelete.id); setError(""); setNotice("");
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}/icp`, {
        method: "DELETE", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: pendingDelete.id }),
      });
      const remaining = profiles.filter((item) => item.id !== pendingDelete.id);
      setProfiles(remaining);
      if (selectedId === pendingDelete.id) setSelectedId(remaining[0]?.id ?? "");
      setPendingDelete(null);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to delete this ICP."); }
    finally { setBusyId(""); }
  }

  const draft = selected ? draftFor(selected) : null;
  const dirty = selected ? isDirty(selected) : false;
  const over = (draft?.description.length ?? 0) > maxDescription;

  return <article className="panel client-icp-panel">
    <div className="panel-head">
      <div>
        <p className="eyebrow">TARGETING</p>
        <h3>Ideal customer profiles</h3>
        <p>The briefs you run for {client.name}. Naming one creates the ICP tag you apply to prospects and companies, and the ICP picker beside the tabs filters by it.</p>
      </div>
      <button className="primary" disabled={Boolean(busyId) || loading} onClick={() => void addProfile()}>
        <AppIcon name="plus" size={15}/> New ICP
      </button>
    </div>

    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {notice ? <div className="inline-notice" role="status">{notice}</div> : null}

    {loading
      ? <div className="workspace-loading">Loading ICPs…</div>
      : profiles.length
        ? <div className="icp-workbench">
            <nav className="icp-rail" aria-label={`${client.name} ICPs`}>
              <p className="icp-rail-head">{profiles.length} ICP{profiles.length === 1 ? "" : "s"}</p>
              <ul>{profiles.map((profile) => {
                const unsaved = isDirty(profile);
                return <li key={profile.id}>
                  <button type="button" className={profile.id === selectedId ? "is-selected" : ""}
                    aria-current={profile.id === selectedId ? "true" : undefined}
                    onClick={() => setSelectedId(profile.id)}>
                    <span className="icp-rail-name">
                      {icpLabel(profile)}
                      {unsaved ? <i className="icp-unsaved-dot" title="Unsaved changes" aria-label="Unsaved changes"/> : null}
                    </span>
                    {/* "Not counted" and "counted nothing" are different answers,
                        so a null count shows nothing rather than a zero. */}
                    <span className="icp-rail-meta">{profile.tag_id
                      ? profile.prospect_count == null
                        ? "Tag ready"
                        : <>{formatNumber(profile.prospect_count)} {profile.prospect_count === 1 ? "prospect" : "prospects"}
                          {profile.company_count ? <> · {formatNumber(profile.company_count)} {profile.company_count === 1 ? "company" : "companies"}</> : null}</>
                      : "Unnamed - no tag yet"}</span>
                  </button>
                </li>;
              })}</ul>
            </nav>

            {selected && draft ? <section className="icp-detail" aria-label={`${icpLabel(selected)} brief`}>
              <div className="icp-detail-head">
                <div className="form-field">
                  <label htmlFor={`icp-name-${selected.id}`}>ICP name</label>
                  <input id={`icp-name-${selected.id}`} value={draft.name} maxLength={120}
                    placeholder="e.g. UK mid-market SaaS"
                    onChange={(event) => editDraft(selected.id, { name: event.target.value })}/>
                </div>
                {/* The tag is created by naming the ICP, and renaming the ICP
                    renames it. Saying so here is the only place the two are
                    visibly one thing. */}
                <span className={`client-icp-tag${selected.tag_id ? " is-live" : ""}`}>{selected.tag_id
                  ? <><AppIcon name="tag" size={12}/> Applied as &ldquo;{selected.name}&rdquo;</>
                  : <>Name this ICP to tag prospects and companies with it</>}</span>
              </div>

              <div className="form-field icp-brief">
                <label htmlFor={`icp-description-${selected.id}`}>Targeting brief</label>
                <textarea id={`icp-description-${selected.id}`} value={draft.description}
                  placeholder="Paste the ICP brief - industries, size, geography, titles, exclusions."
                  onChange={(event) => editDraft(selected.id, { description: event.target.value })}/>
                <small className={over ? "form-error" : undefined}>
                  {draft.description.length.toLocaleString()} of {maxDescription.toLocaleString()} characters
                  {over ? " - too long to save" : ""}
                </small>
              </div>

              <div className="icp-detail-foot">
                <button className="row-danger" disabled={busyId === selected.id} onClick={() => setPendingDelete(selected)}>Delete</button>
                <span className="client-icp-state" role="status">{dirty ? "Unsaved changes" : "Saved"}</span>
                <button className="primary" disabled={!dirty || over || busyId === selected.id} onClick={() => void saveProfile(selected)}>
                  {busyId === selected.id ? "Saving…" : "Save ICP"}
                </button>
              </div>
            </section> : null}
          </div>
        : <EmptyCompact text={`No ICPs are recorded for ${client.name} yet.`} action="New ICP" onAction={() => void addProfile()} />}

    {pendingDelete ? <div className="modal-backdrop" role="presentation">
      <section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="icp-delete-title">
        <span className="warning-mark">!</span>
        <p className="eyebrow">PERMANENT ACTION</p>
        <h2 id="icp-delete-title">Delete this ICP?</h2>
        <p>The name and its description are removed. Nothing that has been tagged with it is untagged, and no prospects or companies are affected.</p>
        <div className="delete-target"><strong>{icpLabel(pendingDelete)}</strong><span>{pendingDelete.description.length.toLocaleString()} characters</span></div>
        <div className="modal-actions">
          <button className="secondary" data-autofocus disabled={Boolean(busyId)} onClick={() => setPendingDelete(null)}>Keep ICP</button>
          <button className="danger-button solid" disabled={Boolean(busyId)} onClick={() => void confirmDelete()}>Delete ICP</button>
        </div>
      </section>
    </div> : null}
  </article>;
}
