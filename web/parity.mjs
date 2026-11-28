// Runs sentences through the WebAssembly engine under Node's WASI, one per line of stdin, printing the result.
// Usage: node web/parity.mjs path/to/sandalphon-web.wasm path/to/Data < sentences.txt
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
const [wasmPath, dataDir] = process.argv.slice(2);
const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: { "/data": dataDir } });
const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), { wasi_snapshot_preview1: wasi.wasiImport });
wasi.initialize(instance);
const x = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();
const send = (s) => { const b = enc.encode(s); const p = x.sp_buffer(b.length || 1); new Uint8Array(x.memory.buffer, p, b.length).set(b); return b.length; };
const read = () => dec.decode(new Uint8Array(x.memory.buffer, x.sp_out_ptr(), x.sp_out_len()));
const t0 = performance.now();
const words = x.sp_load();
console.error(`loaded ${words} words in ${Math.round(performance.now() - t0)} ms`);
const input = (await new Promise((r) => { let d = ""; process.stdin.on("data", (c) => (d += c)); process.stdin.on("end", () => r(d)); }));
let keys = 0, ms = 0;
for (const line of input.split("\n").filter(Boolean)) {
  x.sp_simulate(send(line + " "));
  console.log(read());
  // Also time the per-key path the page uses.
  x.sp_seed(send(""));
  const t = performance.now();
  for (const ch of line + " ") { x.sp_type(send(ch)); keys++; }
  ms += performance.now() - t;
}
console.error(`per key: ${(ms / keys).toFixed(3)} ms`);
