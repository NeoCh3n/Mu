import Foundation
@testable import MuCore
import Testing

@Suite
struct RuntimeInstanceIdentityTests {
    @Test
    func codexDesktopIsAProductSingleton() throws {
        let endpointA = codexEndpoint(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            executable: "/Applications/Codex.app/Contents/Resources/codex"
        )
        let endpointB = codexEndpoint(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            executable: "/Applications/ChatGPT.app/Contents/Resources/codex"
        )

        let identityA = endpointA.resolvedInstanceIdentity
        let identityB = endpointB.resolvedInstanceIdentity

        #expect(identityA.provider == .codex)
        #expect(identityA.surfaceKind == .desktopApplication)
        #expect(identityA.identityBasis == .desktopSingleton)
        #expect(identityA.stableInstanceKey == "codex:desktop")
        #expect(identityB.stableInstanceKey == identityA.stableInstanceKey)
        #expect(identityA.instanceLabel == "Codex Desktop")
    }

    @Test
    func cliEndpointsRemainDistinctWithoutInventingTTYIdentity() throws {
        let executable = "/opt/homebrew/bin/codex"
        let first = codexEndpoint(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            executable: executable
        ).resolvedInstanceIdentity
        let second = codexEndpoint(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            executable: executable
        ).resolvedInstanceIdentity

        #expect(first.surfaceKind == .terminalCLI)
        #expect(first.identityBasis == .endpointFallback)
        #expect(first.stableInstanceKey != second.stableInstanceKey)
        #expect(!first.hasConcreteTerminalIdentity)
        #expect(first.terminalIdentifier == nil)
        #expect(first.instanceLabel.contains("terminal not recorded"))
    }

    @Test
    func configuredTerminalIdentifierIsAuthoritativeAndUserVisible() throws {
        var first = codexEndpoint(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            executable: "/opt/homebrew/bin/codex"
        )
        first.nativeConfiguration?[
            RuntimeIdentityConfigurationKey.terminalIdentifier
        ] = "Terminal · ttys003"
        var second = codexEndpoint(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            executable: "/opt/homebrew/bin/codex"
        )
        second.nativeConfiguration?[
            RuntimeIdentityConfigurationKey.terminalIdentifier
        ] = "Warp · session 42"

        let firstIdentity = first.resolvedInstanceIdentity
        let secondIdentity = second.resolvedInstanceIdentity

        #expect(firstIdentity.identityBasis == .terminalIdentifier)
        #expect(firstIdentity.hasConcreteTerminalIdentity)
        #expect(
            firstIdentity.instanceLabel
                == "Codex CLI · Terminal · ttys003"
        )
        #expect(firstIdentity.stableInstanceKey != secondIdentity.stableInstanceKey)
    }

    @Test
    func codexThreadSourceDistinguishesAppServerCLIExecAndVSCode() throws {
        let workspace = "/tmp/mu-runtime-identity"
        let packagedProvider =
            "codex-app-server:/Applications/Codex.app/Contents/Resources/codex"
        let cliProvider = "codex-app-server:/opt/homebrew/bin/codex"

        let desktop = try #require(
            CodexAppServerClient.historyCandidate(
                from: thread(
                    id: "desktop-thread",
                    workspace: workspace,
                    source: ["appServer": ["origin": "desktop"]]
                ),
                providerInstanceKey: packagedProvider,
                canonicalWorkspacePath: workspace,
                isArchived: false
            )
        ).resolvedInstanceIdentity
        let cli = try #require(
            CodexAppServerClient.historyCandidate(
                from: thread(
                    id: "cli-thread",
                    workspace: workspace,
                    source: "cli"
                ),
                providerInstanceKey: cliProvider,
                canonicalWorkspacePath: workspace,
                isArchived: false
            )
        ).resolvedInstanceIdentity
        let exec = try #require(
            CodexAppServerClient.historyCandidate(
                from: thread(
                    id: "exec-thread",
                    workspace: workspace,
                    source: ["type": "exec"]
                ),
                providerInstanceKey: cliProvider,
                canonicalWorkspacePath: workspace,
                isArchived: false
            )
        ).resolvedInstanceIdentity
        let vscode = try #require(
            CodexAppServerClient.historyCandidate(
                from: thread(
                    id: "vscode-thread",
                    workspace: workspace,
                    source: ["vscode": [:]]
                ),
                providerInstanceKey: cliProvider,
                canonicalWorkspacePath: workspace,
                isArchived: false
            )
        ).resolvedInstanceIdentity

        #expect(desktop.surfaceKind == .desktopApplication)
        #expect(desktop.nativeSource == "appServer")
        #expect(desktop.stableInstanceKey == "codex:desktop")
        #expect(cli.surfaceKind == .terminalCLI)
        #expect(cli.nativeSource == "cli")
        #expect(exec.surfaceKind == .automation)
        #expect(exec.nativeSource == "exec")
        #expect(vscode.surfaceKind == .editorExtension)
        #expect(vscode.nativeSource == "vscode")
        #expect(
            Set([
                cli.stableInstanceKey,
                exec.stableInstanceKey,
                vscode.stableInstanceKey
            ]).count == 3
        )
    }

    @Test
    func codexHistoryDiscoveryIncludesEveryUserFacingSource() throws {
        let fake = try CodexHistoryListFixture()
        defer { fake.remove() }
        let client = CodexAppServerClient(executableURL: fake.executableURL)
        defer { client.stop() }

        let candidates = try client.listHistory(
            workspacePath: fake.workspaceURL.path,
            timeout: 3
        )
        let identities = Dictionary(
            uniqueKeysWithValues: candidates.map {
                ($0.nativeSessionID, $0.resolvedInstanceIdentity)
            }
        )

        #expect(Set(identities.keys) == Set([
            "cli-session",
            "exec-session",
            "vscode-session",
            "app-server-session"
        ]))
        #expect(
            try #require(identities["cli-session"]).surfaceKind
                == .terminalCLI
        )
        #expect(
            try #require(identities["exec-session"]).surfaceKind
                == .automation
        )
        #expect(
            try #require(identities["vscode-session"]).surfaceKind
                == .editorExtension
        )
        #expect(
            try #require(identities["app-server-session"]).surfaceKind
                == .desktopApplication
        )
        #expect(candidates.allSatisfy {
            $0.provider == .codex
                && $0.canonicalWorkspacePath
                    == fake.canonicalWorkspacePath
        })

        let listRequests = try fake.requests().filter {
            $0["method"] as? String == "thread/list"
        }
        #expect(listRequests.count == 2)
        for request in listRequests {
            let params = try #require(
                request["params"] as? [String: Any]
            )
            #expect(
                params["sourceKinds"] as? [String]
                    == ["cli", "vscode", "exec", "appServer"]
            )
        }
        #expect(Set(listRequests.compactMap {
            ($0["params"] as? [String: Any])?["archived"] as? Bool
        }) == Set([false, true]))
    }

    @Test
    func codexCLISessionsRemainDistinctWithoutClaimingATerminal() throws {
        let first = AgentRuntimeInstanceIdentity.codexHistory(
            executablePath: "/usr/local/bin/codex",
            nativeSource: "cli",
            nativeSessionID: "019f-first-session",
            workspacePath: "/tmp/project"
        )
        let second = AgentRuntimeInstanceIdentity.codexHistory(
            executablePath: "/usr/local/bin/codex",
            nativeSource: "cli",
            nativeSessionID: "019f-second-session",
            workspacePath: "/tmp/project"
        )

        #expect(first.stableInstanceKey != second.stableInstanceKey)
        #expect(first.identityBasis == .sessionFallback)
        #expect(!first.hasConcreteTerminalIdentity)
        #expect(first.instanceLabel.contains("session 019f-first-s"))
        #expect(first.instanceLabel.contains("terminal not recorded"))
    }

    @Test
    func claudeCodeUsesDeterministicSessionAndSourceFileFallback() throws {
        let first = AgentRuntimeInstanceIdentity.claudeCodeHistory(
            providerInstanceKey: "claude-code:/Users/test/.claude",
            nativeSessionID: "claude-session",
            workspacePath: "/tmp/project",
            sourceLocation:
                "/Users/test/.claude/projects/project/claude-session.jsonl"
        )
        let repeated = AgentRuntimeInstanceIdentity.claudeCodeHistory(
            providerInstanceKey: "claude-code:/Users/test/.claude",
            nativeSessionID: "claude-session",
            workspacePath: "/tmp/project",
            sourceLocation:
                "/Users/test/.claude/projects/project/claude-session.jsonl"
        )
        let otherFile = AgentRuntimeInstanceIdentity.claudeCodeHistory(
            providerInstanceKey: "claude-code:/Users/test/.claude",
            nativeSessionID: "claude-session",
            workspacePath: "/tmp/project",
            sourceLocation:
                "/Users/test/.claude/projects/other/claude-session.jsonl"
        )

        #expect(first.provider == .claudeCode)
        #expect(first.surfaceKind == .terminalCLI)
        #expect(first.identityBasis == .sessionFallback)
        #expect(first.stableInstanceKey == repeated.stableInstanceKey)
        #expect(first.stableInstanceKey != otherFile.stableInstanceKey)
        #expect(!first.hasConcreteTerminalIdentity)
        #expect(first.instanceLabel.contains("terminal not recorded"))
        #expect(first.sourceLocation?.hasSuffix(".jsonl") == true)
    }

    @Test
    func newOptionalIdentityFieldsDecodeFromLegacyRecords() throws {
        let endpoint = codexEndpoint(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            executable: "/usr/local/bin/codex"
        )
        let endpointData = try JSONEncoder().encode(endpoint)
        let decodedEndpoint = try JSONDecoder().decode(
            RuntimeEndpoint.self,
            from: endpointData
        )

        let candidate = ExternalConversationCandidate(
            provider: .codex,
            providerInstanceKey:
                "codex-app-server:/usr/local/bin/codex",
            nativeSessionID: "legacy-session",
            title: "Legacy",
            canonicalWorkspacePath: "/tmp/project",
            accessKind: .vendorProtocol,
            resumability: .resumable
        )
        let candidateData = try JSONEncoder().encode(candidate)
        let decodedCandidate = try JSONDecoder().decode(
            ExternalConversationCandidate.self,
            from: candidateData
        )

        #expect(decodedEndpoint.instanceIdentity == nil)
        #expect(decodedCandidate.runtimeInstanceIdentity == nil)
        #expect(
            decodedCandidate.resolvedInstanceIdentity.identityBasis
                == .sessionFallback
        )
    }

    private func codexEndpoint(
        id: UUID,
        executable: String
    ) -> RuntimeEndpoint {
        RuntimeEndpoint(
            id: id,
            runtimeTypeID: ControlPlaneService.codexRuntimeTypeID,
            displayName: "Codex",
            adapterVersion: "test",
            runtimeVersion: "test",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .fineGrained,
            capabilities: [],
            status: .active,
            guaranteeNote: "Identity fixture.",
            nativeConfiguration: ["executable": executable]
        )
    }

    private func thread(
        id: String,
        workspace: String,
        source: Any
    ) -> [String: Any] {
        [
            "id": id,
            "cwd": workspace,
            "name": id,
            "source": source
        ]
    }
}

private final class CodexHistoryListFixture {
    let root: URL
    let workspaceURL: URL
    let executableURL: URL
    let requestsURL: URL
    let canonicalWorkspacePath: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mu-codex-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        workspaceURL = root.appending(
            path: "workspace",
            directoryHint: .isDirectory
        )
        executableURL = root
            .appending(path: "FixtureCodex.app", directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "codex")
        requestsURL = root.appending(path: "requests.jsonl")
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        canonicalWorkspacePath = workspaceURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let requestPath = Self.shellQuote(requestsURL.path)
        let workspace = Self.jsonString(canonicalWorkspacePath)
        let script =
            """
            #!/bin/sh
            request_log=\(requestPath)
            list_count=0
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$request_log"
              case "$line" in
                *'"method":"initialize"'*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"Codex History Test/1.0","platformOs":"macos"}}'
                  ;;
                *thread*list*)
                  list_count=$((list_count + 1))
                  if [ "$list_count" -eq 1 ]; then
                    printf '%s\\n' '{"id":2,"result":{"data":[{"id":"cli-session","cwd":\(workspace),"name":"CLI","source":"cli"},{"id":"exec-session","cwd":\(workspace),"name":"Exec","source":"exec"},{"id":"vscode-session","cwd":\(workspace),"name":"VS Code","source":"vscode"},{"id":"app-server-session","cwd":\(workspace),"name":"App Server","source":"appServer"}],"nextCursor":null}}'
                  else
                    printf '%s\\n' '{"id":3,"result":{"data":[],"nextCursor":null}}'
                  fi
                  ;;
              esac
            done
            """
        try script.write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func requests() throws -> [[String: Any]] {
        let data = try Data(contentsOf: requestsURL)
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { line in
                let object = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                )
                guard let request = object as? [String: Any] else {
                    throw MuError.commandFailed(
                        "Fake Codex history request was not an object."
                    )
                }
                return request
            }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsonString(_ value: String) -> String {
        let encoded = try! JSONSerialization.data(
            withJSONObject: [value],
            options: []
        )
        let array = String(decoding: encoded, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
