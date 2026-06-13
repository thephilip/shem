#!/usr/bin/env bash
set -euo pipefail

REPO="thephilip/shem"
LIB_DIR="${HOME}/.local/lib/shem"
BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/shem"

# ── Colours ───────────────────────────────────────────────────────────────────
_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n'  "$*"; }
_err()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
_ok()     { printf ' \033[32m✓\033[0m\n'; }
_step()   { printf '  ✦ %-44s' "$1"; }
_line()   { printf '%s\n' "──────────────────────────────────────────────────"; }

# ── Platform detection ────────────────────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Linux-x86_64)  TARGET="shem-linux-x86_64.tar.gz"  ;;
  Darwin-x86_64) TARGET="shem-macos-x86_64.tar.gz"  ;;
  Darwin-arm64)  TARGET="shem-macos-arm64.tar.gz"   ;;
  *)
    _err "Unsupported platform: ${OS}-${ARCH}"
    echo "Build from source: https://github.com/${REPO}"
    exit 1
    ;;
esac

echo ""
_bold "Shem Installer"
_line

# ── OpenSSL check ─────────────────────────────────────────────────────────────
_step "Checking system requirements (OpenSSL 3.x)"
_ossl_ok=false
if command -v openssl >/dev/null 2>&1; then
  _ossl_major=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
  if [ "${_ossl_major:-0}" -ge 3 ] 2>/dev/null; then _ossl_ok=true; fi
fi

if [ "${_ossl_ok}" = "false" ]; then
  printf '\n'
  _err "OpenSSL 3.x required but not found."
  echo ""
  echo "  Install it with:"
  case "${OS}" in
    Linux)
      command -v apt-get >/dev/null 2>&1 && echo "    sudo apt-get install -y libssl3" && exit 1
      command -v dnf     >/dev/null 2>&1 && echo "    sudo dnf install -y openssl"     && exit 1
      command -v pacman  >/dev/null 2>&1 && echo "    sudo pacman -S openssl"           && exit 1
      echo "    Install openssl >= 3.0 via your system package manager"
      ;;
    Darwin) echo "    brew install openssl@3" ;;
  esac
  exit 1
fi
_ok

# ── Fetch release tag ─────────────────────────────────────────────────────────
_step "Fetching latest release"
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -z "${LATEST}" ]; then
  printf '\n'
  _err "Could not determine latest release."
  echo "  Check: https://github.com/${REPO}/releases"
  exit 1
fi
printf ' %s\n' "${LATEST}"

URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARGET}"

# ── Download and extract ──────────────────────────────────────────────────────
_step "Downloading and extracting"
rm -rf "${LIB_DIR}"
mkdir -p "${LIB_DIR}"
curl -fsSL "${URL}" | tar -xz -C "${LIB_DIR}" --strip-components=1
_ok

# ── Write smart wrapper ───────────────────────────────────────────────────────
_step "Installing to ${WRAPPER}"
mkdir -p "${BIN_DIR}"

cat > "${WRAPPER}" <<'WRAPPER_EOF'
#!/bin/sh
# Shem CLI dispatcher
_SHEM_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../lib/shem"
_SHEM_BIN="${_SHEM_DIR}/bin/shem"
_SHEM_REPO="thephilip/shem"

_shem_version() {
  # releases/start_erl.data is the canonical "<erts_vsn> <release_vsn>" record;
  # a bare ls would pick up that very file (s > 0 in sort -V)
  if [ -f "${_SHEM_DIR}/releases/start_erl.data" ]; then
    cut -d' ' -f2 < "${_SHEM_DIR}/releases/start_erl.data"
  else
    ls "${_SHEM_DIR}/releases/" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -1
  fi
}

_shem_help() {
  if [ -t 1 ] && { [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; }; then
    _banner=$(ls "${_SHEM_DIR}"/lib/shem-*/priv/banner.ansi 2>/dev/null | head -1)
    [ -n "$_banner" ] && cat "$_banner"
  fi
  cat <<'HELP'

Shem — AI agent platform

Usage:
  shem                       Show this help
  shem start                 Start shem with TUI
  shem start --headless      Start without TUI (HTTP/MCP API only)
  shem setup                 Configure LLM backend (interactive wizard)
  shem config list           Show current configuration
  shem config get <key>      Read a config value  (e.g. server.port)
  shem config set <k> <v>    Write a config value
  shem status                Show running service status
  shem upgrade               Upgrade to latest release
  shem version               Show installed version

HELP
}

case "${1:-}" in
  ""|-h|--help|help)
    _shem_help
    ;;

  version|-v|--version)
    echo "shem $(_shem_version)"
    ;;

  start)
    shift
    if [ "${1:-}" = "--headless" ]; then
      SHEM_NO_TUI=1 SHEM_SKIP_CONFIG_CHECK=1 exec "${_SHEM_BIN}" start
    else
      exec "${_SHEM_BIN}" start "$@"
    fi
    ;;

  setup)
    exec "${_SHEM_BIN}" eval "Shem.CLI.Setup.run()"
    ;;

  config)
    shift
    case "${1:-}" in
      list)
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.list()"
        ;;
      get)
        KEY="${2:?Usage: shem config get <key>}"
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.get(\"${KEY}\")"
        ;;
      set)
        KEY="${2:?Usage: shem config set <key> <value>}"
        VAL="${3:?Usage: shem config set <key> <value>}"
        exec "${_SHEM_BIN}" eval "Shem.CLI.Config.set(\"${KEY}\", \"${VAL}\")"
        ;;
      *)
        echo "Usage: shem config list | get <key> | set <key> <value>"
        exit 1
        ;;
    esac
    ;;

  status)
    exec "${_SHEM_BIN}" eval "Shem.CLI.Status.run()"
    ;;

  upgrade)
    CURRENT="$(_shem_version)"
    echo "Checking for updates (current: ${CURRENT:-unknown})..."
    LATEST=$(curl -fsSL "https://api.github.com/repos/${_SHEM_REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
    if [ "${CURRENT}" = "${LATEST}" ]; then
      echo "Already up to date (v${CURRENT})."
      exit 0
    fi
    echo "Upgrading v${CURRENT} → v${LATEST}..."
    curl -fsSL "https://raw.githubusercontent.com/${_SHEM_REPO}/master/install.sh" | bash
    ;;

  *)
    echo "shem: unknown command '${1}'"
    _shem_help
    exit 1
    ;;
esac
WRAPPER_EOF

chmod +x "${WRAPPER}"
_ok

# ── Smoke test ────────────────────────────────────────────────────────────────
_step "Verifying (crypto + boot check)"
if ! SHEM_SKIP_CONFIG_CHECK=1 "${LIB_DIR}/bin/shem" eval \
    "Application.ensure_all_started(:crypto)" >/dev/null 2>&1; then
  printf '\n'
  _err "Could not load the crypto library. OpenSSL 3.x must be visible to the dynamic linker."
  case "${OS}" in
    Linux)
      command -v apt-get >/dev/null 2>&1 && echo "  sudo apt-get install -y libssl3"
      command -v dnf     >/dev/null 2>&1 && echo "  sudo dnf install -y openssl"
      command -v pacman  >/dev/null 2>&1 && echo "  sudo pacman -S openssl"
      ;;
    Darwin) echo "  brew install openssl@3" ;;
  esac
  rm -f "${WRAPPER}"
  exit 1
fi
_ok

echo ""
_line
_green "Shem ${LATEST} installed."
echo ""
echo "  Next step: run \`shem setup\` to configure your LLM backend."
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  echo "  Note: add ${BIN_DIR} to your PATH"
  echo "    echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
  echo "    (or ~/.zshrc / ~/.config/fish/config.fish)"
  echo ""
fi
