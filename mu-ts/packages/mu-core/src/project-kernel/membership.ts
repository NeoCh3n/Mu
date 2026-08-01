import { stableId, uuid, type UUID } from '../identity.ts'

export const ProjectMembershipRole = {
  owner: 'owner',
  lead: 'lead',
  contributor: 'contributor',
  reviewer: 'reviewer',
  externalAgent: 'external_agent',
} as const
export type ProjectMembershipRole =
  (typeof ProjectMembershipRole)[keyof typeof ProjectMembershipRole]

export const ProjectMembershipStatus = {
  invited: 'invited',
  active: 'active',
  suspended: 'suspended',
  revoked: 'revoked',
  expired: 'expired',
} as const
export type ProjectMembershipStatus =
  (typeof ProjectMembershipStatus)[keyof typeof ProjectMembershipStatus]

export interface ProjectMembershipRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly actorID: UUID
  readonly role: ProjectMembershipRole
  readonly taskScope: readonly UUID[]
  readonly status: ProjectMembershipStatus
  readonly expiresAt?: Date
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createProjectMembershipRecord(params: {
  id?: UUID
  projectID: UUID
  actorID: UUID
  role: ProjectMembershipRole
  taskScope?: readonly UUID[]
  status?: ProjectMembershipStatus
  expiresAt?: Date
  createdAt?: Date
  updatedAt?: Date
}): ProjectMembershipRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    actorID: params.actorID,
    role: params.role,
    taskScope: params.taskScope ?? [],
    status: params.status ?? 'active',
    expiresAt: params.expiresAt,
    createdAt: now,
    updatedAt: now,
  }
}

export function stableMembershipID(projectID: UUID, actorID: UUID): UUID {
  return stableId('mu.project-membership', [projectID.toLowerCase(), actorID.toLowerCase()])
}

export function membershipIsActive(
  membership: ProjectMembershipRecord,
  at: Date = new Date(),
): boolean {
  return membership.status === 'active' && (membership.expiresAt === undefined || membership.expiresAt > at)
}
