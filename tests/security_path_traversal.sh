#!/usr/bin/env bash
# Regression test: exec_location_script() must not execute scripts outside
# $CONFIG_DIR (path traversal / arbitrary script execution).
#
# The Wi-Fi SSID (and alias config) flows into the location name that is used
# to build and execute a script path. A hostile network can influence the SSID,
# so an unsafe location name (path separators, "..") must be refused before it
# reaches the filesystem or is executed.
#
# This test extracts the real exec_location_script() from wifi-loc-control.sh so
# it exercises the actual code, not a re-implementation.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/wifi-loc-control.sh"

log() { echo "LOG: $*"; }

# Extract the actual is_safe_location_name() + exec_location_script() bodies from
# the script under test (exec_location_script depends on is_safe_location_name).
FN_BODY="$(sed -n '/^is_safe_location_name() {/,/^}$/p' "$SCRIPT")"
FN_BODY+=$'\n'
FN_BODY+="$(sed -n '/^exec_location_script() {/,/^}$/p' "$SCRIPT")"

pass=0
fail=0

# Run exec_location_script() (real code) with a given location in a temp config dir.
# Prints the combined stdout/stderr to stdout.
run_location() {
  local location="$1"
  local CONFIG_DIR
  CONFIG_DIR="$(mktemp -d)"

  # A script outside the config dir that must never be executed.
  local outside_target="$CONFIG_DIR/../outside_script"
  printf '#!/usr/bin/env bash\necho OUTSIDE_SCRIPT_EXECUTED\n' > "$outside_target"
  chmod +x "$outside_target"

  # A legit script inside the config dir.
  local safe_script="$CONFIG_DIR/safe_script"
  printf '#!/usr/bin/env bash\necho SAFE_SCRIPT_EXECUTED\n' > "$safe_script"
  chmod +x "$safe_script"

  local harness
  harness="$(mktemp)"
  {
    echo 'log() { echo "LOG: $*"; }'
    echo "CONFIG_DIR=$CONFIG_DIR"
    echo "$FN_BODY"
    echo 'exec_location_script "$1"'
  } > "$harness"
  chmod +x "$harness"
  bash "$harness" "$location" 2>&1
  rm -rf "$CONFIG_DIR" "$harness"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $msg"
    pass=$((pass + 1))
  else
    echo "FAIL: $msg (expected output to contain: $needle)"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $msg"
    pass=$((pass + 1))
  else
    echo "FAIL: $msg (expected output NOT to contain: $needle)"
    fail=$((fail + 1))
  fi
}

echo "=== safe location inside CONFIG_DIR is still executed (functionality guard) ==="
out="$(run_location "safe_script")"
assert_contains "$out" "SAFE_SCRIPT_EXECUTED" "safe in-dir script executed"

echo "=== traversal location (..) must NOT execute an outside script ==="
out="$(run_location "../outside_script")"
assert_not_contains "$out" "OUTSIDE_SCRIPT_EXECUTED" "traversal script not executed"
assert_contains "$out" "refusing to execute" "unsafe location refused"

echo "=== empty location must be refused, not executed ==="
out="$(run_location "")"
assert_not_contains "$out" "OUTSIDE_SCRIPT_EXECUTED" "empty location not executed"
assert_contains "$out" "refusing to execute" "empty location refused"

echo "=== location with path separator must be refused ==="
out="$(run_location "a/b")"
assert_not_contains "$out" "OUTSIDE_SCRIPT_EXECUTED" "slash location not executed"
assert_contains "$out" "refusing to execute" "slash location refused"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
