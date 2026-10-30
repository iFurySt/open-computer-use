#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const defaultOutDir = path.join(repoRoot, "dist", "npm");
const appBundleName = "Open Computer Use.app";
const appExecutableName = "OpenComputerUse";
const metaPackageNames = [
  "open-computer-use",
  "open-computer-use-mcp",
  "open-codex-computer-use-mcp",
];
const runtimeTargets = [
  {
    os: "darwin",
    cpu: "arm64",
    kind: "macos-app",
    executablePath: ["dist", appBundleName, "Contents", "MacOS", appExecutableName],
  },
  {
    os: "darwin",
    cpu: "x64",
    kind: "macos-app",
    executablePath: ["dist", appBundleName, "Contents", "MacOS", appExecutableName],
  },
  {
    os: "linux",
    cpu: "arm64",
    kind: "binary",
    buildArch: "arm64",
    executablePath: ["dist", "linux", "arm64", "open-computer-use"],
  },
  {
    os: "linux",
    cpu: "x64",
    kind: "binary",
    buildArch: "amd64",
    executablePath: ["dist", "linux", "amd64", "open-computer-use"],
  },
  {
    os: "win32",
    cpu: "arm64",
    kind: "binary",
    buildArch: "arm64",
    executablePath: ["dist", "windows", "arm64", "open-computer-use.exe"],
  },
  {
    os: "win32",
    cpu: "x64",
    kind: "binary",
    buildArch: "amd64",
    executablePath: ["dist", "windows", "amd64", "open-computer-use.exe"],
  },
];
const packageNames = [
  ...metaPackageNames,
];

function parseArgs(argv) {
  const options = {
    arch: "universal",
    configuration: "release",
    outDir: defaultOutDir,
    packageNames: [...packageNames],
    skipBuild: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--arch":
        options.arch = argv[index + 1];
        index += 1;
        break;
      case "--configuration":
        options.configuration = argv[index + 1];
        index += 1;
        break;
      case "--out-dir":
        options.outDir = path.resolve(repoRoot, argv[index + 1]);
        index += 1;
        break;
      case "--package":
        options.packageNames = [argv[index + 1]];
        index += 1;
        break;
      case "--skip-build":
        options.skipBuild = true;
        break;
      case "-h":
      case "--help":
        printHelp();
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  for (const packageName of options.packageNames) {
    if (!packageNames.includes(packageName)) {
      throw new Error(`Unsupported package name: ${packageName}`);
    }
  }

  return options;
}

function printHelp() {
  process.stdout.write(`Usage: node ./scripts/npm/build-packages.mjs [options]

Options:
  --configuration debug|release
  --arch native|arm64|x86_64|universal  macOS app build arch. Defaults to universal.
  --out-dir <dir>
  --package <package-name>
  --skip-build

Packages:
${packageNames.map((name) => `  - ${name}`).join("\n")}
`);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    stdio: "inherit",
    ...options,
  });

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with exit code ${result.status ?? "unknown"}`);
  }
}

function readJSON(filePath) {
  return JSON.parse(readFileSync(filePath, "utf-8"));
}

function removeJunkFiles(targetPath) {
  if (!existsSync(targetPath)) {
    return;
  }

  const entryStat = statSync(targetPath);
  if (entryStat.isDirectory()) {
    for (const entry of readdirSync(targetPath)) {
      removeJunkFiles(path.join(targetPath, entry));
    }
    return;
  }

  if (path.basename(targetPath) === ".DS_Store") {
    unlinkSync(targetPath);
  }
}

function ensureBuilt(configuration, arch) {
  run(path.join(repoRoot, "scripts", "build-open-computer-use-app.sh"), [
    "--configuration",
    configuration,
    "--arch",
    arch,
  ]);

  for (const buildArch of ["arm64", "amd64"]) {
    run(path.join(repoRoot, "scripts", "build-open-computer-use-linux.sh"), [
      "--configuration",
      configuration,
      "--arch",
      buildArch,
    ]);
    run(path.join(repoRoot, "scripts", "build-open-computer-use-windows.sh"), [
      "--configuration",
      configuration,
      "--arch",
      buildArch,
    ]);
  }
}

function writeExecutable(filePath, content) {
  writeFileSync(filePath, content, "utf-8");
  chmodSync(filePath, 0o755);
}

function platformLaunchTable() {
  return Object.fromEntries(
    runtimeTargets.map((runtimeTarget) => [
      `${runtimeTarget.os}-${runtimeTarget.cpu}`,
      {
        executablePath: runtimeTarget.executablePath,
      },
    ]),
  );
}

function renderLauncher() {
  return `#!/usr/bin/env node
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const platformPackages = ${JSON.stringify(platformLaunchTable(), null, 2)};
const packageRoot = path.resolve(__dirname, "..");
const cliModule = pathToFileURL(path.join(packageRoot, "scripts", "node-repl", "open-computer-use-cli.mjs")).href;

import(cliModule)
  .then(({ main }) => main({ packageRoot, platformPackages }))
  .then(code => { process.exitCode = Number.isInteger(code) ? code : 1; })
  .catch(error => {
    console.error(\`open-computer-use: \${error instanceof Error ? error.message : String(error)}\`);
    process.exitCode = 1;
  });
`;
}

function renderPostinstall(packageName, version) {
  return `#!/usr/bin/env node
const mcpConfig = ${JSON.stringify({
  mcpServers: {
    "open-computer-use": {
      command: "open-computer-use",
      args: ["mcp"],
    },
  },
}, null, 2)};
const lines = [
  "",
  "Installed ${packageName}@${version}.",
  "Package: https://www.npmjs.com/package/${packageName}",
  "Commands: open-computer-use, ocu, open-computer-use-mcp, open-codex-computer-use-mcp",
  "Native runtime will be selected from bundled artifacts for " + process.platform + "-" + process.arch + ".",
  "",
  "Next:",
  "1. Run open-computer-use --version or ocu capabilities",
  "2. Add the MCP config below to your host client, or use ocu js / ocu repl directly",
  "3. On macOS, run open-computer-use doctor and grant Accessibility / Screen Recording if prompted",
  "",
  "MCP config:",
  JSON.stringify(mcpConfig, null, 2),
  "",
];
for (const line of lines) {
  console.log(line);
}
`;
}

function renderReadme(packageName, version) {
  return `# ${packageName}

Cross-platform npm distribution for the open-source **Open Computer Use** MCP server.

This package bundles native runtimes for these supported platforms and lets the Node launcher choose the current \`process.platform\` / \`process.arch\` pair:

${runtimeTargets.map((runtimeTarget) => `- \`${runtimeTarget.os}-${runtimeTarget.cpu}\``).join("\n")}

Global command aliases:

- \`open-computer-use\`
- \`ocu\`
- \`open-computer-use-mcp\`
- \`open-codex-computer-use-mcp\`

## Install

\`\`\`bash
npm install -g ${packageName}
\`\`\`

The root launcher resolves the current \`process.platform\` / \`process.arch\` pair and runs the matching bundled native runtime.

## MCP config

If your MCP client accepts a stdio-style \`mcpServers\` JSON config, this is the default setup:

\`\`\`json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "open-computer-use",
      "args": ["mcp"]
    }
  }
}
\`\`\`

Package page: https://www.npmjs.com/package/${packageName}

## Use

\`\`\`bash
open-computer-use --version
ocu --version
open-computer-use --help
open-computer-use mcp
ocu mcp
ocu capabilities
ocu capabilities --json
ocu js 'nodeRepl.write(6 * 7)'
printf 'var answer = 40\nanswer += 2; nodeRepl.write(answer)\n.exit\n' | ocu repl
open-computer-use call list_apps

# macOS permission check and onboarding
open-computer-use doctor

# Installer helpers for MCP-capable CLIs
open-computer-use install-claude-mcp
open-computer-use install-gemini-mcp
open-computer-use install-gemini-mcp --scope user
open-computer-use install-codex-mcp
open-computer-use install-opencode-mcp
open-computer-use install-codex-plugin
\`\`\`

## Notes

- Version: \`${version}\`
- Supported npm platforms: \`darwin-arm64\`, \`darwin-x64\`, \`linux-arm64\`, \`linux-x64\`, \`win32-arm64\`, \`win32-x64\`
- \`ocu js\` creates a one-shot JavaScript/native session; \`ocu repl\` keeps one session for the current terminal and preserves bindings between evaluations.
- Both code-first commands use the Node executable that started the npm launcher. The npm launcher itself still requires Node.js 18 or newer to be available when the command starts.
- \`ocu mcp\` intentionally continues to expose the native 9-tool compatibility surface; the Codex plugin adapter exposes \`js\` / \`js_reset\` separately.
- macOS still requires \`Accessibility\` and \`Screen Recording\` permissions.
- Linux requires a signed-in desktop session with AT-SPI2 / D-Bus accessibility available for real app control.
- Windows requires a signed-in desktop session for UI Automation access.

Source repository: https://github.com/iFurySt/open-computer-use
`;
}

function packageKeywords(extraKeywords = []) {
  return [
    "computer-use",
    "codex",
    "mcp",
    "macos",
    "linux",
    "windows",
    "automation",
    ...extraKeywords,
  ];
}

function renderMetaPackageJson(packageName, version) {
  return {
    name: packageName,
    version,
    description: "Cross-platform Computer Use MCP server launcher. After install, configure open-computer-use mcp.",
    license: "MIT",
    homepage: "https://github.com/iFurySt/open-computer-use",
    repository: {
      type: "git",
      url: "git+https://github.com/iFurySt/open-computer-use.git",
    },
    bugs: {
      url: "https://github.com/iFurySt/open-computer-use/issues",
    },
    keywords: packageKeywords(),
    engines: {
      node: ">=18",
    },
    preferGlobal: true,
    publishConfig: {
      access: "public",
    },
    bin: {
      "open-computer-use": "bin/open-computer-use",
      "ocu": "bin/ocu",
      "open-computer-use-mcp": "bin/open-computer-use-mcp",
      "open-codex-computer-use-mcp": "bin/open-codex-computer-use-mcp",
    },
    scripts: {
      postinstall: "node ./scripts/postinstall.mjs",
    },
    files: [
      ".agents/plugins/marketplace.json",
      "bin/",
      "dist/Open Computer Use.app/",
      "dist/linux/",
      "dist/windows/",
      "plugins/open-computer-use/.codex-plugin/",
      "plugins/open-computer-use/.mcp.json",
      "plugins/open-computer-use/assets/",
      "plugins/open-computer-use/scripts/",
      "scripts/install-claude-mcp.sh",
      "scripts/install-gemini-mcp.sh",
      "scripts/install-config-helper.mjs",
      "scripts/install-codex-mcp.sh",
      "scripts/install-opencode-mcp.sh",
      "scripts/install-dsh-mcp.sh",
      "scripts/install-codex-plugin.sh",
      "scripts/node-repl/",
      "scripts/postinstall.mjs",
      "skills/open-computer-use/",
      "README.md",
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
    ],
  };
}

function copyInstallerScripts(packageRoot) {
  cpSync(path.join(repoRoot, "scripts", "install-claude-mcp.sh"), path.join(packageRoot, "scripts", "install-claude-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-gemini-mcp.sh"), path.join(packageRoot, "scripts", "install-gemini-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-config-helper.mjs"), path.join(packageRoot, "scripts", "install-config-helper.mjs"));
  cpSync(path.join(repoRoot, "scripts", "install-codex-mcp.sh"), path.join(packageRoot, "scripts", "install-codex-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-opencode-mcp.sh"), path.join(packageRoot, "scripts", "install-opencode-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-dsh-mcp.sh"), path.join(packageRoot, "scripts", "install-dsh-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-codex-plugin.sh"), path.join(packageRoot, "scripts", "install-codex-plugin.sh"));
  cpSync(path.join(repoRoot, "skills", "open-computer-use"), path.join(packageRoot, "skills", "open-computer-use"), { recursive: true });
  mkdirSync(path.join(packageRoot, "scripts", "node-repl"), { recursive: true });
  for (const scriptName of [
    "open-computer-use-cli.mjs",
    "ocu-config.mjs",
    "open-computer-use-repl.mjs",
    "open-computer-use-kernel.mjs",
  ]) {
    cpSync(
      path.join(repoRoot, "scripts", "node-repl", scriptName),
      path.join(packageRoot, "scripts", "node-repl", scriptName),
    );
  }
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "ocu-config.mjs"),
    path.join(packageRoot, "plugins", "open-computer-use", "scripts", "ocu-config.mjs")
  );
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "open-computer-use-repl.mjs"),
    path.join(packageRoot, "plugins", "open-computer-use", "scripts", "open-computer-use-repl.mjs")
  );
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "open-computer-use-kernel.mjs"),
    path.join(packageRoot, "plugins", "open-computer-use", "scripts", "open-computer-use-kernel.mjs")
  );

  for (const scriptName of [
    "install-claude-mcp.sh",
    "install-gemini-mcp.sh",
    "install-codex-mcp.sh",
    "install-opencode-mcp.sh",
    "install-dsh-mcp.sh",
    "install-codex-plugin.sh",
  ]) {
    chmodSync(path.join(packageRoot, "scripts", scriptName), 0o755);
  }
}

function assertFileExists(filePath, packageName) {
  if (!existsSync(filePath)) {
    throw new Error(`Missing artifact for ${packageName}: ${filePath}. Run without --skip-build first.`);
  }
}

function copyBundledRuntimes(packageRoot, packageName) {
  const distRoot = path.join(packageRoot, "dist");
  mkdirSync(distRoot, { recursive: true });

  const macosSourcePath = path.join(repoRoot, "dist", appBundleName);
  const macosDestinationPath = path.join(distRoot, appBundleName);
  assertFileExists(macosSourcePath, packageName);
  cpSync(macosSourcePath, macosDestinationPath, { recursive: true });

  for (const platformDir of ["linux", "windows"]) {
    const sourcePath = path.join(repoRoot, "dist", platformDir);
    const destinationPath = path.join(distRoot, platformDir);
    assertFileExists(sourcePath, packageName);
    cpSync(sourcePath, destinationPath, { recursive: true });
  }

  for (const runtimeTarget of runtimeTargets) {
    const executablePath = path.join(packageRoot, ...runtimeTarget.executablePath);
    assertFileExists(executablePath, packageName);
    if (runtimeTarget.kind !== "macos-app") {
      chmodSync(executablePath, 0o755);
    }
  }
}

function stageMetaPackage(packageName, version, outDir) {
  const packageRoot = path.join(outDir, packageName);
  rmSync(packageRoot, { recursive: true, force: true });

  mkdirSync(path.join(packageRoot, ".agents", "plugins"), { recursive: true });
  mkdirSync(path.join(packageRoot, "bin"), { recursive: true });
  mkdirSync(path.join(packageRoot, "dist"), { recursive: true });
  mkdirSync(path.join(packageRoot, "plugins"), { recursive: true });
  mkdirSync(path.join(packageRoot, "scripts"), { recursive: true });

  cpSync(path.join(repoRoot, ".agents", "plugins", "marketplace.json"), path.join(packageRoot, ".agents", "plugins", "marketplace.json"));
  cpSync(path.join(repoRoot, "plugins", "open-computer-use"), path.join(packageRoot, "plugins", "open-computer-use"), {
    recursive: true,
  });
  cpSync(path.join(repoRoot, "LICENSE"), path.join(packageRoot, "LICENSE"));
  cpSync(path.join(repoRoot, "THIRD_PARTY_NOTICES.md"), path.join(packageRoot, "THIRD_PARTY_NOTICES.md"));
  copyBundledRuntimes(packageRoot, packageName);
  copyInstallerScripts(packageRoot);

  const launcher = renderLauncher();
  writeExecutable(path.join(packageRoot, "bin", "open-computer-use"), launcher);
  writeExecutable(path.join(packageRoot, "bin", "ocu"), launcher);
  writeExecutable(path.join(packageRoot, "bin", "open-computer-use-mcp"), launcher);
  writeExecutable(path.join(packageRoot, "bin", "open-codex-computer-use-mcp"), launcher);
  writeFileSync(path.join(packageRoot, "scripts", "postinstall.mjs"), renderPostinstall(packageName, version), "utf-8");
  writeFileSync(path.join(packageRoot, "README.md"), renderReadme(packageName, version), "utf-8");
  writeFileSync(path.join(packageRoot, "package.json"), `${JSON.stringify(renderMetaPackageJson(packageName, version), null, 2)}\n`, "utf-8");

  removeJunkFiles(packageRoot);
}

function stagePackage(packageName, version, outDir) {
  if (!metaPackageNames.includes(packageName)) {
    throw new Error(`Unsupported package name: ${packageName}`);
  }

  stageMetaPackage(packageName, version, outDir);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const pluginManifestPath = path.join(repoRoot, "plugins", "open-computer-use", ".codex-plugin", "plugin.json");
  const { version } = readJSON(pluginManifestPath);

  if (!options.skipBuild) {
    ensureBuilt(options.configuration, options.arch);
  }

  if (options.configuration === "release") {
    run(path.join(repoRoot, "scripts", "verify-locked-use-bundle.sh"), [path.join(repoRoot, "dist", appBundleName)]);
  }

  rmSync(options.outDir, { recursive: true, force: true });
  mkdirSync(options.outDir, { recursive: true });

  for (const packageName of options.packageNames) {
    stagePackage(packageName, version, options.outDir);
  }

  process.stdout.write(`${options.outDir}\n`);
}

main();
