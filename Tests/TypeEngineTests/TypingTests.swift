import XCTest
@testable import TypeEngine

final class TypingTests: XCTestCase {
    static let dataDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Data")
    static let shared = try! Engine(dataDirectory: dataDir)

    /// A fresh session with nothing learned, sharing the (expensive) lexicon.
    func session() -> TypingSession {
        TypingSession(engine: try! Engine(lexicon: Self.shared.lexicon, dataDirectory: Self.dataDir))
    }

    /// Spelling only, so those tests read as typed.
    func type(_ s: String) -> String {
        let session = session()
        session.capitalizeSentences = false
        return session.simulate(typing: s)
    }

    /// Everything on, as shipped.
    func full(_ s: String) -> String { session().simulate(typing: s) }

    func testFixesCommonTypos() {
        XCTAssertEqual(type("teh quick brown fox "), "the quick brown fox ")
        XCTAssertEqual(type("i dont knwo waht you mean "), "I don't know what you mean ")
        XCTAssertEqual(type("please recieve this, thankyou. "), "please receive this, thank you. ")
        XCTAssertEqual(type("definately tommorow "), "definitely tomorrow ")
        XCTAssertEqual(type("Teh end "), "The end ")
        XCTAssertEqual(type("see you on monday\n"), "see you on Monday\n")
        // Unfinished or unknown words must not be turned into something else entirely.
        for text in ["see you tomor ", "the wor is ", "ask priyanka about ", "my hovercraft is ", "lets go to zyvoria "] {
            XCTAssertEqual(type(text), text, text)
        }
    }

    func testEverydayWordsAreKnown() {
        // American and British spellings are both left as typed.
        for text in ["my favorite color ", "my favourite colour ", "at the theater ", "the neighbors were traveling "] {
            XCTAssertEqual(type(text), text, text)
        }
        // Interjections, single letters and possessives are not "corrected".
        for text in ["oh well ", "um maybe ", "plan b is ", "the dog's bowl ", "tick tock "] {
            XCTAssertEqual(type(text), text, text)
        }
        // Acronyms, places and names get their capitals; so does the surname after a title.
        XCTAssertEqual(type("the fbi asked nasa "), "the FBI asked NASA ")
        XCTAssertEqual(type("we met james in kyoto "), "we met James in Kyoto ")
        XCTAssertEqual(type("ask mr smith or ms brown or dr jones "), "ask Mr Smith or Ms Brown or Dr Jones ")
        XCTAssertEqual(type("the dr said so "), "the Dr said so ")
        // Misspellings from the imported list.
        XCTAssertEqual(type("it was a catapiller "), "it was a caterpillar ")
    }

    func testCapitalsPunctuationAndGrammar() {
        XCTAssertEqual(full("hello there. how are you? fine thanks! good "), "Hello there. How are you? Fine thanks! Good ")
        XCTAssertEqual(full("i went to london on friday with john "), "I went to London on Friday with John ")
        XCTAssertEqual(full("you could of told me "), "You could have told me ")
        XCTAssertEqual(full("ok its a nice day and your welcome "), "Ok it's a nice day and you're welcome ")
        XCTAssertEqual(full("i ate a apple and an banana "), "I ate an apple and a banana ")
        XCTAssertEqual(full("go to the the shop "), "Go to the shop ")
        XCTAssertEqual(full("well , that is more then enough "), "Well, that is more than enough ")
        XCTAssertEqual(full("it works  then we go "), "It works. Then we go ")
        // Things that look like sentence ends but are not.
        XCTAssertEqual(full("See e.g. the docs, costs 3.5 dollars... maybe "), "See e.g. the docs, costs 3.5 dollars... maybe ")
        XCTAssertEqual(full("Ask Dr. smith or plan a or b "), "Ask Dr. smith or plan a or b ")
        XCTAssertEqual(full("Open foo.com now, mail a@b.co today "), "Open foo.com now, mail a@b.co today ")
        // Undo with backspace restores exactly what was typed.
        XCTAssertEqual(full("You could of \u{8}"), "You could of ")
        XCTAssertEqual(full("hello \u{8}"), "hello ")
    }

    func testGoesBackWhenLaterWordsShowAMistake() {
        // "form" is a real word, so it is left alone at first; "the store" then makes "from" obvious.
        XCTAssertEqual(full("I got it form the store yesterday "), "I got it from the store yesterday ")
        XCTAssertEqual(full("helo there my friend "), "Hello there my friend ")
        XCTAssertEqual(full("i think your going to love it "), "I think you're going to love it ")
        // A fix that was already right is not second-guessed into a different word.
        XCTAssertEqual(full("i think thier house is nice "), "I think their house is nice ")
        XCTAssertEqual(full("thier coming on friday "), "Their coming on Friday ")
        // Correct text is not touched.
        let fine = "Please fill in the form and send it back to me before the end of the week "
        XCTAssertEqual(full(fine), fine)
    }

    func testLeavesGoodTextAlone() {
        let text = "The quick brown fox jumps over the lazy dog. I think we should meet at noon, it's fine. "
        XCTAssertEqual(type(text), text)
        XCTAssertEqual(type("I feel ill today "), "I feel ill today ")
    }

    func testLeavesNonProseAlone() {
        for text in ["open foo.cmo now ", "mail jsmth@gmail.com ", "use fooBar and HTTPS ",
                     "path /usr/lcoal/bin ", "version v2beta ", "tag #thnks ", "call getUsr() "] {
            XCTAssertEqual(type(text), text, text)
        }
    }

    func testBackspaceUndoesCorrectionAndRemembersIt() {
        let s = session()
        s.capitalizeSentences = false
        XCTAssertEqual(s.simulate(typing: "teh \u{8}"), "teh ")
        XCTAssertEqual(s.simulate(typing: "teh cat "), "teh cat ")
    }

    func testTabAcceptsCompletionAndSmartPunctuation() {
        XCTAssertEqual(type("see you tomor\t"), "see you tomorrow ")
        XCTAssertEqual(type("see you tomor\t."), "see you tomorrow.")
    }

    func testPredictions() {
        let e = Self.shared
        XCTAssertEqual(e.predictions(context: ["how", "are"]).first, "you")
        XCTAssertEqual(e.predictions(context: ["looking", "forward"]).first, "to")
        XCTAssertEqual(e.predictions(context: ["thank"]).first, "you")
        XCTAssertTrue(e.predictions(context: ["<s>"]).contains("I"))
    }

    func testLearnsNewWords() {
        let s = session()
        _ = s.simulate(typing: "ask sandalphon about it. ask sandalphon again. tell sandalphon now. ")
        XCTAssertTrue(s.engine.isKnown("sandalphon"))
        XCTAssertEqual(s.engine.suggestions(typed: "sanda", context: ["ask"]).first?.text, "sandalphon")
    }

    func testSeedingMidText() {
        let s = session()
        s.seed(textBeforeCaret: "I will see you tomor")
        XCTAssertEqual(s.word, "tomor")
        XCTAssertEqual(s.suggestions.first?.text, "tomorrow")
        s.seed(textBeforeCaret: nil)
        s.character("t"); s.character("e"); s.character("h")
        XCTAssertNil(s.delimiter(" "), "unknown surroundings: do not touch the first token")
        s.character("t"); s.character("e"); s.character("h")
        XCTAssertEqual(s.delimiter(" ")?.insert, "the")
    }

    func testSpeed() {
        let e = Self.shared
        let words = ["teh", "becuase", "tomor", "wor", "definately", "th", "helo", "accomodation", "pred", "xqzv"]
        let start = Date()
        var n = 0
        for _ in 0..<200 {
            for w in words {
                _ = e.analyze(typed: w, context: ["i", "think"])
                n += 1
            }
        }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(n)
        print(String(format: "analyze: %.3f ms per keystroke", ms))
        XCTAssertLessThan(ms, 3)
    }
}
