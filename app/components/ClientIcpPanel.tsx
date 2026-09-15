"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import type { ClientIcpProfile, ClientRecord } from "../../lib/types";
import { AppIcon, EmptyCompact } from "./DashboardUi";

// Where a client's ICP briefs live.
//
// Several per client, not one: an agency routinely runs "UK mid-market SaaS"
// and "US enterprise fintech" for the same client, and those are two different
// briefs. Each has a name and a pasted description.
//
// Saving is explicit rather than on every keystroke. These are long pasted
// documents, and autosaving one would mean a PATCH per character and no way to
// abandon an edit. The dirty marker is what makes an unsaved change visible.
const maxDescription = 20_000;

export default function ClientIcpPanel({ client }: { client: ClientRecord }) {
  const [profiles, setProfiles] = useState<ClientIcpProfile[]>([]);
  const [drafts, setDrafts] = useState<Record<string, { name: string; description: string }>>({});
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

  function draftFor(profile: ClientIcpProfile) {
    return drafts[profile.id] ?? { name: profile.name, description: profile.description };
  }

  function isDirty(profile: ClientIcpProfile) {
    const draft = draftFor(profile);
    return draft.name !== profile.name || draft.description !== profile.description;
  }

  function editDraft(id: string, patch: Partial<{ name: string; description: string }>) {
    setDrafts((current) => ({ ...current, [id]: { ...(current[id] ?? { name: "", description: "" }), ...patch } }));
  }

  async function addProfile() {
    setBusyId("new"); setError(""); setNotice("");
    try {
      const result = await api<{ profile: ClientIcpProfile }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "", description: "" }),
      });
      setProfiles((current) => [...current, result.profile]);
      setDrafts((current) => ({ ...current, [result.profile.id]: { name: "", description: "" } }));
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
      setProfiles((current) => current.map((item) => item.id === profile.id ? result.profile : item));
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
      setProfiles((current) => current.filter((item) => item.id !== pendingDelete.id));
      setPendingDelete(null);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to delete this ICP."); }
    finally { setBusyId(""); }
  }

  return <article className="panel client-icp-panel">
    <div className="panel-head">
      <div>
        <h3>Ideal customer profiles</h3>
        <p>Paste the targeting brief for each ICP you run for {client.name}. These are notes for your team - they do not filter anything on their own.</p>
      </div>
      <button className="primary" disabled={Boolean(busyId) || loading} onClick={() => void addProfile()}>
        <AppIcon name="plus" size={15}/> Add ICP
      </button>
    </div>

    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {notice ? <div className="inline-notice" role="status">{notice}</div> : null}

    {loading
      ? <div className="workspace-loading">Loading ICPs…</div>
      : profiles.length
        ? <div className="client-icp-list">{profiles.map((profile) => {
            const draft = draftFor(profile);
            const dirty = isDirty(profile);
            const over = draft.description.length > maxDescription;
            return <section className="client-icp-card" key={profile.id}>
              <div className="form-field">
                <label htmlFor={`icp-name-${profile.id}`}>ICP name</label>
                <input id={`icp-name-${profile.id}`} value={draft.name} maxLength={120}
                  placeholder="e.g. UK mid-market SaaS"
                  onChange={(event) => editDraft(profile.id, { name: event.target.value })}/>
              </div>
              <div className="form-field">
                <label htmlFor={`icp-description-${profile.id}`}>Description</label>
                <textarea id={`icp-description-${profile.id}`} rows={8} value={draft.description}
                  placeholder="Paste the ICP brief - industries, size, geography, titles, exclusions."
                  onChange={(event) => editDraft(profile.id, { description: event.target.value })}/>
                <small className={over ? "form-error" : undefined}>
                  {draft.description.length.toLocaleString()} of {maxDescription.toLocaleString()} characters
                  {over ? " - too long to save" : ""}
                </small>
              </div>
              <div className="client-icp-actions">
                <button className="row-danger" disabled={busyId === profile.id} onClick={() => setPendingDelete(profile)}>Delete</button>
                <span className="client-icp-state">{dirty ? "Unsaved changes" : "Saved"}</span>
                <button className="secondary" disabled={!dirty || over || busyId === profile.id} onClick={() => void saveProfile(profile)}>
                  {busyId === profile.id ? "Saving…" : "Save"}
                </button>
              </div>
            </section>;
          })}</div>
        : <EmptyCompact text={`No ICPs are recorded for ${client.name} yet.`} action="Add ICP" onAction={() => void addProfile()} />}

    {pendingDelete ? <div className="modal-backdrop" role="presentation">
      <section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="icp-delete-title">
        <span className="warning-mark">!</span>
        <p className="eyebrow">PERMANENT ACTION</p>
        <h2 id="icp-delete-title">Delete this ICP?</h2>
        <p>The name and its description are removed. Nothing that has been tagged with it is untagged, and no prospects or companies are affected.</p>
        <div className="delete-target"><strong>{pendingDelete.name || "Untitled ICP"}</strong><span>{pendingDelete.description.length.toLocaleString()} characters</span></div>
        <div className="modal-actions">
          <button className="secondary" data-autofocus disabled={Boolean(busyId)} onClick={() => setPendingDelete(null)}>Keep ICP</button>
          <button className="danger-button solid" disabled={Boolean(busyId)} onClick={() => void confirmDelete()}>Delete ICP</button>
        </div>
      </section>
    </div> : null}
  </article>;
}
