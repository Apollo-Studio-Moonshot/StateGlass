/** Typed wrappers around Tauri IPC commands. */

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AnalysisSummary,
  ApiError,
  Bootstrap,
  DataFlow,
  Experiment,
  FileContent,
  FileEntry,
  Project,
  ProjectConfigInput,
  PythonRuntime,
  RunRequest,
  RunOutputEvent,
  RunStatsEvent,
  RunTraceEvent,
  Session,
  SessionComparison,
  SessionOutput,
  TraceEvent,
  TracePage,
  TraceStats,
  VariableSnapshot,
  WorkspaceChangedEvent,
} from "./types";

export const api = {
  bootstrap: () => invoke<Bootstrap>("bootstrap"),
  listProjects: () => invoke<Project[]>("list_projects"),
  openProject: (path: string) => invoke<Project>("open_project", { path }),
  createSampleProject: () => invoke<Project>("create_sample_project"),
  getProject: (projectId: string) => invoke<Project>("get_project", { projectId }),
  updateProjectConfig: (projectId: string, config: ProjectConfigInput) =>
    invoke<Project>("update_project_config", { projectId, config }),
  setProjectConsent: (projectId: string, granted: boolean) =>
    invoke<Project>("set_project_consent", { projectId, granted }),
  listFiles: (projectId: string, experimentId: string | null) =>
    invoke<FileEntry[]>("list_files", { projectId, experimentId }),
  readFile: (projectId: string, experimentId: string | null, path: string) =>
    invoke<FileContent>("read_file", { projectId, experimentId, path }),
  writeFile: (projectId: string, experimentId: string | null, path: string, content: string) =>
    invoke<FileContent>("write_file", { projectId, experimentId, path, content }),
  analyzeWorkspace: (projectId: string, experimentId: string | null) =>
    invoke<AnalysisSummary>("analyze_workspace", { projectId, experimentId }),
  startRun: (request: RunRequest) => invoke<Session>("start_run", { request }),
  cancelRun: (sessionId: string) => invoke<void>("cancel_run", { sessionId }),
  listSessions: (projectId: string, limit?: number) =>
    invoke<Session[]>("list_sessions", { projectId, limit }),
  getSession: (sessionId: string) => invoke<Session>("get_session", { sessionId }),
  getSessionOutput: (sessionId: string) =>
    invoke<SessionOutput>("get_session_output", { sessionId }),
  listTraceEvents: (
    sessionId: string,
    options: { kinds?: string[]; limit?: number; offset?: number; tail?: boolean } = {},
  ) =>
    invoke<TracePage>("list_trace_events", {
      sessionId,
      kinds: options.kinds,
      limit: options.limit,
      offset: options.offset,
      tail: options.tail,
    }),
  traceStats: (sessionId: string) => invoke<TraceStats>("trace_stats", { sessionId }),
  variablesAt: (sessionId: string, seq: number | null) =>
    invoke<VariableSnapshot[]>("variables_at", { sessionId, seq }),
  variableHistory: (sessionId: string, name: string, limit?: number) =>
    invoke<TraceEvent[]>("variable_history", { sessionId, name, limit }),
  dataFlow: (sessionId: string, variable: string) =>
    invoke<DataFlow>("data_flow", { sessionId, variable }),
  createExperiment: (
    projectId: string,
    baselineSessionId: string,
    name: string,
    note: string | null,
  ) =>
    invoke<Experiment>("create_experiment", {
      projectId,
      baselineSessionId,
      name,
      note,
    }),
  listExperiments: (projectId: string) =>
    invoke<Experiment[]>("list_experiments", { projectId }),
  compareSessions: (baselineSessionId: string, experimentSessionId: string) =>
    invoke<SessionComparison>("compare_sessions", {
      baselineSessionId,
      experimentSessionId,
    }),
  listPythonRuntimes: (projectId: string | null) =>
    invoke<PythonRuntime[]>("list_python_runtimes", { projectId }),
  setGlobalPythonPath: (path: string | null) =>
    invoke<void>("set_global_python_path", { path }),
};

export function toApiError(error: unknown): ApiError {
  if (typeof error === "string") {
    return { kind: "error", message: error };
  }
  if (error && typeof error === "object") {
    const candidate = error as Partial<ApiError>;
    if (typeof candidate.message === "string") {
      return { kind: candidate.kind ?? "error", message: candidate.message };
    }
  }
  return { kind: "error", message: "Unexpected application error" };
}

export function errorMessage(error: unknown): string {
  return toApiError(error).message;
}

/* Event subscriptions ------------------------------------------------------ */

export const onRunOutput = (handler: (event: RunOutputEvent) => void): Promise<UnlistenFn> =>
  listen<RunOutputEvent>("run:output", (event) => handler(event.payload));

export const onRunTrace = (handler: (event: RunTraceEvent) => void): Promise<UnlistenFn> =>
  listen<RunTraceEvent>("run:trace", (event) => handler(event.payload));

export const onRunStats = (handler: (event: RunStatsEvent) => void): Promise<UnlistenFn> =>
  listen<RunStatsEvent>("run:stats", (event) => handler(event.payload));

export const onRunFinished = (handler: (session: Session) => void): Promise<UnlistenFn> =>
  listen<Session>("run:finished", (event) => handler(event.payload));

export const onWorkspaceChanged = (
  handler: (event: WorkspaceChangedEvent) => void,
): Promise<UnlistenFn> =>
  listen<WorkspaceChangedEvent>("workspace:changed", (event) => handler(event.payload));
