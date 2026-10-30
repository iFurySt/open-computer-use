#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_helper="${repo_root}/scripts/install-config-helper.mjs"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
config_path="${codex_home}/config.toml"
marketplace_name="open-computer-use-local"
plugin_name="open-computer-use"
plugin_source_root="${repo_root}/plugins/${plugin_name}"
plugin_manifest="${plugin_source_root}/.codex-plugin/plugin.json"
repl_source_root="${repo_root}/scripts/node-repl"
macos_build_script="${repo_root}/scripts/build-open-computer-use-app.sh"
linux_build_script="${repo_root}/scripts/build-open-computer-use-linux.sh"
windows_build_script="${repo_root}/scripts/build-open-computer-use-windows.sh"
configuration="debug"
rebuild="false"

node_arch() {
  node -p "process.arch" 2>/dev/null || true
}

go_arch_for_node_arch() {
  case "$1" in
    arm64) printf '%s\n' "arm64" ;;
    x64) printf '%s\n' "amd64" ;;
    *) return 1 ;;
  esac
}

resolve_app_bundle() {
  local -a candidates

  if [[ "${configuration}" == "release" ]]; then
    candidates=("Open Computer Use.app")
  else
    candidates=("Open Computer Use (Dev).app" "Open Computer Use.app")
  fi

  for bundle_name in "${candidates[@]}"; do
    for candidate in "${repo_root}/dist/${bundle_name}"; do
      if [[ -d "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done
  done

  return 1
}

resolve_native_binary() {
  local platform="$1"
  local arch="$2"
  local go_arch
  go_arch="$(go_arch_for_node_arch "${arch}" || true)"
  local -a candidates=()

  case "${platform}" in
    linux)
      if [[ -n "${go_arch}" ]]; then
        candidates+=("${repo_root}/dist/linux/${go_arch}/open-computer-use")
      fi
      ;;
    win32)
      if [[ -n "${go_arch}" ]]; then
        candidates+=("${repo_root}/dist/windows/${go_arch}/open-computer-use.exe")
      fi
      ;;
  esac

  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      rebuild="true"
      shift
      ;;
    --configuration)
      configuration="${2:-}"
      if [[ -z "${configuration}" ]]; then
        echo "--configuration requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--rebuild] [--configuration debug|release]" >&2
      exit 1
      ;;
  esac
done

platform="$(node -p "process.platform")"
arch="$(node_arch)"
payload_path=""

case "${platform}" in
  darwin)
    payload_path="$(resolve_app_bundle || true)"
    app_binary="${payload_path:+${payload_path}/Contents/MacOS/OpenComputerUse}"
    if [[ "${rebuild}" == "true" || -z "${app_binary}" || ! -x "${app_binary}" ]]; then
      if [[ -x "${macos_build_script}" ]]; then
        "${macos_build_script}" "${configuration}"
        payload_path="$(resolve_app_bundle || true)"
        app_binary="${payload_path:+${payload_path}/Contents/MacOS/OpenComputerUse}"
      else
        echo "Missing runnable app bundle at ${app_binary} and no local build script is available." >&2
        exit 1
      fi
    fi
    if [[ -z "${payload_path}" || ! -x "${app_binary}" ]]; then
      echo "Missing runnable app binary at ${app_binary}" >&2
      exit 1
    fi
    ;;
  linux)
    payload_path="$(resolve_native_binary linux "${arch}" || true)"
    if [[ "${rebuild}" == "true" || -z "${payload_path}" || ! -x "${payload_path}" ]]; then
      go_arch="$(go_arch_for_node_arch "${arch}" || true)"
      if [[ -n "${go_arch}" && -x "${linux_build_script}" ]]; then
        "${linux_build_script}" --configuration "${configuration}" --arch "${go_arch}"
        payload_path="$(resolve_native_binary linux "${arch}" || true)"
      fi
    fi
    if [[ -z "${payload_path}" || ! -x "${payload_path}" ]]; then
      echo "Missing runnable Linux binary for ${platform}-${arch}." >&2
      exit 1
    fi
    ;;
  win32)
    payload_path="$(resolve_native_binary win32 "${arch}" || true)"
    if [[ "${rebuild}" == "true" || -z "${payload_path}" || ! -x "${payload_path}" ]]; then
      go_arch="$(go_arch_for_node_arch "${arch}" || true)"
      if [[ -n "${go_arch}" && -x "${windows_build_script}" ]]; then
        "${windows_build_script}" --configuration "${configuration}" --arch "${go_arch}"
        payload_path="$(resolve_native_binary win32 "${arch}" || true)"
      fi
    fi
    if [[ -z "${payload_path}" || ! -x "${payload_path}" ]]; then
      echo "Missing runnable Windows binary for ${platform}-${arch}." >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported Codex plugin install platform: ${platform}-${arch}" >&2
    exit 1
    ;;
esac

if [[ -z "${payload_path}" ]]; then
  echo "Failed to resolve native runtime payload for ${platform}-${arch}" >&2
  exit 1
fi

if [[ ! -e "${payload_path}" ]]; then
  echo "Missing native runtime payload at ${payload_path}" >&2
  exit 1
fi

if [[ ! -d "${payload_path}" && ! -x "${payload_path}" ]]; then
  echo "Native runtime payload is not executable: ${payload_path}" >&2
  exit 1
fi

if [[ "${platform}" != "darwin" ]]; then
  if [[ ! -x "${payload_path}" ]]; then
    echo "Native runtime payload is not executable: ${payload_path}" >&2
    exit 1
  fi
fi

if [[ ! -f "${repo_root}/.agents/plugins/marketplace.json" ]]; then
  echo "Missing ${repo_root}/.agents/plugins/marketplace.json" >&2
  exit 1
fi

if [[ ! -f "${plugin_manifest}" ]]; then
  echo "Missing ${plugin_manifest}" >&2
  exit 1
fi

# Source checkouts keep the adapter under scripts/node-repl, while staged npm
# packages place it directly in the plugin's scripts directory.
if [[ ! -f "${repl_source_root}/open-computer-use-repl.mjs" ]]; then
  repl_source_root="${plugin_source_root}/scripts"
fi
for repl_file in open-computer-use-repl.mjs open-computer-use-kernel.mjs ocu-config.mjs; do
  if [[ ! -f "${repl_source_root}/${repl_file}" ]]; then
    echo "Missing JS REPL runtime at ${repl_source_root}/${repl_file}" >&2
    exit 1
  fi
done

plugin_version="$(node "${config_helper}" codex-plugin-version "${plugin_manifest}")"

if [[ -z "${plugin_version}" ]]; then
  echo "Failed to read plugin version from ${plugin_manifest}" >&2
  exit 1
fi

plugin_cache_root="${codex_home}/plugins/cache/${marketplace_name}/${plugin_name}"
plugin_install_root="${plugin_cache_root}/${plugin_version}"

mkdir -p "${codex_home}" "${plugin_cache_root}"
rm -rf "${plugin_install_root}"
mkdir -p "${plugin_install_root}"

cp -R "${plugin_source_root}/." "${plugin_install_root}/"
node "${config_helper}" copy-into-dir "${plugin_install_root}" "${payload_path}"
cp "${repl_source_root}/open-computer-use-repl.mjs" "${plugin_install_root}/scripts/open-computer-use-repl.mjs"
cp "${repl_source_root}/open-computer-use-kernel.mjs" "${plugin_install_root}/scripts/open-computer-use-kernel.mjs"
cp "${repl_source_root}/ocu-config.mjs" "${plugin_install_root}/scripts/ocu-config.mjs"

node "${config_helper}" codex-plugin-config "${config_path}" "${repo_root}" "${marketplace_name}" "${plugin_name}"

echo "Installed ${plugin_name}@${marketplace_name}"
echo "Marketplace source: ${repo_root}"
echo "Plugin cache: ${plugin_install_root}"
echo "Updated Codex config: ${config_path}"
echo "Restart Codex to load the plugin marketplace."
