#!/usr/bin/env bash
#
# mayhem/test.sh — RUN thefuzz's own pytest suite (the functional oracle).
#
# build.sh already created the venv and installed thefuzz (editable) + pytest +
# hypothesis + pycodestyle. This script only RUNS the suite and maps the result
# to a CTRF summary; it never compiles or installs.
#
# The suite is the UPSTREAM one (tox.ini: pytest over test_thefuzz.py,
# test_thefuzz_pytest.py, test_thefuzz_hypothesis.py) and is BEHAVIORAL: it
# asserts exact scorer values, extraction results and dedupe/processing output,
# so a PATCH that neuters thefuzz to a no-op FAILS here — satisfying the
# anti-reward-hacking oracle requirement (§6.3).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

VENV="${THEFUZZ_VENV:-/opt/toolchains/python/venv}"
PY="$VENV/bin/python"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker); returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$PY" ]; then
  echo "test.sh: venv python missing at $PY — build.sh must run first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

JUNIT="$(mktemp /tmp/thefuzz-junit.XXXXXX.xml)"
# Run the full upstream suite; emit JUnit XML for machine-readable counts. Don't
# let a non-zero pytest exit abort the script before we parse + emit CTRF.
set +e
"$PY" -m pytest test_thefuzz.py test_thefuzz_pytest.py test_thefuzz_hypothesis.py \
  -p no:cacheprovider \
  -q --no-header \
  --junit-xml="$JUNIT"
set -e

# Map JUnit -> CTRF counts.
read -r P F S < <("$PY" - "$JUNIT" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    print("0 1 0"); sys.exit(0)
suites = root.findall("testsuite") or ([root] if root.tag == "testsuite" else [])
tests = errors = failures = skipped = 0
for s in suites:
    tests   += int(s.get("tests", 0))
    errors  += int(s.get("errors", 0))
    failures+= int(s.get("failures", 0))
    skipped += int(s.get("skipped", 0))
failed = errors + failures
passed = tests - failed - skipped
if passed < 0:
    passed = 0
print(f"{passed} {failed} {skipped}")
PY
)
rm -f "$JUNIT"

emit_ctrf "pytest" "${P:-0}" "${F:-1}" "${S:-0}"
