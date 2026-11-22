# WTiVo — WatertightVoxel (ComfyUI Node — Linux / PyTorch 2.11 / Blackwell Fork)

A high-performance watertight remeshing node for ComfyUI (`WTiVo - Mesh Watertight`). WTiVo converts defective, non-manifold, or open 3D triangle meshes (such as raw outputs from AI 3D generators like **TRELLIS / TRELLIS.2**) into dense, closed, manifold meshes using sparse OpenVDB voxel fields, CGAL tetrahedral cell cuts, CUDA push-relabel graph optimization, and FaithC-style manifold contouring.

> **Linux Port Notice:** This is a Linux fork of **[Mstafa-awad/WTiVo-WatertightVoxel-ComfyuiNode](https://github.com/Mstafa-awad/WTiVo-WatertightVoxel-ComfyuiNode)** (original author: **MostAadTech**), incorporating the isolated worker-bridge design from **[nick-knack-knight/WTiVo-WatertightVoxel-ComfyuiNode](https://github.com/nick-knack-knight/WTiVo-WatertightVoxel-ComfyuiNode)** and adding **self-contained compilation for modern Linux ComfyUI + TRELLIS.2 environments** — including **PyTorch 2.8–2.11+ (`cu128` / `cu130`)**, **NumPy 2.x (`pybind11 >= 3.0`)**, **NVIDIA RTX 50-series Blackwell (`sm_120`)** GPUs, and an optional **`--rootless` (`no-sudo`)** installer.

---

## 🎥 Watch the WTiVo Node in Action

**Want to see how WTiVo works? Watch the full video explanation here:**

[![WTiVo — WatertightVoxel ComfyUI Node](https://img.youtube.com/vi/QwILmqyjEow/maxresdefault.jpg)](https://www.youtube.com/watch?v=QwILmqyjEow&t=105s)

▶️ **[Watch the video on YouTube](https://www.youtube.com/watch?v=QwILmqyjEow&t=105s)**

---

## ⚡ Key Highlights

* **Native ComfyUI Custom Node:** Executes directly on native ComfyUI `MESH` objects (`3d/mesh/WTiVo` → `WTiVo - Mesh Watertight`).
* **Isolated Worker Architecture (Zero Heap Leaks):** Each execution spawns a fresh isolated worker process in its own session (`start_new_session=True`), exchanges mesh tensors via a fast `.npy` bridge, streams real-time progress to ComfyUI, supports the ComfyUI **Cancel** button (`os.killpg`), and returns 100% of CGAL/OpenVDB heap memory to Linux on exit.
* **Automatic VRAM Eviction:** Optional `unload_models` toggle (enabled by default) unloads upstream diffusion/3D models from VRAM before CUDA push-relabel graph cutting begins.
* **2K / High-Detail Reconstruction:** Supports **2K meshes (`2048` resolution)** and **25M+ proxy points** for high-detail geometry preservation on 16 GB+ VRAM GPUs.
* **CUDA-Accelerated Graph Cut:** Multi-discharge Push-Relabel CUDA graph optimization + CGAL parallel Delaunay tetrahedralization for fast watertight surface extraction.
* **Exact Edge Validation:** Verifies `boundary edges = 0` and `non-manifold edges = 0` on every output mesh.

---

## 🐧 What Changed in This Linux Fork

1. **PyTorch 2.11 + CUDA 13.x + RTX 50-Series (`sm_120` Blackwell) Support**
   - Compiles directly against **ComfyUI's existing Python 3.12+ `.venv` and installed PyTorch/CUDA** instead of hard-requiring `torch==2.8.0+cu128` or creating a duplicate `.venv`.
   - Auto-detects GPU compute capability (tested on **NVIDIA GeForce RTX 5060 Ti `sm_120`**, `torch 2.11.0+cu130`, `nvcc 13.4`).
   - Embeds `INSTALL_RPATH` (`$ORIGIN`, Torch `lib`, CUDA `lib64`, optional `.deps/prefix`) into `wtivo_core`, `wtivo_vdb`, and `wtivo_gpupr`.

2. **All-in-One Repository Layout + Optional Rootless (`--rootless`) Build**
   - Includes the Linux `native/` sources (`wtivo_core`, `wtivo_vdb`, `wtivo_gpupr`) and `wtivo.py` directly inside the custom node repository so no external backend clone is required (while remaining compatible with `WTIVO_HOME` / `./backend`).
   - Adds `--rootless` to `scripts/install_linux.sh` to stage Ubuntu/Debian C++ packages into `.deps/prefix` via `apt-get download` + `dpkg-deb -x` when `sudo` is unavailable.

3. **NumPy 2.x / `pybind11 >= 3.0` ABI Enforcement**
   - Enforces `find_package(pybind11 3.0 CONFIG REQUIRED)` resolved via `${WTIVO_PYTHON} -m pybind11 --cmakedir` and strips distro `pybind11 2.11.x` headers in rootless mode.
   - Fixes a silent ABI mismatch on NumPy 2.x where `pybind11 < 3.0` caused `SparseUDF::sample_tet_labels` to return 1D `uint8` arrays with `strides == (0,)`, corrupting all tetrahedral UDF labels.
   - Includes an automated ABI stride check in `scripts/verify_install.py`.

4. **Native C++ & CLI Bugfixes**
   - **`native/gpupr/wtivo_gpupr_bindings.cpp`**: Fixed `solve_from_tet_arrays` early-return tuple when `free_N == 0` returning 16 values instead of 18 (`ValueError: not enough values to unpack` in `wtivo.py`).
   - **`native/vdb/wtivo_vdb.cpp`**: Populated `st["volume_to_mesh_calls"] = 0` on empty FaithC contour early return so Python raises a clean `RuntimeError` instead of `KeyError: 'volume_to_mesh_calls'`.
   - **`wtivo.py`**: Added `inside=<count>` diagnostics to the `BoxSampler` tetrahedral label log line, Linux glibc `malloc_trim(0)` heap compaction, `/proc` memory telemetry, and standalone `LD_LIBRARY_PATH` bootstrap when run directly from the CLI.

---

## 🖼️ Examples

### 🔥 2K High-Detail Reconstruction

WTiVo can reconstruct meshes at **2K resolution** while preserving fine surface detail. Increasing the proxy-point count gives the reconstruction a larger geometric budget for sharp edges, creases, and small features.

**2K Example 1**

![WTiVo 2K Example](Doc/2K.png)

**2K Example 2**

![WTiVo 2K High-Detail Example](Doc/2k-1.png)

> **Recommended for 2K:** `input_res = 2048`, `final_res = 2048`, and around `25,000,000` proxy points. Higher proxy-point counts preserve more detail, at the cost of additional VRAM/RAM and runtime.

### 💧 Watertight Reconstruction

WTiVo rebuilds the mesh topology to produce a **closed, manifold, watertight surface**, making the resulting mesh suitable for downstream decimation (e.g. LODTailor), UV unwrapping, PBR baking, rigging, game-ready asset pipelines, and 3D printing.

![WTiVo Watertight Example](Doc/watertight.png)

---

## 📋 System Requirements (Linux)

* **OS:** Ubuntu 24.04+ x86_64 (or Debian-based Linux)
* **GPU:** NVIDIA CUDA-capable GPU — RTX 20 / 30 / 40 / **50 Series (Blackwell `sm_120`)**
* **CUDA Toolkit:** `nvcc` installed (`12.8`–`13.x`, matching or compatible with your PyTorch build)
* **VRAM:** **8 GB+** recommended for standard workflows; **16 GB+** recommended for 2K / high-detail workflows
* **Environment:** ComfyUI running in **Python 3.12+** with CUDA-enabled **PyTorch** (`2.8`–`2.11+`) and **NumPy 2.x** (or 1.26+)

---

## 📦 Installation (Linux)

> **Note:** This node registers the official `WTiVoNativeMeshToMesh` class so all existing WTiVo / TRELLIS.2 workflows work out of the box. If you previously cloned the Windows `WTiVo-WatertightVoxel-ComfyuiNode` folder into `ComfyUI/custom_nodes/`, remove it first so both folders are not loaded simultaneously.

```bash
cd ComfyUI/custom_nodes
git clone https://github.com/metazero-dev/WTiVo-WatertightVoxel-ComfyuiNode-Linux.git
cd WTiVo-WatertightVoxel-ComfyuiNode-Linux

# Standard install (uses sudo apt-get for C++ libraries, compiles against ComfyUI's venv):
scripts/install_linux.sh --python /path/to/ComfyUI/.venv/bin/python
```

### Rootless install (no `sudo` required on Ubuntu/Debian)

```bash
scripts/install_linux.sh --python /path/to/ComfyUI/.venv/bin/python --rootless
```

### Installer options

| Option | Description |
| :-- | :-- |
| `--python PATH` | Path to ComfyUI's Python interpreter (default: `python3` on `PATH`) |
| `--cuda-arch X.Y` | Override GPU compute capability, e.g. `12.0` or `8.6` (default: auto-detected from GPU) |
| `--rootless` | Download & extract `.deb` C++ dependencies into `.deps/prefix` without `sudo` |
| `--skip-apt` | Skip `apt-get` if `libcgal-dev`, `libopenvdb-dev`, `libtbb-dev`, etc. are already installed |
| `--rebuild` | Force a clean CMake rebuild |
| `--no-e2e` | Run ABI/import smoke checks only (skip GPU sphere reconstruction test) |

### Environment variables (optional)

| Variable | Purpose |
| :-- | :-- |
| `WTIVO_HOME` | Override backend directory (default: `<node>/backend` if present, otherwise `<node>`) |
| `WTIVO_BUILD_DIR` | Override directory holding compiled `.so` extensions (default: `<backend>/build`) |
| `WTIVO_PYTHON` | Override Python interpreter used for the worker subprocess (default: ComfyUI's interpreter) |

Restart ComfyUI after installation. The node appears under **`3d/mesh/WTiVo` → `WTiVo - Mesh Watertight`**.

---

## ⚙️ Node Parameters (`WTiVo - Mesh Watertight`)

| Parameter               | Type        |   Default   | Range / Options                | Description                                                                                                                                             |
| :---------------------- | :---------- | :---------: | :----------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mesh`                  | **MESH**    |      —      | ComfyUI `MESH` (batch size 1)  | Input ComfyUI native mesh object, e.g. from `VaeDecodeShapeTrellis` or `MeshReconstructWithQuad`.                                                       |
| `input_res`             | **INT**     |   `1536`    | `256` – `8192` (step `128`)    | Resolution for the initial thick sparse OpenVDB UDF field and tetrahedral cell-label pass. Increase to `2048` for 2K workflows.                         |
| `final_res`             | **INT**     |   `1536`    | `256` – `8192` (step `128`)    | Resolution for the final signed sparse OpenVDB field and FaithC manifold contouring. Increase to `2048` for 2K workflows.                               |
| `proxy_points`          | **INT**     | `12000000`  | `0` – `100000000` (step `1M`)  | QEF proxy-point budget sent to CGAL for Delaunay tetrahedralization. `4M–12M` for standard workflows; `~25M` for high-detail 2K meshes (16 GB+ VRAM).   |
| `proxy_eps_scale`       | **FLOAT**   |    `1.0`    | `0.25` – `4.0` (step `0.05`)   | Inset scale for graph proxy geometry relative to resolution (`1/R`).                                                                                    |
| `proxy_feature_weight`  | **FLOAT**   |    `1.5`    | `0.0` – `20.0` (step `0.05`)   | Priority weight for preserving sharp corners, creases, and geometric features during QEF point selection.                                               |
| `lambda_fill`           | **FLOAT**   |   `20.0`    | `0.0` – `1000.0` (step `1.0`)  | Regularization factor for tetrahedral cell-cut interior fill (`10–20` for small holes, `30–40` for larger gaps; too high can bridge intended openings). |
| `threads`               | **INT**     |  *Max CPU*  | `1` – *Max CPU*                | Number of logical CPU threads allocated for parallel CGAL/OpenVDB/FaithC stages.                                                                        |
| `thin_iso_vox`          | **FLOAT**   |    `0.0`    | `-2.0` – `2.0` (step `0.05`)   | Iso-surface offset in voxel units for the final signed OpenVDB level set.                                                                               |
| `faithc_component_mode` | **ENUM**    | `keep_all`  | `auto`, `keep_all`, `largest`  | Connected-component selection mode: `largest` keeps only the main closed body and drops floating fragments; `keep_all` preserves separate parts.        |
| `unload_models`         | **BOOLEAN** |   `True`    | *Optional* (`True` / `False`)  | Evicts ComfyUI's currently loaded models from VRAM (`unload_all_models` + `soft_empty_cache`) before spawning the WTiVo CUDA worker.                    |

---

## 🔄 Workflow Integration & Recommended Presets

```text
[ VaeDecodeShapeTrellis / MeshReconstructWithQuad ]
                        │
                        │ MESH
                        ▼
           [ WTiVo - Mesh Watertight ]
                        │
                        │ Watertight MESH
                        ▼
  [ LODTailor / UV Unwrap / BakeTextureFromVoxel / Save 3D ]
```

| Workflow       | `input_res` | `final_res` | `proxy_points` | Recommended VRAM / RAM          |
| :------------- | :---------: | :---------: | :------------: | :------------------------------ |
| Lightweight    |   `1024`    |   `1280`    |      `4M`      | ~6–8 GB+ VRAM, 16–32 GB RAM     |
| Standard       |   `1536`    |   `1536`    |     `12M`      | ~8 GB+ VRAM, 32 GB RAM          |
| High Detail    |   `1536`    |   `1536`    |     `20M`      | 12–16 GB+ VRAM                  |
| 2K High Detail |   `2048`    |   `2048`    |     `25M`      | **16 GB+ VRAM**, 32–64 GB RAM   |

### 🧠 Quality vs Memory & Important Notes

* **Topology rebuild:** WTiVo completely reconstructs mesh topology into a closed, manifold surface (`boundary edges = 0`, `non-manifold edges = 0`). Input UVs, vertex colors, and textures are **not preserved** — unwrap and bake textures downstream (e.g. `BakeTextureFromVoxel` using WTiVo's output as `reference_mesh`).
* **Batch size:** Process **one mesh at a time** (`batch_size = 1`).
* **Memory tuning:** If you hit VRAM or system RAM limits, lower `proxy_points` first, then reduce `input_res` / `final_res`. On 32 GB RAM Linux systems running TRELLIS.2 + WTiVo, launching ComfyUI with `--disable-pinned-memory` and `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` is recommended.

---

## 🧪 Running Tests

```bash
# Worker bridge unit tests (no GPU needed):
python3 tests/test_worker_bridge.py

# Native module ABI + full GPU end-to-end watertight check:
/path/to/ComfyUI/.venv/bin/python scripts/verify_install.py --e2e
```

---

## ⚖️ License & Attribution

* **License:** GNU General Public License v3.0 or later (**GPL-3.0-or-later**). See [`LICENSE`](LICENSE), [`LICENSING.md`](LICENSING.md), and [`NOTICE`](NOTICE).
* **Credits & Lineage:**
  * **WTiVo & ComfyUI Node:** [MostAadTech (`Mstafa-awad`)](https://github.com/Mstafa-awad/WTiVo-WatertightVoxel-ComfyuiNode)
  * **Ubuntu Worker Bridge:** [`nick-knack-knight`](https://github.com/nick-knack-knight/WTiVo-WatertightVoxel-ComfyuiNode)
  * **CelloCut:** Constructive Watertight Remeshing via Tetrahedral Cell Cuts ([Xuan Yang et al.](https://github.com/rangeryx-66/CelloCut), Apache-2.0)
  * **FaithC:** Faithful Contouring ([Yihao Luo et al.](https://github.com/Luo-Yihao/FaithC), Apache-2.0)
  * OpenVDB, CGAL 3D Triangulations, oneTBB, Eigen, pybind11, and PyTorch

---

## 🚀 Support the Original Author (MostAadTech)

WTiVo was created and open-sourced by **MostAadTech**:

* 💜 **[Patreon](https://www.patreon.com/cw/MostafaAwad/membership)**
* ▶️ **[YouTube](https://www.youtube.com/@MostAadTech)**
* 𝕏 **[X / Twitter](https://x.com/MostAadTech)**
* 💻 **[GitHub](https://github.com/Mstafa-awad)**
