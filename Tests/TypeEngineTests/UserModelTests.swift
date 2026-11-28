import XCTest
@testable import TypeEngine

final class UserModelTests: XCTestCase {
    private func roundTrip(_ model: UserModel) throws -> UserModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sandalphon-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        model.save(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        return UserModel.load(from: url)
    }

    func testOnlyRepeatedWordsAndPhrasesAreSaved() throws {
        let m = UserModel()
        // Typed once: a phrase that must never reach the disk.
        for (i, w) in ["correct", "horse", "battery", "staple"].enumerated() {
            m.observe(word: w, context: Array(["correct", "horse", "battery"].prefix(i)))
        }
        m.casing["zorblat"] = "Zorblat"
        m.observe(word: "zorblat", context: [])
        // Typed twice: kept.
        for _ in 0..<2 { m.observe(word: "omw", context: ["im"]) }
        m.markKept("teh")

        let saved = try roundTrip(m)
        XCTAssertEqual(saved.words, ["omw": 2])
        XCTAssertEqual(saved.bigrams, ["im": ["omw": 2]])
        XCTAssertTrue(saved.trigrams.isEmpty)
        XCTAssertTrue(saved.casing.isEmpty)
        XCTAssertEqual(saved.keep, ["teh"])
        // In memory, this session still knows everything it saw.
        XCTAssertEqual(m.count("horse"), 1)
    }

    func testHandEditedCountsCannotOverflow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sandalphon-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"words":{"a":9223372036854775807,"b":-4},"bigrams":{"a":{"b":9223372036854775807}},"trigrams":{},"keep":[],"casing":{},"total":9223372036854775807}"#
        try Data(json.utf8).write(to: url)
        let m = UserModel.load(from: url)
        XCTAssertEqual(m.count("a"), UserModel.countLimit)
        XCTAssertEqual(m.count("b"), 0)
        m.observe(word: "a", context: ["a"]) // must not trap
        XCTAssertEqual(m.bigramTotal("a"), UserModel.countLimit)
    }
}
