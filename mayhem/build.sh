#!/usr/bin/env bash
#
# mayhem/build.sh — build the thefuzz fuzz harness + ready the functional test suite.
#
# thefuzz is PURE PYTHON (fuzzy string matching on top of rapidfuzz). The fuzzed
# code is the fuzz.* scorers and process.extract/extractOne handling
# attacker-controlled strings. Mayhem targets must be a native ELF that libFuzzer
# drives (fuzz-smoke + the DWARF gate), so we compile a small C driver
# (mayhem/fuzz_ratio_driver.c) that EMBEDS CPython and dispatches each input into
# fuzz_ratio.TestOneInput — the matcher stays 100% Python, the target is a real
# libFuzzer ELF carrying DWARF < 4 symbols.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base
# image exports the build contract (CC, CXX, SANITIZER_FLAGS, DEBUG_FLAGS,
# LIB_FUZZING_ENGINE, STANDALONE_FUZZ_MAIN, SRC). Idempotent + air-gapped: a wheelhouse
# is baked into the image (mayhem/Dockerfile) so the offline PATCH re-run installs from
# it with --no-index; recompiling the harness on the already-built tree just re-links.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (overridable), with sane fallbacks.
# SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty value (the sanitizer
# off-switch) is honored; the others default on empty too.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS SRC

cd "$SRC"

# Wheelhouse baked by the Dockerfile (offline install source for the PATCH re-run).
WHEELHOUSE="${THEFUZZ_WHEELHOUSE:-/opt/toolchains/python/wheelhouse}"

# ---------------------------------------------------------------------------
# 1) Install the project + its test deps into a fixed, $HOME-independent venv so
#    mayhem/test.sh only RUNS the suite. Pure Python: no sanitizer build here —
#    the suite is the honest functional oracle (project's NORMAL install).
#    --no-index --find-links keeps it air-gapped (resolves from the wheelhouse).
# ---------------------------------------------------------------------------
VENV="${THEFUZZ_VENV:-/opt/toolchains/python/venv}"
# `--copies`: put a REAL interpreter binary at the venv path (not a symlink to the
# system python) so (1) it lives at a fixed $HOME-independent location, and (2) the
# anti-reward-hack sabotage check neuters non-system executables — a copied
# interpreter under /opt/toolchains IS neutered, so a no-op'd thefuzz makes the
# suite fail, proving the oracle is behavioral (§6.3).
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv --copies "$VENV"
fi

pip_install() {
  local attempt rc
  for attempt in 1 2 3; do
    "$VENV/bin/python" -m pip install --no-index --find-links="$WHEELHOUSE" "$@" && return 0
    rc=$?
    echo "build.sh: pip install ($*) attempt ${attempt} failed (rc=${rc}); retrying" >&2
    sleep 1
  done
  echo "build.sh: pip install ($*) failed after retries (rc=${rc})" >&2
  return "${rc:-1}"
}

pip_install --upgrade pip >/dev/null 2>&1 || true
# Test deps (tox.ini: pytest, pycodestyle, hypothesis) + the runtime dep rapidfuzz.
pip_install pytest hypothesis pycodestyle rapidfuzz
# The build backend (setuptools/wheel) goes in FIRST so the editable install can
# run with build isolation OFF (offline — no PEP 517 isolated env reaching PyPI).
pip_install setuptools wheel
# Install thefuzz itself (editable so test.sh exercises the in-tree source the
# agent may patch). Build isolation off + no index → resolves setuptools locally.
pip_install --no-build-isolation -e .

# ---------------------------------------------------------------------------
# 2) Build the native fuzz harness ELF that embeds CPython. The driver itself is
#    instrumented with $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF < 4); libpython is
#    linked via python3-config --embed. PYFUZZ_PATHS points sys.path at the
#    harness dir, the repo root (in-tree thefuzz package) and the venv
#    site-packages (rapidfuzz) so the embedded interpreter imports everything.
# ---------------------------------------------------------------------------
PYCFG="${PYTHON_CONFIG:-python3-config}"
PY_CFLAGS="$("$PYCFG" --cflags)"
PY_EMBED_LDFLAGS="$("$PYCFG" --embed --ldflags 2>/dev/null || "$PYCFG" --ldflags)"

SITEPKG="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"

# Tokens are inserted at sys.path position 0 in order, so the LAST token ends up
# FIRST — list venv site-packages, then mayhem, then the repo root so the in-tree
# thefuzz package wins over any installed copy.
DEFS=(
  -DPYFUZZ_MODULE='"fuzz_ratio"'
  -DPYFUZZ_FUNC='"TestOneInput"'
  -DPYFUZZ_PATHS="\"$SITEPKG:$SRC/mayhem:$SRC\""
)

# 2a) The fuzzer binary (linked against the libFuzzer engine).
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $PY_CFLAGS "${DEFS[@]}" $LIB_FUZZING_ENGINE \
  "$SRC/mayhem/fuzz_ratio_driver.c" \
  -o /mayhem/ratio \
  $PY_EMBED_LDFLAGS

# 2b) The standalone (NON-fuzzer) run-once reproducer (linked against the LLVM
#     standalone driver instead of the libFuzzer engine). Respects $SANITIZER_FLAGS.
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $PY_CFLAGS "${DEFS[@]}" \
  "$STANDALONE_FUZZ_MAIN" \
  "$SRC/mayhem/fuzz_ratio_driver.c" \
  -o /mayhem/ratio-standalone \
  $PY_EMBED_LDFLAGS

echo "build.sh: built /mayhem/ratio (+ -standalone) and installed the test venv"
