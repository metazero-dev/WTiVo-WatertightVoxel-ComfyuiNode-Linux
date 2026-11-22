# SPDX-License-Identifier: GPL-3.0-or-later
# Portable Linux build for WTiVo native extensions (wtivo_core, wtivo_vdb, wtivo_gpupr).
# Supports Python 3.12+, PyTorch 2.8–2.11+ (CUDA 12.8–13.x), NumPy 2.x (pybind11 >= 3.0),
# and Ampere through Blackwell GPUs (including RTX 50-series sm_120).
cmake_minimum_required(VERSION 3.24)
project(WTiVoNativeLinux VERSION 1.3.0 LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(WTIVO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")
set(WTIVO_PYTHON "python3" CACHE FILEPATH "ComfyUI Python interpreter to compile against")
set(WTIVO_OUTPUT_DIR "${WTIVO_ROOT}/build" CACHE PATH "Output directory for compiled .so modules")
set(WTIVO_DEPS_PREFIX "${WTIVO_ROOT}/.deps/prefix" CACHE PATH "Optional rootless dependency prefix")

# Query pybind11, Torch install path, and GPU compute capability from WTIVO_PYTHON.
execute_process(
  COMMAND "${WTIVO_PYTHON}" -m pybind11 --cmakedir
  OUTPUT_VARIABLE WTIVO_PYBIND11_DIR
  OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND "${WTIVO_PYTHON}" -c "import pathlib, torch; print(pathlib.Path(torch.__file__).resolve().parent)"
  OUTPUT_VARIABLE WTIVO_TORCH_PREFIX
  OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY
)

if(NOT DEFINED TORCH_CUDA_ARCH_LIST OR "${TORCH_CUDA_ARCH_LIST}" STREQUAL "")
  execute_process(
    COMMAND "${WTIVO_PYTHON}" -c "import torch; c = torch.cuda.get_device_capability(0) if torch.cuda.is_available() else (8, 6); print(f'{c[0]}.{c[1]}')"
    OUTPUT_VARIABLE _DETECTED_ARCH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
  )
  set(TORCH_CUDA_ARCH_LIST "${_DETECTED_ARCH}" CACHE STRING "Target CUDA arch list for Torch" FORCE)
endif()
set(ENV{TORCH_CUDA_ARCH_LIST} "${TORCH_CUDA_ARCH_LIST}")

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  string(REPLACE "." "" _CUDA_ARCH_NUM "${TORCH_CUDA_ARCH_LIST}")
  string(REGEX MATCH "^[0-9]+" _CUDA_ARCH_FIRST "${_CUDA_ARCH_NUM}")
  if(_CUDA_ARCH_FIRST)
    set(CMAKE_CUDA_ARCHITECTURES "${_CUDA_ARCH_FIRST}")
  endif()
endif()

set(Python3_EXECUTABLE "${WTIVO_PYTHON}")
set(pybind11_DIR "${WTIVO_PYBIND11_DIR}" CACHE PATH "pybind11 >= 3.0 CMake dir (required for NumPy 2.x ABI)" FORCE)
list(PREPEND CMAKE_PREFIX_PATH "${WTIVO_TORCH_PREFIX}")

# Support optional rootless staging in .deps/prefix alongside standard /usr installs.
set(_WTIVO_EXTRA_INC "")
set(_WTIVO_EXTRA_RPATH "")
if(EXISTS "${WTIVO_DEPS_PREFIX}/usr")
  list(PREPEND CMAKE_PREFIX_PATH
    "${WTIVO_DEPS_PREFIX}/usr"
    "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu")
  if(EXISTS "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu/cmake/OpenVDB")
    list(PREPEND CMAKE_MODULE_PATH "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu/cmake/OpenVDB")
  endif()
  if(EXISTS "${WTIVO_DEPS_PREFIX}/usr/share/eigen3/cmake")
    set(Eigen3_DIR "${WTIVO_DEPS_PREFIX}/usr/share/eigen3/cmake")
  endif()
  if(EXISTS "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu/cmake/CGAL")
    set(CGAL_DIR "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu/cmake/CGAL")
  endif()
  set(Boost_ROOT "${WTIVO_DEPS_PREFIX}/usr")
  list(APPEND _WTIVO_EXTRA_INC
    "${WTIVO_DEPS_PREFIX}/usr/include"
    "${WTIVO_DEPS_PREFIX}/usr/include/x86_64-linux-gnu")
  list(APPEND _WTIVO_EXTRA_RPATH "${WTIVO_DEPS_PREFIX}/usr/lib/x86_64-linux-gnu")
endif()
if(EXISTS "/usr/lib/x86_64-linux-gnu/cmake/OpenVDB")
  list(APPEND CMAKE_MODULE_PATH "/usr/lib/x86_64-linux-gnu/cmake/OpenVDB")
endif()

find_package(Python3 3.12 REQUIRED COMPONENTS Interpreter Development.Module)
find_package(pybind11 3.0 CONFIG REQUIRED)
find_package(Eigen3 CONFIG REQUIRED)
find_package(CGAL CONFIG REQUIRED)
find_package(TBB CONFIG REQUIRED)
find_package(OpenVDB REQUIRED)

# PyTorch CUDA wheels (e.g. cu130) sometimes reference MKL in Caffe2Config without shipping libmkl.
# Generate an empty static archive stand-in if MKL is not installed on the host.
find_library(_SYSTEM_MKL_CORE NAMES mkl_core)
if(NOT _SYSTEM_MKL_CORE)
  set(_MKL_STUB_SRC "${CMAKE_BINARY_DIR}/wtivo_mkl_stub.c")
  set(_MKL_STUB_OBJ "${CMAKE_BINARY_DIR}/wtivo_mkl_stub.o")
  set(_MKL_STUB_LIB "${CMAKE_BINARY_DIR}/libwtivo_mkl_stub.a")
  if(NOT EXISTS "${_MKL_STUB_LIB}")
    file(WRITE "${_MKL_STUB_SRC}" "void wtivo_mkl_stub_symbol(void) {}\n")
    execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -x c -c "${_MKL_STUB_SRC}" -o "${_MKL_STUB_OBJ}" COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND "${CMAKE_AR}" rcs "${_MKL_STUB_LIB}" "${_MKL_STUB_OBJ}" COMMAND_ERROR_IS_FATAL ANY)
  endif()
  set(MKL_LIBRARIES "${_MKL_STUB_LIB}" CACHE FILEPATH "Empty MKL stand-in for PyTorch wheels without MKL" FORCE)
  set(MKL_INCLUDE_DIR "/usr/include" CACHE PATH "" FORCE)
endif()

find_package(Torch REQUIRED)

set(_WTIVO_TORCH_LIBS "")
foreach(_lib IN LISTS TORCH_LIBRARIES)
  if(NOT _lib STREQUAL "FALSE" AND NOT _lib STREQUAL "TRUE")
    list(APPEND _WTIVO_TORCH_LIBS "${_lib}")
  endif()
endforeach()

file(MAKE_DIRECTORY "${WTIVO_OUTPUT_DIR}")

find_package(CUDAToolkit REQUIRED)
get_filename_component(_CUDA_LIB_DIR "${CUDAToolkit_LIBRARY_DIR}" ABSOLUTE)

set(WTIVO_RPATH
  "\$ORIGIN"
  ${_WTIVO_EXTRA_RPATH}
  "${WTIVO_TORCH_PREFIX}/lib"
  "${_CUDA_LIB_DIR}")
set(CMAKE_BUILD_RPATH "${WTIVO_RPATH}")
set(CMAKE_INSTALL_RPATH "${WTIVO_RPATH}")
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)

function(wtivo_place target)
  set_target_properties(${target} PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${WTIVO_OUTPUT_DIR}"
    BUILD_RPATH "${WTIVO_RPATH}"
    INSTALL_RPATH "${WTIVO_RPATH}")
endfunction()

pybind11_add_module(wtivo_core "${WTIVO_ROOT}/native/core/wtivo_core.cpp")
target_link_libraries(wtivo_core PRIVATE CGAL::CGAL TBB::tbb TBB::tbbmalloc Eigen3::Eigen)
target_include_directories(wtivo_core PRIVATE ${_WTIVO_EXTRA_INC})
target_compile_definitions(wtivo_core PRIVATE CGAL_LINKED_WITH_TBB EIGEN_MPL2_ONLY)
target_compile_options(wtivo_core PRIVATE -O3)
wtivo_place(wtivo_core)

pybind11_add_module(wtivo_vdb "${WTIVO_ROOT}/native/vdb/wtivo_vdb.cpp")
target_link_libraries(wtivo_vdb PRIVATE OpenVDB::openvdb TBB::tbb TBB::tbbmalloc)
target_include_directories(wtivo_vdb PRIVATE ${_WTIVO_EXTRA_INC})
target_compile_options(wtivo_vdb PRIVATE -O3)
wtivo_place(wtivo_vdb)

pybind11_add_module(wtivo_gpupr
  "${WTIVO_ROOT}/native/gpupr/wtivo_gpupr_bindings.cpp"
  "${WTIVO_ROOT}/native/gpupr/gpu_push_relabel_fast.cu")
target_compile_definitions(wtivo_gpupr PRIVATE TORCH_EXTENSION_NAME=wtivo_gpupr)
target_include_directories(wtivo_gpupr PRIVATE
  "${TORCH_INCLUDE_DIRS}"
  "${WTIVO_ROOT}/native/gpupr"
  "${CUDAToolkit_INCLUDE_DIRS}")
target_link_libraries(wtivo_gpupr PRIVATE
  ${_WTIVO_TORCH_LIBS}
  "${WTIVO_TORCH_PREFIX}/lib/libtorch_python.so")
target_compile_options(wtivo_gpupr PRIVATE
  $<$<COMPILE_LANGUAGE:CUDA>:--expt-relaxed-constexpr;-O3>
  $<$<COMPILE_LANGUAGE:CXX>:-O3>)
wtivo_place(wtivo_gpupr)

message(STATUS "WTiVo Python    : ${Python3_EXECUTABLE}")
message(STATUS "WTiVo pybind11  : ${pybind11_VERSION} (${WTIVO_PYBIND11_DIR})")
message(STATUS "WTiVo CUDA arch : ${TORCH_CUDA_ARCH_LIST}")
message(STATUS "WTiVo output    : ${WTIVO_OUTPUT_DIR}")
