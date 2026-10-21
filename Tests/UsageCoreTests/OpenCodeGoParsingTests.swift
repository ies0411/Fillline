import Foundation
import Testing
import UsageCore

@Suite("OpenCode Go usage parsing")
struct OpenCodeGoParsingTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    @Test("parses rolling, weekly, and monthly windows from the live fixture")
    func parsesFixture() async throws {
        let fixture = try TestFixtures.data("opencodego_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = OpenCodeGoProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "oc_sk_test_key")
        )

        let snapshot = await provider.fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .openCodeGo)
        #expect(snapshot.windows.count == 3)

        let rolling = try #require(snapshot.window(kind: .rolling))
        #expect(rolling.usedFraction == 0)
        #expect(rolling.remainingFraction == 1)
        // 0% still parses the upstream placeholder reset time, flagged for the UI.
        #expect(rolling.isPlaceholder == true)
        #expect(rolling.resetsAt == Date(timeIntervalSince1970: 1_792_561_463))

        let weekly = try #require(snapshot.window(kind: .weekly7d))
        #expect(abs(weekly.usedFraction - 0.59) < 1e-9)
        #expect(abs(weekly.remainingFraction - 0.41) < 1e-9)
        #expect(weekly.isPlaceholder == false)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_792_972_800))

        let monthly = try #require(snapshot.window(kind: .monthly))
        #expect(abs(monthly.usedFraction - 0.74) < 1e-9)
        #expect(monthly.isPlaceholder == false)
        #expect(monthly.resetsAt == Date(timeIntervalSince1970: 1_794_784_768))
    }

    @Test("403 means valid key without a Go subscription, 401 means login")
    func statusMapping() async throws {
        let notSubscribedHTTP = ScriptedHTTPClient([.init(statusCode: 403)])
        let notSubscribedProvider = OpenCodeGoProvider(
            httpClient: notSubscribedHTTP,
            credentialStore: StubCredentialStore(token: "oc_sk_test_key")
        )
        let notSubscribed = await notSubscribedProvider.fetch(now: now)
        #expect(notSubscribed.status == .notSubscribed)

        let unauthorizedHTTP = ScriptedHTTPClient([.init(statusCode: 401)])
        let unauthorizedProvider = OpenCodeGoProvider(
            httpClient: unauthorizedHTTP,
            credentialStore: StubCredentialStore(token: "oc_sk_bad_key")
        )
        let unauthorized = await unauthorizedProvider.fetch(now: now)
        #expect(unauthorized.status == .needsLogin)
    }

    @Test("key discovery order: env → key file → auth.json")
    func keyDiscoveryOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configHome = root.appendingPathComponent("config", isDirectory: true)
        let dataHome = root.appendingPathComponent("data", isDirectory: true)
        let keyDirectory =
            configHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent(".secrets", isDirectory: true)
        let authDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)

        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try "oc_sk_file_key\n".write(
            to: keyDirectory.appendingPathComponent("opencode-key"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"opencode-go":{"key":"oc_sk_auth_key"}}"#
            .write(to: authDirectory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let baseVariables = [
            "XDG_CONFIG_HOME": configHome.path,
            "XDG_DATA_HOME": dataHome.path,
        ]

        let envVariables = baseVariables.merging(["OPENCODE_API_KEY": "oc_sk_env_key"]) { _, new in new }
        let envCredential = try OpenCodeAuthStore(
            environment: CredentialEnvironment(variables: envVariables, homeDirectory: root)
        ).loadCredentials()
        #expect(envCredential.accessToken.reveal() == "oc_sk_env_key")

        let fileCredential = try OpenCodeAuthStore(
            environment: CredentialEnvironment(variables: baseVariables, homeDirectory: root)
        ).loadCredentials()
        #expect(fileCredential.accessToken.reveal() == "oc_sk_file_key")

        try FileManager.default.removeItem(at: keyDirectory.appendingPathComponent("opencode-key"))

        let authCredential = try OpenCodeAuthStore(
            environment: CredentialEnvironment(variables: baseVariables, homeDirectory: root)
        ).loadCredentials()
        #expect(authCredential.accessToken.reveal() == "oc_sk_auth_key")
    }

    @Test("no key anywhere is notInstalled")
    func notInstalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let environment = CredentialEnvironment(
            variables: [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            ],
            homeDirectory: root
        )

        do {
            _ = try OpenCodeAuthStore(environment: environment).loadCredentials()
            Issue.record("expected .notInstalled")
        } catch let error as CredentialError {
            #expect(error == .notInstalled)
        }
    }

    @Test("sends the OpenCode bearer key")
    func requestHeaders() async throws {
        let fixture = try TestFixtures.data("opencodego_usage")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let provider = OpenCodeGoProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: "oc_sk_test_key")
        )

        _ = await provider.fetch(now: now)

        let requests = await http.requests
        let request = try #require(requests.first)
        #expect(request.url == OpenCodeGoEndpoints.usage)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oc_sk_test_key")
    }
}
