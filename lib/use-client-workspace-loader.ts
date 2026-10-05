"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, isAbortError } from "./dashboard-api.ts";
import type { ClientRecord, ListRecord } from "./types.ts";

export type ClientWorkspaceLoadError = {
  kind: "client" | "lists" | "list";
  message: string;
};

export function useClientWorkspaceLoader(initialClientId: string, initialListId: string) {
  const [requestedClientId, setRequestedClientId] = useState(initialClientId);
  const [requestedListId, setRequestedListId] = useState(initialListId);
  const [selectedClient, setSelectedClient] = useState<ClientRecord | null>(null);
  const [selectedList, setSelectedList] = useState<ListRecord | null>(null);
  const [lists, setLists] = useState<ListRecord[]>([]);
  const [clientLoading, setClientLoading] = useState(Boolean(initialClientId));
  const [listLoading, setListLoading] = useState(Boolean(initialClientId && initialListId));
  const [listsLoading, setListsLoading] = useState(Boolean(initialClientId));
  const [loadError, setLoadError] = useState<ClientWorkspaceLoadError | null>(null);
  const [initialResolutionComplete, setInitialResolutionComplete] = useState(!initialClientId);
  const [revision, setRevision] = useState(0);
  const generation = useRef(0);
  const activeController = useRef<AbortController | null>(null);
  const intent = useRef({ clientId: initialClientId, listId: initialListId });
  const knownClient = useRef<ClientRecord | null>(null);
  const knownList = useRef<ListRecord | null>(null);

  const invalidate = useCallback(() => {
    generation.current += 1;
    activeController.current?.abort();
    activeController.current = null;
  }, []);

  const request = useCallback((clientId: string, listId = "", client?: ClientRecord | null, list?: ListRecord | null) => {
    invalidate();
    intent.current = { clientId, listId: clientId ? listId : "" };
    if (!clientId) {
      knownClient.current = null;
      knownList.current = null;
      setRequestedClientId("");
      setRequestedListId("");
      setSelectedClient(null);
      setSelectedList(null);
      setLists([]);
      setClientLoading(false);
      setListLoading(false);
      setListsLoading(false);
      setLoadError(null);
      setInitialResolutionComplete(true);
      setRevision((value) => value + 1);
      return;
    }
    knownClient.current = client?.id === clientId ? client : null;
    knownList.current = listId && list?.id === listId ? list : null;
    setSelectedClient(knownClient.current);
    setSelectedList(knownList.current);
    setLists([]);
    setClientLoading(!knownClient.current);
    setListLoading(Boolean(listId && !knownList.current));
    setListsLoading(true);
    setLoadError(null);
    setRequestedClientId(clientId);
    setRequestedListId(listId);
    setRevision((value) => value + 1);
  }, [invalidate]);

  const closeList = useCallback(() => {
    invalidate();
    intent.current = { clientId: intent.current.clientId, listId: "" };
    knownClient.current = selectedClient;
    knownList.current = null;
    setRequestedListId("");
    setSelectedList(null);
    setListLoading(false);
    setLoadError(null);
    setRevision((value) => value + 1);
  }, [invalidate, selectedClient]);

  const closeClient = useCallback(() => {
    invalidate();
    intent.current = { clientId: "", listId: "" };
    knownClient.current = null;
    knownList.current = null;
    setRequestedClientId("");
    setRequestedListId("");
    setSelectedClient(null);
    setSelectedList(null);
    setLists([]);
    setClientLoading(false);
    setListLoading(false);
    setListsLoading(false);
    setLoadError(null);
    setInitialResolutionComplete(true);
    setRevision((value) => value + 1);
  }, [invalidate]);

  const isCurrent = useCallback((clientId: string, listId?: string) =>
    intent.current.clientId === clientId && (listId === undefined || intent.current.listId === listId), []);

  useEffect(() => {
    const currentGeneration = ++generation.current;
    const controller = new AbortController();
    activeController.current = controller;
    const current = () => generation.current === currentGeneration && !controller.signal.aborted;

    if (!requestedClientId) {
      return () => {
        controller.abort();
        if (activeController.current === controller) activeController.current = null;
      };
    }

    const reusableClient = knownClient.current?.id === requestedClientId ? knownClient.current : null;
    const reusableList = requestedListId && knownList.current?.id === requestedListId ? knownList.current : null;
    knownClient.current = null;
    knownList.current = null;
    const clientTask = reusableClient
      ? Promise.resolve(reusableClient)
      : api<{ client: ClientRecord }>(`/api/clients/${encodeURIComponent(requestedClientId)}`, {
          cache: "no-store",
          signal: controller.signal,
        }).then((data) => data.client);
    void clientTask.then((client) => {
      if (current()) setSelectedClient(client);
    }).catch((caught) => {
      if (current() && !isAbortError(caught)) {
        setSelectedClient(null);
        setLoadError({ kind: "client", message: caught instanceof Error ? caught.message : "Unable to open this client." });
      }
    }).finally(() => {
      if (current()) setClientLoading(false);
    });

    const listsTask = api<{ lists: ListRecord[] }>(`/api/lists?clientId=${encodeURIComponent(requestedClientId)}`, {
      cache: "no-store",
      signal: controller.signal,
    });
    void listsTask.then((data) => {
      if (current()) setLists(data.lists ?? []);
    }).catch((caught) => {
      if (current() && !isAbortError(caught)) {
        setLoadError((existing) => existing ?? {
          kind: "lists",
          message: caught instanceof Error ? caught.message : "Unable to load this client's lists.",
        });
      }
    }).finally(() => {
      if (current()) setListsLoading(false);
    });

    const listTask = !requestedListId || reusableList
      ? Promise.resolve(reusableList)
      : api<{ list: ListRecord }>(`/api/lists/${encodeURIComponent(requestedListId)}?clientId=${encodeURIComponent(requestedClientId)}`, {
          cache: "no-store",
          signal: controller.signal,
        }).then((data) => data.list);
    void listTask.then((list) => {
      if (current()) setSelectedList(list);
    }).catch((caught) => {
      if (current() && !isAbortError(caught)) {
        setSelectedList(null);
        setLoadError((existing) => existing?.kind === "client" ? existing : {
          kind: "list",
          message: caught instanceof Error ? caught.message : "Unable to open this list for this client.",
        });
      }
    }).finally(() => {
      if (current()) setListLoading(false);
    });

    void Promise.allSettled([clientTask, listsTask, listTask]).finally(() => {
      if (current()) setInitialResolutionComplete(true);
    });

    return () => {
      controller.abort();
      if (activeController.current === controller) activeController.current = null;
    };
  }, [requestedClientId, requestedListId, revision]);

  return {
    requestedClientId,
    requestedListId,
    selectedClient,
    selectedList,
    lists,
    clientLoading,
    listLoading,
    listsLoading,
    loadError,
    initialResolutionComplete,
    request,
    closeList,
    closeClient,
    isCurrent,
    setSelectedClient,
    setLists,
  };
}
