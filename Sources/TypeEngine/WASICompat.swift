// The web demo builds the engine against FoundationEssentials only, which keeps the module tens of
// megabytes smaller. These fill the few gaps; on macOS this file is empty.
#if os(WASI)
@_exported import WASILibc
import FoundationEssentials

extension String {
    func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard !target.isEmpty, contains(target) else { return self }
        return split(separator: target, omittingEmptySubsequences: false).joined(separator: replacement)
    }
}

struct CharacterSet {
    let test: (Unicode.Scalar) -> Bool
    func contains(_ s: Unicode.Scalar) -> Bool { test(s) }
    static let letters = CharacterSet { $0.properties.isAlphabetic }
    static let uppercaseLetters = CharacterSet { $0.properties.isUppercase }
}
#endif
