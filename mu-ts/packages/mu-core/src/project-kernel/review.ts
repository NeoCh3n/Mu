import { uuid, type UUID } from '../identity.ts'

export const ProjectReviewVerdict = {
  pending: 'pending',
  approved: 'approved',
  changesRequested: 'changes_requested',
  rejected: 'rejected',
} as const
export type ProjectReviewVerdict =
  (typeof ProjectReviewVerdict)[keyof typeof ProjectReviewVerdict]

export interface ProjectReviewRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID?: UUID
  readonly artifactID?: UUID
  readonly reviewerActorID: UUID
  readonly verdict: ProjectReviewVerdict
  readonly findings: readonly string[]
  readonly createdAt: Date
  readonly resolvedAt?: Date
}

export function createProjectReviewRecord(params: {
  id?: UUID
  projectID: UUID
  taskID?: UUID
  artifactID?: UUID
  reviewerActorID: UUID
  verdict?: ProjectReviewVerdict
  findings?: readonly string[]
  createdAt?: Date
  resolvedAt?: Date
}): ProjectReviewRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    artifactID: params.artifactID,
    reviewerActorID: params.reviewerActorID,
    verdict: params.verdict ?? 'pending',
    findings: params.findings ?? [],
    createdAt: params.createdAt ?? new Date(),
    resolvedAt: params.resolvedAt,
  }
}
