# Changelog

All notable changes to the WTiVo (WatertightVoxel Optimizer) ComfyUI node will be documented in this file.

## [1.3.0-linux] - 2026-11-22

### Added
- Self-contained Linux `CMakeLists.txt` and `native/` sources (`wtivo_core`, `wtivo_vdb`, `wtivo_gpupr`) directly inside the custom node repository.
- Support for **PyTorch 2.8–2.11+ (`cu128`/`cu130`)**, **CUDA 13.x**, and **NVIDIA RTX 50-series (`sm_120` Blackwell)** GPUs using ComfyUI's existing `.venv`.
- `--rootless` mode in `scripts/install_linux.sh` to stage C++ build/runtime packages into `.deps/prefix` without `sudo`.
- `scripts/verify_install.py` with automated **NumPy 2.x / `pybind11 >= 3.0` stride ABI verification** and `--e2e` GPU sphere reconstruction test.

### Fixed
- Enforced `pybind11 >= 3.0` via `${WTIVO_PYTHON} -m pybind11 --cmakedir` so distro `pybind11 2.11.x` headers cannot corrupt NumPy 2.x array strides (`strides == (0,)`) in `SparseUDF::sample_tet_labels`.
- Fixed `solve_from_tet_arrays` early return on `free_N == 0` in `native/gpupr/wtivo_gpupr_bindings.cpp` returning 16 tuple elements instead of 18.
- Populated `volume_to_mesh_calls = 0` on empty FaithC contour early return in `native/vdb/wtivo_vdb.cpp` to prevent `KeyError`.
- Added standalone `LD_LIBRARY_PATH` bootstrap and `BoxSampler` `inside=<count>` diagnostics in `wtivo.py`.

## [1.2.1-ubuntu] - Ubuntu fork (`nick-knack-knight`)

### Changed
- Linux/Ubuntu 24.04 (Python 3.12, torch 2.8.0+cu128, sm_86) worker bridge (`wtivo_env.py`, `inprocess.py`, `comfy_node.py`).
- Worker runs in its own process group (`start_new_session=True`); ComfyUI Cancel button terminates the worker cleanly; progress bar follows worker stages.
- Optional `unload_models` input (default `True`) frees ComfyUI models/VRAM before WTiVo runs.
- Linux glibc `malloc_trim(0)` heap compaction and `/proc` memory snapshots.

## [1.2.0] - 2026-09-19 (`Mstafa-awad`)

### Critical Fixes
- Transitioned native mesh generation to an isolated subprocess `.npy` bridge so OS virtual memory and fragmented CGAL/OpenVDB heaps are reclaimed after every run.
