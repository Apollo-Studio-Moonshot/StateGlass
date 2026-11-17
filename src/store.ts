/** Zustand store: project workspace, execution selection, tracing data, UI state. */

import { create } from "zustand";
import {
  api,
  errorMessage,
  onRunOutput,
  onRunStats,
  onRunTrace,
  onRunFinished,
  onWorkspaceChanged,
} from "./api";
import { relativePath } from "./lib/format";
import type {
  AnalysisSummary,
  Bootstrap,
  CenterTab,
  DataFlow,
  Experiment,
  FileEntry,
  InspectTab,
  Project,
  ProjectConfigInput,
  RunStatsEvent,
  RunStatus,
  Session,
  SessionComparison,
  SessionOutput,
  TraceEvent,
  VariableSnapshot,
} from "./types";

const MAX_LIVE_OUTPUT = 800_000;
const MAX_TOASTS = 4;
const MAX_WATCHED = 30;
const WATCH_KEY_PREFIX = "stateglass.watch.";

function readWatchlist(projectId: string | null | undefined): string[] {
  if (!projectId) return [];
  try {
    const raw = window.localStorage.getItem(WATCH_KEY_PREFIX + projectId);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === "string").slice(0, MAX_WATCHED);
  } catch {
    return [];
  }
}

function persistWatchlist(projectId: string, names: string[]): void {
  try {
    window.localStorage.setItem(WATCH_KEY_PREFIX + projectId, JSON.stringify(names));
  } catch {
    // Storage may be unavailable; the watchlist is still kept in memory.
  }
}

export interface OpenFile {
  path: string;
  content: string;
  savedContent: string;
  language: string;
  modifiedAt: number;
}

export interface Workspace {
  kind: "original" | "experiment";
  experimentId: string | null;
  root: string;
  label: string;
}

export interface Toast {
  id: string;
  tone: "info" | "success" | "error";
  message: string;
}

interface AppStore {
  boot: Bootstrap | null;
  booting: boolean;
  bootError: string | null;
  projects: Project[];
  project: Project | null;
  files: FileEntry[];
  filesLoading: boolean;
  workspace: Workspace | null;
  experiments: Experiment[];
  sessions: Session[];
  activeSession: Session | null;
  output: SessionOutput | null;
  liveStdout: string;
  liveStderr: string;
  liveStats: RunStatsEvent | null;
  traceRevision: number;
  cursorSeq: number | null;
  variables: VariableSnapshot[];
  selectedVariable: string | null;
  watchlist: string[];
  history: TraceEvent[];
  dataFlow: DataFlow | null;
  flowLoading: boolean;
  comparison: SessionComparison | null;
  comparisonLoading: boolean;
  compareA: string | null;
  compareB: string | null;
  analysis: AnalysisSummary | null;
  analysisError: string | null;
  openFiles: OpenFile[];
  activeFile: string | null;
  reveal: { file: string; line: number; nonce: number } | null;
  centerTab: CenterTab;
  inspectTab: InspectTab;
  explorerOpen: boolean;
  inspectorOpen: boolean;
  consoleOpen: boolean;
  runStdin: string;
  consentOpen: boolean;
  newExperimentOpen: boolean;
  quickOpenOpen: boolean;
  shortcutsOpen: boolean;
  toasts: Toast[];
  busy: string | null;
  startingRun: boolean;

  init: () => Promise<void>;
  openProjectPath: (path: string) => Promise<void>;
  loadSampleProject: () => Promise<void>;
  refreshProjects: () => Promise<void>;
  updateConfig: (config: ProjectConfigInput) => Promise<void>;
  grantConsentAndRun: () => Promise<void>;
  closeConsent: () => void;
  run: () => Promise<void>;
  cancelRun: () => Promise<void>;
  saveDirty: () => Promise<void>;
  refreshSessions: () => Promise<void>;
  refreshExperiments: () => Promise<void>;
  selectSession: (sessionId: string) => Promise<void>;
  setWorkspace: (experimentId: string | null) => Promise<void>;
  setCursor: (seq: number | null) => Promise<void>;
  loadVariables: (seq: number | null) => Promise<void>;
  selectVariable: (name: string | null) => Promise<void>;
  toggleWatch: (name: string) => void;
  loadFlow: () => Promise<void>;
  loadComparison: () => Promise<void>;
  setComparePair: (baselineId: string | null, experimentId: string | null) => Promise<void>;
  createExperiment: (name: string, note: string, baselineId: string) => Promise<Experiment | null>;
  runAnalysis: (silent?: boolean) => Promise<void>;
  refreshFiles: () => Promise<void>;
  openFile: (path: string) => Promise<void>;
  closeFile: (path: string) => void;
  setActiveFile: (path: string) => void;
  updateFileContent: (path: string, content: string) => void;
  saveFile: (path?: string) => Promise<void>;
  revealLocation: (file: string | null, line: number | null) => Promise<void>;
  setRunStdin: (value: string) => void;
  setCenterTab: (tab: CenterTab) => void;
  setInspectTab: (tab: InspectTab) => void;
  toggleExplorer: () => void;
  toggleInspector: () => void;
  toggleConsole: () => void;
  setNewExperimentOpen: (open: boolean) => void;
  setQuickOpenOpen: (open: boolean) => void;
  setShortcutsOpen: (open: boolean) => void;
  notify: (message: string, tone?: Toast["tone"]) => void;
  dismissToast: (id: string) => void;
  handleOutput: (sessionId: string, stream: "stdout" | "stderr", chunk: string) => void;
  handleTraceBatch: (sessionId: string, events: TraceEvent[], total: number) => void;
  handleStats: (stats: RunStatsEvent) => void;
  handleFinished: (session: Session) => Promise<void>;
  handleWorkspaceChanged: (workspaceId: string) => void;
  subscribeToEvents: () => Promise<() => void>;
}

export function workspaceRoot(state: Pick<AppStore, "workspace" | "project" | "experiments">): string {
  return state.workspace?.root ?? state.project?.rootPath ?? "";
}

export function selectedExperiment(state: Pick<AppStore, "workspace" | "experiments">): Experiment | null {
  if (state.workspace?.kind !== "experiment" || !state.workspace.experimentId) return null;
  return state.experiments.find((item) => item.id === state.workspace?.experimentId) ?? null;
}

export function activeWorkspaceSessions(state: Pick<AppStore, "sessions" | "workspace">): Session[] {
  if (!state.workspace) return [];
  if (state.workspace.kind === "original") {
    return state.sessions.filter((session) => session.experimentId === null);
  }
  return state.sessions.filter((session) => session.experimentId === state.workspace?.experimentId);
}

export function latestBaseline(state: Pick<AppStore, "sessions">): Session | null {
  return (
    state.sessions.find(
      (session) => session.kind === "baseline" && session.status !== "running",
    ) ?? null
  );
}

function statusOrder(status: RunStatus): number {
  return status === "running" ? 0 : 1;
}

function mergeSession(sessions: Session[], session: Session): Session[] {
  const without = sessions.filter((item) => item.id !== session.id);
  return [session, ...without].sort((left, right) => {
    const order = statusOrder(left.status) - statusOrder(right.status);
    if (order !== 0) return order;
    return right.startedAt - left.startedAt;
  });
}

function isFinished(status: RunStatus): boolean {
  return status !== "running";
}

// Monotonic tokens prevent a slow response from overwriting a newer selection.
let sessionLoadToken = 0;
let variableLoadToken = 0;
let flowLoadToken = 0;
let comparisonToken = 0;
let analysisToken = 0;

export const useStore = create<AppStore>()((set, get) => ({
  boot: null,
  booting: true,
  bootError: null,
  projects: [],
  project: null,
  files: [],
  filesLoading: false,
  workspace: null,
  experiments: [],
  sessions: [],
  activeSession: null,
  output: null,
  liveStdout: "",
  liveStderr: "",
  liveStats: null,
  traceRevision: 0,
  cursorSeq: null,
  variables: [],
  selectedVariable: null,
  watchlist: [],
  history: [],
  dataFlow: null,
  flowLoading: false,
  comparison: null,
  comparisonLoading: false,
  compareA: null,
  compareB: null,
  analysis: null,
  analysisError: null,
  openFiles: [],
  activeFile: null,
  reveal: null,
  centerTab: "editor",
  inspectTab: "variables",
  explorerOpen: true,
  inspectorOpen: true,
  consoleOpen: true,
  runStdin: "",
  consentOpen: false,
  newExperimentOpen: false,
  quickOpenOpen: false,
  shortcutsOpen: false,
  toasts: [],
  busy: null,
  startingRun: false,

  notify: (message, tone = "info") => {
    const id = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    set((state) => ({
      toasts: [...state.toasts.slice(-(MAX_TOASTS - 1)), { id, tone, message }],
    }));
    if (tone !== "error") {
      window.setTimeout(() => get().dismissToast(id), 4200);
    }
  },

  dismissToast: (id) =>
    set((state) => ({ toasts: state.toasts.filter((toast) => toast.id !== id) })),

  init: async () => {
    set({ booting: true, bootError: null });
    try {
      const [boot, projects] = await Promise.all([api.bootstrap(), api.listProjects()]);
      set({ boot, projects, booting: false });
      if (!boot.tracerAvailable) {
        get().notify(
          "Python instrumentation helper is missing. Tracing and experiments are unavailable.",
          "error",
        );
      }
      if (boot.initialProjectPath) {
        await get().openProjectPath(boot.initialProjectPath);
      }
    } catch (error) {
      set({ booting: false, bootError: errorMessage(error) });
    }
  },

  refreshProjects: async () => {
    try {
      set({ projects: await api.listProjects() });
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  openProjectPath: async (path) => {
    set({ busy: "Opening project…" });
    try {
      await get().saveDirty();
      sessionLoadToken += 1;
      variableLoadToken += 1;
      flowLoadToken += 1;
      const project = await api.openProject(path);
      set({
        project,
        busy: null,
        experiments: [],
        sessions: [],
        activeSession: null,
        output: null,
        openFiles: [],
        activeFile: null,
        cursorSeq: null,
        selectedVariable: null,
        history: [],
        variables: [],
        dataFlow: null,
        comparison: null,
        compareA: null,
        compareB: null,
        liveStdout: "",
        liveStderr: "",
        liveStats: null,
        analysis: null,
        analysisError: null,
        runStdin: "",
        centerTab: "editor",
        watchlist: readWatchlist(project.id),
        workspace: {
          kind: "original",
          experimentId: null,
          root: project.rootPath,
          label: "Original project",
        },
      });
      await Promise.all([
        get().refreshFiles(),
        get().refreshSessions(),
        get().refreshExperiments(),
      ]);
      await get().runAnalysis(true);
      await get().refreshProjects();
      get().notify(`Opened ${project.name}`, "success");
    } catch (error) {
      set({ busy: null });
      get().notify(errorMessage(error), "error");
    }
  },

  loadSampleProject: async () => {
    set({ busy: "Creating sample project…" });
    try {
      const project = await api.createSampleProject();
      set({ busy: null });
      await get().openProjectPath(project.rootPath);
    } catch (error) {
      set({ busy: null });
      get().notify(errorMessage(error), "error");
    }
  },

  updateConfig: async (config) => {
    const project = get().project;
    if (!project) return;
    try {
      const updated = await api.updateProjectConfig(project.id, config);
      set({ project: updated });
      get().notify("Run settings saved", "success");
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  closeConsent: () => set({ consentOpen: false }),

  grantConsentAndRun: async () => {
    const project = get().project;
    if (!project) return;
    try {
      const updated = await api.setProjectConsent(project.id, true);
      set({ project: updated, consentOpen: false });
      await get().run();
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  run: async () => {
    const { project, workspace, startingRun, activeSession } = get();
    if (!project || !workspace || startingRun) return;
    const backgroundRun = get().sessions.find((session) => session.status === "running");
    if (backgroundRun && backgroundRun.id !== activeSession?.id) {
      await get().selectSession(backgroundRun.id);
      get().notify("Another execution is still running", "info");
      return;
    }
    if (activeSession?.status === "running") {
      get().notify("An execution is already running", "info");
      return;
    }
    if (!project.consentGranted) {
      set({ consentOpen: true });
      return;
    }
    set({ startingRun: true, busy: "Starting execution…" });
    try {
      await get().saveDirty();
      await get().runAnalysis(true);
      const experiment =
        workspace.kind === "experiment"
          ? get().experiments.find((item) => item.id === workspace.experimentId) ?? null
          : null;
      const baselineId = experiment ? experiment.baselineSessionId : null;
      const session = await api.startRun({
        projectId: project.id,
        experimentId: experiment?.id ?? null,
        baselineSessionId: baselineId,
        stdin: experiment ? null : get().runStdin || null,
      });
      sessionLoadToken += 1;
      variableLoadToken += 1;
      flowLoadToken += 1;
      set({
        activeSession: session,
        sessions: mergeSession(get().sessions, session),
        output: null,
        liveStdout: "",
        liveStderr: "",
        liveStats: { sessionId: session.id, elapsedMs: 0, peakMemoryBytes: 0, traceEvents: 0 },
        cursorSeq: null,
        variables: [],
        selectedVariable: null,
        history: [],
        dataFlow: null,
        consoleOpen: true,
        inspectTab: "timeline",
        startingRun: false,
        busy: null,
        traceRevision: get().traceRevision + 1,
      });
      await get().refreshFiles();
      await get().loadVariables(null);
      get().notify(
        experiment ? `Running experiment “${experiment.name}”` : "Execution started",
        "info",
      );
    } catch (error) {
      set({ startingRun: false, busy: null });
      get().notify(errorMessage(error), "error");
    }
  },

  cancelRun: async () => {
    const session = get().activeSession;
    if (!session || session.status !== "running") return;
    try {
      await api.cancelRun(session.id);
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  saveDirty: async () => {
    const dirty = get().openFiles.filter((file) => file.content !== file.savedContent);
    for (const file of dirty) {
      await get().saveFile(file.path);
    }
  },

  refreshSessions: async () => {
    const project = get().project;
    if (!project) return;
    try {
      const sessions = await api.listSessions(project.id, 120);
      const current = get().activeSession;
      const refreshed = current ? sessions.find((item) => item.id === current.id) ?? current : null;
      const workspace = get().workspace;
      const preferred =
        refreshed ??
        sessions.find((session) =>
          workspace?.kind === "experiment"
            ? session.experimentId === workspace.experimentId
            : session.experimentId === null,
        ) ??
        null;
      set({ sessions, activeSession: preferred });
      if (!current && preferred) {
        await get().selectSession(preferred.id);
      }
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  refreshExperiments: async () => {
    const project = get().project;
    if (!project) return;
    try {
      set({ experiments: await api.listExperiments(project.id) });
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  selectSession: async (sessionId) => {
    const token = ++sessionLoadToken;
    try {
      const session = await api.getSession(sessionId);
      if (token !== sessionLoadToken) return;
      // The session may belong to another workspace (for example "Inspect
      // baseline" from a comparison). Align the workspace first so the editor
      // and analysis show the sources the execution actually ran.
      const workspace = get().workspace;
      const currentExperimentId =
        workspace?.kind === "experiment" ? workspace.experimentId : null;
      if (workspace && session.experimentId !== currentExperimentId) {
        const experiment = session.experimentId
          ? get().experiments.find((item) => item.id === session.experimentId) ?? null
          : null;
        if (!session.experimentId || experiment) {
          await get().saveDirty();
          set({
            workspace: experiment
              ? {
                  kind: "experiment",
                  experimentId: experiment.id,
                  root: experiment.path,
                  label: experiment.name,
                }
              : {
                  kind: "original",
                  experimentId: null,
                  root: get().project?.rootPath ?? "",
                  label: "Original project",
                },
            openFiles: [],
            activeFile: null,
            reveal: null,
          });
          await get().refreshFiles();
          await get().runAnalysis(true);
          if (token !== sessionLoadToken) return;
        }
      }
      const [output, variables] = await Promise.all([
        isFinished(session.status) ? api.getSessionOutput(sessionId) : Promise.resolve(null),
        api.variablesAt(sessionId, null),
      ]);
      if (token !== sessionLoadToken) return;
      set({
        activeSession: session,
        output,
        liveStdout: session.status === "running" ? get().liveStdout : "",
        liveStderr: session.status === "running" ? get().liveStderr : "",
        cursorSeq: null,
        variables,
        selectedVariable: null,
        history: [],
        dataFlow: null,
        traceRevision: get().traceRevision + 1,
      });
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  setWorkspace: async (experimentId) => {
    const { project, experiments, sessions } = get();
    if (!project) return;
    await get().saveDirty();
    const experiment = experimentId
      ? experiments.find((item) => item.id === experimentId) ?? null
      : null;
    if (experimentId && !experiment) {
      get().notify("Experiment not found", "error");
      return;
    }
    sessionLoadToken += 1;
    variableLoadToken += 1;
    flowLoadToken += 1;
    const workspace: Workspace = experiment
      ? {
          kind: "experiment",
          experimentId: experiment.id,
          root: experiment.path,
          label: experiment.name,
        }
      : {
          kind: "original",
          experimentId: null,
          root: project.rootPath,
          label: "Original project",
        };
    set({
      workspace,
      openFiles: [],
      activeFile: null,
      reveal: null,
      comparison: null,
      compareA: null,
      compareB: null,
      centerTab: "editor",
    });
    const relevant = sessions.find((session) =>
      experiment ? session.experimentId === experiment.id : session.experimentId === null,
    );
    if (relevant) {
      await get().selectSession(relevant.id);
    } else {
      set({
        activeSession: null,
        output: null,
        variables: [],
        selectedVariable: null,
        history: [],
        dataFlow: null,
        cursorSeq: null,
        liveStdout: "",
        liveStderr: "",
        liveStats: null,
      });
    }
    await get().refreshFiles();
    await get().runAnalysis(true);
  },

  setCursor: async (seq) => {
    set({ cursorSeq: seq });
    await get().loadVariables(seq);
  },

  loadVariables: async (seq) => {
    const session = get().activeSession;
    if (!session) {
      set({ variables: [] });
      return;
    }
    const token = ++variableLoadToken;
    try {
      const variables = await api.variablesAt(session.id, seq);
      if (token !== variableLoadToken) return;
      set({ variables });
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  selectVariable: async (name) => {
    flowLoadToken += 1;
    set({ selectedVariable: name, history: [], dataFlow: null });
    const session = get().activeSession;
    if (!session || !name) {
      set({ history: [] });
      return;
    }
    try {
      const history = await api.variableHistory(session.id, name, 400);
      if (get().selectedVariable !== name) return;
      set({ history });
      await get().loadFlow();
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  toggleWatch: (name) => {
    const { project, watchlist } = get();
    const next = watchlist.includes(name)
      ? watchlist.filter((item) => item !== name)
      : [...watchlist, name].slice(-MAX_WATCHED);
    set({ watchlist: next });
    if (project) persistWatchlist(project.id, next);
  },

  loadFlow: async () => {
    const { activeSession: session, selectedVariable: variable } = get();
    if (!session || !variable) {
      set({ dataFlow: null });
      return;
    }
    const token = ++flowLoadToken;
    set({ flowLoading: true });
    try {
      const dataFlow = await api.dataFlow(session.id, variable);
      if (token !== flowLoadToken) return;
      set({ dataFlow, flowLoading: false });
    } catch (error) {
      set({ flowLoading: false });
      get().notify(errorMessage(error), "error");
    }
  },

  setComparePair: async (baselineId, experimentId) => {
    const token = ++comparisonToken;
    set({ compareA: baselineId, compareB: experimentId, comparison: null });
    const { compareA, compareB } = get();
    if (!compareA || !compareB) return;
    set({ comparisonLoading: true, centerTab: "compare" });
    try {
      const comparison = await api.compareSessions(compareA, compareB);
      if (token !== comparisonToken) return;
      set({ comparison, comparisonLoading: false });
    } catch (error) {
      if (token !== comparisonToken) return;
      set({ comparisonLoading: false });
      get().notify(errorMessage(error), "error");
    }
  },

  loadComparison: async () => {
    const { compareA, compareB } = get();
    if (!compareA || !compareB) return;
    const token = ++comparisonToken;
    set({ comparisonLoading: true });
    try {
      const comparison = await api.compareSessions(compareA, compareB);
      if (token !== comparisonToken) return;
      set({ comparison, comparisonLoading: false });
    } catch (error) {
      if (token !== comparisonToken) return;
      set({ comparisonLoading: false });
      get().notify(errorMessage(error), "error");
    }
  },

  createExperiment: async (name, note, baselineId) => {
    const project = get().project;
    if (!project) return null;
    await get().saveDirty();
    set({ busy: "Copying project for experiment…" });
    try {
      const experiment = await api.createExperiment(
        project.id,
        baselineId,
        name,
        note.trim() ? note.trim() : null,
      );
      set({ busy: null });
      await get().refreshExperiments();
      await get().setWorkspace(experiment.id);
      get().notify(`Created experiment “${experiment.name}”`, "success");
      return experiment;
    } catch (error) {
      set({ busy: null });
      get().notify(errorMessage(error), "error");
      return null;
    }
  },

  runAnalysis: async (silent = false) => {
    const { project, workspace } = get();
    if (!project || !workspace) return;
    const token = ++analysisToken;
    try {
      const analysis = await api.analyzeWorkspace(project.id, workspace.experimentId);
      if (token !== analysisToken) return;
      set({
        analysis,
        analysisError: analysis.errors.length > 0 ? analysis.errors[0] ?? null : null,
      });
      if (silent) return;
      if (analysis.errors.length > 0) {
        get().notify(`Analysis completed with ${analysis.errors.length} issue(s)`, "info");
      } else {
        get().notify(
          `Analyzed ${analysis.files} files, ${analysis.assignments} assignments`,
          "success",
        );
      }
    } catch (error) {
      set({ analysisError: errorMessage(error) });
      if (!silent) get().notify(errorMessage(error), "error");
    }
  },

  refreshFiles: async () => {
    const { project, workspace } = get();
    if (!project || !workspace) return;
    set({ filesLoading: true });
    try {
      const files = await api.listFiles(project.id, workspace.experimentId);
      set({ files, filesLoading: false });
    } catch (error) {
      set({ filesLoading: false });
      get().notify(errorMessage(error), "error");
    }
  },

  openFile: async (path) => {
    const existing = get().openFiles.find((file) => file.path === path);
    if (existing) {
      set({ activeFile: path, centerTab: "editor" });
      return;
    }
    const { project, workspace } = get();
    if (!project || !workspace) return;
    const experimentId = workspace.experimentId;
    try {
      const content = await api.readFile(project.id, experimentId, path);
      if ((get().workspace?.experimentId ?? null) !== experimentId) return;
      set((state) => {
        if (state.openFiles.some((file) => file.path === path)) return state;
        return {
          openFiles: [
            ...state.openFiles,
            {
              path,
              content: content.content,
              savedContent: content.content,
              language: content.language,
              modifiedAt: content.modifiedAt,
            },
          ],
          activeFile: path,
          centerTab: "editor",
        };
      });
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  closeFile: (path) => {
    const file = get().openFiles.find((item) => item.path === path);
    if (file && file.content !== file.savedContent) {
      const discard = window.confirm(`Discard unsaved changes to ${path}?`);
      if (!discard) return;
    }
    set((state) => {
      const index = state.openFiles.findIndex((file) => file.path === path);
      const openFiles = state.openFiles.filter((file) => file.path !== path);
      let activeFile = state.activeFile;
      if (activeFile === path) {
        const next = openFiles[Math.min(index, openFiles.length - 1)];
        activeFile = next ? next.path : null;
      }
      return { openFiles, activeFile };
    });
  },

  setActiveFile: (path) => set({ activeFile: path, centerTab: "editor" }),

  updateFileContent: (path, content) =>
    set((state) => ({
      openFiles: state.openFiles.map((file) =>
        file.path === path ? { ...file, content } : file,
      ),
    })),

  saveFile: async (path) => {
    const file = get().openFiles.find((item) => item.path === (path ?? get().activeFile));
    const { project, workspace } = get();
    if (!file || !project || !workspace) return;
    if (file.content === file.savedContent) return;
    const written = file.content;
    try {
      const saved = await api.writeFile(
        project.id,
        workspace.experimentId,
        file.path,
        written,
      );
      set((state) => ({
        openFiles: state.openFiles.map((item) =>
          item.path === file.path
            ? // Only record what actually reached disk: edits typed while the
              // write was in flight must stay dirty.
              { ...item, savedContent: written, modifiedAt: saved.modifiedAt }
            : item,
        ),
      }));
    } catch (error) {
      get().notify(errorMessage(error), "error");
    }
  },

  revealLocation: async (file, line) => {
    if (!file) return;
    const { workspace } = get();
    if (!workspace) return;
    const relative = relativePath(file, workspace.root);
    await get().openFile(relative);
    if (line && line > 0) {
      set((state) => ({
        reveal: { file: relative, line, nonce: (state.reveal?.nonce ?? 0) + 1 },
        centerTab: "editor",
      }));
    }
  },

  setRunStdin: (value) => set({ runStdin: value }),
  setCenterTab: (tab) => set({ centerTab: tab }),
  setInspectTab: (tab) => set({ inspectTab: tab }),
  toggleExplorer: () => set((state) => ({ explorerOpen: !state.explorerOpen })),
  toggleInspector: () => set((state) => ({ inspectorOpen: !state.inspectorOpen })),
  toggleConsole: () => set((state) => ({ consoleOpen: !state.consoleOpen })),
  setNewExperimentOpen: (open) => set({ newExperimentOpen: open }),
  setQuickOpenOpen: (open) => set({ quickOpenOpen: open }),
  setShortcutsOpen: (open) => set({ shortcutsOpen: open }),

  handleOutput: (sessionId, stream, chunk) => {
    if (get().activeSession?.id !== sessionId) return;
    if (stream === "stdout") {
      set((state) => ({
        liveStdout: (state.liveStdout + chunk).slice(-MAX_LIVE_OUTPUT),
      }));
    } else {
      set((state) => ({
        liveStderr: (state.liveStderr + chunk).slice(-MAX_LIVE_OUTPUT),
      }));
    }
  },

  handleTraceBatch: (sessionId, _events, total) => {
    const session = get().activeSession;
    if (!session || session.id !== sessionId) return;
    set((state) => ({
      traceRevision: state.traceRevision + 1,
      activeSession: state.activeSession
        ? { ...state.activeSession, traceEventCount: total }
        : null,
    }));
  },

  handleStats: (stats) => {
    if (get().activeSession?.id !== stats.sessionId) return;
    set({ liveStats: stats });
  },

  handleFinished: async (session) => {
    const isActive = get().activeSession?.id === session.id;
    set((state) => ({ sessions: mergeSession(state.sessions, session) }));
    if (!isActive) {
      await get().refreshExperiments();
      return;
    }
    let output: SessionOutput | null = null;
    try {
      output = await api.getSessionOutput(session.id);
    } catch {
      output = null;
    }
    set({
      activeSession: session,
      output,
      liveStdout: "",
      liveStderr: "",
      liveStats: null,
      traceRevision: get().traceRevision + 1,
      cursorSeq: null,
    });
    await get().loadVariables(null);
    const selected = get().selectedVariable;
    if (selected) {
      await get().selectVariable(selected);
    }
    if (session.status === "ok") {
      get().notify(
        `Execution finished in ${Math.round((session.durationMs ?? 0) / 1000)}s`,
        "success",
      );
    } else if (session.status !== "cancelled") {
      get().notify(session.error ?? `Execution ${session.status}`, "error");
    }
    await get().refreshExperiments();
    await get().refreshFiles();
  },

  handleWorkspaceChanged: (workspaceId) => {
    const workspace = get().workspace;
    if (!workspace) return;
    const currentId = workspace.kind === "experiment" ? workspace.experimentId : get().project?.id;
    if (workspaceId !== currentId) return;
    void get().refreshFiles();
  },

  subscribeToEvents: async () => {
    const unlisten = await Promise.all([
      onRunOutput((event) => get().handleOutput(event.sessionId, event.stream, event.chunk)),
      onRunTrace((event) => get().handleTraceBatch(event.sessionId, event.events, event.total)),
      onRunStats((event) => get().handleStats(event)),
      onRunFinished((session) => {
        void get().handleFinished(session);
      }),
      onWorkspaceChanged((event) => get().handleWorkspaceChanged(event.workspaceId)),
    ]);
    return () => {
      for (const stop of unlisten) stop();
    };
  },
}));

export function useActiveSession(): Session | null {
  return useStore((state) => state.activeSession);
}

export function useActiveFile(): OpenFile | null {
  return useStore((state) => {
    if (!state.activeFile) return null;
    return state.openFiles.find((file) => file.path === state.activeFile) ?? null;
  });
}
