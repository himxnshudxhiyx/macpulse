// Standalone checks for the only code in MacPulse that deletes anything.
// Compile with the sources it needs:
//   swiftc -parse-as-library Sources/MacPulse/Core/CacheScanner.swift \
//       Sources/MacPulse/Core/Sysctl.swift Tests/CleanupTests.swift -o /tmp/cleanup-tests && /tmp/cleanup-tests
import Foundation

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        print("  FAIL \(message)")
        failures += 1
    }
}

func makeFixture() -> URL {
    let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".macpulse-test-\(UUID().uuidString.prefix(8))")
    let nested = root.appendingPathComponent("nested/deeper")
    try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try! Data(repeating: 0x41, count: 200_000).write(to: root.appendingPathComponent("a.bin"))
    try! Data(repeating: 0x42, count: 300_000).write(to: nested.appendingPathComponent("b.bin"))
    return root
}

func target(at path: String) -> CleanupTarget {
    CleanupTarget(id: "test", title: "Test", detail: "", path: path, risk: .safe)
}

@main
struct CleanupTests {
    static func main() {
        let scanner = CacheScanner()
        let fileManager = FileManager.default

        print("sizing")
        let fixture = makeFixture()
        let scan = scanner.size(of: target(at: fixture.path))
        expect(scan.size >= 500_000, "totals nested files (\(scan.size) bytes)")
        expect(scan.itemCount == 2, "counts immediate children (\(scan.itemCount))")

        print("cleaning")
        let outcome = scanner.clean(target(at: fixture.path), moveToTrash: false)
        expect(outcome.failures.isEmpty, "no failures: \(outcome.failures)")
        expect(outcome.removedItems == 2, "removed both children (\(outcome.removedItems))")
        expect(outcome.freedBytes >= 500_000, "reported freed bytes (\(outcome.freedBytes))")
        expect(fileManager.fileExists(atPath: fixture.path), "the target folder itself survives")
        expect(((try? fileManager.contentsOfDirectory(atPath: fixture.path)) ?? []).isEmpty, "folder is now empty")
        try? fileManager.removeItem(at: fixture)

        print("allow-list")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macpulse-outside")
        try? fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: 10).write(to: outside.appendingPathComponent("keep.bin"))
        let refused = scanner.clean(target(at: outside.path), moveToTrash: false)
        expect(refused.removedItems == 0, "refuses a path outside the home directory")
        expect(refused.failures.count == 1, "explains why it refused")
        expect(fileManager.fileExists(atPath: outside.appendingPathComponent("keep.bin").path), "file outside home is untouched")
        try? fileManager.removeItem(at: outside)

        let home = scanner.clean(target(at: NSHomeDirectory()), moveToTrash: false)
        expect(home.removedItems == 0, "refuses the home directory itself")

        let missing = scanner.clean(target(at: NSHomeDirectory() + "/.macpulse-does-not-exist"), moveToTrash: false)
        expect(missing.removedItems == 0, "refuses a path that does not exist")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
