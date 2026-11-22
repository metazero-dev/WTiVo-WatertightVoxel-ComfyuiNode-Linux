#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Smoke and end-to-end verification for the WTiVo Linux ComfyUI node."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

NODE_ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = Path(os.environ.get("WTIVO_BUILD_DIR") or (NODE_ROOT / "build")).resolve()
DEPS_LIB = NODE_ROOT / ".deps" / "prefix" / "usr" / "lib" / "x86_64-linux-gnu"

if DEPS_LIB.is_dir() and os.environ.get("_WTIVO_VERIFY_REEXEC") != "1":
    cur_ld = os.environ.get("LD_LIBRARY_PATH", "")
    parts = [p for p in cur_ld.split(os.pathsep) if p]
    if str(DEPS_LIB) not in parts:
        env = dict(os.environ)
        env["_WTIVO_VERIFY_REEXEC"] = "1"
        env["LD_LIBRARY_PATH"] = os.pathsep.join([str(BUILD_DIR), str(DEPS_LIB)] + parts)
        os.execve(sys.executable, [sys.executable] + sys.argv, env)


def verify_imports_and_abi() -> None:
    sys.path.insert(0, str(BUILD_DIR))
    import torch  # noqa: F401 — load libtorch symbols before wtivo_gpupr
    import wtivo_core
    import wtivo_gpupr
    import wtivo_vdb

    print(f"[verify] wtivo_core : {wtivo_core.__file__}")
    print(f"[verify] wtivo_vdb  : {wtivo_vdb.__file__}")
    print(f"[verify] wtivo_gpupr: {wtivo_gpupr.__file__}")

    # Regression guard for NumPy 2.x + pybind11 < 3.0 ABI bug (strides == (0,))
    v = np.array([[0.1, 0.1, 0.1], [0.9, 0.1, 0.1], [0.1, 0.9, 0.1], [0.1, 0.1, 0.9]], dtype=np.float32)
    f = np.array([[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]], dtype=np.int32)
    field = wtivo_vdb.SparseUDF(v, f, 1.0 / 64.0, 3.0, 2, False)
    pts = np.array([[0.1, 0.1, 0.1], [0.5, 0.5, 0.5], [0.9, 0.9, 0.9]], dtype=np.float64)
    verts = np.ascontiguousarray(np.repeat(pts, 4, axis=0))
    tets = np.arange(12, dtype=np.int32).reshape(3, 4)
    labels, _ = field.sample_tet_labels(verts, tets, np.zeros(3), np.ones(3), 0.0, 0.02, 1)
    if labels.strides != (1,):
        raise RuntimeError(
            f"NumPy/pybind11 ABI mismatch detected: sample_tet_labels returned strides={labels.strides} "
            "(expected (1,)). Ensure wtivo_vdb was compiled against pybind11 >= 3.0.1."
        )
    if labels.tolist() != [0, 1, 1]:
        raise RuntimeError(f"Unexpected sample_tet_labels result: {labels.tolist()} (expected [0, 1, 1])")
    print("[verify] NumPy 2.x / pybind11 ABI check passed (strides=(1,), labels=[0, 1, 1]).")


def verify_e2e() -> None:
    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available; pass --no-e2e to skip GPU verification.")

    import trimesh

    sphere = trimesh.creation.icosphere(subdivisions=3, radius=0.4)
    # Deliberately drop several faces so WTiVo has to repair an open mesh.
    open_faces = np.asarray(sphere.faces[:-6], dtype=np.int32)
    open_verts = np.asarray(sphere.vertices, dtype=np.float64)

    with tempfile.TemporaryDirectory(prefix="wtivo_verify_") as tmp:
        v_in = os.path.join(tmp, "v_in.npy")
        f_in = os.path.join(tmp, "f_in.npy")
        v_out = os.path.join(tmp, "v_out.npy")
        f_out = os.path.join(tmp, "f_out.npy")
        np.save(v_in, open_verts)
        np.save(f_in, open_faces)

        env = dict(os.environ)
        env["WTIVO_SUBPROCESS"] = "1"
        env["WTIVO_BUILD_DIR"] = str(BUILD_DIR)
        ld_parts = [str(BUILD_DIR)]
        if DEPS_LIB.is_dir():
            ld_parts.append(str(DEPS_LIB))
        if env.get("LD_LIBRARY_PATH"):
            ld_parts.append(env["LD_LIBRARY_PATH"])
        env["LD_LIBRARY_PATH"] = os.pathsep.join(ld_parts)

        subprocess.run(
            [
                sys.executable,
                str(NODE_ROOT / "wtivo.py"),
                "--input-vertices-npy", v_in,
                "--input-faces-npy", f_in,
                "--output-vertices-npy", v_out,
                "--output-faces-npy", f_out,
                "--input-res", "128",
                "--final-res", "128",
                "--proxy_points", "50000",
                "--lambda_fill", "20",
                "--threads", "4",
            ],
            env=env,
            check=True,
        )

        out_v = np.load(v_out)
        out_f = np.load(f_out)
        repaired = trimesh.Trimesh(vertices=out_v, faces=out_f, process=False)
        if not repaired.is_watertight:
            raise RuntimeError("E2E verification failed: output mesh is not watertight.")
        print(
            f"[verify] E2E GPU pipeline passed: {len(out_v):,} vertices / {len(out_f):,} faces | "
            f"watertight={repaired.is_watertight} | volume={repaired.volume:.5f}"
        )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--e2e", action="store_true", help="Run full GPU watertight reconstruction on a broken sphere")
    args = ap.parse_args()
    verify_imports_and_abi()
    if args.e2e:
        verify_e2e()


if __name__ == "__main__":
    main()
