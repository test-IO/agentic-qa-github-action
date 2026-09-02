#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=8771
BASE="http://127.0.0.1:$PORT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

start_stub() {
  python3 "$ROOT/tests/stub_api.py" "$1" "$PORT" "$WORK" &
  STUB_PID=$!
  curl -s --retry 30 --retry-connrefused --retry-delay 1 -o /dev/null \
    -H 'Authorization: ApiKey x' "$BASE/api/v1/token/verify" || true
}

stop_stub() {
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
}

# run_action <mode> <expected-exit> <label> [EXTRA_ENV=...]
run_action() {
  local mode="$1" expected="$2" label="$3"; shift 3
  start_stub "$mode"
  : > "$WORK/output"; : > "$WORK/summary"
  env \
    GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
    GITHUB_WORKFLOW="CI" GITHUB_SHA="abc1234567" GITHUB_RUN_NUMBER="14" \
    AQ_HOST="$BASE" AQ_TOKEN="secret-token" AQ_PROJECT_ID="proj-1" \
    AQ_CHECK_SUITE_ID="suite-1" AQ_URL="https://staging.example.com" AQ_ENVIRONMENT_ID="" \
    AQ_SESSION_NAME="" AQ_WORKFLOW_TYPE="web" AQ_BROWSER_TYPE="chrome" AQ_VIEWPORT="1280x800" \
    AQ_USE_REPLAYS="false" AQ_AWAIT_COMPLETION="true" AQ_CONTINUE_ON_FAILURE="false" \
    AQ_FAIL_ON_BLOCKED="true" AQ_TIMEOUT_SECONDS="60" AQ_POLL_INTERVAL_SECONDS="1" \
    AQ_JUNIT_PATH="$WORK/report.xml" \
    "$@" bash "$ROOT/scripts/run.sh" > "$WORK/log" 2>&1
  # shellcheck disable=SC2319  # $? is the run above; `local rc` would reset it
  local rc=$?
  stop_stub
  if [[ "$rc" == "$expected" ]]; then
    echo "ok   $label"
    pass=$((pass + 1))
  else
    echo "FAIL $label — exit $rc, wanted $expected"
    sed 's/^/       /' "$WORK/log"
    fail=$((fail + 1))
  fi
}

assert_file_has() {
  if grep -qF "$2" "$1"; then
    echo "ok   $3"
    pass=$((pass + 1))
  else
    echo "FAIL $3 — '$2' not found in $1"
    fail=$((fail + 1))
  fi
}

run_action mixed 1 "fails the build when a check fails"
assert_file_has "$WORK/output" "checks-failed=1"  "reports the failed count"
assert_file_has "$WORK/output" "checks-passed=1"  "reports the passed count"
assert_file_has "$WORK/output" "checks-blocked=1" "reports the blocked count"
assert_file_has "$WORK/output" "status=completed" "reports the session status"
assert_file_has "$WORK/summary" "| Failed | 1 |" "writes a job summary"
assert_file_has "$WORK/payload.json" '"workflow_type": "web"' "sends workflow_type"
assert_file_has "$WORK/payload.json" '"test_urls"' "sends test_urls"
assert_file_has "$WORK/payload.json" '"name": "CI abc1234 #14"' "names the session with the run number"

if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$WORK/report.xml"; then
  echo "ok   writes valid JUnit XML"
  pass=$((pass + 1))
else
  echo "FAIL JUnit XML is not well formed"
  fail=$((fail + 1))
fi
assert_file_has "$WORK/report.xml" "&lt;Submit&gt;" "escapes XML in check output"

run_action green 0 "passes the build when every check passes"
run_action mixed 0 "honours continue-on-failure"   AQ_CONTINUE_ON_FAILURE=true
run_action blocked 0 "ignores blocked when fail-on-blocked is false" AQ_FAIL_ON_BLOCKED=false
run_action blocked 1 "fails on blocked by default"
run_action mixed 0 "skips waiting when await-completion is false" AQ_AWAIT_COMPLETION=false
run_action mixed 1 "rejects a missing url and environment-id" AQ_URL=
run_action mixed 1 "times out instead of hanging" AQ_TIMEOUT_SECONDS=0
run_action expired 1 "reports an expired token"
run_action empty 1 "fails when the suite produced no checks"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
