import type { FastifyInstance } from 'fastify'
import type { CollaborationService, ControlPlaneService } from '@mu/core'
import type { SSEEventHub } from '../sse/events.ts'
import { registerProjectsRoutes } from './projects.ts'
import { registerTasksRoutes } from './tasks.ts'
import { registerTurnsRoutes } from './turns.ts'
import { registerContextRoutes } from './context.ts'
import { registerApprovalRoutes } from './approvals.ts'
import { registerHandoffRoutes } from './handoffs.ts'
import { registerLedgerRoutes } from './ledger.ts'
import { registerEventsRoutes } from './events.ts'
import { registerHistoryRoutes } from './history.ts'
import { registerCollaborationRoutes } from './collaboration.ts'

export interface RouteContext {
  readonly service: ControlPlaneService
  readonly hub: SSEEventHub
  readonly collaboration: CollaborationService
  readonly now: () => Date
}

export function registerRoutes(app: FastifyInstance, ctx: RouteContext): void {
  registerProjectsRoutes(app, ctx)
  registerTasksRoutes(app, ctx)
  registerTurnsRoutes(app, ctx)
  registerContextRoutes(app, ctx)
  registerApprovalRoutes(app, ctx)
  registerHandoffRoutes(app, ctx)
  registerLedgerRoutes(app, ctx)
  registerEventsRoutes(app, ctx)
  registerHistoryRoutes(app, ctx)
  registerCollaborationRoutes(app, ctx)
}
