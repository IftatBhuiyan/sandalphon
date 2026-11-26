import Foundation

/// Costs of single typing errors, roughly in "edits". Cheaper means more likely to be a slip of the fingers.
struct KeyboardModel {
    static var transposition: Float = ProcessInfo.processInfo.environment["SANDALPHON_TRANS"].flatMap(Float.init) ?? 0.5
    static let firstLetterMultiplier: Float = 1.4

    /// sub[intended * 27 + typed]
    let sub: [Float]
    let adjacent: [Bool]

    init() {
        let rows: [(String, Float)] = [("qwertyuiop", 0), ("asdfghjkl", 0.25), ("zxcvbnm", 0.75)]
        var pos = [(x: Float, y: Float)](repeating: (-10, -10), count: alphabetSize)
        for (r, row) in rows.enumerated() {
            for (i, ch) in row.0.utf8.enumerated() {
                pos[Int(ch - 97)] = (Float(i) + row.1, Float(r))
            }
        }
        pos[Int(apostropheCode)] = (10.25, 1) // right of ; on the home row
        let vowels: Set<UInt8> = [0, 4, 8, 14, 20]
        var sub = [Float](repeating: 1, count: alphabetSize * alphabetSize)
        var adj = [Bool](repeating: false, count: alphabetSize * alphabetSize)
        for a in 0..<alphabetSize {
            for b in 0..<alphabetSize where a != b {
                let dx = pos[a].x - pos[b].x, dy = pos[a].y - pos[b].y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < 1.3 {
                    adj[a * alphabetSize + b] = true
                    sub[a * alphabetSize + b] = 0.55
                } else if vowels.contains(UInt8(a)) && vowels.contains(UInt8(b)) {
                    sub[a * alphabetSize + b] = 0.75
                }
            }
            sub[a * alphabetSize + a] = 0
        }
        self.sub = sub
        self.adjacent = adj
    }

    @inline(__always) func isAdjacent(_ a: UInt8, _ b: UInt8) -> Bool {
        adjacent[Int(a) * alphabetSize + Int(b)]
    }

    /// Cost of each typed character being a stray extra keypress.
    func extraCosts(_ t: [UInt8]) -> [Float] {
        var out = [Float](repeating: 0.95, count: t.count)
        for j in 0..<t.count {
            if j > 0 && t[j] == t[j - 1] {
                out[j] = 0.45
            } else if (j > 0 && isAdjacent(t[j], t[j - 1])) || (j + 1 < t.count && isAdjacent(t[j], t[j + 1])) {
                out[j] = 0.7
            }
            if j == 0 { out[j] *= KeyboardModel.firstLetterMultiplier }
        }
        return out
    }

    /// Cost of the typist leaving out intended character `c` at intended position `pos`.
    @inline(__always) func omit(_ c: UInt8, parent: UInt8, pos: Int) -> Float {
        if c == apostropheCode { return 0.1 }
        if pos > 0 && c == parent { return 0.5 }
        return pos == 0 ? 0.9 * KeyboardModel.firstLetterMultiplier : 0.9
    }

    /// Largest total cost we are willing to consider for a typed word of this length.
    static func maxCost(length n: Int) -> Float {
        switch n {
        case 0...2: return 0.6
        case 3: return 0.95
        case 4: return 1.1
        case 5, 6: return 1.5
        case 7, 8: return 1.9
        default: return 2.4
        }
    }
}
