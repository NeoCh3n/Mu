import { stableId, uuid, type UUID } from '../identity.ts'
import { canonicalPath } from '../paths.ts'

export const ProjectStatus = {
  active: 'active',
  archived: 'archived',
} as const
export type ProjectStatus = (typeof ProjectStatus)[keyof typeof ProjectStatus]

/**
 * The Mu-owned identity of a Project. A Project can exist without Tasks or an
 * online Runtime; external conversation databases never become its source of
 * truth.
 */
export interface ProjectRecord {
  readonly id: UUID
  readonly displayName: string
  readonly repositoryPath?: string
  readonly ownerPrincipalID: UUID
  readonly status: ProjectStatus
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createProjectRecord(params: {
  id?: UUID
  displayName: string
  repositoryPath?: string
  ownerPrincipalID: UUID
  status?: ProjectStatus
  createdAt?: Date
  updatedAt?: Date
}): ProjectRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    displayName: params.displayName,
    repositoryPath: params.repositoryPath === undefined
      ? undefined
      : canonicalPath(params.repositoryPath),
    ownerPrincipalID: params.ownerPrincipalID,
    status: params.status ?? 'active',
    createdAt: now,
    updatedAt: now,
  }
}

/** Stable project ID derived from a canonical repository path. */
export function stableProjectID(repositoryPath: string): UUID {
  return stableId('mu.project.repository', [canonicalPath(repositoryPath)])
}
