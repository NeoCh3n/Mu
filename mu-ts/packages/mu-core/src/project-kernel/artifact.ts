import { uuid, type UUID } from '../identity.ts'

export const ProjectArtifactKind = {
  contextPack: 'context_pack',
  runtimeOutput: 'runtime_output',
  patch: 'patch',
  document: 'document',
  dataset: 'dataset',
  testResult: 'test_result',
  decision: 'decision',
  checkpoint: 'checkpoint',
} as const
export type ProjectArtifactKind = (typeof ProjectArtifactKind)[keyof typeof ProjectArtifactKind]

export const ProjectArtifactStatus = {
  draft: 'draft',
  submitted: 'submitted',
  accepted: 'accepted',
  rejected: 'rejected',
  superseded: 'superseded',
} as const
export type ProjectArtifactStatus =
  (typeof ProjectArtifactStatus)[keyof typeof ProjectArtifactStatus]

export interface ProjectArtifactRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID?: UUID
  readonly producerActorID?: UUID
  readonly kind: ProjectArtifactKind
  readonly title: string
  readonly uri: string
  readonly sha256: string
  readonly version: number
  readonly status: ProjectArtifactStatus
  readonly sourceArtifactIDs: readonly UUID[]
  readonly metadata: Readonly<Record<string, string>>
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createProjectArtifactRecord(params: {
  id?: UUID
  projectID: UUID
  taskID?: UUID
  producerActorID?: UUID
  kind: ProjectArtifactKind
  title: string
  uri: string
  sha256: string
  version?: number
  status?: ProjectArtifactStatus
  sourceArtifactIDs?: readonly UUID[]
  metadata?: Readonly<Record<string, string>>
  createdAt?: Date
  updatedAt?: Date
}): ProjectArtifactRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    producerActorID: params.producerActorID,
    kind: params.kind,
    title: params.title,
    uri: params.uri,
    sha256: params.sha256,
    version: params.version ?? 1,
    status: params.status ?? 'submitted',
    sourceArtifactIDs: params.sourceArtifactIDs ?? [],
    metadata: params.metadata ?? {},
    createdAt: now,
    updatedAt: now,
  }
}
