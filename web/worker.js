// Runs the Sandalphon engine (WebAssembly) off the page's main thread. Loaded only when someone starts the
// demo. It fetches the engine and its word data from this site, keeps everything in memory, and never sends
// anything anywhere: there is no network code here beyond loading those files.
import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from "./wasi/index.js";

let x = null;
const enc = new TextEncoder();
const dec = new TextDecoder();

function send(s) {
  const bytes = enc.encode(s);
  const p = x.sp_buffer(Math.max(bytes.length, 1));
  new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
  return bytes.length;
}
const read = () => dec.decode(new Uint8Array(x.memory.buffer, x.sp_out_ptr(), x.sp_out_len()));

// Downloads a gzipped file, reporting bytes as they arrive, and returns it decompressed. Some servers undo the
// gzip on the way (Content-Encoding), so the bytes are only decompressed here if they still are gzip.
async function fetchGz(url, onBytes) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: ${res.status}`);
  const reader = res.body.getReader();
  const parts = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    onBytes(value.byteLength);
  }
  const blob = new Blob(parts);
  const head = new Uint8Array(await blob.slice(0, 2).arrayBuffer());
  if (head[0] !== 0x1f || head[1] !== 0x8b) return new Uint8Array(await blob.arrayBuffer());
  return new Uint8Array(await new Response(blob.stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer());
}

async function load(base) {
  const manifest = await (await fetch(`${base}manifest.json`)).json();
  let received = 0;
  const progress = (n) => { received += n; postMessage({ type: "progress", received, total: manifest.bytes }); };
  const [wasm, ...files] = await Promise.all([
    fetchGz(`${base}${manifest.engine}`, progress),
    ...manifest.data.map((f) => fetchGz(`${base}data/${f.name}.gz`, progress)),
  ]);
  const dir = new PreopenDirectory("/data", manifest.data.map((f, i) => [f.name, new File(files[i], { readonly: true })]));
  const wasi = new WASI([], [], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered(() => {}),
    ConsoleStdout.lineBuffered((m) => console.warn(m)),
    dir,
  ]);
  const { instance } = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: wasi.wasiImport });
  wasi.initialize(instance);
  x = instance.exports;
  const started = performance.now();
  const words = x.sp_load();
  if (words < 0) throw new Error("the word data could not be read");
  postMessage({ type: "ready", words, ms: Math.round(performance.now() - started), commit: manifest.commit });
}

onmessage = async ({ data: m }) => {
  try {
    if (m.type === "load") return await load(m.base);
    if (!x) return;
    if (m.type === "seed") { x.sp_seed(send(m.text)); return postMessage({ type: "text", id: m.id, text: m.text }); }
    if (m.type === "type") { x.sp_type(send(m.keys)); return postMessage({ type: "text", id: m.id, text: read() }); }
    if (m.type === "settle") { const changed = x.sp_settle(); return postMessage({ type: "text", id: m.id, text: read(), changed: !!changed }); }
  } catch (error) {
    postMessage({ type: "error", message: String(error && error.message || error) });
  }
};
