import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Discovery and Settings › Cloud's model: what's fetched and when (nothing without a key; OpenRouter's prices once a
/// key is set, kept for a day), lists kept until a refresh, keys checked before they're kept, and this device's
/// preferences. A fake server answers for all three services; no network.
final class CloudDirectoryTests: XCTestCase {
    private let anthropicKey = CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA")!

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// Anthropic's and OpenAI's model lists by key, and OpenRouter's (no key) with Sonnet 5.5 at `sonnetInput`.
    private func serve(_ server: FakeCloudServer, sonnetInput: String = "0.0000025", anthropicStatus: Int = 200) {
        server.handle { request in
            if request.header("x-api-key") != nil {
                guard anthropicStatus == 200 else {
                    return .json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]], status: anthropicStatus)
                }
                return .json(["data": [["id": "claude-sonnet-5-5"], ["id": "claude-haiku-5-5"], ["id": "claude-opus-5-5"]], "has_more": false])
            }
            if request.header("Authorization") != nil {
                return .json(["data": [["id": "gpt-6.1-sol"], ["id": "gpt-6.1-terra"], ["id": "dall-e-3"]]])
            }
            return .json(["data": [["id": "anthropic/claude-sonnet-5.5", "name": "Anthropic: Claude Sonnet 5.5",
                                    "pricing": ["prompt": sonnetInput, "completion": "0.00001"]]]])
        }
    }

    private func directory(_ server: FakeCloudServer, keys: MemoryCloudKeyStore, defaults: UserDefaults, clock: Clock = Clock()) -> CloudDirectory {
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { _ in }
        return CloudDirectory(keys: keys, client: client, defaults: defaults, now: { clock.now })
    }

    private func openRouterRequests(_ server: FakeCloudServer) -> Int {
        server.requests.filter { $0.header("x-api-key") == nil && $0.header("Authorization") == nil }.count
    }

    func testBehaviorNothingIsFetchedOrOfferedWithoutAKey() async {
        let server = FakeCloudServer()
        serve(server)
        let directory = directory(server, keys: MemoryCloudKeyStore(), defaults: makeTestDefaults())
        let offers = await directory.offers(refresh: true)
        XCTAssertTrue(offers.isEmpty)
        await directory.refreshPrices(force: true)
        XCTAssertTrue(server.requests.isEmpty, "Not even OpenRouter's prices")
    }

    func testBehaviorPricesComeFromOpenRouterOnceThereIsAKeyAndAreKeptForADay() async throws {
        let server = FakeCloudServer()
        serve(server)
        let clock = Clock()
        let defaults = makeTestDefaults()
        let keys = MemoryCloudKeyStore([.anthropic: anthropicKey])
        let directory = directory(server, keys: keys, defaults: defaults, clock: clock)
        var offers = await directory.offers()
        XCTAssertEqual(offers.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(offers.offer("claude-sonnet-5-5")?.model.inputPrice, 2.5, "OpenRouter's price over the snapshot's")
        XCTAssertEqual(offers.offer("claude-haiku-5-5")?.model.inputPrice, 0.1, "What OpenRouter didn't list: the snapshot's")
        XCTAssertEqual(openRouterRequests(server), 1)

        clock.advance(60 * 60)
        offers = await directory.offers()
        XCTAssertEqual(openRouterRequests(server), 1, "Kept for a day")
        XCTAssertEqual(server.requests.count, 2, "The model list is kept until a refresh")

        // Another launch reads both back.
        let later = self.directory(server, keys: keys, defaults: defaults, clock: clock)
        let kept = await later.currentOffers()
        XCTAssertEqual(kept.offer("claude-sonnet-5-5")?.model.inputPrice, 2.5)

        clock.advance(24 * 60 * 60)
        serve(server, sonnetInput: "0.000003")
        offers = await later.offers()
        XCTAssertEqual(openRouterRequests(server), 2)
        XCTAssertEqual(offers.offer("claude-sonnet-5-5")?.model.inputPrice, 3)
    }

    func testBehaviorOpenRouterOutOfReachLeavesTheSnapshotsPrices() async throws {
        let server = FakeCloudServer()
        server.handle { request in
            request.header("x-api-key") != nil ? .json(["data": [["id": "claude-sonnet-5-5"]]]) : .failure(.cannotFindHost)
        }
        let directory = directory(server, keys: MemoryCloudKeyStore([.anthropic: anthropicKey]), defaults: makeTestDefaults())
        let offers = await directory.offers()
        XCTAssertEqual(offers.offer("claude-sonnet-5-5")?.model.inputPrice, 2)
        XCTAssertEqual(offers.offer("claude-sonnet-5-5")?.model.priceIsEstimated, false)
    }

    func testBehaviorListsAreKeptUntilARefreshAndGoWithTheirKey() async throws {
        let server = FakeCloudServer()
        serve(server)
        let keys = MemoryCloudKeyStore([.anthropic: anthropicKey, .openai: CloudAPIKey("sk-proj-TESTtestTESTtestTEST-x9Qa")!])
        let directory = directory(server, keys: keys, defaults: makeTestDefaults())
        var offers = await directory.offers()
        XCTAssertEqual(Set(offers.map(\.id)), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-6.1-sol", "gpt-6.1-terra"])
        let fetched = server.requests.count
        _ = await directory.offers()
        XCTAssertEqual(server.requests.count, fetched)
        _ = await directory.offers(refresh: true)
        XCTAssertEqual(server.requests.count, fetched + 2, "Both lists again; prices are kept for a day")

        try keys.removeKey(for: .openai)
        offers = await directory.offers()
        XCTAssertEqual(offers.map(\.model.provider), [.anthropic, .anthropic, .anthropic])
        let openAIListing = await directory.listing(.openai)
        XCTAssertNil(openAIListing, "A removed key's list goes")
    }

    // MARK: Settings › Cloud

    @MainActor
    func testBehaviorAKeyIsKeptOnlyOnceTheProviderAcceptsIt() async throws {
        let server = FakeCloudServer()
        serve(server, anthropicStatus: 401)
        let keys = MemoryCloudKeyStore()
        var client = CloudClient(session: server.session, endpoints: CloudEndpoints(base: server.base))
        client.wait = { _ in }
        let setup = CloudSetup(keys: keys, client: client, defaults: makeTestDefaults())
        XCTAssertFalse(setup.isSetUp)
        XCTAssertEqual(setup.summary, "Off")

        var kept = await setup.addKey(anthropicKey.secret, for: .anthropic)
        XCTAssertFalse(kept)
        XCTAssertEqual(setup.checks[.anthropic], .failed(message: "Anthropic didn’t accept this key.",
                                                         details: "HTTP 401 · authentication_error · invalid x-api-key"))
        XCTAssertNil(try keys.key(for: .anthropic))
        XCTAssertFalse(setup.isSetUp)

        kept = await setup.addKey("   ", for: .anthropic)
        XCTAssertFalse(kept)

        serve(server)
        kept = await setup.addKey(" \(anthropicKey.secret)\n", for: .anthropic)
        XCTAssertTrue(kept)
        XCTAssertEqual(setup.checks[.anthropic], .works)
        XCTAssertEqual(setup.keys, [.anthropic: "sk-ant-…gDAA"])
        XCTAssertEqual(try keys.key(for: .anthropic), anthropicKey)
        XCTAssertEqual(setup.offers.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(setup.resolved?.id, "claude-sonnet-5-5")
        XCTAssertEqual(setup.summary, "Claude Sonnet 5.5")

        await setup.removeKey(for: .anthropic)
        XCTAssertFalse(setup.isSetUp)
        XCTAssertTrue(setup.offers.isEmpty)
        XCTAssertNil(setup.resolved)
    }

    @MainActor
    func testBehaviorPreferencesAreThisDevicesOwnAndATierGoesBackToItsRecommendation() async throws {
        let defaults = makeTestDefaults()
        let setup = CloudSetup.demo(providers: [.anthropic, .openai], defaults: defaults)
        XCTAssertEqual(setup.preferences, CloudSummaryPreferences())
        XCTAssertEqual(setup.resolved?.id, "claude-sonnet-5-5")
        setup.chosenModel = "gpt-6.1-sol"
        XCTAssertEqual(setup.resolved?.id, "gpt-6.1-sol")
        setup.choose(.economy)
        XCTAssertNil(setup.preferences.model)
        XCTAssertEqual(setup.resolved?.id, "claude-haiku-5-5")
        setup.preferences.effort = .high
        setup.preferences.policy = .always
        setup.preferences.countdownSeconds = 30

        let stored = CloudSummaryPreferences.load(from: defaults)
        XCTAssertEqual(stored.tier, .economy)
        XCTAssertEqual(stored.effort, .high)
        XCTAssertEqual(stored.policy, .always)
        XCTAssertEqual(stored.countdownSeconds, 30)

        setup.preferences.policy = .never
        XCTAssertEqual(setup.summary, "Never")

        // A chosen model no key reaches reads as Recommended, and comes back with its key.
        setup.preferences.model = "gpt-7-astra"
        XCTAssertNil(setup.chosenModel)
        XCTAssertEqual(setup.preferences.model, "gpt-7-astra")
        XCTAssertEqual(setup.resolved?.id, "claude-haiku-5-5")
    }

    @MainActor
    func testBehaviorAKeyTheKeychainWontRemoveSaysSo() async throws {
        final class StuckStore: CloudKeyStore, @unchecked Sendable {
            let key = CloudAPIKey("sk-ant-api03-TESTtestTESTtestTESTtest-gDAA")!
            func key(for provider: CloudProvider) throws -> CloudAPIKey? { provider == .anthropic ? key : nil }
            func store(_ key: CloudAPIKey, for provider: CloudProvider) throws {}
            func removeKey(for provider: CloudProvider) throws { throw CloudKeyStoreError.keychain(-25_244) }
        }
        let setup = CloudSetup(keys: StuckStore(), client: CloudClient(session: FakeCloudServer().session), defaults: makeTestDefaults())
        setup.fetches = false
        XCTAssertEqual(setup.keys, [.anthropic: "sk-ant-…gDAA"])
        await setup.removeKey(for: .anthropic)
        XCTAssertEqual(setup.keys, [.anthropic: "sk-ant-…gDAA"], "Still there, and it says so")
        guard case .failed(let message, let details)? = setup.checks[.anthropic] else { return XCTFail("\(String(describing: setup.checks))") }
        XCTAssertEqual(message, "The keychain couldn’t remove the key.")
        XCTAssertTrue(details.hasSuffix("(-25244)"), details)
    }

    @MainActor
    func testBehaviorCostPerHourUsesThePreferredEffort() async throws {
        let setup = CloudSetup.demo(providers: [.anthropic], defaults: makeTestDefaults())
        let sonnet = try XCTUnwrap(setup.offers.offer("claude-sonnet-5-5"))
        let medium = try XCTUnwrap(setup.costPerHour(sonnet))
        setup.preferences.effort = .high
        let high = try XCTUnwrap(setup.costPerHour(sonnet))
        XCTAssertGreaterThan(high, medium)
        XCTAssertEqual(medium, 0.09, accuracy: 0.02)
    }
}
