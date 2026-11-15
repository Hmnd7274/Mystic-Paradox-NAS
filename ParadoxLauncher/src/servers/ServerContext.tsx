import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { acknowledgeLocalServer, getAuthCapabilities, getOfficialPlay, listServers, selectServer, type ServerView } from "../api/tauri";
import type { LauncherAuthCapabilities, OfficialPlay } from "../api/types";
import { LocalServerWarning } from "../components/LocalServerWarning";

// [2026-10-13 realms S5] The selected server, as the whole UI sees it. Sign-in, the session, the policy and the status
// chip all follow it; the launcher's native side resolves the same selection and refuses a call that names another.

/** [2026-10-15] How often the official server's play switch is read again. */
const OFFICIAL_PLAY_POLL_MS = 60_000;

const DEFAULT_AUTH_CAPABILITIES: LauncherAuthCapabilities = {
  usernameAuthentication: false,
  emailRequired: true,
  emailVerificationRequired: false,
};

export interface ServerState {
  /** The server list has been read (if it could not be, the official server is assumed). */
  ready: boolean;
  servers: ServerView[];
  selected: ServerView | null;
  /** The selected server's id; `undefined` while it is unknown (the native side then uses its own selection). */
  serverId: string | undefined;
  /** The selected server is local and its warning has not been accepted: nothing may be sent to it yet. */
  needsAck: boolean;
  /** Authentication options reported by the selected server, not inferred from its server kind. */
  authCapabilities: LauncherAuthCapabilities;
  authCapabilitiesReady: boolean;
  /** The official backend and sign-in serve the selected server (the official server and Paradox realms). */
  officialNetwork: boolean;
  /**
   * [2026-10-15] The official server's play switch, read from its own status whichever server is selected (the server
   * list shows it while another is chosen). Null until it is read, or when it cannot be read: no note is shown then.
   */
  officialPlay: OfficialPlay | null;
  /** Replaces the list with a fresher one returned by a server command. */
  sync: (next: ServerView[]) => void;
  /** Selects a server. Rejects with a readable message (for example while a game runs). */
  select: (serverId: string) => Promise<void>;
  /** Shows a local server's warning popup (the red badge). */
  openWarning: (serverId: string) => void;
}

const IDLE: ServerState = {
  ready: true,
  servers: [],
  selected: null,
  serverId: undefined,
  needsAck: false,
  authCapabilities: DEFAULT_AUTH_CAPABILITIES,
  authCapabilitiesReady: false,
  officialNetwork: true,
  officialPlay: null,
  sync: () => {},
  select: async () => {},
  openWarning: () => {},
};

const ServerContext = createContext<ServerState>(IDLE);

export function useServer(): ServerState {
  return useContext(ServerContext);
}

export function ServerProvider({ children }: { children: ReactNode }) {
  const [list, setList] = useState<{ ready: boolean; servers: ServerView[] }>({ ready: false, servers: [] });
  const [warningFor, setWarningFor] = useState<string | null>(null);
  const movedFromLocalRef = useRef(false);

  const sync = useCallback((next: ServerView[]) => setList({ ready: true, servers: next }), []);

  useEffect(() => {
    let cancelled = false;
    listServers()
      .then((servers) => { if (!cancelled) setList({ ready: true, servers }); })
      .catch(() => { if (!cancelled) setList({ ready: true, servers: [] }); });
    return () => { cancelled = true; };
  }, []);

  // [2026-10-15] The official server's status is read whichever server is selected: the switcher, the Servers tab and
  // Home all show it. Nothing is sent with it (no token), so a local server's warning does not apply.
  const [officialPlay, setOfficialPlay] = useState<OfficialPlay | null>(null);
  useEffect(() => {
    let cancelled = false;
    const read = () => {
      getOfficialPlay()
        .then((play) => { if (!cancelled) setOfficialPlay(play); })
        .catch(() => { if (!cancelled) setOfficialPlay(null); });
    };
    read();
    const timer = window.setInterval(read, OFFICIAL_PLAY_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  const selected = list.servers.find((server) => server.selected) ?? null;
  const needsAck = selected?.kind === "local" && !selected.acknowledged;
  const selectedId = selected?.id;

  const [authCapabilitiesState, setAuthCapabilitiesState] = useState<{
    serverId: string | undefined;
    loading: boolean;
    value: LauncherAuthCapabilities;
  }>({
    serverId: undefined,
    loading: true,
    value: DEFAULT_AUTH_CAPABILITIES,
  });

  useEffect(() => {
    if (!list.ready) return;

    const requestedServerId = selectedId;
    let cancelled = false;

    setAuthCapabilitiesState({
      serverId: requestedServerId,
      loading: true,
      value: DEFAULT_AUTH_CAPABILITIES,
    });

    // Do not contact a local server before its warning has been accepted.
    if (needsAck) {
      setAuthCapabilitiesState({
        serverId: requestedServerId,
        loading: false,
        value: DEFAULT_AUTH_CAPABILITIES,
      });
      return () => { cancelled = true; };
    }

    getAuthCapabilities(requestedServerId)
      .then((capabilities) => {
        if (!cancelled) {
          setAuthCapabilitiesState({
            serverId: requestedServerId,
            loading: false,
            value: capabilities,
          });
        }
      })
      .catch(() => {
        // Older or unreachable backends keep the conservative email-required behavior.
        if (!cancelled) {
          setAuthCapabilitiesState({
            serverId: requestedServerId,
            loading: false,
            value: DEFAULT_AUTH_CAPABILITIES,
          });
        }
      });

    return () => { cancelled = true; };
  }, [list.ready, selectedId, needsAck, selected?.kind]);

  const authCapabilitiesReady =
    authCapabilitiesState.serverId === selectedId && !authCapabilitiesState.loading;

  const authCapabilities = authCapabilitiesReady
    ? authCapabilitiesState.value
    : DEFAULT_AUTH_CAPABILITIES;

  // [2026-10-16] Local servers are not supported by this launcher any more: one still selected from an earlier version is
  // left for the official server as soon as the list is read (once; a refusal, for example while a game runs, is left alone).
  // The local server's warning no longer opens by itself.
  const selectedKind = selected?.kind;
  useEffect(() => {
    if (!list.ready || selectedKind !== "local" || movedFromLocalRef.current) return;
    const official = list.servers.find((server) => server.kind === "official");
    if (!official) return;
    movedFromLocalRef.current = true;
    selectServer(official.id)
      .then((next) => setList({ ready: true, servers: next }))
      .catch(() => {});
  }, [list, selectedKind]);

  const select = useCallback(async (serverId: string) => {
    sync(await selectServer(serverId));
  }, [sync]);

  const openWarning = useCallback((serverId: string) => setWarningFor(serverId), []);

  const value = useMemo<ServerState>(() => ({
    ready: list.ready,
    servers: list.servers,
    selected,
    serverId: selectedId,
    needsAck: Boolean(needsAck),
    authCapabilities,
    authCapabilitiesReady,
    officialNetwork: selected ? selected.kind !== "local" : true,
    officialPlay,
    sync,
    select,
    openWarning,
  }), [list, selected, selectedId, needsAck, authCapabilities, authCapabilitiesReady, officialPlay, sync, select, openWarning]);

  const warningServer = warningFor
    ? list.servers.find((server) => server.id === warningFor && server.kind === "local") ?? null
    : null;

  return (
    <ServerContext.Provider value={value}>
      {children}
      {warningServer && (
        <LocalServerWarning
          key={warningServer.id}
          server={warningServer}
          onClose={() => setWarningFor(null)}
          onAgree={async (remember) => {
            sync(await acknowledgeLocalServer(warningServer.id, remember));
            setWarningFor(null);
          }}
        />
      )}
    </ServerContext.Provider>
  );
}
