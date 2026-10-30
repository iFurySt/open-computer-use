import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, statSync, cpSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { configCommand, configPath, inspectConfig } from "./ocu-config.mjs";
import { main } from "./open-computer-use-cli.mjs";
function fixture(t) {
  const directory = mkdtempSync(path.join(tmpdir(), "ocu-config-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return { HOME: directory, OPEN_COMPUTER_USE_CONFIG_FILE: path.join(directory, "config.json") };
}
test("config paths and read-only defaults", t => {
  const env = fixture(t);
  assert.equal(configPath({ HOME: "/users/test" }), "/users/test/.config/ocu/config.json");
  assert.equal(configPath({ XDG_CONFIG_HOME: "/settings" }), "/settings/ocu/config.json");
  assert.throws(() => configPath({ XDG_CONFIG_HOME: "relative" }), /absolute/);
  assert.equal(inspectConfig(env).values["image.format"], "png");
  assert.throws(() => statSync(env.OPEN_COMPUTER_USE_CONFIG_FILE), /ENOENT/);
});
test("persistent settings, environment precedence and reset", t => {
  const env = fixture(t);
  configCommand(["set", "image.format", "jpg"], env);
  configCommand(["set", "image.maxLongEdgePixels", "640"], env);
  assert.equal(inspectConfig(env).values["image.format"], "jpg");
  const report = inspectConfig({ ...env, OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION: "800" });
  assert.equal(report.values["image.maxLongEdgePixels"], 800);
  assert.equal(report.sources["image.maxLongEdgePixels"], "env");
  assert.equal(inspectConfig({ ...env, OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION: "NaN" }).values["image.maxLongEdgePixels"], 640);
  configCommand(["reset", "image.format"], env);
  assert.equal(inspectConfig(env).values["image.format"], "png");
  assert.equal(statSync(env.OPEN_COMPUTER_USE_CONFIG_FILE).mode & 0o777, 0o600);
});
test("invalid settings and malformed files never overwrite existing content", t => {
  const env = fixture(t);
  configCommand(["set", "image.format", "jpg"], env);
  const before = readFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, "utf8");
  for (const [key, value] of [["image.maxLongEdgePixels", "0"], ["image.maxBytes", "Infinity"], ["image.byteBudgetMinScale", "1.2"], ["image.format", "gif"], ["safety.global", "1"]]) {
    assert.throws(() => configCommand(["set", key, value], env));
  }
  assert.equal(readFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, "utf8"), before);
  writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, "broken");
  assert.throws(() => configCommand(["set", "image.format", "png"], env), /Cannot read config/);
  assert.equal(readFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, "utf8"), "broken");
});
test("unknown config fields are preserved on writes", t => {
  const env = fixture(t);
  writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({ future: { enabled: true }, image: { future: "keep" } }));
  configCommand(["set", "image.format", "jpg"], env);
  const saved = JSON.parse(readFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE));
  assert.equal(saved.future.enabled, true);
  assert.equal(saved.image.future, "keep");
});
test("launcher config works without native artifacts or spawning", async t => {
  const env = fixture(t), output = [];
  const exit = await main({ packageRoot: env.HOME, platformPackages: {}, env, argv: ["config", "list", "--json"], output: { write: s => output.push(s) }, spawnFn: () => { throw new Error("unexpected spawn"); } });
  assert.equal(exit, 0);
  assert.equal(JSON.parse(output.join("")).values["image.format"], "png");
});

test("staged npm launcher includes config module and persists without a native launch", t => {
  const env = fixture(t);
  const root = path.join(env.HOME, "repo");
  const source = fileURLToPath(new URL("../../", import.meta.url));
  mkdirSync(root);
  for (const entry of ["scripts", "skills", "plugins", ".agents", "LICENSE", "THIRD_PARTY_NOTICES.md"]) cpSync(path.join(source, entry), path.join(root, entry), { recursive: true });
  // Debug packaging fixtures only: config must never execute these native
  // artifacts. Release packaging separately validates real signed binaries.
  for (const relative of ["Open Computer Use.app/Contents/MacOS/OpenComputerUse", "linux/arm64/open-computer-use", "linux/amd64/open-computer-use", "windows/arm64/open-computer-use.exe", "windows/amd64/open-computer-use.exe"]) {
    const file = path.join(root, "dist", relative);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, "fixture", { mode: 0o755 });
  }
  const build = spawnSync(process.execPath, [path.join(root, "scripts/npm/build-packages.mjs"), "--configuration", "debug", "--skip-build"], { encoding: "utf8" });
  assert.equal(build.status, 0, build.stderr);
  const pluginAdapter = path.join(root, "dist/npm/open-computer-use/plugins/open-computer-use/scripts/open-computer-use-repl.mjs");
  const imported = spawnSync(process.execPath, ["--input-type=module", "-e", "await import(process.argv[1])", pluginAdapter], { encoding: "utf8" });
  assert.equal(imported.status, 0, imported.stderr);
  const launcher = path.join(root, "dist/npm/open-computer-use/bin/open-computer-use");
  const run = spawnSync(process.execPath, [launcher, "config", "set", "image.format", "jpg"], { env: { ...process.env, ...env }, encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(inspectConfig(env).values["image.format"], "jpg");
});

test("explicit resize/drop settings, pixel-count threshold and nullable limits", t => {
  const env = fixture(t);
  configCommand(["set", "image.scaleDownAfterMaxSize", "false"], env);
  configCommand(["set", "image.discardBelowPixelCount", "4096"], env);
  configCommand(["set", "image.maxLongEdgePixels", "null"], env);
  configCommand(["set", "image.format", "webp"], env);
  const values = inspectConfig(env).values;
  assert.equal(values["image.scaleDownAfterMaxSize"], false);
  assert.equal(values["image.discardBelowPixelCount"], 4096);
  assert.equal(values["image.maxLongEdgePixels"], null);
  assert.equal(values["image.format"], "webp");
  assert.throws(() => configCommand(["set", "image.scaleDownAfterMaxSize", "yes"], env), /true or false/);
  assert.throws(() => configCommand(["set", "image.discardBelowPixelCount", "-1"], env));
});

test("removed byte budgets are rejected and stale values are ignored", t => {
  const env = fixture(t);
  writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({ image: { maxLongEdgePixels: 640, maxBytes: 1, byteBudgetMinScale: 0.01, minScale: 0.01 } }));
  const report = inspectConfig({ ...env, OPEN_COMPUTER_USE_IMAGE_MAX_BYTES: "1", OPEN_COMPUTER_USE_IMAGE_MIN_SCALE: "0.01" });
  assert.equal(report.values["image.maxLongEdgePixels"], 640);
  for (const key of ["image.maxBytes", "image.byteBudgetMinScale"]) {
    assert.equal(key in report.values, false);
    assert.throws(() => configCommand(["set", key, "1"], env), /Unknown setting/);
  }
});


test("virtual displays default off and persist independently of screenshot settings", t => {
  const env = fixture(t);
  assert.equal(configCommand(["get", "virtualDisplay.enabled"], env), "false");
  configCommand(["set", "image.format", "jpg"], env);
  configCommand(["set", "virtualDisplay.enabled", "true"], env);
  assert.equal(inspectConfig(env).values["virtualDisplay.enabled"], true);
  assert.equal(inspectConfig({ ...env, OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED: "false" }).values["virtualDisplay.enabled"], false);
  assert.equal(inspectConfig({ ...env, OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED: "1" }).values["virtualDisplay.enabled"], false);
  assert.throws(() => configCommand(["set", "virtualDisplay.enabled", "1"], env), /true or false/);
  configCommand(["reset", "virtualDisplay.enabled"], env);
  assert.equal(inspectConfig(env).values["virtualDisplay.enabled"], false);
  assert.equal(inspectConfig(env).values["image.format"], "jpg");
  assert.equal(JSON.parse(readFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE)).virtualDisplay.enabled, undefined);
  configCommand(["set", "virtualDisplay.enabled", "true"], env);
  configCommand(["reset", "image.format"], env);
  assert.equal(inspectConfig(env).values["virtualDisplay.enabled"], true);
});

test("invalid persisted virtual display values do not enable the feature", t => {
  const env = fixture(t);
  for (const enabled of [1, "true", null, [], {}]) {
    writeFileSync(env.OPEN_COMPUTER_USE_CONFIG_FILE, JSON.stringify({ virtualDisplay: { enabled } }));
    assert.equal(inspectConfig(env).values["virtualDisplay.enabled"], false);
  }
});
