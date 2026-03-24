#!/usr/bin/env bash

# Mistral Vibe — RISC-V 64 Build Script
#
# Builds the vibe-acp PyInstaller binary on a native RISC-V 64 machine.
# Designed for BananaPi F3 (SpacemiT K1) running Armbian Trixie,
# but should work on any riscv64 Linux with Python 3.12+.
#
# Uses uv for dependency management — same toolchain as upstream.
#
# Usage:
#   bash scripts/build-riscv64.sh
#
# What this script does:
#   1. Checks system dependencies (compilers, Cargo, etc.)
#   2. Installs uv if not present
#   3. Syncs dependencies via uv (runtime + build group)
#   4. Builds the vibe-acp onedir binary with PyInstaller
#   5. Smoke-tests the binary

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()    { echo -e "\n${BOLD}==> $1${NC}"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UV_VERSION="${UV_VERSION:-0.10.0}"

# ---------------------------------------------------------------------------
# Step 1: Dependency check
# ---------------------------------------------------------------------------
step "Checking system dependencies"

MISSING=()

check_cmd() {
    local cmd="$1"
    local pkg="$2"
    if command -v "$cmd" &>/dev/null; then
        success "$cmd found: $(command -v "$cmd")"
    else
        error "$cmd not found (install: sudo apt install $pkg)"
        MISSING+=("$pkg")
    fi
}

check_cmd gcc       gcc
check_cmd g++       g++
check_cmd make      make
check_cmd cargo     cargo
check_cmd git       git
check_cmd rg        ripgrep
check_cmd pkg-config pkg-config

# Check dev libraries via dpkg (Debian/Ubuntu)
check_dev_lib() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        success "$pkg installed"
    else
        error "$pkg not found (install: sudo apt install $pkg)"
        MISSING+=("$pkg")
    fi
}

check_dev_lib python3-dev
check_dev_lib zlib1g-dev
check_dev_lib libffi-dev
check_dev_lib libssl-dev

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo
    error "Missing dependencies detected. Install them with:"
    echo -e "  ${YELLOW}sudo apt install ${MISSING[*]}${NC}"
    echo
    echo "For Cargo/Rust (if missing), install via rustup:"
    echo -e "  ${YELLOW}curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Install uv if not present
# ---------------------------------------------------------------------------
step "Ensuring uv is available"

if command -v uv &>/dev/null; then
    success "uv found: $(uv --version)"
else
    info "Installing uv $UV_VERSION..."
    curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | sh
    export PATH="$HOME/.local/bin:$PATH"
    success "uv installed: $(uv --version)"
fi

# ---------------------------------------------------------------------------
# Step 3: Sync dependencies
# ---------------------------------------------------------------------------
step "Syncing dependencies with uv (this may take a while on first build)"

cd "$PROJECT_DIR"

# Relax cryptography upper bound for riscv64: pinned versions may lack
# riscv64 wheels, forcing source builds. Newer patch releases ship wheels.
info "Relaxing cryptography upper bound for riscv64 wheel availability..."
cp pyproject.toml pyproject.toml.bak
trap 'mv -f pyproject.toml.bak pyproject.toml 2>/dev/null || true' EXIT
sed -i 's/"cryptography>=\([0-9.]*\),<=\?[0-9.]*"/"cryptography>=\1"/' pyproject.toml

# Limit concurrent Rust builds to avoid overwhelming riscv64 boards
export UV_CONCURRENT_BUILDS=1
uv sync --no-dev --group build
success "All dependencies synced"

# ---------------------------------------------------------------------------
# Step 4: Build vibe-acp binary
# ---------------------------------------------------------------------------
step "Building vibe-acp with PyInstaller"

uv run --no-dev --group build pyinstaller vibe-acp.spec 2>&1 | tail -n 15

if [[ ! -f "$PROJECT_DIR/dist/vibe-acp-dir/vibe-acp" ]]; then
    error "Build failed: dist/vibe-acp-dir/vibe-acp not found"
    exit 1
fi

success "Binary built: dist/vibe-acp-dir/vibe-acp ($(du -sh "$PROJECT_DIR/dist/vibe-acp-dir" | cut -f1) total)"

# ---------------------------------------------------------------------------
# Step 5: Smoke test the binary
# ---------------------------------------------------------------------------
step "Smoke-testing the binary"

info "Testing --version..."
"$PROJECT_DIR/dist/vibe-acp-dir/vibe-acp" --version
success "--version OK"

info "Testing --help..."
"$PROJECT_DIR/dist/vibe-acp-dir/vibe-acp" --help >/dev/null 2>&1
success "--help OK"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
VERSION="$(uv run python -c 'from vibe import __version__; print(__version__)')"

echo
echo -e "${GREEN}${BOLD}Build complete!${NC}"
echo
echo "  Binary:   dist/vibe-acp-dir/vibe-acp"
echo "  Version:  $VERSION"
echo "  Arch:     $(uname -m)"
echo
