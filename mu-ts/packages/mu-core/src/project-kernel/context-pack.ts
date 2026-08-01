import { uuid, type UUID } from '../identity.ts'
import type { ProjectPermission } from './permissions.ts'

/**
 * The structured state shared with a Runtime for one Task. Raw imported
 * transcripts stay outside the Pack; only permission-filtered canonical
 * records and accepted artifacts are eligible for governed delivery.
 */
export interface ProjectContextPackRecord {
  readonly id: UUID
  readonly projectID: UUID
  readonly taskID: UUID
  readonly workspaceID: UUID
  readonly objective: string
  readonly relevantFilePaths: readonly string[]
  readonly acceptedArtifactIDs: readonly UUID[]
  readonly dependencyTaskIDs: readonly UUID[]
  readonly constraints: readonly string[]
  readonly permissions: readonly ProjectPermission[]
  readonly acceptanceTests: readonly string[]
  readonly expectedOutputs: readonly string[]
  readonly baseRevision?: string
  readonly actorID?: UUID
  readonly principalID?: UUID
  readonly runtimeEndpointID?: UUID
  readonly runtimeBindingID?: UUID
  readonly taskLeaseID?: UUID
  readonly leaseFencingToken?: number
  readonly selectionPolicyVersion?: string
  readonly tokenBudget?: number
  readonly contextRevision?: string
  readonly taskRevision?: string
  readonly policyRevision?: string
  readonly itemSetFingerprint?: string
  readonly budgetEstimatorVersion?: string
  readonly canonicalizationVersion?: string
  readonly includedContextRecordIDs?: readonly UUID[]
  readonly unresolvedContextConflictIDs?: readonly UUID[]
  readonly contextPackItemIDs?: readonly UUID[]
  readonly renderedContextMarkdown?: string
  readonly renderedArtifactURI?: string
  readonly contentSHA256: string
  readonly createdAt: Date
}

export function createProjectContextPackRecord(params: {
  id?: UUID
  projectID: UUID
  taskID: UUID
  workspaceID: UUID
  objective: string
  relevantFilePaths?: readonly string[]
  acceptedArtifactIDs?: readonly UUID[]
  dependencyTaskIDs?: readonly UUID[]
  constraints?: readonly string[]
  permissions?: readonly ProjectPermission[]
  acceptanceTests?: readonly string[]
  expectedOutputs?: readonly string[]
  baseRevision?: string
  actorID?: UUID
  principalID?: UUID
  runtimeEndpointID?: UUID
  runtimeBindingID?: UUID
  taskLeaseID?: UUID
  leaseFencingToken?: number
  selectionPolicyVersion?: string
  tokenBudget?: number
  contextRevision?: string
  taskRevision?: string
  policyRevision?: string
  itemSetFingerprint?: string
  budgetEstimatorVersion?: string
  canonicalizationVersion?: string
  includedContextRecordIDs?: readonly UUID[]
  unresolvedContextConflictIDs?: readonly UUID[]
  contextPackItemIDs?: readonly UUID[]
  renderedContextMarkdown?: string
  renderedArtifactURI?: string
  contentSHA256: string
  createdAt?: Date
}): ProjectContextPackRecord {
  return {
    id: params.id ?? uuid(),
    projectID: params.projectID,
    taskID: params.taskID,
    workspaceID: params.workspaceID,
    objective: params.objective,
    relevantFilePaths: params.relevantFilePaths ?? [],
    acceptedArtifactIDs: params.acceptedArtifactIDs ?? [],
    dependencyTaskIDs: params.dependencyTaskIDs ?? [],
    constraints: params.constraints ?? [],
    permissions: params.permissions ?? [],
    acceptanceTests: params.acceptanceTests ?? [],
    expectedOutputs: params.expectedOutputs ?? [],
    baseRevision: params.baseRevision,
    actorID: params.actorID,
    principalID: params.principalID,
    runtimeEndpointID: params.runtimeEndpointID,
    runtimeBindingID: params.runtimeBindingID,
    taskLeaseID: params.taskLeaseID,
    leaseFencingToken: params.leaseFencingToken,
    selectionPolicyVersion: params.selectionPolicyVersion,
    tokenBudget: params.tokenBudget,
    contextRevision: params.contextRevision,
    taskRevision: params.taskRevision,
    policyRevision: params.policyRevision,
    itemSetFingerprint: params.itemSetFingerprint,
    budgetEstimatorVersion: params.budgetEstimatorVersion,
    canonicalizationVersion: params.canonicalizationVersion,
    includedContextRecordIDs: params.includedContextRecordIDs,
    unresolvedContextConflictIDs: params.unresolvedContextConflictIDs,
    contextPackItemIDs: params.contextPackItemIDs,
    renderedContextMarkdown: params.renderedContextMarkdown,
    renderedArtifactURI: params.renderedArtifactURI,
    contentSHA256: params.contentSHA256,
    createdAt: params.createdAt ?? new Date(),
  }
}

/** Byte-identical to `ProjectContextPackRecord.renderedMarkdown` (Swift). */
export function renderedContextPackMarkdown(pack: ProjectContextPackRecord): string {
  const sections: string[] = [
    '# Mu Project Context Pack',
    '',
    `Project: ${pack.projectID.toLowerCase()}`,
    `Task: ${pack.taskID.toLowerCase()}`,
    `Workspace: ${pack.workspaceID.toLowerCase()}`,
    '',
    '## Objective',
    pack.objective,
  ]
  appendList(sections, 'Relevant files', pack.relevantFilePaths)
  appendList(sections, 'Constraints', pack.constraints)
  appendList(sections, 'Permissions', pack.permissions.map((p) => p))
  appendList(sections, 'Acceptance tests', pack.acceptanceTests)
  appendList(sections, 'Expected outputs', pack.expectedOutputs)
  if (pack.baseRevision !== undefined && pack.baseRevision !== '') {
    sections.push('', '## Base revision', pack.baseRevision)
  }
  if (pack.acceptedArtifactIDs.length > 0) {
    appendList(sections, 'Accepted artifacts', pack.acceptedArtifactIDs.map((id) => id.toLowerCase()))
  }
  if (pack.dependencyTaskIDs.length > 0) {
    appendList(sections, 'Dependencies', pack.dependencyTaskIDs.map((id) => id.toLowerCase()))
  }
  if (pack.renderedContextMarkdown !== undefined && pack.renderedContextMarkdown !== '') {
    sections.push('', '## Governed Project Context', pack.renderedContextMarkdown)
  }
  return sections.join('\n')
}

function appendList(sections: string[], title: string, values: readonly string[]): void {
  if (values.length === 0) return
  sections.push('', `## ${title}`, ...values.map((v) => `- ${v}`))
}
