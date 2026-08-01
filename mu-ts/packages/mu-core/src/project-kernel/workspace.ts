import { stableId, uuid, type UUID } from '../identity.ts'
import { canonicalPath } from '../paths.ts'

export const WorkspaceIsolationKind = {
  sharedProjectFolder: 'shared_project_folder',
  gitWorktree: 'git_worktree',
  documentVersion: 'document_version',
  externalSandbox: 'external_sandbox',
} as const
export type WorkspaceIsolationKind =
  (typeof WorkspaceIsolationKind)[keyof typeof WorkspaceIsolationKind]

export const ProjectWorkspaceStatus = {
  preparing: 'preparing',
  active: 'active',
  quiesced: 'quiesced',
  closed: 'closed',
  failed: 'failed',
} as const
export type ProjectWorkspaceStatus =
  (typeof ProjectWorkspaceStatus)[keyof typeof ProjectWorkspaceStatus]

export interface ProjectWorkspaceRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID?: UUID
  readonly repositoryPath: string
  readonly worktreePath?: string
  readonly branch?: string
  readonly baseRevision?: string
  readonly isolationKind: WorkspaceIsolationKind
  readonly status: ProjectWorkspaceStatus
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createProjectWorkspaceRecord(params: {
  id?: UUID
  projectID: UUID
  taskID?: UUID
  repositoryPath: string
  worktreePath?: string
  branch?: string
  baseRevision?: string
  isolationKind: WorkspaceIsolationKind
  status?: ProjectWorkspaceStatus
  createdAt?: Date
  updatedAt?: Date
}): ProjectWorkspaceRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    repositoryPath: canonicalPath(params.repositoryPath),
    worktreePath: params.worktreePath === undefined
      ? undefined
      : canonicalPath(params.worktreePath),
    branch: params.branch,
    baseRevision: params.baseRevision,
    isolationKind: params.isolationKind,
    status: params.status ?? 'active',
    createdAt: now,
    updatedAt: now,
  }
}

export function stableWorkspaceID(taskID: UUID): UUID {
  return stableId('mu.workspace.task', [taskID.toLowerCase()])
}
