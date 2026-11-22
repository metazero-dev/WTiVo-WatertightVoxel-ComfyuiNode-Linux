#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and verify the WTiVo native Linux backend directly inside the ComfyUI node directory.
#
# Supports Python 3.12+, PyTorch 2.8–2.11+ (cu128/cu130), NumPy 2.x (pybind11 >= 3.0),
# and Ampere through Blackwell GPUs (including RTX 50-series sm_120).
#
# Usage:
#   scripts/install_linux.sh --python /path/to/ComfyUI/.venv/bin/python [options]
#
# Options:
#   --python PATH      ComfyUI Python interpreter (default: python3 on PATH)
#   --cuda-arch X.Y    Override target CUDA compute capability (default: auto-detected from GPU)
#   --rootless         Stage Ubuntu/Debian C++ dependencies into .deps/prefix without sudo
#   --skip-apt         Assume C++ system libraries are already installed (no apt-get)
#   --rebuild          Force a clean CMake rebuild even if .so modules already exist
#   --no-e2e           Skip GPU end-to-end verification after building
set -euo pipefail
export LC_ALL=C

NODE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$(command -v python3 || true)"
CUDA_ARCH="${WTIVO_CUDA_ARCH:-}"
ROOTLESS=0
SKIP_APT=0
REBUILD=0
E2E=1
JOBS="${WTIVO_JOBS:-$(nproc)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python) PY="$2"; shift ;;
    --cuda-arch) CUDA_ARCH="$2"; shift ;;
    --rootless) ROOTLESS=1 ;;
    --skip-apt) SKIP_APT=1 ;;
    --rebuild) REBUILD=1 ;;
    --no-e2e) E2E=0 ;;
    *) echo "[WTiVo ERROR] Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

info() { echo "[WTiVo] $*"; }
fail() { echo "[WTiVo ERROR] $*" >&2; exit 1; }

[[ -x "$PY" ]] || fail "Python interpreter not found: '$PY' (pass --python /path/to/ComfyUI/.venv/bin/python)"
# Preserve the .venv/bin/python symlink path so Python's pyvenv.cfg site-packages remain active!
PY="$(cd "$(dirname "$PY")" && pwd)/$(basename "$PY")"

"$PY" - <<'PYEOF' || fail "Requires Python >= 3.12 with CUDA-enabled PyTorch installed in the target venv."
import sys, torch
assert sys.version_info >= (3, 12), f"Expected Python >= 3.12, got {sys.version.split()[0]}"
assert torch.version.cuda is not None, f"PyTorch {torch.__version__} was built without CUDA support"
print(f"[WTiVo] Python {sys.version.split()[0]} | PyTorch {torch.__version__} | CUDA {torch.version.cuda}")
PYEOF

# Ensure pybind11 >= 3.0.1 (mandatory for NumPy 2.x PyArray_Descr ABI) without altering torch.
"$PY" -m pip install "pybind11>=3.0.1" "trimesh>=4.4.0"

APT_TOP_PKGS=(
  libcgal-dev
  libopenvdb-dev
  libeigen3-dev
  libtbb-dev
  libboost-dev
  libboost-iostreams-dev
  libboost-system-dev
  libgmp-dev
  libmpfr-dev
  libblosc-dev
  libimath-dev
  zlib1g-dev
)

if [[ $ROOTLESS -eq 1 ]]; then
  info "Resolving missing C++ packages and staging into $NODE/.deps/prefix (no sudo)..."
  rm -rf "$NODE/.build"
  mkdir -p "$NODE/.deps/debs" "$NODE/.deps/prefix"
  mapfile -t MISSING_PKGS < <(
    apt-cache depends --recurse \
      --no-recommends --no-suggests --no-conflicts \
      --no-breaks --no-replaces --no-enhances \
      "${APT_TOP_PKGS[@]}" \
    | awk '
        /^[[:alnum:]][[:alnum:].+-]*$/ { print $1 }
        /^[[:space:]]*(Pre)?Depends:[[:space:]]*[[:alnum:]][[:alnum:].+-]*$/ { print $NF }
      ' \
    | sort -u \
    | while read -r pkg; do
        if ! dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
          echo "$pkg"
        fi
      done
  )
  if (( ${#MISSING_PKGS[@]} > 0 )); then
    (
      cd "$NODE/.deps/debs"
      apt-get download "${MISSING_PKGS[@]}"
      for deb in ./*.deb; do
        [[ -f "$deb" ]] && dpkg-deb -x "$deb" "$NODE/.deps/prefix"
      done
    )
  fi
  # Never let older distro pybind11 headers shadow the venv's pybind11 >= 3.0.
  rm -rf \
    "$NODE/.deps/prefix/usr/include/pybind11" \
    "$NODE/.deps/prefix/usr/lib/cmake/pybind11" \
    "$NODE/.deps/prefix/usr/share/cmake/pybind11"
  # 1. Fix extracted .deb symlinks inside .deps/prefix FIRST.
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    if [[ "$target" == /* && "$target" != "$NODE/.deps/prefix"* && -e "$NODE/.deps/prefix$target" ]]; then
      ln -sfn "$NODE/.deps/prefix$target" "$link"
    elif [[ ! -e "$link" ]]; then
      rel_dir="${link#"$NODE/.deps/prefix"}"
      host_cand="$(dirname "$rel_dir")/$target"
      if [[ -e "$host_cand" ]]; then
        ln -sfn "$host_cand" "$link"
      fi
    fi
  done < <(find "$NODE/.deps/prefix" -type l -print0)
  # 2. Expose already-installed host /usr/lib/x86_64-linux-gnu shared libs inside .deps/prefix
  #    so staged CMake target files (e.g. ImathTargets.cmake) find host-installed .so.X.Y files.
  mkdir -p "$NODE/.deps/prefix/usr/lib/x86_64-linux-gnu"
  for host_lib in /usr/lib/x86_64-linux-gnu/lib*.so*; do
    [[ -e "$host_lib" ]] || continue
    [[ -e "$NODE/.deps/prefix$host_lib" || -L "$NODE/.deps/prefix$host_lib" ]] || \
      ln -s "$host_lib" "$NODE/.deps/prefix$host_lib"
  done
elif [[ $SKIP_APT -eq 0 ]]; then
  SUDO=""
  [[ $EUID -ne 0 ]] && SUDO="sudo"
  info "Installing system C++ packages via apt-get..."
  $SUDO apt-get update
  $SUDO apt-get install -y build-essential cmake pkg-config \
    libcgal-dev libopenvdb-dev libeigen3-dev libtbb-dev \
    libboost-dev libboost-iostreams-dev libboost-system-dev \
    libgmp-dev libmpfr-dev libblosc-dev zlib1g-dev
fi

if [[ -z "$CUDA_ARCH" ]]; then
  CUDA_ARCH="$("$PY" -c "import torch; c = torch.cuda.get_device_capability(0) if torch.cuda.is_available() else (8, 6); print(f'{c[0]}.{c[1]}')")"
fi
info "Target CUDA compute capability: $CUDA_ARCH"

if [[ $REBUILD -eq 1 ]]; then
  rm -rf "$NODE/.build" "$NODE/build"
fi

if compgen -G "$NODE/build/wtivo_core*.so" >/dev/null \
   && compgen -G "$NODE/build/wtivo_vdb*.so" >/dev/null \
   && compgen -G "$NODE/build/wtivo_gpupr*.so" >/dev/null; then
  info "Compiled extensions already present in $NODE/build (pass --rebuild to recompile)."
else
  info "Configuring and compiling WTiVo native modules..."
  TORCH_CUDA_ARCH_LIST="$CUDA_ARCH" cmake -S "$NODE" -B "$NODE/.build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWTIVO_PYTHON="$PY" \
    -DTORCH_CUDA_ARCH_LIST="$CUDA_ARCH"
  TORCH_CUDA_ARCH_LIST="$CUDA_ARCH" cmake --build "$NODE/.build" -j "$JOBS"
fi

"$PY" - "$NODE/build/BUILD_INFO.json" "$CUDA_ARCH" <<'PYEOF'
import json, sys, torch
from pathlib import Path
out_path = Path(sys.argv[1])
info = {
    "python": f"{sys.version_info.major}.{sys.version_info.minor}",
    "torch": torch.__version__.split("+")[0],
    "cuda": torch.version.cuda,
    "arch": sys.argv[2],
}
out_path.write_text(json.dumps(info, indent=2) + "\n")
print("[WTiVo] Wrote", out_path, info)
PYEOF

VERIFY_ARGS=()
[[ $E2E -eq 1 ]] && VERIFY_ARGS+=(--e2e)
info "Verifying installation..."
"$PY" "$NODE/scripts/verify_install.py" "${VERIFY_ARGS[@]}"
info "Success! Restart ComfyUI to use 'WTiVo - Mesh Watertight' (under 3d/mesh/WTiVo)."
