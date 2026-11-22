# SPDX-License-Identifier: GPL-3.0-or-later
"""Locate the WTiVo backend (wtivo.py + compiled extensions) and build the worker environment."""

from __future__ import annotations

import os
import sys
from pathlib import Path

NODE_ROOT = Path(__file__).resolve().parent
EXT_GLOBS = ("wtivo_core*.so", "wtivo_vdb*.so", "wtivo_gpupr*.so")
INSTALL_HINT = "Run scripts/install_linux.sh --python /path/to/ComfyUI/.venv/bin/python in the WTiVo node folder."


class WTiVoSetupError(RuntimeError):
    pass


def backend_dir() -> Path:
    """Resolve backend directory:
    1. $WTIVO_HOME if explicitly set (strict; does not fall back)
    2. <node>/backend if present (compatibility with split-repo layout)
    3. <node> itself (self-contained single-tree layout)
    """
    env_home = os.environ.get("WTIVO_HOME")
    if env_home:
        return Path(env_home).expanduser().resolve()
    cand_backend = NODE_ROOT / "backend"
    if (cand_backend / "wtivo.py").is_file():
        return cand_backend.resolve()
    return NODE_ROOT


def build_dir(backend: Path | None = None) -> Path:
    """WTIVO_BUILD_DIR if set, otherwise <backend>/build."""
    env = os.environ.get("WTIVO_BUILD_DIR")
    return Path(env).expanduser().resolve() if env else (backend or backend_dir()) / "build"


def worker_python() -> str:
    """WTIVO_PYTHON if set, otherwise the interpreter running ComfyUI."""
    return os.environ.get("WTIVO_PYTHON") or sys.executable


def resolve():
    """Return (python, wtivo_script, build_dir), raising WTiVoSetupError with a fix hint."""
    backend = backend_dir()
    script = backend / "wtivo.py"
    if not script.is_file():
        raise WTiVoSetupError(f"WTiVo backend not found at {backend} (missing wtivo.py). {INSTALL_HINT}")
    if "--input-vertices-npy" not in script.read_text(encoding="utf-8", errors="replace"):
        raise WTiVoSetupError(
            f"The backend at {backend} is too old (no .npy bridge). "
            f"Update it and rebuild with {INSTALL_HINT}"
        )
    build = build_dir(backend)
    missing = [g.split("*")[0] for g in EXT_GLOBS if not list(build.glob(g))]
    if missing:
        raise WTiVoSetupError(
            f"Compiled WTiVo extension(s) missing in {build}: {', '.join(missing)}. {INSTALL_HINT}"
        )
    return worker_python(), script, build


def worker_env(build: Path) -> dict:
    env = dict(os.environ)
    env["WTIVO_SUBPROCESS"] = "1"
    env["WTIVO_BUILD_DIR"] = str(build)
    env["PYTHONUNBUFFERED"] = "1"
    deps_lib = NODE_ROOT / ".deps" / "prefix" / "usr" / "lib" / "x86_64-linux-gnu"
    ld_parts = [str(build)]
    if deps_lib.is_dir():
        ld_parts.append(str(deps_lib))
    existing_ld = env.get("LD_LIBRARY_PATH", "")
    if existing_ld:
        ld_parts.append(existing_ld)
    env["LD_LIBRARY_PATH"] = os.pathsep.join(ld_parts)
    return env
