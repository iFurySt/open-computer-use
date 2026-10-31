import { configCommand, configHelp } from "./ocu-config.mjs";
import { spawn } from "node:child_process";
import { constants as fsConstants, accessSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TIMEOUT_MS = 300_000;

const installCommands = new Map([
  ["install-claude-mcp", "install-claude-mcp.sh"],
  ["install-clauce-mcp", "install-claude-mcp.sh"],
  ["install-gemini-mcp", "install-gemini-mcp.sh"],
  ["install-codex-mcp", "install-codex-mcp.sh"],
  ["install-opencode-mcp", "install-opencode-mcp.sh"],
  ["install-dsh-mcp", "install-dsh-mcp.sh"],
  ["install-codex-plugin", "install-codex-plugin.sh"],
]);

function asError(error) {
  return error instanceof Error ? error : new Error(String(error));
}

function canExecute(filePath, platform) {
  if (!existsSync(filePath)) return false;
  if (platform === "win32") return true;
  try {
    accessSync(filePath, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export function runtimePaths({ packageRoot, platformPackages, platform, arch }) {
  const platformKey = `${platform}-${arch}`;
  const target = platformPackages[platformKey];
  return {
    platformKey,
    supported: Boolean(target),
    nativePath: target ? path.join(packageRoot, ...target.executablePath) : undefined,
    adapterPath: path.join(packageRoot, "scripts", "node-repl", "open-computer-use-repl.mjs"),
    kernelPath: path.join(packageRoot, "scripts", "node-repl", "open-computer-use-kernel.mjs"),
    adapterDependencyPaths: ["ocu-config.mjs", "ax-state-diff.mjs"].map(name => path.join(packageRoot, "scripts", "node-repl", name)),
  };
}

export function inspectCapabilities({
  packageRoot,
  platformPackages,
  platform = process.platform,
  arch = process.arch,
  execPath = process.execPath,
  nodeVersion = process.version,
}) {
  const paths = runtimePaths({ packageRoot, platformPackages, platform, arch });
  const nodeMajor = Number.parseInt(String(nodeVersion).replace(/^v/, "").split(".")[0], 10);
  const node = {
    available: Boolean(execPath && nodeVersion && Number.isInteger(nodeMajor) && nodeMajor >= 18),
    version: nodeVersion,
    executable: execPath,
    minimumVersion: "18.0.0",
    source: "launcher",
    bootstrapNote: "The npm launcher itself requires Node.js 18 or newer; a shell with no node on PATH cannot start this command.",
  };
  const missingDependencies = paths.adapterDependencyPaths.filter(file => !existsSync(file));
  const adapter = { available: existsSync(paths.adapterPath) && missingDependencies.length === 0, path: paths.adapterPath, missingDependencies };
  const kernel = { available: existsSync(paths.kernelPath), path: paths.kernelPath };
  const native = {
    available: Boolean(paths.nativePath && canExecute(paths.nativePath, platform)),
    path: paths.nativePath ?? null,
    platform: paths.platformKey,
    supported: paths.supported,
  };
  const unavailableReasons = [];
  if (!node.available) unavailableReasons.push(`Node.js >= ${node.minimumVersion} is unavailable`);
  if (!existsSync(adapter.path)) unavailableReasons.push(`REPL adapter is missing at ${adapter.path}`);
  for (const dependency of missingDependencies) unavailableReasons.push(`REPL adapter dependency is missing at ${dependency}`);
  if (!kernel.available) unavailableReasons.push(`JavaScript kernel is missing at ${kernel.path}`);
  if (!native.supported) unavailableReasons.push(`platform ${paths.platformKey} is unsupported`);
  else if (!native.available) unavailableReasons.push(`native runtime is missing or not executable at ${native.path}`);
  const codeAvailable = unavailableReasons.length === 0;

  return {
    schemaVersion: 1,
    runtime: { node, adapter, kernel, native },
    capabilities: {
      nativeMcp: {
        available: native.available,
        lifecycle: "stdio-session",
        toolSurface: "9 native computer-use tools",
      },
      js: {
        available: codeAvailable,
        lifecycle: "one-shot",
        requires: ["node", "adapter", "kernel", "native"],
        unavailableReasons,
      },
      repl: {
        available: codeAvailable,
        lifecycle: "terminal-session",
        requires: ["node", "adapter", "kernel", "native"],
        unavailableReasons,
      },
    },
  };
}

function availabilityLabel(capabilities) {
  const js = capabilities.capabilities.js;
  return js.available ? "available" : `unavailable: ${js.unavailableReasons.join("; ")}`;
}

export function launcherHelp(capabilities) {
  const codeStatus = availabilityLabel(capabilities);
  return `Open Computer Use

Usage:
  open-computer-use [command] [options]
  ocu [command] [options]
  open-computer-use

Commands:
  mcp                  Start the native 9-tool stdio MCP server.
  js <code>            Run JavaScript once with the asynchronous cua API.
  repl                 Start a persistent interactive JavaScript session.
  config               View or persist macOS screenshot settings.
  capabilities         Report Node, adapter, native, js, and repl availability.
  doctor               Print permission status and launch onboarding if needed on macOS.
  locked-use           macOS status, settings, enable, disable, or recovery.
  list-apps            Print running or recently used apps.
  snapshot <app>       Print the current accessibility snapshot for an app.
  call <tool>          Call one tool, or run a JSON array of tool calls.
  turn-ended           Notify the running MCP process that the host turn ended.
  install-claude-mcp   Install the MCP server into ~/.claude.json for this project.
  install-gemini-mcp   Install the MCP server into Gemini CLI config.
  install-codex-mcp    Install the MCP server into ~/.codex/config.toml.
  install-opencode-mcp Install the MCP server into ~/.config/opencode.
  install-dsh-mcp      Install the MCP server into a DeepSeek Harness profile.
  install-codex-plugin Install this npm package into the local Codex plugin cache.
  help [command]       Show general or command-specific help.
  version              Print the CLI version.

Global options:
  -h, --help           Show help.
  -v, --version        Show version.

Code-first status:
  js / repl            ${codeStatus}

Notes:
  js creates one adapter/native session and exits after the evaluation.
  repl keeps one adapter/native session alive until .exit, Ctrl-D, or termination.
  The npm launcher requires Node.js 18 or newer to start; run 'ocu capabilities --json' for component details.
  'ocu mcp' intentionally keeps the native 9-tool compatibility surface.
  Use 'open-computer-use help <command>' for command-specific help.`;
}

function jsHelp() {
  return `Usage:
  ocu js [--timeout <ms>] [--json] '<code>'
  ocu js [--timeout <ms>] [--json] -
  ocu js [--timeout <ms>] [--json] --file <path>

Runs one JavaScript evaluation with top-level await and the asynchronous cua API, then closes its Worker and native MCP child. Source passed as '-' is read from stdin. The timeout defaults to 30000 ms and is capped at 300000 ms.`;
}

function replHelp() {
  return `Usage:
  ocu repl [--timeout <ms>] [--json]

Starts a JavaScript session whose top-level bindings and cua app bindings persist until exit.

REPL commands:
  .help                Show this help.
  .editor              Enter multiline mode; finish the block with .end.
  .reset               Discard all JavaScript bindings and start a fresh kernel.
  .exit                Close the kernel and native MCP child.

Use nodeRepl.write(value) for explicit output. When stdin is not a TTY, each non-empty input line is evaluated in the same session; .editor / .end also works in piped input.`;
}

function capabilitiesHelp() {
  return `Usage:
  ocu capabilities [--json]

Reports whether the current package has a usable Node runtime, REPL adapter, JavaScript kernel, and native runtime. Commands remain visible in help even when a component is unavailable.`;
}

function installHelp(scriptName, usage) {
  return `Usage:
  ${usage}

This helper updates a local MCP or plugin config to run:
  open-computer-use mcp

Script:
  ${scriptName}`;
}

function parseTimeout(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`--timeout expects a positive integer, received: ${value ?? "<missing>"}`);
  return Math.min(parsed, MAX_TIMEOUT_MS);
}

export function parseJavaScriptArgs(argv, { replMode = false } = {}) {
  const options = { timeoutMs: DEFAULT_TIMEOUT_MS, json: false, filePath: undefined, sourceParts: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--timeout") {
      options.timeoutMs = parseTimeout(argv[index + 1]);
      index += 1;
    } else if (arg === "--file") {
      if (replMode) throw new Error("--file is only supported by 'ocu js'");
      if (!argv[index + 1]) throw new Error("--file expects a path");
      options.filePath = argv[index + 1];
      index += 1;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "-h" || arg === "--help") {
      options.help = true;
    } else if (arg === "--") {
      options.sourceParts.push(...argv.slice(index + 1));
      break;
    } else if (arg.startsWith("-") && arg !== "-") {
      throw new Error(`Unknown option: ${arg}`);
    } else {
      options.sourceParts.push(arg);
    }
  }
  if (options.filePath && options.sourceParts.length > 0) throw new Error("use exactly one JavaScript source: positional code, '-', or --file");
  if (replMode && options.sourceParts.length > 0) throw new Error("'ocu repl' does not accept positional JavaScript; enter code after it starts");
  return options;
}

async function readStream(stream) {
  let source = "";
  for await (const chunk of stream) source += chunk;
  return source;
}

function writeLine(stream, value = "") {
  stream.write(`${value}\n`);
}

export function renderCapabilityReport(report) {
  const status = value => value ? "available" : "unavailable";
  const reasons = report.capabilities.js.unavailableReasons;
  return [
    `Node.js:       ${status(report.runtime.node.available)} (${report.runtime.node.version} at ${report.runtime.node.executable})`,
    `REPL adapter:  ${status(report.runtime.adapter.available)} (${report.runtime.adapter.path})`,
    `JS kernel:     ${status(report.runtime.kernel.available)} (${report.runtime.kernel.path})`,
    `Native MCP:    ${status(report.runtime.native.available)} (${report.runtime.native.platform}${report.runtime.native.path ? ` at ${report.runtime.native.path}` : ""})`,
    `ocu js:        ${status(report.capabilities.js.available)} (one-shot)`,
    `ocu repl:      ${status(report.capabilities.repl.available)} (terminal-session)`,
    ...(reasons.length ? ["", "Unavailable because:", ...reasons.map(reason => `- ${reason}`)] : []),
    "",
    report.runtime.node.bootstrapNote,
  ].join("\n");
}

function assertCodeCapability(report) {
  if (report.capabilities.js.available) return;
  throw new Error(`JavaScript capability is unavailable:\n${report.capabilities.js.unavailableReasons.map(reason => `- ${reason}`).join("\n")}\n\nRun 'ocu capabilities --json' for details, then reinstall the package if files are missing.`);
}

async function loadReplRuntime(paths) {
  const adapter = await import(pathToFileURL(paths.adapterPath).href);
  return {
    JsonLinePeer: adapter.JsonLinePeer,
    WorkerJavaScriptSession: adapter.WorkerJavaScriptSession,
  };
}

async function openSession({ paths, env }) {
  const { JsonLinePeer, WorkerJavaScriptSession } = await loadReplRuntime(paths);
  const native = new JsonLinePeer({ command: paths.nativePath, args: ["mcp"], env });
  try {
    await native.initialize();
    const session = new WorkerJavaScriptSession({ native });
    let closing;
    return {
      native,
      session,
      async close() {
        if (!closing) {
          closing = session.close().finally(() => native.close());
        }
        await closing;
      },
    };
  } catch (error) {
    native.close();
    throw error;
  }
}

function installSessionSignalHandlers(runtime, onSignal) {
  let handling = false;
  const exitCodes = new Map([["SIGHUP", 129], ["SIGINT", 130], ["SIGTERM", 143]]);
  const handlers = new Map();
  for (const [signal, exitCode] of exitCodes) {
    const handler = () => {
      if (handling) return;
      handling = true;
      onSignal?.();
      void runtime.close().finally(() => process.exit(exitCode));
    };
    handlers.set(signal, handler);
    process.once(signal, handler);
  }
  return () => {
    for (const [signal, handler] of handlers) process.off(signal, handler);
  };
}

function printEvaluation(result, { json, output }) {
  if (json) {
    writeLine(output, JSON.stringify(result));
    return;
  }
  for (const item of result.content ?? []) {
    if (item.type === "text") writeLine(output, item.text);
    else if (item.type === "image") writeLine(output, `[image ${item.mimeType ?? "application/octet-stream"}, ${Buffer.byteLength(item.data ?? "", "base64")} bytes]`);
  }
}

async function runJavaScript({ options, paths, env, input, output }) {
  let source;
  if (options.filePath) source = readFileSync(options.filePath, "utf8");
  else if (options.sourceParts.length === 1 && options.sourceParts[0] === "-") source = await readStream(input);
  else source = options.sourceParts.join(" ");
  if (!source.trim()) throw new Error("'ocu js' expects JavaScript source, '-' for stdin, or --file <path>");

  const runtime = await openSession({ paths, env });
  const removeSignalHandlers = installSessionSignalHandlers(runtime);
  try {
    const result = await runtime.session.run(source, options.timeoutMs);
    printEvaluation(result, { json: options.json, output });
    return result.isError ? 1 : 0;
  } finally {
    removeSignalHandlers();
    await runtime.close();
  }
}

async function runInteractiveRepl({ options, paths, env, input, output, errorOutput }) {
  const runtime = await openSession({ paths, env });
  const terminal = Boolean(input.isTTY && output.isTTY);
  const lines = readline.createInterface({ input, output: terminal ? output : undefined, terminal, prompt: "ocu> " });
  const removeSignalHandlers = installSessionSignalHandlers(runtime, () => lines.close());
  let editorLines;
  if (terminal) {
    writeLine(output, "Open Computer Use JavaScript REPL. Use nodeRepl.write(value) for output; type .help for commands.");
    lines.prompt();
  }
  try {
    for await (const line of lines) {
      const source = line.trim();
      if (editorLines) {
        if (source === ".end") {
          const block = editorLines.join("\n");
          editorLines = undefined;
          if (block.trim()) {
            const result = await runtime.session.run(block, options.timeoutMs);
            printEvaluation(result, { json: options.json, output });
          }
          if (terminal) {
            lines.setPrompt("ocu> ");
            lines.prompt();
          }
        } else {
          editorLines.push(line);
          if (terminal) lines.prompt();
        }
        continue;
      }
      if (!source) {
        if (terminal) lines.prompt();
        continue;
      }
      if (source === ".exit") break;
      if (source === ".help") writeLine(output, replHelp());
      else if (source === ".editor") {
        editorLines = [];
        if (terminal) {
          writeLine(output, "Enter JavaScript. Finish with .end on its own line.");
          lines.setPrompt("... ");
        }
      } else if (source === ".reset") {
        await runtime.session.reset();
        printEvaluation({ content: [{ type: "text", text: "Open Computer Use JavaScript session reset" }], isError: false }, { json: options.json, output });
      } else {
        const result = await runtime.session.run(line, options.timeoutMs);
        printEvaluation(result, { json: options.json, output });
      }
      if (terminal) lines.prompt();
    }
    return 0;
  } catch (error) {
    writeLine(errorOutput, `open-computer-use repl: ${asError(error).message}`);
    return 1;
  } finally {
    removeSignalHandlers();
    lines.close();
    await runtime.close();
  }
}

function runChild(executable, executableArgs, { env, spawnFn = spawn }) {
  return new Promise((resolve, reject) => {
    const child = spawnFn(executable, executableArgs, { stdio: "inherit", windowsHide: false, env });
    const forward = signal => child.kill(signal);
    const signalHandlers = new Map();
    for (const signal of ["SIGINT", "SIGTERM"]) {
      const handler = () => forward(signal);
      signalHandlers.set(signal, handler);
      process.on(signal, handler);
    }
    const cleanup = () => {
      for (const [signal, handler] of signalHandlers) process.off(signal, handler);
    };
    child.on("error", error => { cleanup(); reject(error); });
    child.on("exit", (code, signal) => { cleanup(); resolve(signal ? 1 : (code ?? 0)); });
  });
}

function resolveNativeExecutable(report) {
  const native = report.runtime.native;
  if (!native.supported) throw new Error(`Unsupported platform ${native.platform}.`);
  if (!native.available) throw new Error(`Missing or non-executable bundled native runtime at ${native.path}.\n\nReinstall with:\n  npm install -g open-computer-use`);
  return native.path;
}

function installerUsage(command) {
  const usages = {
    "install-dsh-mcp": "open-computer-use install-dsh-mcp [--profile <name>] [--command <path>] [--no-hook] [--no-skill]",
    "install-codex-plugin": "open-computer-use install-codex-plugin",
    "install-codex-mcp": "open-computer-use install-codex-mcp",
    "install-gemini-mcp": "open-computer-use install-gemini-mcp [--scope project|user]",
    "install-opencode-mcp": "open-computer-use install-opencode-mcp",
    "install-claude-mcp": "open-computer-use install-claude-mcp",
    "install-clauce-mcp": "open-computer-use install-claude-mcp",
  };
  return usages[command];
}

export async function main({
  packageRoot,
  platformPackages,
  argv = process.argv.slice(2),
  input = process.stdin,
  output = process.stdout,
  errorOutput = process.stderr,
  env = process.env,
  platform = process.platform,
  arch = process.arch,
  execPath = process.execPath,
  nodeVersion = process.version,
  spawnFn = spawn,
} = {}) {
  const command = argv[0] ?? "";
  const report = inspectCapabilities({ packageRoot, platformPackages, platform, arch, execPath, nodeVersion });
  const paths = runtimePaths({ packageRoot, platformPackages, platform, arch });
  try {
    if (command === "-h" || command === "--help" || (command === "help" && argv.length <= 1)) {
      writeLine(output, launcherHelp(report));
      return 0;
    }
    if (command === "help" && argv[1] === "js") {
      writeLine(output, jsHelp());
      return 0;
    }
    if (command === "help" && argv[1] === "repl") {
      writeLine(output, replHelp());
      return 0;
    }
    if (command === "help" && argv[1] === "capabilities") {
      writeLine(output, capabilitiesHelp());
      return 0;
    }
    if (command === "help" && installCommands.has(argv[1])) {
      writeLine(output, installHelp(installCommands.get(argv[1]), installerUsage(argv[1])));
      return 0;
    }
    if (command === "config") {
      writeLine(output, configCommand(argv.slice(1), env));
      return 0;
    }
    if (command === "help" && argv[1] === "config") {
      writeLine(output, configHelp);
      return 0;
    }
    if (command === "capabilities") {
      const extra = argv.slice(1);
      if (extra.includes("-h") || extra.includes("--help")) writeLine(output, capabilitiesHelp());
      else if (extra.length === 0) writeLine(output, renderCapabilityReport(report));
      else if (extra.length === 1 && extra[0] === "--json") writeLine(output, JSON.stringify(report, null, 2));
      else throw new Error(`Unknown capabilities option: ${extra.join(" ")}`);
      return 0;
    }
    if (command === "js") {
      const options = parseJavaScriptArgs(argv.slice(1));
      if (options.help) {
        writeLine(output, jsHelp());
        return 0;
      }
      assertCodeCapability(report);
      return await runJavaScript({ options, paths, env, input, output });
    }
    if (command === "repl") {
      const options = parseJavaScriptArgs(argv.slice(1), { replMode: true });
      if (options.help) {
        writeLine(output, replHelp());
        return 0;
      }
      assertCodeCapability(report);
      return await runInteractiveRepl({ options, paths, env, input, output, errorOutput });
    }
    if (installCommands.has(command)) {
      if (platform === "win32") throw new Error(`${command} currently requires a POSIX shell. Configure your MCP client with command "open-computer-use" and args ["mcp"] on Windows.`);
      const scriptPath = path.join(packageRoot, "scripts", installCommands.get(command));
      if (!existsSync(scriptPath)) throw new Error(`Missing installer helper at ${scriptPath}.`);
      return await runChild(scriptPath, argv.slice(1), { env, spawnFn });
    }
    return await runChild(resolveNativeExecutable(report), argv, { env, spawnFn });
  } catch (error) {
    writeLine(errorOutput, `open-computer-use: ${asError(error).message}`);
    return 1;
  }
}
