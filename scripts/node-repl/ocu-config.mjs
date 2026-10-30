import { existsSync, readFileSync, mkdirSync, writeFileSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

export const settings = {
  "virtualDisplay.enabled": { default: false, env: "OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED", boolean: true },
  "image.format": { default: "png", env: "OPEN_COMPUTER_USE_IMAGE_FORMAT", choices: ["png", "jpg", "webp"] },
  "image.jpegQuality": { default: 0.8, env: "OPEN_COMPUTER_USE_IMAGE_JPEG_QUALITY", min: 0, max: 1 },
  "image.maxLongEdgePixels": { default: 1280, env: "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION", min: 1, max: 16384, integer: true, nullable: true },
  "image.scaleDownAfterMaxSize": { default: true, env: "OPEN_COMPUTER_USE_IMAGE_SCALE_DOWN_AFTER_MAX_SIZE", boolean: true },
  "image.discardBelowPixelCount": { default: 64, env: "OPEN_COMPUTER_USE_IMAGE_DISCARD_BELOW_PIXEL_COUNT", min: 0, max: 268435456, integer: true },
  "image.captureTimeout": { default: 5, env: "OPEN_COMPUTER_USE_IMAGE_CAPTURE_TIMEOUT", min: 0.01, max: 300 },
};

export function configPath(env = process.env) {
  if (env.OPEN_COMPUTER_USE_CONFIG_FILE) {
    if (!path.isAbsolute(env.OPEN_COMPUTER_USE_CONFIG_FILE)) throw new Error("OPEN_COMPUTER_USE_CONFIG_FILE must be absolute");
    return env.OPEN_COMPUTER_USE_CONFIG_FILE;
  }
  const base = env.XDG_CONFIG_HOME || path.join(env.HOME || homedir(), ".config");
  if (!path.isAbsolute(base)) throw new Error("XDG_CONFIG_HOME must be absolute");
  return path.join(base, "ocu", "config.json");
}

export function validateSetting(key, raw, { fromText = false } = {}) {
  const spec = settings[key];
  if (!spec) throw new Error(`Unknown setting: ${key}`);
  if (spec.nullable && (raw === null || (fromText && raw === "null"))) return null;
  if (spec.boolean) {
    if (typeof raw === "boolean") return raw;
    if (fromText && ["true", "false"].includes(raw)) return raw === "true";
    throw new Error(`${key} must be true or false`);
  }
  if (key === "image.format" && raw === "jpeg") raw = "jpg";
  const value = fromText && !spec.choices ? (String(raw).trim() ? Number(raw) : NaN) : raw;
  if (spec.choices) {
    if (!spec.choices.includes(value)) throw new Error(`${key} must be ${spec.choices.join(" or ")}`);
  } else if (typeof value !== "number" || !Number.isFinite(value) || value < spec.min || value > spec.max || (spec.integer && !Number.isSafeInteger(value))) {
    throw new Error(`${key} must be ${spec.integer ? "an integer" : "a number"} between ${spec.min} and ${spec.max}`);
  }
  return value;
}

export function readConfig(file) {
  if (!existsSync(file)) return {};
  let value;
  try { value = JSON.parse(readFileSync(file, "utf8")); }
  catch (error) { throw new Error(`Cannot read config ${file}: ${error.message}`); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Config must be a JSON object");
  for (const section of ["image", "virtualDisplay"]) {
    if (value[section] !== undefined && (!value[section] || typeof value[section] !== "object" || Array.isArray(value[section]))) throw new Error(`Config ${section} must be an object`);
  }
  return value;
}

export function inspectConfig(env = process.env) {
  const file = configPath(env);
  const persisted = readConfig(file);
  const values = {}, sources = {}, warnings = [];
  for (const [key, spec] of Object.entries(settings)) {
    const [section, name] = key.split(".");
    const legacyName = { maxLongEdgePixels: "maxDimension" }[name];
    if (section === "image" && persisted.image?.[name] === undefined && legacyName && persisted.image?.[legacyName] !== undefined) persisted.image[name] = persisted.image[legacyName];
    let value = spec.default, source = "default";
    if (persisted[section]?.[name] !== undefined) {
      try { value = validateSetting(key, persisted[section][name]); source = "file"; }
      catch (error) { warnings.push(error.message); }
    }
    if (env[spec.env] !== undefined) {
      try { value = validateSetting(key, env[spec.env], { fromText: true }); source = "env"; }
      catch (error) {
        if (key === "virtualDisplay.enabled") { value = false; source = "default"; }
        warnings.push(`${spec.env}: ${error.message}`);
      }
    }
    values[key] = value; sources[key] = source;
  }
  return { path: file, values, sources, warnings };
}

function save(file, config) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, JSON.stringify(config, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temporary, file);
  } finally { rmSync(temporary, { force: true }); }
}

export function configCommand(argv, env = process.env) {
  if (argv.length === 1 && ["--help", "-h"].includes(argv[0])) return configHelp;
  const action = argv[0] || "list";
  if (action === "path" && argv.length === 1) return configPath(env);
  if (action === "list" && (argv.length <= 1 || (argv.length === 2 && argv[1] === "--json"))) {
    const report = inspectConfig(env);
    if (argv[1] === "--json") return JSON.stringify(report, null, 2);
    return [`Config: ${report.path}`, "Screenshot and virtual display settings apply to macOS.", ...Object.entries(report.values).map(([key, value]) => `${key} = ${value} (${report.sources[key]})`), ...report.warnings.map(w => `Warning: ${w}`)].join("\n");
  }
  if (action === "get" && argv.length === 2) {
    validateKey(argv[1]); return String(inspectConfig(env).values[argv[1]]);
  }
  if (action === "set" && argv.length === 3) {
    const [key, raw] = argv.slice(1), value = validateSetting(key, raw, { fromText: true });
    const file = configPath(env), config = readConfig(file);
    const [section, name] = key.split(".");
    config[section] ??= {}; config[section][name] = value;
    save(file, config);
    return `${key} = ${value} saved to ${file}${env[settings[key].env] !== undefined ? `\nWarning: ${settings[key].env} overrides this saved setting.` : ""}`;
  }
  if (action === "reset" && argv.length === 2) {
    const key = argv[1]; validateKey(key);
    const file = configPath(env), config = readConfig(file);
    const [section, name] = key.split(".");
    if (config[section]) {
      delete config[section][name];
      const legacy = section === "image" && { maxLongEdgePixels: "maxDimension" }[name];
      if (legacy) delete config[section][legacy];
    }
    if (existsSync(file)) save(file, config);
    return `${key} reset (environment overrides still apply)`;
  }
  throw new Error("Usage: ocu config [list [--json] | path | get KEY | set KEY VALUE | reset KEY]");
}
function validateKey(key) { if (!settings[key]) throw new Error(`Unknown setting: ${key}`); }
export const configHelp = `Usage: ocu config [list [--json] | path | get KEY | set KEY VALUE | reset KEY]
Settings (macOS): ${Object.keys(settings).join(", ")}
image.maxLongEdgePixels: maximum long edge in pixels (null disables).
image.scaleDownAfterMaxSize: true resizes oversized images; false omits them.
image.discardBelowPixelCount: omit when width * height is below this total pixel count (0 disables).
Formats: png (default), jpg, webp (lossless); jpeg is a jpg alias.
Precedence: environment > config file > defaults. Changes apply on the next capture or tools/list; reconnect MCP clients to refresh cached schemas.
virtualDisplay.enabled: false by default; true exposes window_placement and permits virtual display creation.
Examples:
  ocu config set virtualDisplay.enabled true
  ocu config set image.format jpg
  ocu config set image.maxLongEdgePixels 1024
  ocu config reset image.format`;
