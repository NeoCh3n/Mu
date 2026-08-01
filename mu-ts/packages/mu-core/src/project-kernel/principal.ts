import { uuid, type UUID } from '../identity.ts'

export const PrincipalKind = {
  person: 'person',
  organization: 'organization',
  project: 'project',
} as const
export type PrincipalKind = (typeof PrincipalKind)[keyof typeof PrincipalKind]

export const PrincipalStatus = {
  active: 'active',
  suspended: 'suspended',
} as const
export type PrincipalStatus = (typeof PrincipalStatus)[keyof typeof PrincipalStatus]

/** A person or organization that remains accountable for an Actor. */
export interface PrincipalRecord {
  readonly id: UUID
  readonly kind: PrincipalKind
  readonly displayName: string
  readonly status: PrincipalStatus
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createPrincipalRecord(params: {
  id?: UUID
  kind: PrincipalKind
  displayName: string
  status?: PrincipalStatus
  createdAt?: Date
  updatedAt?: Date
}): PrincipalRecord {
  const now = params.createdAt ?? new Date()
  return {
    id: params.id ?? uuid(),
    kind: params.kind,
    displayName: params.displayName,
    status: params.status ?? 'active',
    createdAt: now,
    updatedAt: now,
  }
}
