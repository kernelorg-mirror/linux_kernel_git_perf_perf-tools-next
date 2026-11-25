#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Check jevents.py reports unknown keys as errors (no_mlock)
#
# A key that is spelled differently is dropped without a word, so jevents.py
# compares the keys of each object in a table against the keys a table may
# carry and fails on anything else.

jevents=$(dirname "$0")/../../pmu-events/jevents.py
python=${PYTHON:-python3}

# An installed perf has the test but not the generator, and a python that is
# not there or too old to run it is a skip, not a failure of the check.
[ -r "${jevents}" ] || exit 2
[ "$("${python}" -c 'import sys; print(sys.version_info >= (3, 9))' 2>/dev/null)" = True ] \
  || exit 2

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "${tmp}"' EXIT HUP INT TERM
tables="${tmp}/arch/x86/model"
mkdir -p "${tables}" "${tmp}/arch/common"
printf '[]\n' > "${tmp}/arch/common/empty.json"
printf 'Family-model,Version,Filename,EventType\nGenuineIntel-6-97,v1.0,model,core\n' \
  > "${tmp}/arch/x86/mapfile.csv"
printf '[{"EventName": "a", "NotAKey": "x"}]\n' > "${tables}/events.json"

if "${python}" -B "${jevents}" x86 all "${tmp}/arch" \
    "${tmp}/pmu-events.c" "${tmp}/pmu-events-string.c" \
    > "${tmp}/out" 2> "${tmp}/err"; then
  echo "jevents.py accepted a key it does not read" >&2
  exit 1
fi

# The generator says which file it was reading, and the exception says which
# key it did not expect.
grep -qF -- "Exception processing" "${tmp}/out" || {
  echo "jevents.py failed without naming the file" >&2
  cat "${tmp}/out" "${tmp}/err" >&2
  exit 1
}
grep -qF -- "${tables}/events.json" "${tmp}/out" || {
  echo "jevents.py failed without naming the path" >&2
  cat "${tmp}/out" "${tmp}/err" >&2
  exit 1
}
grep -qF -- "NotAKey" "${tmp}/err" || {
  echo "jevents.py failed without naming the key" >&2
  cat "${tmp}/out" "${tmp}/err" >&2
  exit 1
}

exit 0
