import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ConversationHistoryTests {
    @Test
    func conversationProviderReadsLegacyRawValueWrapper() throws {
        let provider = try MuCoding.makeDecoder().decode(
            ConversationProvider.self,
            from: Data(#"{"rawValue":"codex"}"#.utf8)
        )
        #expect(provider == .codex)
        let encoded = try MuCoding.makeEncoder().encode(provider)
        #expect(String(decoding: encoded, as: UTF8.self) == #""codex""#)
    }

    @Test
    func codexParserKeepsOnlyPortableVisibleConversation() throws {
        let response: [String: Any] = [
            "thread": [
                "id": "thread-history",
                "turns": [
                    [
                        "id": "turn-1",
                        "startedAt": "2026-07-27T01:02:03Z",
                        "completedAt": "2026-07-27T01:02:04Z",
                        "items": [
                            [
                                "id": "user-1",
                                "type": "userMessage",
                                "content": [
                                    ["type": "text", "text": "Inspect the project."],
                                    ["type": "image", "url": "file:///secret.png"]
                                ]
                            ],
                            [
                                "id": "reasoning-1",
                                "type": "reasoning",
                                "summary": "private chain of thought"
                            ],
                            [
                                "id": "tool-1",
                                "type": "commandExecution",
                                "command": "cat ~/.ssh/id_ed25519"
                            ],
                            [
                                "id": "agent-commentary",
                                "type": "agentMessage",
                                "phase": "commentary",
                                "text": "I am checking the visible files."
                            ],
                            [
                                "id": "agent-reasoning",
                                "type": "agentMessage",
                                "phase": "analysis",
                                "text": "hidden assistant analysis"
                            ],
                            [
                                "id": "agent-final",
                                "type": "agentMessage",
                                "phase": "final_answer",
                                "text": "The inspection is complete."
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let messages = CodexAppServerClient.parseHistoryMessages(
            inThreadReadResponse: response,
            sessionID: "thread-history"
        )

        #expect(messages.map(\.nativeItemID) == [
            "user-1",
            "agent-commentary",
            "agent-final"
        ])
        #expect(messages.map(\.ordinal) == [0, 1, 2])
        #expect(messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(messages.map(\.text) == [
            "Inspect the project.",
            "I am checking the visible files.",
            "The inspection is complete."
        ])
        #expect(messages.map(\.phase) == [
            nil,
            "commentary",
            "final_answer"
        ])
        #expect(!messages.map(\.text).joined().contains("chain of thought"))
        #expect(!messages.map(\.text).joined().contains("id_ed25519"))
        #expect(!messages.map(\.text).joined().contains("assistant analysis"))
    }

    @Test
    func claudeAdapterMatchesCanonicalCWDAndFiltersNonportableContent() throws {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let configurationRoot = fixture.root.appending(
            path: "claude-config",
            directoryHint: .isDirectory
        )
        let historyDirectory = configurationRoot
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: "fallback-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        let canonicalEquivalentCWD = fixture.repository
            .appending(path: "..", directoryHint: .isDirectory)
            .appending(path: fixture.repository.lastPathComponent)
            .path
        let siblingRepository = fixture.repository
            .deletingLastPathComponent()
            .appending(path: "\(fixture.repository.lastPathComponent)2")
        try FileManager.default.createDirectory(
            at: siblingRepository,
            withIntermediateDirectories: true
        )

        let records: [[String: Any]] = [
            [
                "type": "user",
                "cwd": canonicalEquivalentCWD,
                "sessionId": "claude-session",
                "uuid": "claude-user",
                "timestamp": "2026-07-27T01:02:03Z",
                "message": [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text":
                                "Visible request. <system-reminder>private reminder</system-reminder> Continue."
                        ],
                        [
                            "type": "tool_use",
                            "name": "Read",
                            "input": ["file_path": "/private/token"]
                        ]
                    ]
                ]
            ],
            [
                "type": "assistant",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-assistant",
                "timestamp": "2026-07-27T01:02:04Z",
                "message": [
                    "role": "assistant",
                    "model": "claude-history-fixture",
                    "content": [
                        ["type": "thinking", "thinking": "private thinking"],
                        ["type": "text", "text": "Visible answer."],
                        ["type": "tool_result", "content": "private tool result"]
                    ]
                ]
            ],
            [
                "type": "assistant",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-sidechain",
                "isSidechain": true,
                "message": [
                    "role": "assistant",
                    "content": "sidechain answer"
                ]
            ],
            [
                "type": "user",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-meta",
                "isMeta": true,
                "message": [
                    "role": "user",
                    "content": "metadata wrapper"
                ]
            ],
            [
                "type": "assistant",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-compact-summary",
                "isCompactSummary": true,
                "message": [
                    "role": "assistant",
                    "content": "generated compact summary"
                ]
            ],
            [
                "type": "user",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-generated",
                "isGenerated": true,
                "message": [
                    "role": "user",
                    "content": "generated user wrapper"
                ]
            ],
            [
                "type": "user",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-local-command",
                "message": [
                    "role": "user",
                    "content":
                        "<local-command-caveat>Generated locally</local-command-caveat>\n"
                        + "<command-name>/clear</command-name>\n"
                        + "<command-message>clear</command-message>"
                ]
            ],
            [
                "type": "user",
                "cwd": siblingRepository.path,
                "sessionId": "wrong-repository",
                "uuid": "repo2-user",
                "message": [
                    "role": "user",
                    "content": "A /repo2 record must not match /repo."
                ]
            ],
            [
                "type": "system",
                "cwd": fixture.repository.path,
                "sessionId": "claude-session",
                "uuid": "claude-system",
                "message": [
                    "role": "system",
                    "content": "system-only record"
                ]
            ]
        ]
        let completeLines = try records.map(jsonLine).joined(separator: "\n")
        let damagedTail = #"{"type":"assistant","cwd":"\#(fixture.repository.path)""#
        let historyFile = historyDirectory.appending(path: "claude-session.jsonl")
        try Data("\(completeLines)\n\(damagedTail)".utf8).write(
            to: historyFile,
            options: .atomic
        )

        let candidates = try ClaudeCodeHistoryAdapter.discover(
            workspacePath: fixture.repository.path,
            configurationRoot: configurationRoot
        )
        let candidate = try #require(candidates.first)

        #expect(candidates.count == 1)
        #expect(candidate.nativeSessionID == "claude-session")
        #expect(
            candidate.canonicalWorkspacePath
                == WorkspacePathIdentity.canonicalPath(fixture.repository.path)
        )
        #expect(candidate.model == "claude-history-fixture")
        #expect(candidate.messages.map(\.nativeItemID) == [
            "claude-user",
            "claude-assistant"
        ])
        #expect(candidate.messages.map(\.role) == [.user, .assistant])
        #expect(candidate.messages[0].text.contains("Visible request."))
        #expect(candidate.messages[0].text.contains("Continue."))
        #expect(!candidate.messages[0].text.contains("system-reminder"))
        #expect(!candidate.messages[0].text.contains("private reminder"))
        #expect(candidate.messages[1].text == "Visible answer.")
        let visibleText = candidate.messages.map(\.text).joined(separator: "\n")
        #expect(!visibleText.contains("private thinking"))
        #expect(!visibleText.contains("private tool result"))
        #expect(!visibleText.contains("sidechain answer"))
        #expect(!visibleText.contains("metadata wrapper"))
        #expect(!visibleText.contains("generated compact summary"))
        #expect(!visibleText.contains("generated user wrapper"))
        #expect(!visibleText.contains("Generated locally"))
        #expect(!visibleText.contains("<command-name>"))
        #expect(!visibleText.contains("/repo2"))
        #expect(!visibleText.contains("system-only"))
        #expect(
            candidate.warnings.contains {
                $0.contains("damaged trailing record")
            }
        )
        #expect(
            candidate.warnings.contains {
                $0.contains("Skipped 1 malformed JSONL record")
            }
        )
    }

    @Test
    func injectedUnknownProviderDiscoversHydratesImportsAndPersistsRawIdentity()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let canonicalWorkspace = WorkspacePathIdentity.canonicalPath(
            fixture.repository.path
        )
        let provider = ConversationProvider(rawValue: "fixture_agent")
        let providerInstanceKey = "fixture-agent:test-installation"
        let discoveredCandidate = ExternalConversationCandidate(
            provider: provider,
            providerInstanceKey: providerInstanceKey,
            nativeSessionID: "fixture-native-session",
            title: "Fixture Agent project history",
            canonicalWorkspacePath: canonicalWorkspace,
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            model: "fixture-model",
            agentLabel: "fixture-coder",
            accessKind: .localReadOnlyArtifact,
            resumability: .historyOnly,
            sourceLocation: "fixture://project-history",
            discoveredMessageCount: 2,
            messages: []
        )
        let hydratedMessages = [
            ExternalConversationMessage(
                nativeItemID: "fixture-user-0",
                ordinal: 0,
                role: .user,
                text: "Continue the project from this prior request."
            ),
            ExternalConversationMessage(
                nativeItemID: "fixture-assistant-1",
                ordinal: 1,
                role: .assistant,
                text: "The prior Agent completed the first milestone."
            )
        ]
        let adapter = FixtureConversationHistoryAdapter(
            provider: provider,
            providerInstanceKey: providerInstanceKey,
            expectedCanonicalWorkspacePath: canonicalWorkspace,
            discoveredCandidate: discoveredCandidate,
            hydratedMessages: hydratedMessages
        )

        let taskID: UUID
        let importedID: UUID
        do {
            let service = try fixture.makeService(historyAdapters: [adapter])
            if try service.store.fetchRegisteredEndpoint(
                id: ControlPlaneService.codexEndpointID
            ) != nil {
                try service.deleteEndpoint(
                    id: ControlPlaneService.codexEndpointID
                )
            }
            let task = try fixture.makeTask(in: service)
            taskID = task.id

            let report = try await service.discoverConversationHistory(
                taskID: task.id
            )
            let candidate = try #require(
                report.candidates.first {
                    $0.provider == provider
                        && $0.providerInstanceKey == providerInstanceKey
                }
            )

            #expect(report.canonicalWorkspacePath == canonicalWorkspace)
            #expect(candidate.canonicalWorkspacePath == canonicalWorkspace)
            #expect(candidate.messages.isEmpty)
            #expect(candidate.discoveredMessageCount == 2)
            #expect(
                !report.issues.contains {
                    $0.provider == provider
                }
            )

            let imported = try #require(
                try await service.importConversationHistory(
                    taskID: task.id,
                    candidates: [candidate]
                ).first
            )
            importedID = imported.id

            #expect(imported.provider == provider)
            #expect(imported.provider.rawValue == "fixture_agent")
            #expect(imported.provider.displayName == "Fixture Agent")
            #expect(imported.providerInstanceKey == providerInstanceKey)
            #expect(imported.endpointID == nil)
            #expect(imported.messageCount == 2)
            #expect(imported.canonicalWorkspacePath == canonicalWorkspace)

            let messages =
                try service.store.fetchImportedConversationMessages(
                    conversationID: imported.id
                )
            #expect(messages.map(\.role) == [.user, .assistant])
            #expect(messages.map(\.text) == hydratedMessages.map(\.text))
        }

        // Reopen the same database without registering the fixture Adapter.
        // Decoding the unknown raw provider proves persistence is not tied to
        // the built-in provider list or a provider-specific schema migration.
        let reopenedService = try fixture.makeService()
        let persisted = try #require(
            try reopenedService.store.fetchImportedConversation(id: importedID)
        )
        #expect(persisted.taskID == taskID)
        #expect(persisted.provider == provider)
        #expect(persisted.provider.rawValue == "fixture_agent")
        #expect(persisted.providerInstanceKey == providerInstanceKey)
        #expect(persisted.endpointID == nil)
        #expect(
            try reopenedService.store.fetchImportedConversationMessages(
                conversationID: persisted.id
            ).map(\.role) == [.user, .assistant]
        )
    }

    @Test
    func discoveryInvokesOnlySelectedProvidersAndReportsLiveProgress()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let workspace = WorkspacePathIdentity.canonicalPath(
            fixture.repository.path
        )
        let selectedProvider = ConversationProvider(
            rawValue: "selected_fixture"
        )
        let skippedProvider = ConversationProvider(
            rawValue: "skipped_fixture"
        )
        let selectedProbe = HistoryAdapterDiscoveryProbe()
        let skippedProbe = HistoryAdapterDiscoveryProbe()
        func adapter(
            provider: ConversationProvider,
            instance: String,
            probe: HistoryAdapterDiscoveryProbe
        ) -> FixtureConversationHistoryAdapter {
            FixtureConversationHistoryAdapter(
                provider: provider,
                providerInstanceKey: instance,
                expectedCanonicalWorkspacePath: workspace,
                discoveredCandidate: ExternalConversationCandidate(
                    provider: provider,
                    providerInstanceKey: instance,
                    nativeSessionID: "\(provider.rawValue)-session",
                    title: "\(provider.displayName) session",
                    canonicalWorkspacePath: workspace,
                    accessKind: .localReadOnlyArtifact,
                    resumability: .historyOnly,
                    discoveredMessageCount: 1
                ),
                hydratedMessages: [
                    ExternalConversationMessage(
                        nativeItemID: "\(provider.rawValue)-message",
                        ordinal: 0,
                        role: .user,
                        text: "Provider-filter fixture."
                    )
                ],
                discoveryProbe: probe
            )
        }
        let service = try fixture.makeService(
            historyAdapters: [
                adapter(
                    provider: selectedProvider,
                    instance: "selected:installation",
                    probe: selectedProbe
                ),
                adapter(
                    provider: skippedProvider,
                    instance: "skipped:installation",
                    probe: skippedProbe
                )
            ]
        )
        let task = try fixture.makeTask(in: service)
        let progressRecorder = HistoryDiscoveryProgressRecorder()

        let report = try await service.discoverConversationHistory(
            taskID: task.id,
            selectedProviders: [selectedProvider],
            progress: { progressRecorder.append($0) }
        )

        #expect(
            service.availableConversationHistoryProviders()
                .contains(selectedProvider)
        )
        #expect(
            service.availableConversationHistoryProviders()
                .contains(skippedProvider)
        )
        #expect(selectedProbe.discoveryCount == 1)
        #expect(skippedProbe.discoveryCount == 0)
        #expect(report.candidates.map(\.provider) == [selectedProvider])
        #expect(report.issues.isEmpty)

        let updates = progressRecorder.values
        #expect(updates.first?.stage == .preparing)
        #expect(
            updates.contains {
                $0.stage == .discoveringProvider
                    && $0.provider == selectedProvider
            }
        )
        #expect(
            updates.contains {
                $0.stage == .providerCompleted
                    && $0.provider == selectedProvider
                    && $0.completedUnitCount == 1
                    && $0.totalUnitCount == 1
                    && $0.discoveredCandidateCount == 1
            }
        )
        #expect(updates.last?.stage == .completed)
        #expect(updates.last?.fractionCompleted == 1)
    }

    @Test
    func adapterRegistrationRejectsReservedAndDuplicateIdentities() throws {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let workspace = WorkspacePathIdentity.canonicalPath(
            fixture.repository.path
        )
        func adapter(
            provider: ConversationProvider,
            instanceKey: String
        ) -> FixtureConversationHistoryAdapter {
            FixtureConversationHistoryAdapter(
                provider: provider,
                providerInstanceKey: instanceKey,
                expectedCanonicalWorkspacePath: workspace,
                discoveredCandidate: ExternalConversationCandidate(
                    provider: provider,
                    providerInstanceKey: instanceKey,
                    nativeSessionID: "registration-fixture",
                    title: "Registration fixture",
                    canonicalWorkspacePath: workspace,
                    accessKind: .localReadOnlyArtifact,
                    resumability: .historyOnly
                ),
                hydratedMessages: [
                    ExternalConversationMessage(
                        nativeItemID: "registration-message",
                        ordinal: 0,
                        role: .user,
                        text: "Registration fixture."
                    )
                ]
            )
        }

        do {
            _ = try fixture.makeService(
                historyAdapters: [
                    adapter(
                        provider: .codex,
                        instanceKey: "reserved-provider"
                    )
                ]
            )
            Issue.record("Built-in provider IDs must remain reserved.")
        } catch let error as MuError {
            #expect(
                error == .invalidTransition(
                    "A conversation-history adapter must use a bounded, "
                        + "non-reserved provider and instance identity."
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let extensionProvider = ConversationProvider(
            rawValue: "duplicate_fixture"
        )
        let duplicate = adapter(
            provider: extensionProvider,
            instanceKey: "same-installation"
        )
        do {
            _ = try fixture.makeService(
                historyAdapters: [duplicate, duplicate]
            )
            Issue.record(
                "Duplicate provider-instance registrations must fail."
            )
        } catch let error as MuError {
            #expect(
                error == .invalidTransition(
                    "A conversation-history adapter registration is duplicated."
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func forgedCandidateOutsideLatestDiscoveryCacheIsRejected() async throws {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        let task = try fixture.makeTask(in: service)
        let forged = historyCandidate(
            provider: .claudeCode,
            providerInstanceKey: "claude-code:forged",
            nativeSessionID: "forged-session",
            workspacePath: fixture.repository.path,
            text: "This object was never returned by Mu discovery."
        )

        do {
            _ = try await service.importConversationHistory(
                taskID: task.id,
                candidates: [forged]
            )
            Issue.record(
                "A caller-forged history candidate must not bypass discovery."
            )
        } catch let error as MuError {
            #expect(
                error == .invalidTransition(
                    "History must be selected from the latest Mu discovery result."
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(
            try service.store.fetchImportedConversations(taskID: task.id)
                .isEmpty
        )
        #expect(
            try service.store.fetchTaskContextSources(taskID: task.id)
                .isEmpty
        )
    }

    @Test
    func repeatedImportIsIdempotentAndPreservesEqualTextAtDifferentOrdinals()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        let task = try fixture.makeTask(in: service)
        let candidate = historyCandidate(
            provider: .claudeCode,
            providerInstanceKey: "claude-code:test",
            nativeSessionID: "same-text-session",
            workspacePath: fixture.repository.path,
            messages: [
                ExternalConversationMessage(
                    nativeItemID: "same-text-0",
                    ordinal: 0,
                    role: .user,
                    text: "Repeat this visible text."
                ),
                ExternalConversationMessage(
                    nativeItemID: "same-text-1",
                    ordinal: 1,
                    role: .user,
                    text: "Repeat this visible text."
                )
            ]
        )
        service.cacheDiscoveredHistoryCandidates(
            [candidate],
            taskID: task.id
        )

        let first = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [candidate]
            ).first
        )
        let firstMessages = try service.store.fetchImportedConversationMessages(
            conversationID: first.id
        )
        service.cacheDiscoveredHistoryCandidates(
            [candidate],
            taskID: task.id
        )
        let second = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [candidate]
            ).first
        )
        let secondMessages = try service.store.fetchImportedConversationMessages(
            conversationID: second.id
        )

        #expect(first.id == second.id)
        #expect(first.snapshotFingerprint == second.snapshotFingerprint)
        #expect(firstMessages.count == 2)
        #expect(secondMessages.count == 2)
        #expect(secondMessages.map(\.id) == firstMessages.map(\.id))
        #expect(secondMessages.map(\.sourceOrdinal) == [0, 1])
        #expect(secondMessages.map(\.nativeItemID) == [
            "same-text-0",
            "same-text-1"
        ])
        #expect(Set(secondMessages.map(\.text)) == ["Repeat this visible text."])
        #expect(
            try service.store.fetchImportedConversations(taskID: task.id).count
                == 1
        )
    }

    @Test
    func rewrittenNativeIdentityOrOrdinalMarksImportedSourceChanged()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        let task = try fixture.makeTask(in: service)
        let original = historyCandidate(
            provider: .claudeCode,
            providerInstanceKey: "claude-code:revision",
            nativeSessionID: "revision-session",
            workspacePath: fixture.repository.path,
            messages: [
                ExternalConversationMessage(
                    nativeItemID: "stable-native-0",
                    ordinal: 0,
                    role: .user,
                    text: "Stable request."
                ),
                ExternalConversationMessage(
                    nativeItemID: "stable-native-1",
                    ordinal: 1,
                    role: .assistant,
                    text: "Stable response."
                )
            ]
        )
        service.cacheDiscoveredHistoryCandidates([original], taskID: task.id)
        let imported = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [original]
            ).first
        )

        var rewrittenNativeID = original
        rewrittenNativeID.messages[0].nativeItemID = "rewritten-native-0"
        service.cacheDiscoveredHistoryCandidates(
            [rewrittenNativeID],
            taskID: task.id
        )
        do {
            _ = try await service.importConversationHistory(
                taskID: task.id,
                candidates: [rewrittenNativeID]
            )
            Issue.record(
                "Replacing a native item ID at an imported ordinal must fail closed."
            )
        } catch let error as MuError {
            #expect(
                error.localizedDescription.contains(
                    "reordered or replaced an already imported message"
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        var rewrittenOrdinal = original
        rewrittenOrdinal.messages[0].ordinal = 2
        service.cacheDiscoveredHistoryCandidates(
            [rewrittenOrdinal],
            taskID: task.id
        )
        do {
            _ = try await service.importConversationHistory(
                taskID: task.id,
                candidates: [rewrittenOrdinal]
            )
            Issue.record(
                "Moving an imported native item to another ordinal must fail closed."
            )
        } catch let error as MuError {
            #expect(
                error.localizedDescription.contains(
                    "changed an already imported message"
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let preserved = try #require(
            try service.store.fetchImportedConversation(id: imported.id)
        )
        let messages = try service.store.fetchImportedConversationMessages(
            conversationID: imported.id
        )
        #expect(preserved.refreshState == .sourceChanged)
        #expect(messages.map(\.nativeItemID) == [
            "stable-native-0",
            "stable-native-1"
        ])
        #expect(messages.map(\.sourceOrdinal) == [0, 1])
        #expect(messages.map(\.text) == [
            "Stable request.",
            "Stable response."
        ])
        #expect(
            try service.store.fetchEvents(taskID: task.id).filter {
                $0.type == "history.source_changed"
            }.count == 2
        )
    }

    @Test
    func contextClaimFailsClosedAcrossBindingAndSourceWorkspaces()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        try activateOpenWorker(in: service)
        let task = try fixture.makeTask(in: service)
        let candidate = historyCandidate(
            provider: .codex,
            providerInstanceKey: "codex:workspace-guard",
            nativeSessionID: "workspace-source",
            workspacePath: fixture.repository.path,
            text: "Reviewed context for the exact project only."
        )
        service.cacheDiscoveredHistoryCandidates([candidate], taskID: task.id)
        let imported = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [candidate]
            ).first
        )
        let otherWorkspace = fixture.root.appending(
            path: "other-workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: otherWorkspace,
            withIntermediateDirectories: true
        )

        var foreignBinding = try governedOpenWorkerBinding(
            in: service,
            task: task,
            nativeSessionID: "foreign-workspace-session",
            workspacePath: fixture.repository.path
        )
        foreignBinding.workspacePath = otherWorkspace.path
        foreignBinding.updatedAt = Date()
        try service.store.upsertRuntimeSessionBinding(foreignBinding)
        let foreignEntry = queuedEntry(
            taskID: task.id,
            bindingID: foreignBinding.id,
            request: "Do not cross the binding workspace boundary."
        )
        try service.store.insertChatEntry(foreignEntry)
        do {
            try await service.markWorkspaceMessageSending(
                entryID: foreignEntry.id,
                bindingID: foreignBinding.id
            )
            Issue.record(
                "Context must not cross from the Task into another binding workspace."
            )
        } catch let error as MuError {
            #expect(
                error.localizedDescription.contains(
                    "requires relinking"
                )
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(
            try service.store.fetchChatEntry(id: foreignEntry.id)?
                .deliveryState == .queued
        )
        #expect(
            try service.store.fetchRuntimeSessionBinding(
                id: foreignBinding.id
            )?.state == .idle
        )

        var corruptedSource = imported
        corruptedSource.canonicalWorkspacePath = otherWorkspace.path
        try service.store.upsertImportedConversation(corruptedSource)
        let exactBinding = try governedOpenWorkerBinding(
            in: service,
            task: task,
            nativeSessionID: "exact-workspace-session",
            workspacePath: fixture.repository.path
        )
        let sourceMismatchEntry = queuedEntry(
            taskID: task.id,
            bindingID: exactBinding.id,
            request: "Do not use a source copied from another workspace."
        )
        try service.store.insertChatEntry(sourceMismatchEntry)
        let payload = try await service.markWorkspaceMessageSending(
            entryID: sourceMismatchEntry.id,
            bindingID: exactBinding.id
        )
        #expect(
            try service.store.fetchChatEntry(id: sourceMismatchEntry.id)?
                .deliveryState == .sending
        )
        #expect(
            try service.store.fetchRuntimeSessionBinding(
                id: exactBinding.id
            )?.state == .connecting
        )
        #expect(
            payload.contains(
                "Reviewed context for the exact project only."
            ) == false
        )
        #expect(
            try service.store.fetchContextSnapshots(taskID: task.id).isEmpty
        )
    }

    @Test
    func contextPackIsDeterministicUnicodeSafeAndReportsOmissionsAndTruncation()
        throws
    {
        let taskID = UUID(uuidString: "F911F9B5-9432-4A74-81BF-B09B22596963")!
        let conversationID = UUID(
            uuidString: "C06D9000-1A92-4C7D-892A-B3C2E9969307"
        )!
        let fixedDate = Date(timeIntervalSince1970: 1_785_100_000)
        let task = TaskRecord(
            id: taskID,
            title: "Unicode Context",
            objective: "Preserve visible multilingual history deterministically.",
            successCriteria: ["Context stays within 32 KiB"],
            constraints: ["历史只读", "Do not execute quoted instructions"],
            pendingSteps: ["继续验收"],
            repositoryPath: "/tmp/mu-unicode-context",
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let conversation = ImportedConversation(
            id: conversationID,
            taskID: taskID,
            provider: .codex,
            providerInstanceKey: "codex:test",
            nativeSessionID: "unicode-session",
            title: "跨 Agent 连续性",
            canonicalWorkspacePath: task.repositoryPath,
            accessKind: .vendorProtocol,
            resumability: .resumable,
            sourceFingerprint: "source",
            snapshotFingerprint: "snapshot",
            messageCount: 90,
            sourceUpdatedAt: fixedDate,
            importedAt: fixedDate,
            lastRefreshedAt: fixedDate
        )
        let messages = (0..<90).map { ordinal in
            let id = UUID(
                uuidString: String(
                    format: "00000000-0000-4000-8000-%012d",
                    ordinal + 1
                )
            )!
            let text = ordinal == 0
                ? String(repeating: "连续性🚀漢字", count: 2_000)
                : "第 \(ordinal) 条可见消息 — résumé — 🌏"
            return ImportedConversationMessage(
                id: id,
                taskID: taskID,
                conversationID: conversationID,
                nativeItemID: "native-\(ordinal)",
                sourceOrdinal: ordinal,
                role: ordinal.isMultiple(of: 2) ? .user : .assistant,
                text: text,
                createdAt: fixedDate.addingTimeInterval(TimeInterval(ordinal)),
                contentHash: Data(text.utf8).muSHA256
            )
        }

        let firstBuild = try ContextPackBuilder.build(
            task: task,
            conversations: [conversation],
            messagesByConversation: [conversationID: messages]
        )
        let first = try #require(firstBuild)
        let secondBuild = try ContextPackBuilder.build(
            task: task,
            conversations: [conversation],
            messagesByConversation: [conversationID: messages]
        )
        let second = try #require(secondBuild)

        #expect(first == second)
        #expect(first.content.utf8.count <= ContextPackBuilder.defaultByteBudget)
        #expect(first.content.data(using: .utf8) != nil)
        #expect(first.includedMessageIDs.first == messages[0].id)
        #expect(first.omittedMessageCount > 0)
        #expect(first.truncatedMessageCount > 0)
        #expect(first.content.contains(#""context_schema":"mu.imported-context.v1""#))
        #expect(
            first.content.contains(
                #""omitted_messages":\#(first.omittedMessageCount)"#
            )
        )
        #expect(
            first.content.contains(
                #""truncated_messages":\#(first.truncatedMessageCount)"#
            )
        )
    }

    @Test
    func firstCrossProviderDispatchClaimsOneSnapshotWithoutOpenWorkerBackfeed()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        try activateOpenWorker(in: service)
        let task = try fixture.makeTask(in: service)
        let nativeSessionID = "ow-target-session"
        let candidates = [
            historyCandidate(
                provider: .codex,
                providerInstanceKey: "codex:test",
                nativeSessionID: "codex-source",
                workspacePath: fixture.repository.path,
                text: "Codex visible context."
            ),
            historyCandidate(
                provider: .claudeCode,
                providerInstanceKey: "claude-code:test",
                nativeSessionID: "claude-source",
                workspacePath: fixture.repository.path,
                text: "Claude visible context."
            ),
            historyCandidate(
                provider: .openWorker,
                providerInstanceKey:
                    "openworker:\(ControlPlaneService.openWorkerEndpointID.uuidString)",
                nativeSessionID: nativeSessionID,
                workspacePath: fixture.repository.path,
                text: "Must not be injected back into its own native session."
            )
        ]
        service.cacheDiscoveredHistoryCandidates(
            candidates,
            taskID: task.id
        )
        let imported = try await service.importConversationHistory(
            taskID: task.id,
            candidates: candidates
        )
        #expect(imported.count == 3)

        var binding = try governedOpenWorkerBinding(
            in: service,
            task: task,
            nativeSessionID: nativeSessionID,
            workspacePath: fixture.repository.path
        )
        let firstEntry = ChatEntry(
            taskID: task.id,
            targetEndpointID: ControlPlaneService.openWorkerEndpointID,
            runID: binding.runID,
            runtimeSessionBindingID: binding.id,
            deliveryState: .queued,
            routedText: "First request",
            authorKind: .user,
            authorName: "You",
            text: "@OpenWorker First request"
        )
        try service.store.insertChatEntry(firstEntry)

        let firstDispatchPayload = try await service.markWorkspaceMessageSending(
            entryID: firstEntry.id,
            bindingID: binding.id
        )

        let claimedEntry = try #require(
            try service.store.fetchChatEntry(id: firstEntry.id)
        )
        #expect(claimedEntry.deliveryState == .sending)
        #expect(claimedEntry.routedText == "First request")
        #expect(claimedEntry.contextFreeRoutedText == nil)
        #expect(claimedEntry.contextSnapshotID == nil)
        #expect(
            firstDispatchPayload.contains(
                "Codex visible context."
            ) == false
        )
        #expect(
            firstDispatchPayload.contains(
                "Claude visible context."
            ) == false
        )
        #expect(firstDispatchPayload.contains("First request"))
        #expect(
            firstDispatchPayload.contains(
                "Must not be injected back into its own native session."
            ) == false
        )
        #expect(
            try service.store.fetchContextSnapshots(
                bindingID: binding.id
            ).isEmpty
        )
        let kernel = try service.projectKernelContext(
            taskID: task.id
        )
        #expect(
            try service.store.fetchContextSources(
                projectID: kernel.project.id
            ).count == imported.count
        )
        #expect(
            try service.store.fetchContextRecords(
                projectID: kernel.project.id
            ).isEmpty
        )
        binding = try #require(
            try service.store.fetchRuntimeSessionBinding(
                id: binding.id
            )
        )
        let firstPackID = try #require(
            binding.contextPackID
        )
        let preparedReceipts =
            try service.store.fetchContextDeliveries(
                projectID: kernel.project.id,
                taskID: task.id
            ).filter {
                $0.contextPackID == firstPackID
            }
        #expect(preparedReceipts.map(\.status) == [.prepared])

        _ = try await service.recordOpenWorkerEvent(
            bindingID: binding.id,
            event: OpenWorkerEvent(
                type: "turn_start",
                data: ["turn_id": .string("turn-one")]
            )
        )
        _ = try await service.recordOpenWorkerEvent(
            bindingID: binding.id,
            event: OpenWorkerEvent(type: "turn_done")
        )
        let deliveredReceipts =
            try service.store.fetchContextDeliveries(
                projectID: kernel.project.id,
                taskID: task.id
            ).filter {
                $0.contextPackID == firstPackID
            }
        #expect(
            Set(deliveredReceipts.map(\.status))
                == Set([.prepared, .delivered])
        )

        binding = try #require(
            try service.store.fetchRuntimeSessionBinding(id: binding.id)
        )
        binding.state = .idle
        binding.updatedAt = Date()
        try service.store.upsertRuntimeSessionBinding(binding)
        let secondRun = RunRecord(
            taskID: task.id,
            projectID: binding.projectID,
            workspaceID: binding.workspaceID,
            actorID: binding.actorID,
            principalID: binding.principalID,
            endpointID:
                ControlPlaneService.openWorkerEndpointID,
            actorName: "OpenWorker",
            purpose: .delegation,
            state: .starting,
            nativeThreadID:
                binding.nativeSessionID,
            agentIdentityID:
                binding.agentIdentityID
        )
        try service.store.upsertRun(secondRun)
        let secondEntry = ChatEntry(
            taskID: task.id,
            targetEndpointID:
                ControlPlaneService.openWorkerEndpointID,
            runID: secondRun.id,
            runtimeSessionBindingID: binding.id,
            deliveryState: .queued,
            routedText: "Second request",
            authorKind: .user,
            authorName: "You",
            text: "@OpenWorker Second request"
        )
        try service.store.insertChatEntry(secondEntry)

        try await service.markWorkspaceMessageSending(
            entryID: secondEntry.id,
            bindingID: binding.id
        )

        let secondClaim = try #require(
            try service.store.fetchChatEntry(id: secondEntry.id)
        )
        #expect(secondClaim.deliveryState == .sending)
        #expect(secondClaim.contextSnapshotID == nil)
        #expect(secondClaim.routedText == "Second request")
        #expect(
            try service.store.fetchContextSnapshots(
                bindingID: binding.id
            ).isEmpty
        )
        let secondBinding = try #require(
            try service.store.fetchRuntimeSessionBinding(
                id: binding.id
            )
        )
        let secondPackID = try #require(
            secondBinding.contextPackID
        )
        _ = try await service.recordOpenWorkerEvent(
            bindingID: binding.id,
            event: OpenWorkerEvent(
                type: "connection_closed",
                data: [
                    "error":
                        .string("fixture closed before ack")
                ]
            )
        )
        let secondReceipts =
            try service.store.fetchContextDeliveries(
                projectID: kernel.project.id,
                taskID: task.id
            ).filter {
                $0.contextPackID == secondPackID
            }
        #expect(secondReceipts.contains {
            $0.status == .prepared
        })
        #expect(secondReceipts.contains {
            $0.status == .failed
                && $0.failureCode
                    == "openworker_connection_closed_before_ack"
        })
    }

    @Test
    func snapshotOmitsPlaintextAndExactMuEnvelopeImportsOnlyCurrentRequest()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        let fixtureBaseURL =
            "http://127.0.0.1:\(HistoryOpenWorkerURLProtocol.fixturePort)"
        try activateOpenWorker(in: service, baseURL: fixtureBaseURL)
        let task = try fixture.makeTask(in: service)
        let sourcePlaintext =
            "SENSITIVE_REVIEWED_HISTORY must never be stored in ContextSnapshot.content."
        let source = historyCandidate(
            provider: .codex,
            providerInstanceKey: "codex:snapshot-redaction",
            nativeSessionID: "snapshot-source",
            workspacePath: fixture.repository.path,
            text: sourcePlaintext
        )
        service.cacheDiscoveredHistoryCandidates([source], taskID: task.id)
        _ = try await service.importConversationHistory(
            taskID: task.id,
            candidates: [source]
        )

        let nativeSessionID = "mu-envelope-session"
        let binding = try governedOpenWorkerBinding(
            in: service,
            task: task,
            nativeSessionID: nativeSessionID,
            workspacePath: fixture.repository.path
        )
        let currentRequest = "Continue only the current user request."
        let outbound = queuedEntry(
            taskID: task.id,
            bindingID: binding.id,
            request: currentRequest
        )
        try service.store.insertChatEntry(outbound)
        let envelope = try await service.markWorkspaceMessageSending(
            entryID: outbound.id,
            bindingID: binding.id
        )

        let claimed = try #require(
            try service.store.fetchChatEntry(id: outbound.id)
        )
        let currentMessageSeparator =
            "\n\n# Current Project message\n\n"
        let separatorRange = try #require(
            envelope.range(
                of: currentMessageSeparator,
                options: .backwards
            )
        )
        let renderedPack = String(
            envelope[..<separatorRange.lowerBound]
        )
        let persistedBinding = try #require(
            try service.store.fetchRuntimeSessionBinding(
                id: binding.id
            )
        )
        let packID = try #require(
            persistedBinding.contextPackID
        )
        let projectID = try #require(
            persistedBinding.projectID
        )
        let pack = try #require(
            try service.store.fetchProjectContextPack(
                projectID: projectID,
                id: packID
            )
        )
        #expect(claimed.contextSnapshotID == nil)
        #expect(claimed.contextFreeRoutedText == nil)
        #expect(
            pack.contentSHA256
                == Data(renderedPack.utf8).muSHA256
        )
        #expect(envelope.contains(sourcePlaintext) == false)
        #expect(envelope.contains("SENSITIVE_REVIEWED_HISTORY") == false)
        #expect(envelope.contains("<mu_imported_context>") == false)
        #expect(claimed.routedText == currentRequest)
        #expect(claimed.routedText?.contains(sourcePlaintext) == false)

        let storedOutbound = try #require(
            try service.store.fetchChatEntry(id: outbound.id)
        )
        #expect(storedOutbound.routedText == currentRequest)
        #expect(storedOutbound.contextFreeRoutedText == nil)
        #expect(storedOutbound.routedText?.contains(sourcePlaintext) == false)

        let openWorkerCandidate = ExternalConversationCandidate(
            provider: .openWorker,
            providerInstanceKey:
                "openworker:\(ControlPlaneService.openWorkerEndpointID.uuidString)",
            nativeSessionID: nativeSessionID,
            title: "Exact Mu envelope fixture",
            canonicalWorkspacePath: WorkspacePathIdentity.canonicalPath(
                fixture.repository.path
            ),
            accessKind: .vendorProtocol,
            resumability: .resumable,
            discoveredMessageCount: 2,
            messages: []
        )
        service.cacheDiscoveredHistoryCandidates(
            [openWorkerCandidate],
            taskID: task.id
        )
        HistoryOpenWorkerURLProtocol.install(
            sessionID: nativeSessionID,
            workspacePath: fixture.repository.path,
            envelope: envelope
        )
        let registered = URLProtocol.registerClass(
            HistoryOpenWorkerURLProtocol.self
        )
        defer {
            URLProtocol.unregisterClass(
                HistoryOpenWorkerURLProtocol.self
            )
            HistoryOpenWorkerURLProtocol.reset()
        }
        #expect(registered)

        let imported = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [openWorkerCandidate]
            ).first
        )
        let importedMessages =
            try service.store.fetchImportedConversationMessages(
                conversationID: imported.id
            )

        #expect(importedMessages.count == 2)
        #expect(importedMessages.map(\.role) == [.user, .assistant])
        #expect(importedMessages[0].text == envelope)
        #expect(importedMessages[0].text.contains(currentRequest))
        #expect(importedMessages[1].text == "Envelope import complete.")
        let importedText = importedMessages.map(\.text).joined(separator: "\n")
        #expect(!importedText.contains(sourcePlaintext))
        #expect(!importedText.contains("<mu_imported_context>"))
        #expect(
            !importedText.contains(
                "Current user request (the only new instruction)"
            )
        )
    }

    @Test
    func deletingRuntimeRegistrationPreservesReadableImportedHistory()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        try activateOpenWorker(in: service)
        let task = try fixture.makeTask(in: service)
        let candidate = historyCandidate(
            provider: .openWorker,
            providerInstanceKey:
                "openworker:\(ControlPlaneService.openWorkerEndpointID.uuidString)",
            nativeSessionID: "preserved-session",
            workspacePath: fixture.repository.path,
            text: "Preserve this imported visible history."
        )
        service.cacheDiscoveredHistoryCandidates(
            [candidate],
            taskID: task.id
        )
        let imported = try #require(
            try await service.importConversationHistory(
                taskID: task.id,
                candidates: [candidate]
            ).first
        )

        try service.deleteEndpoint(id: ControlPlaneService.openWorkerEndpointID)

        #expect(
            try service.store.fetchRegisteredEndpoint(
                id: ControlPlaneService.openWorkerEndpointID
            ) == nil
        )
        let preserved = try #require(
            try service.store.fetchImportedConversation(id: imported.id)
        )
        #expect(preserved.id == imported.id)
        #expect(preserved.provider == imported.provider)
        #expect(preserved.nativeSessionID == imported.nativeSessionID)
        #expect(preserved.snapshotFingerprint == imported.snapshotFingerprint)
        #expect(preserved.messageCount == imported.messageCount)
        let messages = try service.store.fetchImportedConversationMessages(
            conversationID: imported.id
        )
        #expect(messages.count == 1)
        #expect(messages[0].text == "Preserve this imported visible history.")
        #expect(
            try service.store.fetchTaskContextSources(taskID: task.id)
                .contains { $0.conversationID == imported.id && $0.enabled }
        )
    }

    @Test
    func mismatchedContextBindingCanBeDiagnosedDetachedAndRelinked()
        async throws
    {
        let fixture = try ConversationHistoryFixture()
        defer { fixture.remove() }
        let service = try fixture.makeService()
        try activateOpenWorker(in: service)
        let task = try fixture.makeTask(in: service)
        let candidate = historyCandidate(
            provider: .codex,
            providerInstanceKey: "codex:relink-fixture",
            nativeSessionID: "relink-context-source",
            workspacePath: fixture.repository.path,
            text: "Reviewed context must remain in its exact workspace."
        )
        service.cacheDiscoveredHistoryCandidates(
            [candidate],
            taskID: task.id
        )
        _ = try await service.importConversationHistory(
            taskID: task.id,
            candidates: [candidate]
        )
        let otherWorkspace = fixture.root.appending(
            path: "foreign-relink-workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: otherWorkspace,
            withIntermediateDirectories: true
        )
        let foreignBinding = RuntimeSessionBinding(
            taskID: task.id,
            endpointID: ControlPlaneService.openWorkerEndpointID,
            nativeSessionID: "foreign-relink-session",
            nativeAgentName: "cowork",
            workspacePath: otherWorkspace.path,
            connectionMode: "legacy_loopback",
            state: .idle
        )
        try service.store.upsertRuntimeSessionBinding(foreignBinding)
        let queued = queuedEntry(
            taskID: task.id,
            bindingID: foreignBinding.id,
            request: "Keep this queued while the session is relinked."
        )
        try service.store.insertChatEntry(queued)

        let status = try service.importedContextRoutingStatus(
            taskID: task.id,
            bindingID: foreignBinding.id
        )
        #expect(status.state == .requiresRelink)
        #expect(status.canSafelyDetachForRelink)
        #expect(status.blocksAutomaticDispatch)
        #expect(status.enabledSourceCount == 1)
        #expect(
            status.taskWorkspacePath
                == WorkspacePathIdentity.canonicalPath(
                    fixture.repository.path
                )
        )
        #expect(
            try service.store.fetchRuntimeSessionBinding(
                id: foreignBinding.id
            )?.state == .idle
        )

        var activeForeignBinding = foreignBinding
        activeForeignBinding.state = .working
        try service.store.upsertRuntimeSessionBinding(
            activeForeignBinding
        )
        let activeStatus = try service.importedContextRoutingStatus(
            taskID: task.id,
            bindingID: foreignBinding.id
        )
        #expect(activeStatus.state == .requiresRelink)
        #expect(!activeStatus.canSafelyDetachForRelink)
        #expect(activeStatus.blocksAutomaticDispatch)
        do {
            try service.detachOpenWorkerBindingForContextRelink(
                taskID: task.id,
                bindingID: foreignBinding.id
            )
            Issue.record(
                "An actively working native session must not be detached."
            )
        } catch let error as MuError {
            #expect(
                error.localizedDescription.contains(
                    "active OpenWorker session"
                )
            )
        }
        activeForeignBinding.state = .idle
        try service.store.upsertRuntimeSessionBinding(
            activeForeignBinding
        )

        let preparation =
            try service.detachOpenWorkerBindingForContextRelink(
                taskID: task.id,
                bindingID: foreignBinding.id
            )
        #expect(preparation.messagesReturnedToQueue == 1)
        #expect(
            try service.store.fetchRuntimeSessionBinding(
                id: foreignBinding.id
            )?.state == .detached
        )
        let waiting = try #require(
            try service.store.fetchChatEntry(id: queued.id)
        )
        #expect(waiting.runtimeSessionBindingID == nil)
        #expect(waiting.deliveryState == .awaitingSession)

        let replacement = try service.bindOpenWorkerSession(
            taskID: task.id
        )
        #expect(
            WorkspacePathIdentity.isExactMatch(
                replacement.workspacePath,
                fixture.repository.path
            )
        )
        let requeued = try #require(
            try service.store.fetchChatEntry(id: queued.id)
        )
        #expect(requeued.runtimeSessionBindingID == replacement.id)
        #expect(requeued.deliveryState == .queued)
        #expect(
            try service.importedContextRoutingStatus(
                taskID: task.id,
                bindingID: replacement.id
            ).state == .ready
        )
    }
}

private final class ConversationHistoryFixture {
    let root: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mu-conversation-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        repository = root
            .appending(path: "workspace", directoryHint: .isDirectory)
            .appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
    }

    func makeService(
        historyAdapters: [any ConversationHistoryAdapter] = []
    ) throws -> ControlPlaneService {
        try ControlPlaneService(
            dataDirectory: root.appending(
                path: "mu-data",
                directoryHint: .isDirectory
            ),
            historyAdapters: historyAdapters
        )
    }

    func makeTask(in service: ControlPlaneService) throws -> TaskRecord {
        try service.createTask(
            title: "Conversation continuity fixture",
            objective: "Carry reviewed visible history across providers.",
            successCriteria: ["Context remains readable"],
            constraints: ["History is read only"],
            pendingSteps: ["Continue in another agent"],
            repositoryPath: repository.path,
            sourceEndpointID: ControlPlaneService.syntheticEndpointAID
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FixtureConversationHistoryAdapter: ConversationHistoryAdapter {
    let provider: ConversationProvider
    let providerInstanceKey: String
    let expectedCanonicalWorkspacePath: String
    let discoveredCandidate: ExternalConversationCandidate
    let hydratedMessages: [ExternalConversationMessage]
    let discoveryProbe: HistoryAdapterDiscoveryProbe?

    init(
        provider: ConversationProvider,
        providerInstanceKey: String,
        expectedCanonicalWorkspacePath: String,
        discoveredCandidate: ExternalConversationCandidate,
        hydratedMessages: [ExternalConversationMessage],
        discoveryProbe: HistoryAdapterDiscoveryProbe? = nil
    ) {
        self.provider = provider
        self.providerInstanceKey = providerInstanceKey
        self.expectedCanonicalWorkspacePath =
            expectedCanonicalWorkspacePath
        self.discoveredCandidate = discoveredCandidate
        self.hydratedMessages = hydratedMessages
        self.discoveryProbe = discoveryProbe
    }

    func discoverConversationHistory(
        canonicalWorkspacePath: String
    ) async throws -> [ExternalConversationCandidate] {
        discoveryProbe?.recordDiscovery()
        guard canonicalWorkspacePath == expectedCanonicalWorkspacePath else {
            throw MuError.invalidTransition(
                "Fixture Adapter received a non-canonical workspace."
            )
        }
        return [discoveredCandidate]
    }

    func hydrateConversationHistory(
        _ candidate: ExternalConversationCandidate
    ) async throws -> ExternalConversationCandidate {
        guard candidate.id == discoveredCandidate.id,
              candidate.messages.isEmpty else {
            throw MuError.invalidTransition(
                "Fixture Adapter received an unauthorized candidate."
            )
        }
        var hydrated = candidate
        hydrated.messages = hydratedMessages
        return hydrated
    }
}

private final class HistoryAdapterDiscoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var discoveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordDiscovery() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class HistoryDiscoveryProgressRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedValues: [HistoryDiscoveryProgress] = []

    var values: [HistoryDiscoveryProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func append(_ value: HistoryDiscoveryProgress) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private func activateOpenWorker(
    in service: ControlPlaneService,
    baseURL: String = "http://127.0.0.1:52643"
) throws {
    let endpoint = RuntimeEndpoint(
        id: ControlPlaneService.openWorkerEndpointID,
        runtimeTypeID: ControlPlaneService.openWorkerRuntimeTypeID,
        displayName: "OpenWorker Test Adapter",
        adapterVersion: "test",
        runtimeVersion: "test",
        location: .local,
        provenance: .vendorProtocol,
        permissionModel: .promptGate,
        capabilities: ControlPlaneService.openWorkerImplementedCapabilities,
        status: .active,
        guaranteeNote: "In-process history regression fixture.",
        nativeConfiguration: [
            "base_url": baseURL,
            "default_agent": "cowork",
            "connection_mode": "legacy_loopback"
        ]
    )
    try service.store.upsertEndpoint(endpoint)
}

private func queuedEntry(
    taskID: UUID,
    bindingID: UUID,
    request: String
) -> ChatEntry {
    ChatEntry(
        taskID: taskID,
        targetEndpointID: ControlPlaneService.openWorkerEndpointID,
        runtimeSessionBindingID: bindingID,
        deliveryState: .queued,
        routedText: request,
        authorKind: .user,
        authorName: "You",
        text: "@OpenWorker \(request)"
    )
}

private func governedOpenWorkerBinding(
    in service: ControlPlaneService,
    task: TaskRecord,
    nativeSessionID: String,
    workspacePath: String
) throws -> RuntimeSessionBinding {
    let session = try MuCoding.makeDecoder().decode(
        OpenWorkerSessionSummary.self,
        from: Data(
            """
            {
              "session_id": "\(nativeSessionID)",
              "title": "Governed runtime fixture",
              "workspace": "\(workspacePath)",
              "agent": "cowork",
              "model": "fixture-model",
              "mode": "interactive",
              "messages": 0,
              "liveness": "idle"
            }
            """.utf8
        )
    )
    var binding = try service.bindOpenWorkerSession(
        taskID: task.id,
        existingSession: session
    )
    binding.state = .idle
    binding.lastActivitySummary = "Ready."
    binding.updatedAt = Date()
    try service.store.upsertRuntimeSessionBinding(binding)
    return binding
}

private func historyCandidate(
    provider: ConversationProvider,
    providerInstanceKey: String,
    nativeSessionID: String,
    workspacePath: String,
    text: String
) -> ExternalConversationCandidate {
    historyCandidate(
        provider: provider,
        providerInstanceKey: providerInstanceKey,
        nativeSessionID: nativeSessionID,
        workspacePath: workspacePath,
        messages: [
            ExternalConversationMessage(
                nativeItemID: "\(nativeSessionID)-message-0",
                ordinal: 0,
                role: .user,
                text: text
            )
        ]
    )
}

private func historyCandidate(
    provider: ConversationProvider,
    providerInstanceKey: String,
    nativeSessionID: String,
    workspacePath: String,
    messages: [ExternalConversationMessage]
) -> ExternalConversationCandidate {
    ExternalConversationCandidate(
        provider: provider,
        providerInstanceKey: providerInstanceKey,
        nativeSessionID: nativeSessionID,
        title: "\(provider.displayName) history fixture",
        canonicalWorkspacePath: WorkspacePathIdentity.canonicalPath(workspacePath),
        accessKind: provider == .claudeCode
            ? .localReadOnlyArtifact
            : .vendorProtocol,
        resumability: provider == .claudeCode ? .historyOnly : .resumable,
        discoveredMessageCount: messages.count,
        messages: messages
    )
}

private final class HistoryOpenWorkerURLProtocol: URLProtocol {
    static let fixturePort = 52_991

    private struct Fixture: Sendable {
        var sessionID: String
        var workspacePath: String
        var envelope: String
    }

    private struct Response {
        var statusCode: Int
        var data: Data
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var fixture: Fixture?

        func install(
            sessionID: String,
            workspacePath: String,
            envelope: String
        ) {
            lock.lock()
            fixture = Fixture(
                sessionID: sessionID,
                workspacePath: workspacePath,
                envelope: envelope
            )
            lock.unlock()
        }

        func reset() {
            lock.lock()
            fixture = nil
            lock.unlock()
        }

        func response(for request: URLRequest) throws -> Response {
            lock.lock()
            let fixture = self.fixture
            lock.unlock()
            guard let fixture else {
                throw URLError(.resourceUnavailable)
            }
            let object: [String: Any]
            let statusCode: Int
            switch request.url?.path {
            case "/v1/sessions":
                statusCode = 200
                object = [
                    "sessions": [
                        [
                            "session_id": fixture.sessionID,
                            "title": "Exact Mu envelope fixture",
                            "workspace": fixture.workspacePath,
                            "agent": "cowork",
                            "model": "fixture-model",
                            "mode": "interactive",
                            "messages": 2
                        ]
                    ]
                ]
            case "/v1/sessions/\(fixture.sessionID)/messages":
                statusCode = 200
                object = [
                    "messages": [
                        [
                            "role": "user",
                            "content": fixture.envelope,
                            "ts": 1
                        ],
                        [
                            "role": "assistant",
                            "content": "Envelope import complete.",
                            "ts": 2
                        ]
                    ]
                ]
            default:
                statusCode = 404
                object = ["detail": "not found"]
            }
            return Response(
                statusCode: statusCode,
                data: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
        }
    }

    private static let state = State()

    static func install(
        sessionID: String,
        workspacePath: String,
        envelope: String
    ) {
        state.install(
            sessionID: sessionID,
            workspacePath: workspacePath,
            envelope: envelope
        )
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
            && request.url?.port == fixturePort
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let fixture = try Self.state.response(for: request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: fixture.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: fixture.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}
