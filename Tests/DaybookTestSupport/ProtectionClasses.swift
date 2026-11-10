import Darwin
import Foundation
import XCTest

/// Data protection classes as the file system keeps them (`F_GETPROTECTIONCLASS`), for both apps' tests, and whether
/// this file system keeps them at all. A Mac with FileVault keeps a class it's given, and so do the simulators on it and
/// every iPhone; CI's runners take a class and read every file back as class C. The classes themselves are a device
/// check (docs/iphone.md, "File protection"), so where they aren't kept a class assertion is left out and the test goes
/// on with what it checks about behaviour (what waits for an unlock, what's never deleted, what resumes).
public enum FileProtectionClasses {
    private static let classes: [Int32: FileProtectionType] = [
        1: .complete, 2: .completeUnlessOpen, 3: .completeUntilFirstUserAuthentication, 4: FileProtectionType.none]

    /// The class of the file or folder at `url`, as the file system keeps it; nil when it can't be opened.
    public static func of(_ url: URL) -> FileProtectionType? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return classes[fcntl(descriptor, F_GETPROTECTIONCLASS)]
    }

    /// Whether a class given to a file comes back from it: probed once, on a scratch file given class B.
    public static let areKept: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-protection-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: Data("probe".utf8)) else { return false }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETPROTECTIONCLASS, Int32(2)) == 0 else { return false }
        return fcntl(descriptor, F_GETPROTECTIONCLASS) == 2
    }()
}

/// Asserts the class of the file or folder at `url` where the file system keeps classes; elsewhere nothing.
public func XCTAssertProtectionClass(
    _ url: URL, _ expected: FileProtectionType?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) {
    guard FileProtectionClasses.areKept else { return }
    XCTAssertEqual(FileProtectionClasses.of(url), expected, message(), file: file, line: line)
}

/// Asserts the file or folder at `url` doesn't have `unexpected` where the file system keeps classes; elsewhere nothing.
public func XCTAssertProtectionClassIsNot(
    _ url: URL, _ unexpected: FileProtectionType, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) {
    guard FileProtectionClasses.areKept else { return }
    XCTAssertNotEqual(FileProtectionClasses.of(url), unexpected, message(), file: file, line: line)
}
