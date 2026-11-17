import type { Experiment, Session } from "../types";
import { formatShortDate } from "./format";

export function sessionTitle(session: Session, experiments: Experiment[]): string {
  if (session.kind === "baseline") return "Baseline";
  return (
    session.label ??
    experiments.find((experiment) => experiment.id === session.experimentId)?.name ??
    "Experiment"
  );
}

export function sessionSubtitle(session: Session): string {
  return `${formatShortDate(session.startedAt)} · ${session.command}`;
}

export function completedBaselines(sessions: Session[]): Session[] {
  return sessions.filter(
    (session) => session.kind === "baseline" && session.status !== "running",
  );
}

export function latestSessionForExperiment(
  sessions: Session[],
  experimentId: string,
): Session | null {
  return (
    sessions
      .filter((session) => session.experimentId === experimentId)
      .sort((left, right) => right.startedAt - left.startedAt)[0] ?? null
  );
}

export function experimentRunCount(sessions: Session[], experimentId: string): number {
  return sessions.filter((session) => session.experimentId === experimentId).length;
}
