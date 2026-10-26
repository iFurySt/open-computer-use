#!/usr/bin/env node

import { AsyncLocalStorage } from "node:async_hooks";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";

const require = createRequire(import.meta.url);
// The js call whose code is running. Timers and promises carry it, so a callback
// scheduled by a finished call still names that call, not the one running now.
const evaluationOwner = new AsyncLocalStorage();
const repl = require("node:repl");
const { PassThrough } = require("node:stream");

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TIMEOUT_MS = 300_000;
const MAX_FRAME_BYTES = 32 * 1024 * 1024;
const HERE = path.dirname(fileURLToPath(import.meta.url));

const SERVER_INSTRUCTIONS = `UI automation through a persistent JavaScript REPL using the initialized cua API.

On the first call after startup or js_reset, bind the requested app with await cua.getApp("Example App"), or call await cua.getState() only when an app inventory is actually needed. On macOS, use getApp(name, { initialState: false }) followed by app.query({ text, role }) for targeted lookup without an initial snapshot. App bindings persist across js calls. Batch deterministic actions and the resulting getAXState() in one js call, then verify the returned UI state. Use nodeRepl.write(value) for additional text and await nodeRepl.emitImage(image) for additional images. Ask the user before destructive or externally visible actions such as sending, deleting, or purchasing.`;

const JS_DESCRIPTION = `Run JavaScript in a persistent Node.js REPL with top-level await and an initialized asynchronous cua API for Open Computer Use. Use this for all desktop interactions. Bind an app with let app = await cua.getApp("Example App"); then call await app.click(...), await app.typeText(...), and await app.getAXState(). Top-level bindings persist until js_reset, so prefer top-level var for names that may be assigned again. Batch deterministic actions and the resulting state read in one call to reduce round trips. Use nodeRepl.write(value) for extra text and await nodeRepl.emitImage(image) for extra images. If timeout_ms is omitted, execution times out after 30000 ms.`;

const RESET_DESCRIPTION = `Reset the persistent Open Computer Use JavaScript session and discard all bindings created by prior js calls. The next js call starts with a freshly initialized cua API. This does not close native apps or erase their state.`;

const COMPUTER_USE_GUIDANCE = `## Open Computer Use JavaScript API

The runtime exposes an asynchronous app-bound API:

- \`await cua.getState({ emit? })\`: list current apps.
- \`await cua.listApps({ emit? })\`: list current apps.
- \`await cua.getApp(nameOrBundleID, { initialState? })\`: bind an app; initialState defaults to true. Use false for a lightweight binding before query.
- \`await cua.readClipboard()\` / \`await cua.writeClipboard(text)\`: macOS-only plain-text clipboard. Items marked concealed, transient or auto-generated are not returned. Write only when the user asked, since it replaces what they copied.
- \`await app.query({ text?, role?, exact?, limit?, maxNodes?, windowId? })\`: macOS-only AX lookup; returns matches and truncation metadata, with indexes usable in this native session.
- \`await app.getAXState({ emit?, textLimit?, maxTreeNodes?, maxTreeDepth?, windowPlacement? })\`
- \`await app.getScreenshot({ emit? })\`
- \`await app.getAXStateAndScreenshot(options?)\`
- Optional observation on macOS, Windows and Linux: \`app.getScreenshot({ includeAX: false })\` skips AX/focus/selection and invalidates prior element indexes; refresh AX before element actions. \`app.getAXState({ includeScreenshot: false })\` skips capture; screenshot-coordinate actions require a fresh screenshot. Omitted options retain full native observation.
- \`await app.click(elementIndexOrPoint, { mouseButton?, clickCount?, clickMethod? })\`
- \`await app.scroll(elementIndex, direction, pages?)\`
- \`await app.drag([fromX, fromY], [toX, toY])\`
- \`await app.typeText(text, { keyMethod? })\`
- \`await app.pressKey(key, { keyMethod? })\`
- \`await app.setValue(elementIndex, value)\`
- \`await app.selectText(elementIndex, text, { prefix?, suffix?, selection? })\`: macOS-only; selection is text (default), cursor_before or cursor_after. Ambiguous text and unverified selections throw.
- \`await app.performSecondaryAction(elementIndex, action)\`

After actions, call \`getAXState()\` in the same js invocation when the next decision depends on the updated UI. Re-derive element indexes from fresh state after navigation or layout changes. Prefer element indexes over coordinates. Open Computer Use keeps its existing local safety gates, including password-manager denial and explicit authorization for global pointer fallbacks.`;

function asError(error) {
  if (error instanceof Error) return error;
  // Errors thrown inside the REPL context come from another realm and fail instanceof.
  return new Error(typeof error?.message === "string" ? error.message : String(error));
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function formatValue(value) {
  if (typeof value === "string") return value;
  return require("node:util").inspect(value, { depth: 6, colors: false, breakLength: 100 });
}

function sniffMimeType(bytes) {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  throw new Error("nodeRepl.emitImage could not infer PNG, JPEG, or WebP MIME type");
}

function normalizeImage(value) {
  if (typeof value === "string") {
    if (!value.startsWith("data:image/")) throw new Error("nodeRepl.emitImage accepts image data URLs or bytes");
    const match = /^data:([^;,]+);base64,(.*)$/s.exec(value);
    if (!match) throw new Error("nodeRepl.emitImage expected a base64 image data URL");
    return { mimeType: match[1], data: match[2] };
  }
  if (Buffer.isBuffer(value) || value instanceof Uint8Array || value instanceof ArrayBuffer) {
    const bytes = Buffer.from(value instanceof ArrayBuffer ? new Uint8Array(value) : value);
    return { mimeType: sniffMimeType(bytes), data: bytes.toString("base64") };
  }
  if (isPlainObject(value) && value.bytes !== undefined) {
    const bytes = Buffer.from(value.bytes instanceof ArrayBuffer ? new Uint8Array(value.bytes) : value.bytes);
    const mimeType = typeof value.mimeType === "string" ? value.mimeType : sniffMimeType(bytes);
    if (!mimeType.startsWith("image/")) throw new Error("nodeRepl.emitImage expected an image MIME type");
    return { mimeType, data: bytes.toString("base64") };
  }
  throw new Error("nodeRepl.emitImage received an unsupported value");
}

export class JsonLinePeer extends EventEmitter {
  constructor({ command, args = [], cwd, env = process.env, child } = {}) {
    super();
    this.options = { command, args, cwd, env };
    this.injected = Boolean(child);
    this.disposed = false;
    this.reopening = null;
    this.#start(child ?? spawn(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"] }));
  }

  #start(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = "";
    this.stderr = "";
    this.closed = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { if (this.child === child) this.#onData(chunk); });
    child.stderr.on("data", chunk => { if (this.child === child) this.stderr = (this.stderr + chunk).slice(-8192); });
    child.on("error", error => { if (this.child === child) this.#close(error); });
    child.on("exit", (code, signal) => {
      if (this.child === child) this.#close(new Error(`native MCP exited (code=${code ?? "null"}, signal=${signal ?? "null"})${this.stderr ? `: ${this.stderr.trim()}` : ""}`));
    });
  }

  #reopen() {
    if (!this.reopening) {
      this.reopening = (async () => {
        const { command, args, cwd, env } = this.options;
        this.#start(spawn(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"] }));
        await this.initialize();
      })().catch(error => { this.endSession(); throw error; }).finally(() => { this.reopening = null; });
    }
    return this.reopening;
  }

  #onData(chunk) {
    this.buffer += chunk;
    if (Buffer.byteLength(this.buffer, "utf8") > MAX_FRAME_BYTES) return this.#close(new Error("native MCP response buffer exceeded limit"));
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch (error) { this.emit("protocolError", new Error(`invalid native MCP JSON: ${line.slice(0, 200)}`)); continue; }
      if (message.id !== undefined && this.pending.has(String(message.id))) {
        const pending = this.pending.get(String(message.id));
        this.pending.delete(String(message.id));
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(message.error.message ?? JSON.stringify(message.error)));
        else pending.resolve(message.result);
      } else {
        this.emit("message", message);
      }
    }
  }

  #close(error) {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    this.emit("close", error);
  }

  request(method, params = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
    if (this.reopening && method !== "initialize") return this.reopening.then(() => this.request(method, params, timeoutMs));
    if (this.closed && !this.injected && !this.disposed) return this.#reopen().then(() => this.request(method, params, timeoutMs));
    if (this.closed) return Promise.reject(new Error("native MCP is closed"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
          this.pending.delete(String(id));
          reject(new Error(`native MCP ${method} timed out after ${timeoutMs} ms`));
          this.endSession();
        }, timeoutMs)
        : undefined;
      this.pending.set(String(id), { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`, error => {
        if (!error) return;
        if (timer) clearTimeout(timer);
        this.pending.delete(String(id));
        reject(error);
      });
    });
  }

  notify(method, params = {}) {
    if (!this.closed) this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  async initialize() {
    const result = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "open-computer-use-node-repl", version: "1" },
    });
    this.notify("notifications/initialized", {});
    return result;
  }

  endSession() {
    if (this.closed) return;
    const child = this.child;
    this.#close(new Error("native Computer Use session ended"));
    child.stdin.end();
    const timer = setTimeout(() => child.kill("SIGKILL"), 1_000);
    timer.unref();
    child.kill("SIGTERM");
  }

  close() {
    this.disposed = true;
    this.endSession();
  }

}

function toolResultText(result) {
  return (result?.content ?? []).filter(item => item?.type === "text").map(item => item.text ?? "").filter(Boolean).join("\n");
}

function toolResultImages(result) {
  return (result?.content ?? []).filter(item => item?.type === "image" && typeof item.data === "string");
}

function parseListAppMarkers(markers) {
  const app = {};
  for (const marker of markers.split(/,\s*/)) {
    if (marker === "running") app.isRunning = true;
    else if (marker.startsWith("last-used=")) app.lastUsedDate = marker.slice("last-used=".length);
    else if (marker.startsWith("uses=")) {
      const useCount = Number.parseInt(marker.slice("uses=".length), 10);
      if (Number.isSafeInteger(useCount)) app.useCount = useCount;
    }
  }
  return app;
}

// The native compatibility surface intentionally returns human-readable text.
// Normalize its macOS (em dash) and Linux/Windows (double hyphen) renderings
// into the stable code-first shape used by cua.listApps(). Unknown lines are
// retained as display names rather than making discovery fail completely.
export function parseListApps(text) {
  if (!text.trim() || /^No running top-level apps are visible/u.test(text.trim())) return [];
  return text.split(/\r?\n/).map(line => {
    const trimmed = line.trim();
    const match = /^(.*?)\s+(?:—|--)\s+(.+?)\s+\[([^\]]*)\]$/u.exec(trimmed);
    if (!match) return { id: trimmed, displayName: trimmed };
    return { id: match[2], displayName: match[1], ...parseListAppMarkers(match[3]) };
  }).filter(app => app.id);
}

function optionsToSnapshotArgs(options = {}) {
  const args = {};
  if (options.textLimit !== undefined) args.text_limit = options.textLimit;
  if (options.maxTreeNodes !== undefined) args.max_tree_nodes = options.maxTreeNodes;
  if (options.maxTreeDepth !== undefined) args.max_tree_depth = options.maxTreeDepth;
  if (options.windowPlacement !== undefined) args.window_placement = options.windowPlacement;
  for (const [option, argument] of [["includeAX", "include_ax"], ["includeScreenshot", "include_screenshot"]]) {
    if (options[option] !== undefined) {
      if (typeof options[option] !== "boolean") throw new Error(`${option} must be a boolean`);
      args[argument] = options[option];
    }
  }
  if (args.include_ax === false && args.include_screenshot === false) {
    throw new Error("At least one of includeAX or includeScreenshot must be true");
  }
  return args;
}

function optionsToClickArgs(options = {}) {
  const args = {};
  if (options.mouseButton !== undefined) args.mouse_button = options.mouseButton;
  if (options.clickCount !== undefined) args.click_count = options.clickCount;
  if (options.clickMethod !== undefined) args.click_method = options.clickMethod;
  return args;
}

function optionsToKeyArgs(options = {}) {
  const args = {};
  if (options.keyMethod !== undefined) args.key_method = options.keyMethod;
  return args;
}

export function createCuaApi(native, activeOutput) {
  let docsEmitted = false;
  async function call(tool, args = {}) {
    const result = await native.request("tools/call", { name: tool, arguments: args });
    if (result?.isError) throw new Error(toolResultText(result) || `${tool} failed`);
    return result;
  }
  async function emitText(text, options = {}) {
    if (options.emit === false || !text) return;
    activeOutput().write(text, "cua.state");
  }
  async function emitImages(images, options = {}) {
    if (options.emit === false) return;
    for (const image of images) await activeOutput().emitImage({ bytes: Buffer.from(image.data, "base64"), mimeType: image.mimeType ?? "image/png" });
  }
  async function emitDocs() {
    if (docsEmitted) return;
    activeOutput().write(COMPUTER_USE_GUIDANCE, "cua.core");
    docsEmitted = true;
  }
  function appBinding(app) {
    return Object.freeze({
      async query(options = {}) {
        if (!isPlainObject(options)) throw new Error("app.query expects an options object");
        for (const key of Object.keys(options)) {
          if (!["text", "role", "exact", "limit", "maxNodes", "windowId"].includes(key)) throw new Error(`Unknown query option: ${key}`);
        }
        for (const key of ["text", "role"]) {
          if (options[key] !== undefined && (typeof options[key] !== "string" || options[key].length > 1000)) throw new Error(`${key} must be a string of at most 1000 UTF-16 code units`);
        }
        if (!options.text?.trim() && !options.role?.trim()) throw new Error("query requires text and/or role");
        if (options.exact !== undefined && typeof options.exact !== "boolean") throw new Error("exact must be true or false");
        for (const key of ["limit", "maxNodes", "windowId"]) {
          if (options[key] !== undefined && (!Number.isSafeInteger(options[key]) || options[key] < 1 || (key === "windowId" && options[key] > 0xffffffff))) throw new Error(`${key} must be a positive integer${key === "windowId" ? " up to 4294967295" : ""}`);
        }
        const result = await call("query", { app, text: options.text, role: options.role, exact: options.exact,
                                             limit: options.limit, max_nodes: options.maxNodes, window_id: options.windowId });
        const response = JSON.parse(toolResultText(result));
        if (!isPlainObject(response) || !Array.isArray(response.matches) || typeof response.truncated !== "boolean" || typeof response.stop_reason !== "string") throw new Error("Invalid query response");
        return response;
      },
      async getAXState(options = {}) {
        const result = await call("get_app_state", { app, ...optionsToSnapshotArgs(options) });
        const text = toolResultText(result);
        await emitText(text, options);
        return text;
      },
      async getScreenshot(options = {}) {
        const result = await call("get_app_state", { app, ...optionsToSnapshotArgs(options), text_limit: 1 });
        const image = toolResultImages(result)[0];
        if (!image) throw new Error(`Screenshot unavailable for ${app}`);
        const bytes = Buffer.from(image.data, "base64");
        await emitImages([image], options);
        return bytes;
      },
      async getAXStateAndScreenshot(options = {}) {
        const result = await call("get_app_state", { app, ...optionsToSnapshotArgs(options) });
        const state = toolResultText(result);
        const images = toolResultImages(result);
        await emitText(state, options);
        await emitImages(images, options);
        return images[0] ? { state, screenshot: Buffer.from(images[0].data, "base64") } : { state };
      },
      async click(target, options = {}) {
        const targetArgs = Array.isArray(target) ? { x: target[0], y: target[1] } : { element_index: target };
        await call("click", { app, ...targetArgs, ...optionsToClickArgs(options) });
      },
      async drag(from, to) { await call("drag", { app, from_x: from[0], from_y: from[1], to_x: to[0], to_y: to[1] }); },
      async pressKey(key, options = {}) { await call("press_key", { app, key, ...optionsToKeyArgs(options) }); },
      async scroll(target, direction, pages = 1) {
        if (Array.isArray(target)) throw new Error("coordinate scroll is not supported by this Open Computer Use runtime");
        await call("scroll", { app, element_index: target, direction, pages });
      },
      async setValue(elementIndex, value) { await call("set_value", { app, element_index: elementIndex, value }); },
      async selectText(elementIndex, text, options = {}) {
        const index = typeof elementIndex === "string" && /^(0|[1-9]\d*)$/u.test(elementIndex) ? Number(elementIndex) : elementIndex;
        if (!Number.isSafeInteger(index) || index < 0) throw new Error("selectText requires a non-negative integer element index");
        if (typeof text !== "string" || !text.length) throw new Error("selectText requires non-empty text");
        if (!isPlainObject(options)) throw new Error("selectText expects an options object");
        for (const key of Object.keys(options)) {
          if (!["prefix", "suffix", "selection"].includes(key)) throw new Error(`Unknown selectText option: ${key}`);
        }
        for (const key of ["prefix", "suffix"]) {
          if (options[key] !== undefined && typeof options[key] !== "string") throw new Error(`${key} must be a string`);
        }
        if (options.selection !== undefined && !["text", "cursor_before", "cursor_after"].includes(options.selection)) {
          throw new Error("selection must be text, cursor_before or cursor_after");
        }
        await call("select_text", { app, element_index: elementIndex, text,
          prefix: options.prefix, suffix: options.suffix, selection: options.selection });
      },
      async typeText(text, options = {}) { await call("type_text", { app, text, ...optionsToKeyArgs(options) }); },
      async performSecondaryAction(elementIndex, action) { await call("perform_secondary_action", { app, element_index: elementIndex, action }); },
    });
  }
  const api = {
    async getState(options = {}) {
      await emitDocs();
      const result = await call("list_apps", {});
      const text = toolResultText(result);
      let apps;
      try {
        const parsed = JSON.parse(text);
        apps = Array.isArray(parsed) ? parsed : parseListApps(text);
      } catch {
        apps = parseListApps(text);
      }
      if (options.emit !== false) activeOutput().write(apps, "cua.state");
      return { apps };
    },
    async listApps(options = {}) {
      await emitDocs();
      const state = await api.getState({ emit: false });
      if (options.emit !== false) activeOutput().write(state.apps, "cua.state");
      return state.apps;
    },
    async getApp(app, options = {}) {
      if (typeof app !== "string" || !app.trim()) throw new Error("getApp requires an app name or bundle ID");
      if (!isPlainObject(options) || (options.initialState !== undefined && typeof options.initialState !== "boolean")) throw new Error("initialState must be true or false");
      await emitDocs();
      if (options.initialState !== false) {
        const result = await call("get_app_state", { app, text_limit: "max" });
        await emitText(toolResultText(result));
      }
      return appBinding(app);
    },
    async readClipboard() { return toolResultText(await call("read_clipboard", {})); },
    async writeClipboard(text) {
      if (typeof text !== "string" || !text.length) throw new Error("writeClipboard requires non-empty text");
      await call("write_clipboard", { text });
    },
    async rewriteDocumentation() { activeOutput().write(COMPUTER_USE_GUIDANCE, "cua.core"); },
  };
  return Object.freeze(api);
}

export class PersistentJavaScriptSession {
  constructor({ native }) {
    this.native = native;
    this.active = null;
    this.reset();
  }

  #currentOutput() {
    const owner = evaluationOwner.getStore();
    if (!owner || owner !== this.active) throw new Error("nodeRepl output is only available while js is executing");
    return owner;
  }

  #settleOwner(owner, error) {
    if (owner && owner === this.active) owner.reject(error);
  }

  #ownedAsyncCallback(callback) {
    if (typeof callback !== "function") return callback;
    const owner = evaluationOwner.getStore();
    const session = this;
    return function (...args) {
      try {
        const value = evaluationOwner.run(owner, () => Reflect.apply(callback, this, args));
        if (value && typeof value.then === "function") {
          void value.catch(error => session.#settleOwner(owner, error));
        }
        return value;
      } catch (error) {
        session.#settleOwner(owner, error);
        return undefined;
      }
    };
  }

  reset() {
    this.repl?.close();
    const input = new PassThrough();
    const output = new PassThrough();
    output.resume();
    // A throw inside evaluated code (sync, or after an await) never reaches the eval
    // callback: the REPL prints it and moves on. Settle the evaluation from the REPL's
    // error path instead (`handleError` on Node 26, a domain on Node 22), but only the
    // call that threw: a late throw from a finished call is dropped, as the REPL would.
    const settle = error => {
      const owner = evaluationOwner.getStore();
      this.#settleOwner(owner, error);
      return "ignore";
    };
    this.repl = repl.start({ prompt: "", input, output, terminal: false, useGlobal: false, ignoreUndefined: true, breakEvalOnSigint: true, handleError: settle });
    this.repl.on("error", () => {});
    this.repl._domain?.on("error", settle);
    // Node's REPL domain can report an old timer's exception while a newer eval is
    // active, losing the AsyncLocalStorage owner that scheduled the callback. Wrap
    // timer callbacks inside the REPL context so their errors settle only their own
    // still-active evaluation and are otherwise dropped.
    this.repl.context.setTimeout = (callback, delay, ...args) => setTimeout(this.#ownedAsyncCallback(callback), delay, ...args);
    this.repl.context.setInterval = (callback, delay, ...args) => setInterval(this.#ownedAsyncCallback(callback), delay, ...args);
    this.repl.context.setImmediate = (callback, ...args) => setImmediate(this.#ownedAsyncCallback(callback), ...args);
    this.repl.context.queueMicrotask = callback => queueMicrotask(this.#ownedAsyncCallback(callback));
    const nodeRepl = {
      cwd: process.cwd(),
      homeDir: process.env.HOME ?? "",
      tmpDir: process.env.TMPDIR ?? "/tmp",
      write: (value, itemId) => this.#currentOutput().write(value, itemId),
      emitImage: async value => this.#currentOutput().emitImage(value),
    };
    Object.defineProperty(nodeRepl, "requestMeta", { get: () => this.requestMeta ?? {} });
    Object.freeze(nodeRepl);
    this.nodeRepl = nodeRepl;
    Object.defineProperty(this.repl.context, "nodeRepl", { value: nodeRepl, configurable: false, writable: false });
    Object.defineProperty(this.repl.context, "cua", { value: createCuaApi(this.native, () => this.#currentOutput()), configurable: false, writable: false });
  }

  async run(code, timeoutMs = DEFAULT_TIMEOUT_MS, requestMeta = {}) {
    if (typeof code !== "string" || !code.trim()) throw new Error("js expects non-empty JavaScript source");
    const content = [];
    const active = {
      write(value, itemId) { content.push({ type: "text", text: formatValue(value), ...(itemId ? { _meta: { id: itemId } } : {}) }); },
      async emitImage(value) { const image = normalizeImage(await value); content.push({ type: "image", mimeType: image.mimeType, data: image.data }); },
    };
    this.active = active;
    this.requestMeta = requestMeta;
    let timer;
    const enforceTimeout = Number.isFinite(timeoutMs) && timeoutMs > 0;
    try {
      const evaluation = new Promise((resolve, reject) => {
        active.reject = reject;
        evaluationOwner.run(active, () => this.repl.eval(code, this.repl.context, "open-computer-use-repl", (error, result) => error ? reject(error) : resolve(result)));
      });
      const value = enforceTimeout
        ? await Promise.race([evaluation, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`js execution timed out after ${timeoutMs} ms; session reset`)), timeoutMs); })])
        : await evaluation;
      if (content.length === 0) content.push({ type: "text", text: "(no output)" });
      return { content, isError: false };
    } catch (error) {
      const message = asError(error).message;
      if (message.includes("timed out")) this.reset();
      content.push({ type: "text", text: `Error: ${message}` });
      return { content, isError: true };
    } finally {
      clearTimeout(timer);
      this.active = null;
    }
  }
}

// Production isolation boundary. JavaScript runs in a worker so a CPU-bound
// loop can be terminated without hanging the MCP transport. Native tool calls
// are brokered back to the parent and still execute serially in the native MCP.
export class WorkerJavaScriptSession {
  constructor({ native }) {
    this.native = native;
    this.nextId = 1;
    this.pending = new Map();
    this.runQueue = Promise.resolve();
    this.invalidatedWorkers = new WeakSet();
    this.#start();
  }

  #start() {
    const worker = new Worker(new URL("./open-computer-use-kernel.mjs", import.meta.url));
    this.worker = worker;
    worker.on("message", message => void this.#onMessage(worker, message));
    worker.on("error", error => {
      if (this.worker === worker && !this.invalidatedWorkers.has(worker)) {
        this.invalidatedWorkers.add(worker);
        this.native.endSession?.();
      }
      this.#failWorker(worker, error);
    });
    worker.on("exit", code => { if (code !== 0) this.#failWorker(worker, new Error(`JavaScript kernel exited with code ${code}`)); });
  }

  async #onMessage(worker, message) {
    if (this.worker !== worker || this.invalidatedWorkers.has(worker)) return;
    if (message.type === "result") {
      const pending = this.pending.get(message.id);
      if (!pending || pending.worker !== worker) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      pending.resolve(message.result);
      return;
    }
    if (message.type === "native_request") {
      try {
        const result = await this.native.request(message.method, message.params, message.timeoutMs);
        if (this.worker === worker) worker.postMessage({ type: "native_response", id: message.id, result });
      } catch (error) {
        if (this.worker === worker) worker.postMessage({ type: "native_response", id: message.id, error: asError(error).message });
      }
    }
  }

  #failWorker(worker, error) {
    for (const [id, pending] of this.pending) {
      if (pending.worker !== worker) continue;
      clearTimeout(pending.timer);
      pending.resolve({ content: [{ type: "text", text: `Error: ${asError(error).message}` }], isError: true });
      this.pending.delete(id);
    }
  }

  async reset() {
    const old = this.worker;
    this.invalidatedWorkers.add(old);
    this.native.endSession?.();
    this.#failWorker(old, new Error("JavaScript session reset"));
    await old.terminate();
    if (this.worker === old) this.#start();
  }

  async close() {
    const old = this.worker;
    this.invalidatedWorkers.add(old);
    this.native.endSession?.();
    this.#failWorker(old, new Error("JavaScript session closed"));
    await old.terminate();
  }

  run(code, timeoutMs = DEFAULT_TIMEOUT_MS, requestMeta = {}) {
    const queued = this.runQueue.then(() => this.#run(code, timeoutMs, requestMeta));
    this.runQueue = queued.catch(() => {});
    return queued;
  }

  #run(code, timeoutMs, requestMeta) {
    const id = this.nextId++;
    return new Promise(resolve => {
      const worker = this.worker;
      const timer = setTimeout(async () => {
        const pending = this.pending.get(id);
        if (!pending || pending.worker !== worker) return;
        this.pending.delete(id);
        this.invalidatedWorkers.add(worker);
        this.native.endSession?.();
        await worker.terminate();
        if (this.worker === worker) this.#start();
        resolve({ content: [{ type: "text", text: `Error: js execution timed out after ${timeoutMs} ms; session reset` }], isError: true });
      }, timeoutMs);
      this.pending.set(id, { resolve, timer, worker });
      worker.postMessage({ type: "exec", id, code, timeoutMs, requestMeta });
    });
  }
}

function resolveNativeCommand(argv) {
  const separator = argv.indexOf("--");
  if (separator >= 0) {
    const command = argv[separator + 1];
    if (!command) throw new Error("expected native MCP command after --");
    return { command, args: argv.slice(separator + 2) };
  }
  const fromEnv = process.env.OPEN_COMPUTER_USE_NATIVE_COMMAND;
  if (fromEnv) return { command: fromEnv, args: (process.env.OPEN_COMPUTER_USE_NATIVE_ARGS ?? "mcp").split(/\s+/).filter(Boolean) };
  const candidates = [
    path.resolve(HERE, "../../dist/Open Computer Use (Dev).app/Contents/MacOS/OpenComputerUse"),
    path.resolve(HERE, "../../dist/Open Computer Use.app/Contents/MacOS/OpenComputerUse"),
    path.resolve(HERE, "../../dist/linux/arm64/open-computer-use"),
    path.resolve(HERE, "../../dist/linux/amd64/open-computer-use"),
  ];
  const command = candidates.find(existsSync) ?? "open-computer-use";
  return { command, args: ["mcp"] };
}

export async function runServer({ command, args }) {
  // Actions return a short status instead of a settle + full snapshot the adapter would
  // discard; state is read explicitly by getAXState(). Runtimes without the flag ignore it.
  const native = new JsonLinePeer({ command, args, env: { ...process.env, OPEN_COMPUTER_USE_ACTION_READ_BACK: "0" } });
  await native.initialize();
  const session = new WorkerJavaScriptSession({ native });
  let buffer = "";
  let requestQueue = Promise.resolve();
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", chunk => {
    buffer += chunk;
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line) requestQueue = requestQueue.then(() => handle(line)).catch(error => console.error(asError(error).message));
    }
  });
  async function handle(line) {
    let request;
    try { request = JSON.parse(line); } catch { return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Invalid JSON-RPC payload" } }); }
    const { id, method, params = {} } = request;
    if (id === undefined) {
      if (method === "notifications/turn-ended") { native.notify(method, params); native.endSession(); }
      return;
    }
    try {
      if (method === "initialize") return send({ jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "open-computer-use-repl", version: "1" }, instructions: SERVER_INSTRUCTIONS } });
      if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
      if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: toolDefinitions() } });
      if (method === "tools/call") {
        if (params.name === "js_reset") { await session.reset(); return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Open Computer Use JavaScript session reset" }], isError: false } }); }
        if (params.name === "js") {
          const requestedTimeoutMs = params.arguments?.timeout_ms;
          const timeoutMs = Number.isInteger(requestedTimeoutMs) && requestedTimeoutMs > 0
            ? Math.min(requestedTimeoutMs, MAX_TIMEOUT_MS)
            : DEFAULT_TIMEOUT_MS;
          const result = await session.run(params.arguments?.code, timeoutMs, request._meta ?? {});
          return send({ jsonrpc: "2.0", id, result });
        }
        throw new Error(`Unsupported tool: ${params.name}`);
      }
      throw new Error(`Unsupported method: ${method}`);
    } catch (error) {
      send({ jsonrpc: "2.0", id, error: { code: -32603, message: asError(error).message } });
    }
  }
  function send(message) { process.stdout.write(`${JSON.stringify(message)}\n`); }
  let shuttingDown;
  const shutdown = () => {
    if (!shuttingDown) shuttingDown = session.close().finally(() => native.close());
    return shuttingDown;
  };
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => { void shutdown().finally(() => process.exit(0)); });
  process.stdin.on("end", () => { void requestQueue.finally(shutdown); });
}

export function toolDefinitions() {
  const annotations = { destructiveHint: false, openWorldHint: false };
  return [
    { name: "js", description: JS_DESCRIPTION, annotations, inputSchema: { type: "object", additionalProperties: false, properties: { code: { type: "string", minLength: 1, description: "JavaScript source to execute with top-level await and the initialized cua API." }, timeout_ms: { type: "integer", minimum: 1, maximum: MAX_TIMEOUT_MS, description: "Optional timeout in milliseconds. Defaults to 30000 and is capped at 300000." }, title: { type: "string", minLength: 1, maxLength: 80, description: "Short user-facing description of what this code is doing." } }, required: ["code"] } },
    { name: "js_reset", description: RESET_DESCRIPTION, annotations: { ...annotations, readOnlyHint: true }, inputSchema: { type: "object", additionalProperties: false, properties: {} } },
  ];
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  runServer(resolveNativeCommand(process.argv.slice(2))).catch(error => { console.error(`open-computer-use-repl: ${asError(error).message}`); process.exit(1); });
}
