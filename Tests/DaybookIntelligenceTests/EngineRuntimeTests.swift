import DaybookIntelligence
import DaybookKit
import DaybookLive
import XCTest

/// The runtimes results name as provenance are the versions the package actually builds: each
/// `EngineRuntime` against Package.resolved, and every engine's descriptor against `EngineRuntime`.
final class EngineRuntimeTests: XCTestCase {
    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { var version: String? }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    func testEachRuntimeNamesTheVersionPackageResolvedPins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: root.appendingPathComponent("Package.resolved")))
        let versions = Dictionary(resolved.pins.map { ($0.identity, $0.state.version) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(EngineRuntime.pinned.count, 3)
        for (package, runtime) in EngineRuntime.pinned {
            let version = try XCTUnwrap(versions[package] ?? nil, "\(package) is pinned to a version")
            XCTAssertEqual(runtime.lowercased(), "\(package) \(version)", "\(runtime) names the pinned \(package)")
        }
    }

    func testEveryEngineNamesItsRuntimeOnce() {
        let named = Set(EngineRuntime.pinned.map(\.runtime))
        let descriptors = ModelEngineRegistry.standard.descriptors + LiveEngines.descriptors
        // Apple's engines name the system they run on, not a package.
        let system: Set<ModelEngineID> = [.appleFoundationModels, .appleVision]
        for descriptor in descriptors where !system.contains(descriptor.id) {
            XCTAssertTrue(named.contains(descriptor.runtime), "\(descriptor.name) runs on \(descriptor.runtime)")
        }
        let live = Dictionary(LiveEngines.descriptors.map { ($0.id, $0.runtime) }, uniquingKeysWith: { first, _ in first })
        for descriptor in ModelEngineRegistry.standard.descriptors {
            guard let runtime = live[descriptor.id] else { continue }
            XCTAssertEqual(descriptor.runtime, runtime, "the Mac and the iPhone name \(descriptor.name)'s runtime alike")
        }
    }
}
