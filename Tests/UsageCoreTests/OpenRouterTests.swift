import Foundation
import Testing
import UsageCore

@Suite("OpenRouter credit parsing")
struct OpenRouterTests {
    private let now = Date(timeIntervalSince1970: 1_792_572_000)

    private func makeProvider(
        http: ScriptedHTTPClient,
        token: String? = "fixture-openrouter-key"
    ) -> OpenRouterProvider {
        OpenRouterProvider(
            httpClient: http,
            credentialStore: StubCredentialStore(token: token)
        )
    }

    private func snapshot(for json: String) async -> UsageSnapshot {
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: Data(json.utf8))])
        return await makeProvider(http: http).fetch(now: now)
    }

    @Test("a capped key renders USD in the label and no fraction")
    func cappedFixture() async throws {
        let fixture = try TestFixtures.data("openrouter_key")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])
        let snapshot = await makeProvider(http: http).fetch(now: now)

        #expect(snapshot.status == .ok)
        #expect(snapshot.provider == .openRouter)
        #expect(snapshot.windows.count == 1)

        let window = try #require(snapshot.window(kind: .credits))
        // The label *is* the value: the UI renders it text-only (UsageFormat.isAmountRow).
        #expect(window.label == "$8.50 left")
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
        // Not a percentage: OpenRouter reports money, and the key limit is not the balance.
        #expect(window.usedFraction == 0)
    }

    @Test("a key with no cap is labelled, never charted as 100%")
    func noCap() async throws {
        let snapshot = await snapshot(
            for: #"{"data":{"limit":null,"limit_remaining":null,"effective_budget":{"remaining_usd":0}}}"#
        )

        let window = try #require(snapshot.window(kind: .credits))
        #expect(window.label == "$0.00 left · no cap")
        #expect(window.resetsAt == nil)
    }

    @Test("a negative balance stays negative instead of clamped to zero")
    func negativeBalance() async throws {
        let snapshot = await snapshot(
            for: #"{"data":{"limit":5.0,"limit_remaining":-0.25}}"#
        )

        let window = try #require(snapshot.window(kind: .credits))
        #expect(window.label == "-$0.25 left")
    }

    @Test("effective_budget wins over limit_remaining")
    func effectiveBudgetWins() async throws {
        let snapshot = await snapshot(
            for: #"{"data":{"limit":50.0,"limit_remaining":50.0,"effective_budget":{"remaining_usd":12.0}}}"#
        )

        let window = try #require(snapshot.window(kind: .credits))
        #expect(window.label == "$12.00 left")
    }

    @Test("no reported balance means no window, not 0%")
    func noBalance() async throws {
        let snapshot = await snapshot(
            for: #"{"data":{"limit":null,"limit_remaining":null,"usage":3.5}}"#
        )

        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.hasValues == false)
    }

    @Test("a free-tier key is labelled, 401 needs a login")
    func planAndStatus() async throws {
        let free = await snapshot(for: #"{"data":{"limit_remaining":1.0,"is_free_tier":true}}"#)
        #expect(free.plan == "Free")

        let unauthorized = await makeProvider(
            http: ScriptedHTTPClient([.init(statusCode: 401)])
        ).fetch(now: now)
        #expect(unauthorized.status == .needsLogin)
    }

    @Test("sends the OpenRouter bearer key")
    func requestHeaders() async throws {
        let fixture = try TestFixtures.data("openrouter_key")
        let http = ScriptedHTTPClient([.init(statusCode: 200, body: fixture)])

        _ = await makeProvider(http: http).fetch(now: now)

        let requests = await http.requests
        let request = try #require(requests.first)
        #expect(request.url == OpenRouterEndpoints.key)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-openrouter-key")
    }
}

@Suite("OpenRouter key discovery")
struct OpenRouterKeyStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("env → opencode auth.json → own keychain")
    func discoveryOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dataHome = root.appendingPathComponent("data", isDirectory: true)
        let authDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try #"{"openrouter":{"access":"file-key"},"other":{"key":"nope"}}"#
            .write(
                to: authDirectory.appendingPathComponent("auth.json"),
                atomically: true,
                encoding: .utf8
            )

        var variables = ["XDG_DATA_HOME": dataHome.path]
        let base = CredentialEnvironment(variables: variables, homeDirectory: root)

        let envStore = OpenRouterKeyStore(
            environment: CredentialEnvironment(
                variables: variables.merging(["OPENROUTER_API_KEY": "env-key"]) { _, new in new },
                homeDirectory: root
            ),
            keychain: StubKeychain(value: "keychain-key")
        )
        #expect(try envStore.loadCredentials().accessToken.reveal() == "env-key")

        let fileStore = OpenRouterKeyStore(environment: base, keychain: StubKeychain(value: "keychain-key"))
        #expect(try fileStore.loadCredentials().accessToken.reveal() == "file-key")

        try FileManager.default.removeItem(at: authDirectory.appendingPathComponent("auth.json"))
        variables["XDG_DATA_HOME"] = dataHome.path
        let keychainStore = OpenRouterKeyStore(
            environment: CredentialEnvironment(variables: variables, homeDirectory: root),
            keychain: StubKeychain(value: "keychain-key")
        )
        #expect(try keychainStore.loadCredentials().accessToken.reveal() == "keychain-key")
    }

    @Test("auth.json accepts key, access, or token")
    func authJSONFields() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let authDirectory = root.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let authFile = authDirectory.appendingPathComponent("auth.json")

        func token() -> String? {
            let store = OpenRouterKeyStore(
                environment: CredentialEnvironment(
                    variables: ["XDG_DATA_HOME": root.path],
                    homeDirectory: root
                ),
                keychain: StubKeychain(value: nil)
            )
            return try? store.loadCredentials().accessToken.reveal()
        }

        // Empty `key` and `access` fall through to `token`.
        try #"{"openrouter":{"key":"","access":"","token":"token-field"}}"#
            .write(to: authFile, atomically: true, encoding: .utf8)
        #expect(token() == "token-field")

        // Empty `key` falls through to `access`.
        try #"{"openrouter":{"key":"  ","access":"access-field"}}"#
            .write(to: authFile, atomically: true, encoding: .utf8)
        #expect(token() == "access-field")
    }

    @Test("no key anywhere is needsLogin, not notInstalled")
    func noKey() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = OpenRouterKeyStore(
            environment: CredentialEnvironment(
                variables: ["XDG_DATA_HOME": root.appendingPathComponent("data").path],
                homeDirectory: root
            ),
            keychain: StubKeychain(value: nil)
        )

        do {
            _ = try store.loadCredentials()
            Issue.record("expected .needsLogin")
        } catch let error as CredentialError {
            #expect(error == .needsLogin)
        }
    }
}

// MARK: - Doubles

struct StubKeychain: OpenRouterKeychainReading {
    let value: String?

    func password(service: String, account: String) -> String? { value }
}
