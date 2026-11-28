// The engine as a WebAssembly module for the browser demo. Built by scripts/build-web.sh.
//
// The host gives the module a WASI file system with the language data at /data, then calls these exports.
// Text crosses the boundary as UTF-8 in a buffer the module owns: the host asks for room with
// `sp_buffer(n)`, writes into it, and reads replies from `sp_out_ptr()` / `sp_out_len()`.
// Nothing is stored or sent anywhere; learning is off.
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import TypeEngine

#if os(WASI)
nonisolated(unsafe) var engine: Engine?
nonisolated(unsafe) var session: TypingSession?
nonisolated(unsafe) var text = ""          // everything before the caret
nonisolated(unsafe) var inbox: UnsafeMutablePointer<UInt8>?
nonisolated(unsafe) var inboxSize = 0
nonisolated(unsafe) var out = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)

func reply(_ s: String) {
    out.deallocate()
    let bytes = Array(s.utf8)
    out = .allocate(capacity: bytes.count)
    _ = out.initialize(from: bytes)
}
func received(_ length: Int32) -> String {
    guard let inbox, length > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: inbox, count: Int(length)), as: UTF8.self)
}

@_expose(wasm, "sp_buffer")
func spBuffer(_ size: Int32) -> UnsafeMutablePointer<UInt8>? {
    if Int(size) > inboxSize {
        inbox?.deallocate()
        inbox = .allocate(capacity: Int(size))
        inboxSize = Int(size)
    }
    return inbox
}
@_expose(wasm, "sp_out_ptr") func spOutPtr() -> UnsafePointer<UInt8>? { UnsafePointer(out.baseAddress) }
@_expose(wasm, "sp_out_len") func spOutLen() -> Int32 { Int32(out.count) }

/// Loads the data. Returns the number of words known, or -1.
@_expose(wasm, "sp_load")
func spLoad() -> Int32 {
    guard let e = try? Engine(dataDirectory: URL(fileURLWithPath: "/data")) else { return -1 }
    engine = e
    let s = TypingSession(engine: e)
    s.learningEnabled = false
    session = s
    text = ""
    s.seed(textBeforeCaret: "")
    return Int32(e.lexicon.count)
}

/// Types the UTF-8 characters in the buffer ("\u{8}" is backspace) and replies with the new text before the caret.
@_expose(wasm, "sp_type")
func spType(_ length: Int32) {
    guard let session else { return reply(text) }
    for ch in received(length) { session.type(ch, into: &text) }
    reply(text)
}

/// Applies a revision of an earlier word, if one is waiting. Replies with the text; returns 1 if it changed.
@_expose(wasm, "sp_settle")
func spSettle() -> Int32 {
    guard let session else { return 0 }
    let changed = session.applyPendingRetro(to: &text)
    reply(text)
    return changed ? 1 : 0
}

/// The caret moved or the text was edited by other means: start again from the text in the buffer.
@_expose(wasm, "sp_seed")
func spSeed(_ length: Int32) {
    text = received(length)
    session?.seed(textBeforeCaret: text)
}

/// The whole of `text` typed through a fresh session, for tests.
@_expose(wasm, "sp_simulate")
func spSimulate(_ length: Int32) {
    guard let engine else { return reply("") }
    let s = TypingSession(engine: engine)
    s.learningEnabled = false
    reply(s.simulate(typing: received(length)))
}
#else
print("sandalphon-web is built for WebAssembly: scripts/build-web.sh")
#endif
