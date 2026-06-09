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

# --- smoke test ---
if ! "${LIB_DIR}/bin/shem" version >/dev/null 2>&1; then
  echo "Install failed — binary did not run."
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
