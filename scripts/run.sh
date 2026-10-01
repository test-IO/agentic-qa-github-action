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
: "${AQ_TIMEOUT_SECONDS:=7200}"
: "${AQ_POLL_INTERVAL_SECONDS:=15}"
: "${AQ_JUNIT_PATH:=}"
: "${AQ_PROXY_CONFIG_ID:=}"
: "${AQ_RESULTS_SETTLE_SECONDS:=60}"
: "${AQ_CHANNEL:=web}"
: "${AQ_PRODUCT_ID:=}"
: "${AQ_DEVICE_SERIAL:=}"
: "${AQ_DEVICE_PLATFORM:=}"
: "${AQ_DEVICE_TYPE:=}"
: "${AQ_OS_VERSION:=}"
: "${AQ_MANUFACTURER:=}"
: "${AQ_DEVICE_BACKEND:=}"
: "${AQ_APP_BINARY_ID:=}"
: "${AQ_APP_BINARY_PATH:=}"
: "${AQ_APP_PACKAGE:=}"
: "${AQ_MOBILE_BROWSER:=false}"
: "${AQ_PREREQUISITES:=}"

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
  # .error is a string for plain failures and an attribute => messages object for
  # validation failures; flatten the object so the second kind stays readable.
  msg=$(jq -r '
    (.error // empty)
    | if   type == "object" then [to_entries[] | "\(.key): \(.value | if type == "array" then join(", ") else tostring end)"] | join("; ")
      elif type == "array"  then join("; ")
      else tostring end' <<<"$API_BODY" 2>/dev/null || true)
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

AQ_CHANNEL="${AQ_CHANNEL,,}"
case "$AQ_CHANNEL" in
  web|mobile) ;;
  *) die "channel must be web or mobile, not '$AQ_CHANNEL'." ;;
esac

if [[ "$AQ_CHANNEL" == "web" ]]; then
  if [[ -z "$AQ_URL" && -z "$AQ_ENVIRONMENT_ID" ]]; then
    die "either url or environment-id must be set."
  fi

  # An id that matches nothing is accepted all the way down: there is no foreign
  # key on it, and the runner logs a warning and runs unproxied. That turns a
  # typo into a green build that never used the proxy, so check it here.
  if [[ -n "$AQ_PROXY_CONFIG_ID" ]]; then
    api GET "/api/v1/proxy_configs"
    [[ "$API_STATUS" == "200" ]] || die "could not list proxy configs: $(api_error)"
    if ! jq -e --arg id "$AQ_PROXY_CONFIG_ID" 'any(.proxy_configs[]; .id == $id)' >/dev/null <<<"$API_BODY"; then
      available=$(jq -r '[.proxy_configs[] | "\(.name) (\(.id))"] | join(", ")' <<<"$API_BODY")
      if [[ -n "$available" ]]; then
        die "proxy-config-id '$AQ_PROXY_CONFIG_ID' is not configured here. Available: $available"
      fi
      die "proxy-config-id '$AQ_PROXY_CONFIG_ID' is not configured here, and this installation has no proxy configs. Add one under System Configuration."
    fi
  fi
else
  [[ -n "$AQ_PRODUCT_ID" ]] || die "product-id is required when channel is mobile. It must be a mobile product."

  # WHERE the run happens. The API takes a pinned serial or search criteria, and
  # a serial wins when both are sent.
  if [[ -z "$AQ_DEVICE_SERIAL" && -z "$AQ_DEVICE_PLATFORM" ]]; then
    die "mobile needs a device: set device-serial, or device-platform to auto-select one."
  fi

  # WHAT runs on it. The API defaults an unspecified source to "binary" and only
  # notices the missing upload when the session starts, which would leave an
  # unstartable session behind, so settle it before anything is created.
  sources=0
  if is_true "$AQ_MOBILE_BROWSER";     then sources=$((sources + 1)); fi
  if [[ -n "$AQ_APP_PACKAGE"     ]];   then sources=$((sources + 1)); fi
  if [[ -n "$AQ_APP_BINARY_ID"   ]];   then sources=$((sources + 1)); fi
  if [[ -n "$AQ_APP_BINARY_PATH" ]];   then sources=$((sources + 1)); fi
  if (( sources == 0 )); then
    die "mobile needs an app source: set one of app-binary-path, app-binary-id, app-package or mobile-browser."
  fi
  if (( sources > 1 )); then
    die "set only one app source out of app-binary-path, app-binary-id, app-package and mobile-browser."
  fi
  if [[ -n "$AQ_APP_BINARY_PATH" ]]; then
    [[ -f "$AQ_APP_BINARY_PATH" ]] || die "app-binary-path '$AQ_APP_BINARY_PATH' is not a file. It is read from the workspace, so check out or download the build first."
    case "${AQ_APP_BINARY_PATH,,}" in
      *.apk|*.aab|*.ipa) ;;
      *) die "app-binary-path must be an .apk, .aab or .ipa, got '$AQ_APP_BINARY_PATH'." ;;
    esac
  fi
  if [[ -n "$AQ_APP_PACKAGE" && -z "$AQ_DEVICE_SERIAL" ]]; then
    die "app-package runs an app already installed on one device, so it needs device-serial."
  fi

  # The API rejects a non-positive value with a 400 after it has already saved the
  # setup instruction, leaving an orphan behind, so settle it here first.
  if [[ -n "$AQ_MAX_CONCURRENCY" ]]; then
    if [[ ! "$AQ_MAX_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
      die "max-concurrency must be a positive integer, got '$AQ_MAX_CONCURRENCY'."
    fi
    if [[ -n "$AQ_DEVICE_SERIAL" ]]; then
      echo "::warning::max-concurrency is ignored when device-serial pins one device."
    fi
  fi
  if [[ -n "$AQ_DEVICE_LOCATION" && -n "$AQ_DEVICE_SERIAL" ]]; then
    echo "::warning::device-location narrows auto-selection and is ignored when device-serial is set."
  fi

  ignored_on_mobile() {
    echo "::warning::$1 is a web input and is ignored when channel is mobile."
  }
  for pair in "url:$AQ_URL" "environment-id:$AQ_ENVIRONMENT_ID" \
              "browser-type:$AQ_BROWSER_TYPE" "viewport:$AQ_VIEWPORT" \
              "proxy-config-id:$AQ_PROXY_CONFIG_ID"; do
    if [[ -n "${pair#*:}" ]]; then ignored_on_mobile "${pair%%:*}"; fi
  done
  if is_true "$AQ_USE_REPLAYS"; then ignored_on_mobile use-replays; fi
  if [[ "$AQ_WORKFLOW_TYPE" != "web" ]]; then ignored_on_mobile workflow-type; fi
fi

session_name="$AQ_SESSION_NAME"
if [[ -z "$session_name" ]]; then
  sha="${GITHUB_SHA:-}"
  session_name="${GITHUB_WORKFLOW:-CI} ${sha:0:7}"
  # without the run number, every re-run of the same commit lands an
  # identically named session in the UI
  if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    session_name="$session_name #$GITHUB_RUN_NUMBER"
    if [[ "${GITHUB_RUN_ATTEMPT:-1}" != "1" ]]; then
      session_name="$session_name.$GITHUB_RUN_ATTEMPT"
    fi
  fi
fi

# Two-phase direct upload: reserve a blob, stream the bytes to wherever the API
# points (local disk, GCS), then turn it into a binary record. The PUT carries
# only the headers the API handed back — never the API key, which would leak it
# to the storage host.
upload_app_binary() {
  local path="$1" name size checksum init url signed
  command -v openssl >/dev/null 2>&1 || die "openssl is required to upload app-binary-path."
  name=$(basename "$path")
  size=$(wc -c < "$path" | tr -d '[:space:]')
  checksum=$(openssl dgst -md5 -binary "$path" | base64 | tr -d '\n')

  api POST "/api/v1/products/$AQ_PRODUCT_ID/mobile_binary_files/initiate_upload" \
    "$(jq -n --arg f "$name" --argjson s "$size" --arg c "$checksum" \
        '{filename: $f, byte_size: $s, checksum: $c}')"
  [[ "$API_STATUS" == "200" ]] || die "could not start the binary upload: $(api_error)"
  init="$API_BODY"
  url=$(jq -r '.direct_upload_url' <<<"$init")
  signed=$(jq -r '.blob_signed_id' <<<"$init")
  [[ -n "$url" && "$url" != "null" ]] || die "upload did not return a direct_upload_url: $init"

  local -a put=(-sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "$path" --max-time 600)
  while IFS= read -r header; do
    [[ -n "$header" ]] && put+=(-H "$header")
  done < <(jq -r '(.direct_upload_headers // {}) | to_entries[] | "\(.key): \(.value)"' <<<"$init")
  local code
  if ! code=$(curl "${put[@]}" "$url" 2>&1); then
    die "could not upload $name to the storage host."
  fi
  [[ "$code" =~ ^2[0-9][0-9]$ ]] || die "uploading $name failed with HTTP $code."

  api POST "/api/v1/products/$AQ_PRODUCT_ID/mobile_binary_files/commit_upload" \
    "$(jq -n --arg b "$signed" '{blob_signed_id: $b}')"
  [[ "$API_STATUS" == "201" ]] || die "could not finish the binary upload: $(api_error)"
  AQ_APP_BINARY_ID=$(jq -r '.id' <<<"$API_BODY")
  [[ -n "$AQ_APP_BINARY_ID" && "$AQ_APP_BINARY_ID" != "null" ]] || die "upload did not return a binary id: $API_BODY"
  echo "Uploaded $name ($size bytes) as $AQ_APP_BINARY_ID"
}

if [[ "$AQ_CHANNEL" == "mobile" ]]; then
  if is_true "$AQ_MOBILE_BROWSER"; then browser_json=true; else browser_json=false; fi
  if [[ -n "$AQ_APP_BINARY_PATH" ]]; then upload_app_binary "$AQ_APP_BINARY_PATH"; fi
  create_path="/api/v1/projects/$AQ_PROJECT_ID/mobile/test_sessions"
  payload=$(jq -n \
    --arg name "$session_name" \
    --arg suite "$AQ_CHECK_SUITE_ID" \
    --arg product "$AQ_PRODUCT_ID" \
    --arg backend "$AQ_DEVICE_BACKEND" \
    --arg serial "$AQ_DEVICE_SERIAL" \
    --arg platform "$AQ_DEVICE_PLATFORM" \
    --arg dtype "$AQ_DEVICE_TYPE" \
    --arg osver "$AQ_OS_VERSION" \
    --arg vendor "$AQ_MANUFACTURER" \
    --arg dcloc "$AQ_DEVICE_LOCATION" \
    --arg artifact "$AQ_APP_BINARY_ID" \
    --arg package "$AQ_APP_PACKAGE" \
    --arg prereq "$AQ_PREREQUISITES" \
    --arg conc "$AQ_MAX_CONCURRENCY" \
    --argjson browser "$browser_json" '
    {test_session: (
      {name: $name, check_suite_id: $suite, product_id: $product}
      + (if $backend  != "" then {device_backend: $backend} else {} end)
      + (if $serial   != "" then {device_serial: $serial}   else {} end)
      # the server ignores search criteria once a serial is pinned, so only send
      # the axis that will actually be used
      + (if $serial == "" and $platform != "" then
           {search_criteria: (
             {platform: $platform}
             + (if $dtype  != "" then {device_type: $dtype}    else {} end)
             + (if $osver  != "" then {os_version: $osver}     else {} end)
             + (if $vendor != "" then {manufacturer: $vendor}  else {} end)
             + (if $dcloc  != "" then {location: $dcloc}       else {} end)
           )}
         else {} end)
      + (if $artifact != "" then {selected_artifact_id: $artifact} else {} end)
      + (if $package  != "" then {app_package: $package}          else {} end)
      + (if $browser        then {mobile_browser: true}           else {} end)
      + (if $prereq   != "" then {prerequisites: $prereq}         else {} end)
      + (if $conc     != "" then {max_concurrency: ($conc | tonumber)} else {} end)
    )}')
else
  if is_true "$AQ_USE_REPLAYS"; then replays_json=true; else replays_json=false; fi
  create_path="/api/v1/projects/$AQ_PROJECT_ID/test_sessions"
  payload=$(jq -n \
    --arg name "$session_name" \
    --arg suite "$AQ_CHECK_SUITE_ID" \
    --arg url "$AQ_URL" \
    --arg env "$AQ_ENVIRONMENT_ID" \
    --arg wtype "$AQ_WORKFLOW_TYPE" \
    --arg browser "$AQ_BROWSER_TYPE" \
    --arg viewport "$AQ_VIEWPORT" \
    --arg proxy "$AQ_PROXY_CONFIG_ID" \
    --argjson replays "$replays_json" '
    {test_session: (
      {name: $name, check_suite_id: $suite, use_replays: $replays, workflow_type: $wtype}
      + (if $url  != "" then {test_urls: [$url]}    else {} end)
      + (if $env  != "" then {environment_id: $env} else {} end)
      + (if $browser  != "" then {browser_type: $browser} else {} end)
      + (if $viewport != "" then {viewport: $viewport}    else {} end)
      + (if $proxy    != "" then {proxy_config_id: $proxy} else {} end)
    )}')
fi

api POST "$create_path" "$payload"
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

RESULTS=""
count_state() { jq --arg s "$1" '[.check_executions[] | select(.state == $s)] | length' <<<"$RESULTS"; }

read_results() {
  api GET "/api/v1/projects/$AQ_PROJECT_ID/test_sessions/$SESSION_ID/check_executions"
  [[ "$API_STATUS" == "200" ]] || die "could not read check executions: $(api_error)"
  RESULTS="$API_BODY"
}

# The session status is derived from its workflow executions alone, so it can turn
# terminal while check executions are still being written — one read then reports a
# partial run as final (a suite of 23 was once reported as 5, with 18 blocked checks
# missing). Re-read until the set stops growing and nothing is still running.
#
# Only a terminal session can settle. A running one has lulls — the gap between one
# check ending and the next being created leaves the set briefly stable with nothing
# running — and mistaking a lull for the end is how a 23-check suite gets reported as
# the 14 that happened to exist when we gave up waiting.
results_settled=false

if $timed_out; then
  read_results
  total=$(jq '.check_executions | length' <<<"$RESULTS")
else
  settle_deadline=$(( SECONDS + AQ_RESULTS_SETTLE_SECONDS ))
  settle_interval=1
  prev_total=-1

  while :; do
    read_results
    total=$(jq '.check_executions | length' <<<"$RESULTS")
    running=$(count_state running)

    if (( total > 0 && total == prev_total && running == 0 )); then
      results_settled=true
      break
    fi
    if (( SECONDS >= settle_deadline )); then
      break
    fi
    if (( prev_total >= 0 && total != prev_total )); then
      echo "  results still arriving ($prev_total -> $total) ..."
    fi
    prev_total=$total
    sleep "$settle_interval"
  done
fi

passed=$(count_state passed)
failed=$(count_state failed)
blocked=$(count_state blocked)
running=$(count_state running)
accounted=$(( passed + failed + blocked ))

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
    def secs: (try fromdateiso8601 catch null);
    def dur:
      ((.created_at | secs) as $a | (.updated_at | secs) as $b
       | if ($a != null and $b != null and $b >= $a) then ($b - $a) else 0 end);
    .check_executions as $ce
    | ($ce | length) as $total
    | ([$ce[] | select(.state == "failed")]  | length) as $failed
    | ([$ce[] | select(.state == "blocked" or .state == "running")] | length) as $skipped
    | ([$ce[] | dur] | add // 0) as $time
    | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<testsuites name=\"Agentic QA\" tests=\"\($total)\" failures=\"\($failed)\" skipped=\"\($skipped)\" time=\"\($time)\">",
      "  <testsuite name=\"Agentic QA\" tests=\"\($total)\" failures=\"\($failed)\" skipped=\"\($skipped)\" time=\"\($time)\">",
      ($ce[] |
        "    <testcase name=\"\(.check.name | esc)\" classname=\"\(.check.check_suite_name | esc)\" time=\"\(dur)\">"
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
    if ! $results_settled; then
      echo "> **Incomplete — do not read these counts as the result of the run.**"
      echo "> Checks were still arriving or still running when the action stopped"
      echo "> reading, so a check missing below has no verdict here."
      echo
    fi
    echo "| | Count |"
    echo "|---|---|"
    echo "| Passed | $passed |"
    echo "| Failed | $failed |"
    echo "| Blocked | $blocked |"
    if (( running > 0 )); then echo "| Still running | $running |"; fi
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

# Not knowing the result is not a result. continue-on-failure suppresses failing and
# blocked checks; it must not suppress a set we already know is partial, or a
# truncated run reaches the branch as a green build.
if $timed_out; then
  die "the session did not finish within ${AQ_TIMEOUT_SECONDS}s, so these counts cover only the $total check(s) that existed at the deadline. It is still running — the API has no cancel endpoint, so stop it in the UI: $SESSION_URL"
fi

if (( total == 0 )); then
  die "the session finished with no check executions. Is the check suite empty? $SESSION_URL"
fi

if ! $results_settled; then
  die "the results never settled: after ${AQ_RESULTS_SETTLE_SECONDS}s the API still reported $running check(s) running or a changing total ($total so far). These counts are incomplete — do not read them as a pass. $SESSION_URL"
fi

if (( accounted != total )); then
  die "$(( total - accounted )) of $total check(s) reported no final state, so the counts are incomplete. $SESSION_URL"
fi

if is_true "$AQ_CONTINUE_ON_FAILURE"; then
  echo "continue-on-failure is set — not failing the build."
  exit 0
fi

if (( failed > 0 )); then
  die "$failed check(s) failed. $SESSION_URL"
fi

if is_true "$AQ_FAIL_ON_BLOCKED" && (( blocked > 0 )); then
  die "$blocked check(s) were blocked. Set fail-on-blocked: false to ignore these. $SESSION_URL"
fi

echo "All checks passed."
