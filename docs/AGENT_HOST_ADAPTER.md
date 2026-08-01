# AgentHostAdapter — 稳定宿主契约

> 状态：正式契约（Phase 4 Harness 之上的稳定协议层，`mu-core/src/host-adapter/`）。
> QM 只作为其中一个可选 Host，永远不是 Mu 的数据库或权限真相源。

## 目标

Mu 的 ControlPlaneService 只通过 `AgentHostAdapter` 与执行宿主对话。宿主可以是
本地子进程（Claude Code CLI、Codex App Server）、Experimental QM Bridge，或未来
任何 runtime。契约保证：

- 宿主**无法**触达 Mu 的 Project Kernel / Context Kernel / 权限数据
- 宿主拿到的只是**受控的 Bounded Context Pack**（SHA-256 校验）
- 宿主的输出回到 Mu 后只是 Candidate / Artifact，必须经 Mu Review

## 契约（endpoint-scoped 能力）

```typescript
export interface AgentHostAdapter {
  readonly hostID: string                    // 'claude-code.cli' / 'codex.app-server' / 'qm.bridge'
  readonly capabilities: HostCapabilities    // 能力声明（含 approvals / deliveryReceipt）

  probe(scope: HostEndpointScope): Promise<HostProbeResult> // 按 endpoint 探活、版本、登录态
  submit(scope: HostEndpointScope, input: HostTurnInput, signal?: AbortSignal): // 提交一轮受控 turn，
    AsyncIterable<HostTurnEvent>                           //   流式事件直到终态
  interrupt(scope: HostEndpointScope, sessionID: string): Promise<void> // 中断活跃 turn
  resolveApproval?(resolution: HostApprovalResolution):   // 可选：审批决策回传宿主
    Promise<void>
  listArtifacts(scope: HostEndpointScope, sessionID: string): Promise<HostArtifactRecord[]>
  discoverHistory?(scope: HostEndpointScope, workspacePath: string): Promise<HostHistoryCandidate[]>
  hydrateHistory?(scope: HostEndpointScope, candidate: HostHistoryCandidate): Promise<HostHistoryCandidate>
  stop?(): void                                           // 停止长驻宿主进程
}
```

`HostEndpointScope` carries the endpoint ID, runtime type, display name, and
the full `AgentRuntimeInstanceIdentity`. Every operation is evaluated against
that scope; a provider string by itself is never sufficient to select a
terminal or desktop instance.

| 能力 | 语义 | 本地宿主 | QM Bridge（实验） |
|---|---|---|---|
| probe | 版本 / 登录 / 可用性 | ✓ | ✓（签名探测） |
| submit | 受控 turn，流式事件 | ✓ | ✓（`/v1/turns`） |
| events | session_started / visible_text / approval_requested / completed / failed / cancelled | ✓ | ✓（+ SSE session-state） |
| interrupt | 中断活跃 turn | ✓ | ✓（run signal abort） |
| approvals | 上报 `report_only`，或 `resolve_forward` | report_only | report_only（上报 pendingApprovals；resolve 通道待真实契约验收） |
| artifacts | 列出 turn 产物 | 未实现（返回空，Phase 5 控制面接管） | ✓（attachments 映射） |
| delivery receipt | 宿主确认交付回执 | 不适用（Mu 侧生成 ContextDeliveryReceipt） | 未来（QM delivery-target 语义） |

## 事件模型（HostTurnEvent）

```
session_started { sessionID }          // 宿主原生会话已建立
visible_text    { text }               // 流式可见文本（增量）
approval_requested { approvals[] }     // 宿主请求审批（Mu 内部决策）
completed       { result }             // 终态：success / failed / cancelled / pending_approval / queued
failed          { errorMessage }       // 宿主级失败（无结果）
cancelled                              // 中止（无结果）
```

## Mu 永远持有（不委派给宿主）

- Agent 身份、Actor、Principal 所有权、Delegation、17 项权限
- Task Lease 栅栏令牌（fencing token）
- Context 记录生命周期（Candidate → Accepted → Superseded）
- 不可变 Context Pack（SHA-256 验证）
- **Delivery receipts**：每次 turn 由 Mu 签发不可变 `ContextDeliveryReceipt`；
  宿主的 `deliveryReceipt` 标志只表示它是否确认交付，不替代 Mu 的回执
- Review / Approval 工作流、Project 成员

## 宿主实现要求

1. 实现 `AgentHostAdapter` 全部必选方法；每次操作必须接收并校验 `HostEndpointScope`，能力不符的字段如实声明（`supportsArtifacts: false`
   等），不得虚假上报
2. `submit` 的输入只接受 Mu 构造的 `HostTurnInput`（含 Context Pack）；禁止宿主自行
   读取 Mu 数据库
3. 审批：默认 `report_only`——宿主上报 `approval_requested` 事件，Mu 内部走
   ProjectApprovalRecord；宿主有 resolve 通道时才声明 `resolve_forward`
4. `stop()` 必须清理长驻子进程/连接（如 Codex App Server 的 stdio 管道，否则事件循环悬挂）

## 现有实现

- `toAgentHostAdapter(harness, options)`：把 Phase 4 Harness 适配为 AgentHostAdapter
  （`harness-adapter.ts`）；控制面默认通过它工作
- `LocalChildProcessHarness` → hostID `mu.local-harness`（Claude/Codex 子进程）
- `QMHTTPHarness` → hostID `qm.bridge`（**Experimental**，见 `qm-http.ts` 顶部声明）
- 控制面：`ControlPlaneDependencies.host` 可显式注入；缺省 `toAgentHostAdapter(harness)`
