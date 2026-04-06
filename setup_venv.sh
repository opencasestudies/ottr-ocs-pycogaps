#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Robust project setup script
# - Creates/repairs a local venv (.venv)
# - Clones/updates PyCoGAPS + submodules
# - Checks out a pinned ref OR the repo’s default branch (auto-detected)
# - Builds the C++ extension + makes the pure-Python PyCoGAPS API importable
# - Registers a Jupyter kernel for Quarto/RStudio
# - Ensures _environment exports QUARTO_PYTHON/RETICULATE_PYTHON
# ------------------------------

# --- config ---
PYCOGAPS_REPO="https://github.com/FertigLab/pycogaps.git"

# Optional: pin for reproducibility (branch / tag / commit SHA)
# Examples:
#   PYCOGAPS_REF=master bash setup_venv.sh
#   PYCOGAPS_REF=<commit_sha> bash setup_venv.sh
PYCOGAPS_REF="${PYCOGAPS_REF:-}"

VENV_DIR="${VENV_DIR:-.venv}"
VENDOR_DIR="${VENDOR_DIR:-vendor}"
PYCOGAPS_DIR="${PYCOGAPS_DIR:-${VENDOR_DIR}/pycogaps}"

KERNEL_NAME="${KERNEL_NAME:-cogaps_sc}"
KERNEL_DISPLAY="${KERNEL_DISPLAY:-Python (cogaps_sc)}"

# If you want the ~2GB LFS data, run:
#   WITH_LFS_DATA=1 bash setup_venv.sh
WITH_LFS_DATA="${WITH_LFS_DATA:-0}"

# Force a clean rebuild of the venv
RECREATE_VENV="${RECREATE_VENV:-0}"

# If vendor/pycogaps exists, update it to the desired ref
UPDATE_VENDOR="${UPDATE_VENDOR:-1}"

ENV_FILE="${ENV_FILE:-_environment}"

PROJECT_ROOT="$(pwd)"
VENV_PY="${PROJECT_ROOT}/${VENV_DIR}/bin/python"

echo "==> Using python3 at: $(command -v python3)"
python3 --version

# ------------------------------
# Venv: create or repair
# ------------------------------
if [ "${RECREATE_VENV}" = "1" ]; then
  echo "==> RECREATE_VENV=1: removing existing ${VENV_DIR}"
  rm -rf "${VENV_DIR}"
fi

if [ -d "${VENV_DIR}" ] && [ ! -x "${VENV_DIR}/bin/python" ]; then
  echo "==> Found partial/broken venv (${VENV_DIR}); removing"
  rm -rf "${VENV_DIR}"
fi

if [ ! -d "${VENV_DIR}" ]; then
  echo "==> Creating venv (${VENV_DIR})"
  python3 -m venv "${VENV_DIR}"
else
  echo "==> Using existing venv (${VENV_DIR})"
fi

echo "==> Upgrading pip/build tools"
"${VENV_PY}" -m pip install -U pip setuptools wheel

echo "==> Installing base notebook requirements"
# requirements.txt should include jupyter + ipykernel at minimum
"${VENV_PY}" -m pip install -r requirements.txt

# ------------------------------
# Ensure _environment exports the right Python for Quarto/reticulate
# ------------------------------
ensure_env_exports () {
  local file="${1}"

  ensure_export_line () {
    local target_file="${1}"
    local key="${2}"
    local value="${3}"

    if grep -qE "^\s*export\s+${key}=" "${target_file}"; then
      sed -i.bak -E "s|^\s*export\s+${key}=.*$|export ${key}=\"${value}\"|" "${target_file}"
      rm -f "${target_file}.bak"
    else
      echo "export ${key}=\"${value}\"" >> "${target_file}"
    fi
  }

  # Create if missing
  if [ ! -f "${file}" ]; then
    cat > "${file}" <<'EOF'
#!/usr/bin/env bash

# Resolve the project root from this file's own location so the environment
# works even when sourced outside the repo root.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _cogaps_env_file="${BASH_SOURCE[0]}"
else
  _cogaps_env_file="$0"
fi

export COGAPS_PROJECT_ROOT="$(cd "$(dirname "${_cogaps_env_file}")" && pwd)"
export VIRTUAL_ENV="${COGAPS_PROJECT_ROOT}/.venv"

case ":${PATH}:" in
  *":${VIRTUAL_ENV}/bin:"*) ;;
  *) export PATH="${VIRTUAL_ENV}/bin:${PATH}" ;;
esac

# Force Quarto + reticulate to use the project venv.
export QUARTO_PYTHON="${VIRTUAL_ENV}/bin/python"
export RETICULATE_PYTHON="${VIRTUAL_ENV}/bin/python"

# Thread limits (keeps containers predictable)
export OMP_NUM_THREADS="4"
export OPENBLAS_NUM_THREADS="4"
export MKL_NUM_THREADS="4"
export NUMEXPR_NUM_THREADS="4"
EOF
    chmod +x "${file}" || true
    return
  fi

  # Add the project-root bootstrap if it is missing.
  if ! grep -qE '^\s*export\s+COGAPS_PROJECT_ROOT=' "${file}"; then
    cat >> "${file}" <<'EOF'

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _cogaps_env_file="${BASH_SOURCE[0]}"
else
  _cogaps_env_file="$0"
fi

export COGAPS_PROJECT_ROOT="$(cd "$(dirname "${_cogaps_env_file}")" && pwd)"
export VIRTUAL_ENV="${COGAPS_PROJECT_ROOT}/.venv"

case ":${PATH}:" in
  *":${VIRTUAL_ENV}/bin:"*) ;;
  *) export PATH="${VIRTUAL_ENV}/bin:${PATH}" ;;
esac
EOF
  fi

  if ! grep -qE '^\s*export\s+VIRTUAL_ENV=' "${file}"; then
    echo 'export VIRTUAL_ENV="${COGAPS_PROJECT_ROOT}/.venv"' >> "${file}"
  fi
  if ! grep -q '\${VIRTUAL_ENV}/bin:\${PATH}' "${file}"; then
    cat >> "${file}" <<'EOF'
case ":${PATH}:" in
  *":${VIRTUAL_ENV}/bin:"*) ;;
  *) export PATH="${VIRTUAL_ENV}/bin:${PATH}" ;;
esac
EOF
  fi

  ensure_export_line "${file}" "QUARTO_PYTHON" '${VIRTUAL_ENV}/bin/python'
  ensure_export_line "${file}" "RETICULATE_PYTHON" '${VIRTUAL_ENV}/bin/python'
}

echo "==> Ensuring ${ENV_FILE} exports QUARTO_PYTHON/RETICULATE_PYTHON"
ensure_env_exports "${ENV_FILE}"

# ------------------------------
# Clone or update PyCoGAPS
# ------------------------------
echo "==> Preparing PyCoGAPS source in ${PYCOGAPS_DIR}"
mkdir -p "${VENDOR_DIR}"

if [ ! -d "${PYCOGAPS_DIR}/.git" ]; then
  echo "==> Cloning PyCoGAPS (with submodules)"
  if [ "${WITH_LFS_DATA}" = "1" ]; then
    git clone "${PYCOGAPS_REPO}" "${PYCOGAPS_DIR}" --recursive
  else
    # Skip Git LFS large files by default (faster for teaching)
    GIT_LFS_SKIP_SMUDGE=1 git clone "${PYCOGAPS_REPO}" "${PYCOGAPS_DIR}" --recursive
  fi
else
  echo "==> Found existing repo at ${PYCOGAPS_DIR}"
  if [ "${UPDATE_VENDOR}" = "1" ]; then
    echo "==> UPDATE_VENDOR=1: will fetch/checkout requested ref"
  else
    echo "==> UPDATE_VENDOR=0: will not fetch; using current working tree"
  fi
fi

cd "${PYCOGAPS_DIR}"

# ------------------------------
# Resolve a default ref if user didn’t supply PYCOGAPS_REF
# ------------------------------
detect_default_branch () {
  local b=""

  # Most reliable on many git versions
  b="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)"
  if [ -n "${b}" ]; then
    echo "${b}"
    return
  fi

  # Sometimes origin/HEAD is set
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  if [ -n "${b}" ]; then
    echo "${b}"
    return
  fi

  # Fallback preference
  for cand in master main; do
    if git show-ref --verify --quiet "refs/remotes/origin/${cand}"; then
      echo "${cand}"
      return
    fi
  done

  # Last resort
  echo "master"
}

if [ -z "${PYCOGAPS_REF}" ]; then
  PYCOGAPS_REF="$(detect_default_branch)"
fi

if [ "${UPDATE_VENDOR}" = "1" ]; then
  echo "==> Fetching origin + tags"
  git fetch --all --tags --prune
fi

echo "==> Checking out PyCoGAPS ref: ${PYCOGAPS_REF}"

# Robust checkout:
# - commit SHA / tag / branch all work if fetched
if git rev-parse -q --verify "${PYCOGAPS_REF}^{commit}" >/dev/null 2>&1; then
  # commit or tag resolved to commit
  git checkout --detach "${PYCOGAPS_REF}"
elif git show-ref --verify --quiet "refs/remotes/origin/${PYCOGAPS_REF}"; then
  # remote branch exists
  git checkout -B "${PYCOGAPS_REF}" "origin/${PYCOGAPS_REF}"
else
  # try local branch or tag name
  if ! git checkout "${PYCOGAPS_REF}"; then
    echo ""
    echo "ERROR: Could not checkout PYCOGAPS_REF='${PYCOGAPS_REF}'."
    echo "Available remote branches (first 30):"
    git branch -r | head -n 30 || true
    echo ""
    exit 1
  fi
fi

echo "==> Updating submodules"
git submodule update --init --recursive

# ------------------------------
# Install PyCoGAPS Python deps from repo requirements
# ------------------------------
echo "==> Installing PyCoGAPS Python dependencies (from source repo requirements.txt)"
"${VENV_PY}" -m pip install -r requirements.txt

# ------------------------------
# Ensure Boost headers are present (needed by CoGAPS core)
# ------------------------------
echo "==> Checking for Boost C++ headers (required by CoGAPS core)"
BOOST_HEADER="boost/align/aligned_allocator.hpp"

need_boost_msg () {
  cat <<'EOF'
ERROR: Missing Boost C++ headers (required to build CoGAPS core).

Fix:

macOS (recommended):
  1) Install Homebrew (if needed): https://brew.sh
  2) brew install boost
  3) Re-run this script.

Linux (Debian/Ubuntu):
  sudo apt-get update
  sudo apt-get install -y libboost-all-dev build-essential git

Windows:
  Recommended: use WSL2 Ubuntu and follow Linux steps,
  OR install Boost via a C++ package manager (vcpkg) and ensure headers are discoverable.
EOF
}

have_boost=0
BOOST_PREFIX=""

if command -v brew >/dev/null 2>&1; then
  if brew list boost >/dev/null 2>&1; then
    BOOST_PREFIX="$(brew --prefix boost)"
    if [ -f "${BOOST_PREFIX}/include/${BOOST_HEADER}" ]; then
      have_boost=1
    fi
  fi
fi

if [ "${have_boost}" = "0" ]; then
  if [ -f "/opt/homebrew/include/${BOOST_HEADER}" ]; then
    have_boost=1
    BOOST_PREFIX="/opt/homebrew"
  elif [ -f "/usr/local/include/${BOOST_HEADER}" ]; then
    have_boost=1
    BOOST_PREFIX="/usr/local"
  elif [ -f "/usr/include/${BOOST_HEADER}" ]; then
    have_boost=1
    BOOST_PREFIX="/usr"
  fi
fi

if [ "${have_boost}" = "0" ]; then
  uname_s="$(uname -s)"
  if [ "${uname_s}" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    echo "   Boost not found; attempting: brew install boost"
    brew install boost
    BOOST_PREFIX="$(brew --prefix boost)"
    if [ -f "${BOOST_PREFIX}/include/${BOOST_HEADER}" ]; then
      have_boost=1
    fi
  fi
fi

if [ "${have_boost}" = "0" ]; then
  need_boost_msg
  exit 1
fi

echo "   Found Boost include dir: ${BOOST_PREFIX}/include"

# Ensure compilation targets the same architecture as the Python interpreter (macOS only)
PY_ARCH="$("${VENV_PY}" -c "import platform; print(platform.machine())")"
echo "==> Python interpreter architecture: ${PY_ARCH}"

export CPPFLAGS="-I${BOOST_PREFIX}/include ${CPPFLAGS:-}"
export CXXFLAGS="-I${BOOST_PREFIX}/include ${CXXFLAGS:-}"
export LDFLAGS="-L${BOOST_PREFIX}/lib ${LDFLAGS:-}"

# ARCHFLAGS is macOS-specific; do not set on Linux (e.g., inside Docker).
if [ "$(uname -s)" = "Darwin" ]; then
  export ARCHFLAGS="-arch ${PY_ARCH}"
fi

# ------------------------------
# Build/install the C++ extension
# ------------------------------
echo "==> Installing PyCoGAPS C++ extension from local source via pip"
"${VENV_PY}" -m pip install . --no-deps --no-build-isolation

# Return to project root
cd "${PROJECT_ROOT}"

# ------------------------------
# Make the pure-Python PyCoGAPS API importable everywhere via .pth
# ------------------------------
echo "==> Making the PyCoGAPS *Python* package importable"
SITE_PACKAGES="$("${VENV_PY}" -c "import site; print(site.getsitepackages()[0])")"
echo "${PROJECT_ROOT}/${PYCOGAPS_DIR}" > "${SITE_PACKAGES}/pycogaps_vendor.pth"
echo "   Wrote: ${SITE_PACKAGES}/pycogaps_vendor.pth -> ${PROJECT_ROOT}/${PYCOGAPS_DIR}"

echo "==> Verifying imports"
"${VENV_PY}" -c "import pycogaps; from PyCoGAPS.parameters import CoParams; print('✅ pycogaps + PyCoGAPS imports OK')"

echo "==> Registering Jupyter kernel for Quarto (project-local)"
"${VENV_PY}" -m ipykernel install \
  --prefix "${PROJECT_ROOT}/${VENV_DIR}" \
  --name "${KERNEL_NAME}" \
  --display-name "${KERNEL_DISPLAY}"

echo ""
echo "✅ Setup complete."
echo "Next:"
echo "  source ${ENV_FILE}"
echo "  quarto check jupyter"
echo "  quarto render cogaps_case_study4_student.qmd"
