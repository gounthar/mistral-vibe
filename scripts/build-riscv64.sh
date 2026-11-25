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

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step() { echo -e "\n${BOLD}==> $1${NC}"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UV_VERSION="${UV_VERSION:-0.11.1}"

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

check_cmd gcc gcc
check_cmd g++ g++
check_cmd make make
check_cmd cargo cargo
check_cmd git git
check_cmd rg ripgrep
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
info "Patching pyproject.toml for riscv64 compatibility..."
cp pyproject.toml pyproject.toml.bak
cp pyinstaller/unified_runtime.py pyinstaller/unified_runtime.py.bak
trap 'mv -f pyproject.toml.bak pyproject.toml 2>/dev/null || true; mv -f pyinstaller/unified_runtime.py.bak pyinstaller/unified_runtime.py 2>/dev/null || true' EXIT
# Relax cryptography upper bound: pinned versions may lack riscv64 wheels
sed -i 's/"cryptography>=\([0-9.]*\),<=\?[0-9.]*"/"cryptography>=\1"/' pyproject.toml
# Remove typos from dev deps: its PyPI sdist has a broken pyproject.toml
# that uv cannot parse, and uv resolves dev deps even with --no-dev
sed -i '/"typos>=/d' pyproject.toml
# Since v3.1.3 the Unified Runtime (mistralai_vibe_local_harness) is built
# from the in-tree harness/ Rust sources by the maturin backend, so riscv64
# compiles it like any other platform. The separate target runtime
# (mistralai.vibe.harness, PyPI dist mistralai-vibe-harness) ships wheels only
# (no sdist) for x86_64, aarch64, macOS and Windows, so riscv64 has nothing to
# resolve. Upstream's pyinstaller/unified_runtime.py says no module imports it
# statically yet; it is only collected so the frozen binary carries it. Drop
# the dependency and skip its collection in the spec helper.
sed -i '/"mistralai-vibe-harness==/d; /^mistralai-vibe-harness = /d' pyproject.toml
python3 - <<'PY'
from pathlib import Path
p = Path("pyinstaller/unified_runtime.py")
s = p.read_text()
patches = [
    ("    require_unified_runtime()\n    require_target_runtime()\n",
     "    require_unified_runtime()\n"),
    ("    packages = [_RUNTIME_PACKAGE, _TARGET_RUNTIME_PACKAGE]\n",
     "    packages = [_RUNTIME_PACKAGE]\n"),
]
for old, new in patches:
    if s.count(old) != 1:
        raise SystemExit(f"unified_runtime.py patch no longer applies: {old!r}")
    s = s.replace(old, new)
p.write_text(s)
PY
# Dropping the target runtime is only safe while nothing imports it. If
# upstream starts importing it, --version/--help would still pass while real
# features break, so refuse to build instead.
harness_hits="$(grep -rnE '^\s*(from|import)\s+mistralai\.vibe\.harness|import_module\(\s*["'"'"']mistralai\.vibe\.harness|from\s+mistralai\.vibe\s+import\s+harness' \
  --include='*.py' vibe harness/runtimes/python/python || true)"
# A module that only tests import never loads in the binary, so its import
# does not count. Since v3.1.5 vibe/app_server/_target_session_errors.py is
# such a module. Anything else importing the module (absolute, relative,
# "from pkg import mod", or a dotted name in a lazy-import table) keeps the
# hit and fails the build.
harness_imports=""
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  file="${hit%%:*}"
  mod="${file%.py}"
  mod="${mod#harness/runtimes/python/python/}"
  mod="${mod//\//.}"
  base="${mod##*.}"
  if [[ "$base" == "__init__" ]]; then
    harness_imports+="$hit"$'\n'
    continue
  fi
  mod_re="${mod//./\\.}"
  if grep -rqE "^\s*(from|import)\s+${mod_re}\b|^\s*from\s+\.+${base}\s+import|^\s*from\s+[.[:alnum:]_]+\s+import\s+.*\b${base}\b|[\"']${mod_re}[\"']" \
    --include='*.py' vibe harness/runtimes/python/python 2>/dev/null; then
    harness_imports+="$hit"$'\n'
  else
    info "Ignoring $file: only tests import it"
  fi
done <<<"$harness_hits"
if [[ -n "$harness_imports" ]]; then
  error "Upstream now imports mistralai.vibe.harness, which has no riscv64 build:"
  echo "$harness_imports" >&2
  exit 1
fi

# Limit concurrent Rust builds to avoid overwhelming riscv64 boards
export UV_CONCURRENT_BUILDS=1
rm -f uv.lock
uv sync --no-dev --group build
success "All dependencies synced"

# ---------------------------------------------------------------------------
# Step 4: Build vibe-acp binary
# ---------------------------------------------------------------------------
step "Building vibe-rs (bundled by vibe-acp for --setup)"

# Since v3.0, vibe-acp.spec refuses to build without vibe-rs. Mirror
# upstream's scripts/ci/build-pyinstaller-binaries.sh: build it from
# source without the voice feature and point the spec at it.
# VIBE_SKIP_RUST_TUI=1 still produces a bundle without the wizard.
if [[ -z "${VIBE_SKIP_RUST_TUI:-}" && -z "${VIBE_ACP_RUST_TUI:-}" ]]; then
  tui_target="$PROJECT_DIR/.native-build/vibe-rs-target"
  read -r -a tui_flags <<<"${CARGO_BUILD_FLAGS:---no-default-features}"
  CARGO_TARGET_DIR="$tui_target" cargo build --release --locked \
    --manifest-path vibe/cli-rust/Cargo.toml --bin vibe-rs "${tui_flags[@]}"
  export VIBE_ACP_RUST_TUI="$tui_target/release/vibe-rs"
  success "vibe-rs built: $VIBE_ACP_RUST_TUI"
else
  info "Skipping vibe-rs build (VIBE_SKIP_RUST_TUI or VIBE_ACP_RUST_TUI set)"
fi

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
