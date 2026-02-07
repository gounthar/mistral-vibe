#!/usr/bin/env bash

# Mistral Vibe — RISC-V 64 Build Script
#
# Builds the vibe-acp PyInstaller binary on a native RISC-V 64 machine.
# Designed for BananaPi F3 (SpacemiT K1) running Armbian Trixie,
# but should work on any riscv64 Linux with Python 3.12+.
#
# Usage:
#   bash scripts/build-riscv64.sh
#
# What this script does:
#   1. Checks system dependencies (Python, compilers, Cargo, etc.)
#   2. Creates a clean virtual environment
#   3. Installs runtime + build dependencies via pip
#   4. Builds PyInstaller's bootloader from source (no riscv64 pre-built)
#   5. Builds the vibe-acp one-file binary with PyInstaller
#   6. Smoke-tests the binary
#   7. Tests pip-installable CLI in a separate venv
#   8. Packages the artifact as a zip

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
BUILD_VENV="$PROJECT_DIR/.venv-riscv64"
TEST_VENV="$PROJECT_DIR/.venv-riscv64-test"
PYTHON="${PYTHON:-python3}"

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

check_python() {
    if command -v python3.12 &>/dev/null; then
        PYTHON="python3.12"
        success "python3.12 found"
    elif command -v python3 &>/dev/null; then
        local ver
        ver="$($PYTHON --version 2>&1 | awk '{print $2}')"
        local major minor
        major="$(echo "$ver" | cut -d. -f1)"
        minor="$(echo "$ver" | cut -d. -f2)"
        if [[ "$major" -ge 3 && "$minor" -ge 12 ]]; then
            success "python3 $ver found (>= 3.12)"
        else
            error "python3 $ver found but >= 3.12 is required"
            MISSING+=("python3 (>= 3.12)")
        fi
    else
        error "python3 not found"
        MISSING+=("python3")
    fi
}

check_python
check_cmd gcc       gcc
check_cmd g++       g++
check_cmd make      make
check_cmd cargo     cargo
check_cmd git       git
check_cmd ldd       binutils
check_cmd objdump   binutils
check_cmd objcopy   binutils
check_cmd rg        ripgrep

# Check dev libraries via dpkg (Debian/Ubuntu)
check_dev_lib() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        success "$pkg installed"
    else
        error "$pkg not found (install: sudo apt install $pkg)"
        MISSING+=("$pkg")
    fi
}

check_dev_lib python3-venv
check_dev_lib python3-dev
check_dev_lib zlib1g-dev
check_dev_lib libffi-dev

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
# Step 2: Create clean build venv
# ---------------------------------------------------------------------------
step "Creating build virtual environment"

if [[ -d "$BUILD_VENV" ]]; then
    warning "Removing existing build venv: $BUILD_VENV"
    rm -rf "$BUILD_VENV"
fi

"$PYTHON" -m venv "$BUILD_VENV"
# shellcheck disable=SC1091
source "$BUILD_VENV/bin/activate"
success "Build venv created and activated: $BUILD_VENV"

# ---------------------------------------------------------------------------
# Step 3: Install dependencies via pip
# ---------------------------------------------------------------------------
step "Installing dependencies (this may take 15-30 min on first build)"

info "Upgrading pip, setuptools, wheel, maturin..."
pip install --upgrade pip setuptools wheel maturin 2>&1 | tail -1

info "Installing project runtime dependencies..."
pip install . 2>&1 | tail -1

info "Installing PyInstaller build dependency..."
pip install "pyinstaller>=6.17.0" 2>&1 | tail -1

success "All Python dependencies installed"

# ---------------------------------------------------------------------------
# Step 4: Verify PyInstaller bootloader for riscv64
# ---------------------------------------------------------------------------
step "Verifying PyInstaller bootloader for riscv64"

# PyInstaller 6.x auto-builds the bootloader for the current arch during
# pip install. We just need to confirm it exists.
PYINSTALLER_DIR="$("$PYTHON" -c "import PyInstaller; print(PyInstaller.__path__[0])")"
EXISTING_BOOT="$(find "$PYINSTALLER_DIR" -path "*/bootloader/Linux-64bit-riscv*" -name "run" 2>/dev/null || true)"

if [[ -n "$EXISTING_BOOT" ]]; then
    success "riscv64 bootloader present: $EXISTING_BOOT"
else
    error "riscv64 bootloader not found after PyInstaller install."
    error "Expected at: $PYINSTALLER_DIR/bootloader/Linux-64bit-riscv/run"
    error "PyInstaller may have failed to auto-build the bootloader."
    error "Ensure gcc, make, and zlib1g-dev are installed and try:"
    echo -e "  ${YELLOW}pip install --force-reinstall --no-binary :all: pyinstaller${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Build vibe-acp binary
# ---------------------------------------------------------------------------
step "Building vibe-acp with PyInstaller"

cd "$PROJECT_DIR"
pyinstaller vibe-acp.spec 2>&1 | tail -5

if [[ ! -f "$PROJECT_DIR/dist/vibe-acp" ]]; then
    error "Build failed: dist/vibe-acp not found"
    exit 1
fi

success "Binary built: dist/vibe-acp ($(du -h "$PROJECT_DIR/dist/vibe-acp" | cut -f1))"

# ---------------------------------------------------------------------------
# Step 6: Smoke test the binary
# ---------------------------------------------------------------------------
step "Smoke-testing the binary"

info "Testing --version..."
"$PROJECT_DIR/dist/vibe-acp" --version
success "--version OK"

info "Testing --help..."
"$PROJECT_DIR/dist/vibe-acp" --help >/dev/null 2>&1
success "--help OK"

# ---------------------------------------------------------------------------
# Step 7: Test pip install path (separate venv)
# ---------------------------------------------------------------------------
step "Testing pip install in separate venv"

deactivate 2>/dev/null || true

if [[ -d "$TEST_VENV" ]]; then
    rm -rf "$TEST_VENV"
fi

"$PYTHON" -m venv "$TEST_VENV"
# shellcheck disable=SC1091
source "$TEST_VENV/bin/activate"

info "Installing project via pip..."
pip install --upgrade pip setuptools wheel maturin 2>&1 | tail -1
pip install . 2>&1 | tail -1

info "Testing vibe --help..."
vibe --help >/dev/null 2>&1
success "vibe --help OK"

info "Testing vibe --version..."
vibe --version
success "vibe --version OK"

deactivate 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 8: Package artifact
# ---------------------------------------------------------------------------
step "Packaging artifact"

# Re-activate build venv to read version
# shellcheck disable=SC1091
source "$BUILD_VENV/bin/activate"

VERSION="$("$PYTHON" -c "from vibe import __version__; print(__version__)")"
ARTIFACT="vibe-acp-linux-riscv64-${VERSION}.zip"

cd "$PROJECT_DIR"
zip -j "$ARTIFACT" dist/vibe-acp

deactivate 2>/dev/null || true

success "Artifact created: $ARTIFACT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}Build complete!${NC}"
echo
echo "  Binary:   dist/vibe-acp"
echo "  Artifact: $ARTIFACT"
echo "  Version:  $VERSION"
echo "  Arch:     $(uname -m)"
echo
