/**
 * 21 Project permissions, mirroring `enum ProjectPermission` from
 * ProjectKernel.swift. Permission checks are pure functions.
 */
export const ProjectPermission = {
  readProjectState: 'project.read',
  readRepository: 'repository.read',
  writeWorkspace: 'workspace.write',
  runCommands: 'command.run',
  runTests: 'test.run',
  useNetwork: 'network.use',
  acceptTask: 'task.accept',
  renewLease: 'task.lease.renew',
  publishEvent: 'event.publish',
  requestApproval: 'approval.request',
  submitArtifact: 'artifact.submit',
  completeTask: 'task.complete',
  manageTasks: 'task.manage',
  manageMembers: 'membership.manage',
  mergeAcceptedState: 'project.merge',
  readContext: 'context.read',
  readRestrictedContext: 'context.restricted.read',
  proposeContext: 'context.propose',
  reviewContext: 'context.review',
  manageContext: 'context.manage',
  declassifyContext: 'context.declassify',
} as const

export type ProjectPermission = (typeof ProjectPermission)[keyof typeof ProjectPermission]

export const ALL_PROJECT_PERMISSIONS: readonly ProjectPermission[] =
  Object.values(ProjectPermission)

export function hasPermission(
  granted: ReadonlySet<ProjectPermission>,
  required: ProjectPermission,
): boolean {
  return granted.has(required)
}

export function hasAnyPermission(
  granted: ReadonlySet<ProjectPermission>,
  required: readonly ProjectPermission[],
): boolean {
  return required.some((p) => granted.has(p))
}

export function hasAllPermissions(
  granted: ReadonlySet<ProjectPermission>,
  required: readonly ProjectPermission[],
): boolean {
  return required.every((p) => granted.has(p))
}
