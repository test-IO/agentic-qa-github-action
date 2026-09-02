#!/usr/bin/env bash
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required but not installed on this runner."
done

[[ -n "${AQ_HOST:-}" ]]           || die "host is required."
[[ -n "${AQ_TOKEN:-}" ]]          || die "token is required."
[[ -n "${AQ_PROJECT_ID:-}" ]]     || die "project-id is required."
[[ -n "${AQ_CHECK_SUITE_ID:-}" ]] || die "check-suite-id is required."

echo "::add-mask::$AQ_TOKEN"

: "${AQ_URL:=}"
: "${AQ_ENVIRONMENT_ID:=}"
: "${AQ_SESSION_NAME:=}"
: "${AQ_WORKFLOW_TYPE:=web}"
: "${AQ_BROWSER_TYPE:=}"
: "${AQ_VIEWPORT:=}"
: "${AQ_USE_REPLAYS:=false}"
: "${AQ_AWAIT_COMPLETION:=true}"
: "${AQ_CONTINUE_ON_FAILURE:=false}"
: "${AQ_FAIL_ON_BLOCKED:=true}"
: "${AQ_TIMEOUT_SECONDS:=1800}"
: "${AQ_POLL_INTERVAL_SECONDS:=15}"
: "${AQ_JUNIT_PATH:=}"

HOST="${AQ_HOST%/}"

is_true() { [[ "${1,,}" == "true" ]]; }

API_STATUS=""
API_BODY=""

api() {
  local method="$1" path="$2" data="${3:-}"
  local body_file
  body_file=$(mktemp)
  local -a args=(
    -sS -o "$body_file" -w '%{http_code}'
    -X "$method"
    -H "Authorization: ApiKey $AQ_TOKEN"
    -H 'Accept: application/json'
    --max-time 60
  )
  if [[ -n "$data" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$data")
  fi
  if ! API_STATUS=$(curl "${args[@]}" "$HOST$path" 2>&1); then
    rm -f "$body_file"
    die "could not reach $HOST — check the host input and that the runner can reach it."
  fi
  API_BODY=$(cat "$body_file")
  rm -f "$body_file"
}

api_error() {
  local msg
  msg=$(jq -r '.error // empty' <<<"$API_BODY" 2>/dev/null || true)
  if [[ -n "$msg" ]]; then
    printf '%s' "$msg"
  else
    printf 'HTTP %s' "$API_STATUS"
  fi
}

api GET "/api/v1/token/verify"
case "$API_STATUS" in
  200) ;;
  401) die "token is missing or malformed." ;;
  403) die "token is expired or revoked. Tokens last one month — mint a new one and update the secret." ;;
  *)   die "token check failed: $(api_error)" ;;
esac

if [[ -z "$AQ_URL" && -z "$AQ_ENVIRONMENT_ID" ]]; then
  die "either url or environment-id must be set."
fi

session_name="$AQ_SESSION_NAME"
if [[ -z "$session_name" ]]; then
  sha="${GITHUB_SHA:-}"
  session_name="${GITHUB_WORKFLOW:-CI} ${sha:0:7}"
fi

if is_true "$AQ_USE_REPLAYS"; then replays_json=true; else replays_json=false; fi

payload=$(jq -n \
  --arg name "$session_name" \
  --arg suite "$AQ_CHECK_SUITE_ID" \
  --arg url "$AQ_URL" \
  --arg env "$AQ_ENVIRONMENT_ID" \
  --arg wtype "$AQ_WORKFLOW_TYPE" \
  --arg browser "$AQ_BROWSER_TYPE" \
  --arg viewport "$AQ_VIEWPORT" \
  --argjson replays "$replays_json" '
  {test_session: (
    {name: $name, check_suite_id: $suite, use_replays: $replays, workflow_type: $wtype}
    + (if $url  != "" then {test_urls: [$url]}  else {} end)
    + (if $env  != "" then {environment_id: $env} else {} end)
    + (if $browser  != "" then {browser_type: $browser} else {} end)
    + (if $viewport != "" then {viewport: $viewport}    else {} end)
  )}')

api POST "/api/v1/projects/$AQ_PROJECT_ID/test_sessions" "$payload"
if [[ "$API_STATUS" == "503" ]]; then
  die "$(api_error)"
elif [[ "$API_STATUS" != "201" ]]; then
  die "could not create the session: $(api_error)"
fi

SESSION_ID=$(jq -r '.test_session.id' <<<"$API_BODY")
SESSION_URL="$HOST/test_sessions/$SESSION_ID"
[[ -n "$SESSION_ID" && "$SESSION_ID" != "null" ]] || die "the API returned no session id."

{
  echo "session-id=$SESSION_ID"
  echo "session-url=$SESSION_URL"
} >> "$GITHUB_OUTPUT"

echo "Created session $SESSION_ID"
echo "$SESSION_URL"

api POST "/api/v1/projects/$AQ_PROJECT_ID/test_sessions/$SESSION_ID/run"
[[ "$API_STATUS" == "200" ]] || die "could not start the session: $(api_error)"
echo "Started."

emit() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

if ! is_true "$AQ_AWAIT_COMPLETION"; then
  emit status "started"
  for k in checks-total checks-passed checks-failed checks-blocked; do emit "$k" 0; done
  echo "await-completion is false — not waiting for results."
  exit 0
fi

deadline=$(( SECONDS + AQ_TIMEOUT_SECONDS ))
status="unknown"
timed_out=false

while :; do
  api GET "/api/v1/projects/$AQ_PROJECT_ID/test_sessions/$SESSION_ID"
  if [[ "$API_STATUS" != "200" ]]; then
    die "could not read the session: $(api_error)"
  fi
  status=$(jq -r '.test_session.status' <<<"$API_BODY")

  case "$status" in
    completed|failed|cancelled) break ;;
  esac

  if (( SECONDS >= deadline )); then
    timed_out=true
    break
  fi
  echo "  $status ..."
  sleep "$AQ_POLL_INTERVAL_SECONDS"
done

api GET "/api/v1/projects/$AQ_PROJECT_ID/test_sessions/$SESSION_ID/check_executions"
[[ "$API_STATUS" == "200" ]] || die "could not read check executions: $(api_error)"
RESULTS="$API_BODY"

count_state() { jq --arg s "$1" '[.check_executions[] | select(.state == $s)] | length' <<<"$RESULTS"; }

total=$(jq '.check_executions | length' <<<"$RESULTS")
passed=$(count_state passed)
failed=$(count_state failed)
blocked=$(count_state blocked)

if $timed_out; then
  status="timed-out"
fi

emit status "$status"
emit checks-total "$total"
emit checks-passed "$passed"
emit checks-failed "$failed"
emit checks-blocked "$blocked"

if [[ -n "$AQ_JUNIT_PATH" ]]; then
  mkdir -p "$(dirname "$AQ_JUNIT_PATH")"
  jq -r '
    def esc: (. // "") | tostring | @html;
    .check_executions as $ce
    | ($ce | length) as $total
    | ([$ce[] | select(.state == "failed")]  | length) as $failed
    | ([$ce[] | select(.state == "blocked" or .state == "running")] | length) as $skipped
    | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<testsuites name=\"Agentic QA\" tests=\"\($total)\" failures=\"\($failed)\" skipped=\"\($skipped)\">",
      "  <testsuite name=\"Agentic QA\" tests=\"\($total)\" failures=\"\($failed)\" skipped=\"\($skipped)\">",
      ($ce[] |
        "    <testcase name=\"\(.check.name | esc)\" classname=\"\(.check.check_suite_name | esc)\">"
        + (if   .state == "failed"  then "\n      <failure message=\"check failed\">\(.reasoning | esc)</failure>\n    "
           elif .state == "blocked" then "\n      <skipped message=\"blocked\"/>\n    "
           elif .state == "running" then "\n      <skipped message=\"still running when the run ended\"/>\n    "
           else "" end)
        + "</testcase>"),
      "  </testsuite>",
      "</testsuites>"
  ' <<<"$RESULTS" > "$AQ_JUNIT_PATH"
  echo "JUnit report written to $AQ_JUNIT_PATH"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Agentic QA — $status"
    echo
    echo "[$session_name]($SESSION_URL)"
    echo
    echo "| | Count |"
    echo "|---|---|"
    echo "| Passed | $passed |"
    echo "| Failed | $failed |"
    echo "| Blocked | $blocked |"
    echo "| Total | $total |"
    if (( total > 0 )); then
      echo
      echo "| Check | Result |"
      echo "|---|---|"
      jq -r '.check_executions[]
        | (if .state == "passed" then "pass" elif .state == "failed" then "FAIL" else .state end) as $r
        | "| \(.check.name) | \($r) |"' <<<"$RESULTS"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "passed=$passed failed=$failed blocked=$blocked total=$total"

if is_true "$AQ_CONTINUE_ON_FAILURE"; then
  echo "continue-on-failure is set — not failing the build."
  exit 0
fi

if $timed_out; then
  die "the session did not finish within ${AQ_TIMEOUT_SECONDS}s. It is still running — the API has no cancel endpoint, so stop it in the UI: $SESSION_URL"
fi

if (( failed > 0 )); then
  die "$failed check(s) failed. $SESSION_URL"
fi

if is_true "$AQ_FAIL_ON_BLOCKED" && (( blocked > 0 )); then
  die "$blocked check(s) were blocked. Set fail-on-blocked: false to ignore these. $SESSION_URL"
fi

if (( total == 0 )); then
  die "the session finished with no check executions. Is the check suite empty? $SESSION_URL"
fi

echo "All checks passed."
