#!/usr/bin/env bash
set -euo pipefail

REPO="thephilip/shem"
LIB_DIR="${HOME}/.local/lib/shem"
BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/shem"

# --- platform detection ---
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Linux-x86_64)  TARGET="shem-linux-x86_64.tar.gz"  ;;
  Darwin-x86_64) TARGET="shem-macos-x86_64.tar.gz"  ;;
  Darwin-arm64)  TARGET="shem-macos-arm64.tar.gz"   ;;
  *)
    echo "Unsupported platform: ${OS}-${ARCH}"
    echo "Build from source: https://github.com/${REPO}"
    exit 1
    ;;
esac

# --- OpenSSL 3.x check ---
# The crypto NIF in the OTP release requires OpenSSL 3.x at runtime.
_ossl_ok=false
if command -v openssl >/dev/null 2>&1; then
  _ossl_major=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
  if [ "${_ossl_major:-0}" -ge 3 ] 2>/dev/null; then
    _ossl_ok=true
  fi
fi

if [ "${_ossl_ok}" = "false" ]; then
  echo "Error: shem requires OpenSSL 3.x, which was not found on this system."
  echo ""
  echo "Install it with:"
  case "${OS}" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get install -y libssl3"
      elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install -y openssl"
      elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S openssl"
      elif command -v zypper >/dev/null 2>&1; then
        echo "  sudo zypper install libopenssl3"
      else
        echo "  Install openssl >= 3.0 via your system package manager"
      fi
      ;;
    Darwin)
      echo "  brew install openssl@3"
      ;;
    *)
      echo "  Install openssl >= 3.0 via your system package manager"
      ;;
  esac
  echo ""
  echo "Then re-run this installer."
  exit 1
fi

# --- fetch latest release tag ---
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -z "${LATEST}" ]; then
  echo "Could not determine latest release. Check https://github.com/${REPO}/releases"
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARGET}"

echo "Installing shem ${LATEST} (${OS}-${ARCH})..."

# --- extract release ---
rm -rf "${LIB_DIR}"
mkdir -p "${LIB_DIR}"
curl -fsSL "${URL}" | tar -xz -C "${LIB_DIR}" --strip-components=1

# --- create wrapper ---
mkdir -p "${BIN_DIR}"
cat > "${WRAPPER}" <<'EOF'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../lib/shem/bin/shem" start "$@"
EOF
chmod +x "${WRAPPER}"

# --- smoke test (boot OTP + crypto) ---
if ! "${LIB_DIR}/bin/shem" eval "Application.ensure_all_started(:crypto)" >/dev/null 2>&1; then
  echo ""
  echo "Install failed — could not load the crypto library."
  echo "OpenSSL 3.x must be installed and visible to the dynamic linker."
  echo ""
  case "${OS}" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get install -y libssl3"
      elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install -y openssl"
      elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S openssl"
      else
        echo "  Install openssl >= 3.0 via your system package manager"
      fi
      ;;
    Darwin)
      echo "  brew install openssl@3"
      ;;
  esac
  rm -f "${WRAPPER}"
  exit 1
fi

echo ""
echo "shem ${LATEST} installed."
echo ""
echo "You're ready. Run \`shem\` to start."
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  echo "  Note: add ${BIN_DIR} to your PATH"
  echo "    echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
  echo "    (or ~/.zshrc / ~/.config/fish/config.fish)"
fi
