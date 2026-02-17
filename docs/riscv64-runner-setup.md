# RISC-V 64 Self-Hosted Runner Setup

Guide for setting up a GitHub Actions self-hosted runner on a RISC-V 64 machine (tested on BananaPi F3 / SpacemiT K1 with Armbian Trixie).

## Why a Self-Hosted Runner?

GitHub does not offer hosted runners for riscv64. The official [actions/runner](https://github.com/actions/runner) also lacks riscv64 binaries ([actions/runner#2157](https://github.com/actions/runner/issues/2157)).

We use [ChristopherHX/github-act-runner](https://github.com/ChristopherHX/github-act-runner), a Go-based alternative that supports riscv64 and is compatible with GitHub's runner protocol.

## Required Runner Labels

Register the runner with these labels:

```text
self-hosted, linux, riscv64
```

These labels are referenced by `.github/workflows/build-riscv64.yml` to route the job.

## System Packages

Install all build prerequisites before the runner picks up jobs:

```bash
sudo apt update
sudo apt install -y \
  python3 python3-venv python3-dev python3-pip \
  gcc g++ make \
  git binutils \
  zlib1g-dev libffi-dev libssl-dev pkg-config \
  ripgrep \
  zip
```

### Rust / Cargo

Several Python dependencies (`pydantic-core`, `watchfiles`, `textual-speedups`) are Rust extensions that compile from source on riscv64. Install Rust via `rustup`:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
cargo --version
```

If Debian packages `cargo` and `rustc` at a recent enough version (1.70+), those work too:

```bash
sudo apt install -y cargo rustc
```

## Python Version

Python **3.12+** is required (`requires-python = ">=3.12"` in `pyproject.toml`). On Armbian Trixie this is the system default. Verify:

```bash
python3 --version   # Should print 3.12.x or higher
```

If your distro ships an older Python, you'll need to build from source or use a PPA.

## Runner Installation

### 1. Download github-act-runner

```bash
# Check latest release at https://github.com/ChristopherHX/github-act-runner/releases
VERSION="0.7.2"  # adjust as needed
wget "https://github.com/ChristopherHX/github-act-runner/releases/download/v${VERSION}/binary-linux-riscv64.tar.gz"
mkdir -p ~/actions-runner && cd ~/actions-runner
tar xzf ../binary-linux-riscv64.tar.gz
```

### 2. Register the Runner

Generate a registration token from **Settings > Actions > Runners > New self-hosted runner** in your GitHub repository, then:

```bash
./github-act-runner configure --url https://github.com/<owner>/<repo> \
  --token <REGISTRATION_TOKEN> \
  --name riscv64-bananapi-f3 \
  --labels self-hosted,linux,riscv64
```

### 3. Start the Runner

Run interactively for testing:

```bash
./github-act-runner run
```

Or install as a systemd service for persistence:

```bash
cat <<EOF | sudo tee /etc/systemd/system/github-runner.service
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/home/$USER/actions-runner
ExecStart=/home/$USER/actions-runner/github-act-runner run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now github-runner
```

### 4. Verify Registration

Check the runner appears under **Settings > Actions > Runners** in your repository with status "Idle" and the correct labels.

## Re-registering the Runner

If the runner needs to be re-registered (e.g., token expired, repo changed):

```bash
cd ~/actions-runner
./github-act-runner remove --token <REMOVAL_TOKEN>
./github-act-runner configure --url https://github.com/<owner>/<repo> \
  --token <NEW_TOKEN> \
  --name riscv64-bananapi-f3 \
  --labels self-hosted,linux,riscv64
```

## Build Performance

First builds are slow (~15-30 minutes) because Rust extensions compile from source. Subsequent builds are faster if the virtual environment is cached. The build script (`scripts/build-riscv64.sh`) creates a fresh venv each time to ensure reproducibility.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `cargo: not found` | Install Rust via rustup (see above) |
| Python < 3.12 | Build Python from source or switch distro |
| PyInstaller bootloader fails | Ensure `gcc`, `make`, `zlib1g-dev` are installed |
| Runner shows "offline" | Check systemd service: `sudo systemctl status github-runner` |
| `rg: not found` at runtime | Install ripgrep: `sudo apt install ripgrep` |
| `cryptography` metadata error | Install `libssl-dev` and `pkg-config`: `sudo apt install libssl-dev pkg-config` |
