import { uuid, type UUID } from '../identity.ts'

/**
 * The bridge record linking a Task to a Project, Workspace, requester,
 * assignee, reviewer, approval owner, and cost owner. Dependency task IDs
 * track task-to-task dependencies.
 */
export interface TaskProjectLink {
  readonly id: UUID
  readonly taskID: UUID
  readonly projectID: UUID
  readonly workspaceID?: UUID
  readonly requestedByActorID?: UUID
  readonly assignedToActorID?: UUID
  readonly reviewerActorID?: UUID
  readonly approvalOwnerActorID?: UUID
  readonly costOwnerPrincipalID?: UUID
  readonly dependencyTaskIDs: readonly UUID[]
  readonly createdAt: Date
  readonly updatedAt: Date
}

export function createTaskProjectLink(params: {
  id?: UUID
  taskID: UUID
  projectID: UUID
  workspaceID?: UUID
  requestedByActorID?: UUID
  assignedToActorID?: UUID
  reviewerActorID?: UUID
  approvalOwnerActorID?: UUID
  costOwnerPrincipalID?: UUID
  dependencyTaskIDs?: readonly UUID[]
  createdAt?: Date
  updatedAt?: Date
}): TaskProjectLink {
  const now = params.createdAt ?? new Date()
  // Swift uses `id ?? taskID` — the link id defaults to the task id.
  return {
    id: params.id ?? params.taskID,
    taskID: params.taskID,
    projectID: params.projectID,
    workspaceID: params.workspaceID,
    requestedByActorID: params.requestedByActorID,
    assignedToActorID: params.assignedToActorID,
    reviewerActorID: params.reviewerActorID,
    approvalOwnerActorID: params.approvalOwnerActorID,
    costOwnerPrincipalID: params.costOwnerPrincipalID,
    dependencyTaskIDs: params.dependencyTaskIDs ?? [],
    createdAt: now,
    updatedAt: now,
  }
}
