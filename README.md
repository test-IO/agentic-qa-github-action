# Agentic QA GitHub Action

Run an [Agentic QA](https://test.io/ai-in-qa/agentic-qa) check suite from a workflow and fail the build when checks fail.

The action creates a test session on your installation, starts it, waits for it to finish, and turns the per-check results into a build result, a job summary, and optionally a JUnit report.

```yaml
- uses: test-IO/agentic-qa-github-action@v1
  with:
    host: ${{ vars.AGENTIC_QA_HOST }}
    token: ${{ secrets.AGENTIC_QA_TOKEN }}
    project-id: ${{ vars.AGENTIC_QA_PROJECT }}
    check-suite-id: ${{ vars.AGENTIC_QA_SUITE }}
    url: https://staging.example.com
```

It runs a web suite against a URL by default. Set `channel: mobile` to run a mobile suite on a real device instead — see [Mobile runs](#mobile-runs).

Agentic QA is single-tenant: every customer runs their own installation, so `host` is always yours.

## Setup

**1. Create a CI user.** Tokens belong to a user and carry that user's access, so use a dedicated account rather than a person's. Give it a role on only the projects CI needs — an owner or engineer token reaches every project on the installation.

**2. Mint a token.** In the Agentic QA UI, go to **System Configuration → API / MCP Config**, create a token, and click **Show API Config**. Leave *destructive actions* off; CI never needs it. Only admins can create tokens.

**3. Find the IDs.** These are UUIDs from your installation:

```bash
curl -s "$HOST/api/v1/projects" -H "Authorization: ApiKey $TOKEN" | jq '.projects[] | {id, name}'
curl -s "$HOST/api/v1/projects/$PROJECT_ID/check_suites" -H "Authorization: ApiKey $TOKEN" | jq '.check_suites[] | {id, name}'
```

For a mobile run you also need the product, and the binary if you install one:

```bash
curl -s "$HOST/api/v1/products" -H "Authorization: ApiKey $TOKEN" \
  | jq '.products[] | select(.product_type == "mobile") | {id, name}'
curl -s "$HOST/api/v1/products/$PRODUCT_ID/mobile_binary_files" -H "Authorization: ApiKey $TOKEN" \
  | jq '.mobile_binary_files[] | {id, filename, platform}'
```

Listing binaries needs an owner token, so do it once yourself and store the ID — the CI token can use a binary ID without being able to list them.

**4. Store the settings on the repository.** The token goes in a secret so it is masked in logs; the rest go in variables so you can read them while debugging.

| Name | Kind | Value |
|---|---|---|
| `AGENTIC_QA_TOKEN` | secret | the token from step 2 |
| `AGENTIC_QA_HOST` | variable | `https://your-installation.example.com` |
| `AGENTIC_QA_PROJECT` | variable | project UUID |
| `AGENTIC_QA_SUITE` | variable | check suite UUID |

### Adding them in the web UI

Both live in the same place. Open the repository and click **Settings** (if you cannot see it, open the **⋯** dropdown on the tab bar). In the left sidebar under *Security*, select **Secrets and variables**, then **Actions**.

For each **variable**:

1. Open the **Variables** tab.
2. Click **New repository variable**.
3. Fill in **Name** and **Value**.
4. Click **Add variable**.

For the **secret**:

1. Open the **Secrets** tab.
2. Click **New repository secret**.
3. Fill in **Name** and **Secret**.
4. Click **Add secret**.

A secret cannot be read back afterwards — you can only overwrite it. Variable names accept letters, digits and underscores, must not start with a digit or with `GITHUB_`, and are matched case-insensitively.

You need admin rights on the repository. If several repositories share one installation, define these at the organization level instead — the same screen exists under the organization's settings, and repository values override organization ones.

### Or from the command line

```bash
gh variable set AGENTIC_QA_HOST    --repo OWNER/REPO --body "https://your-installation.example.com"
gh variable set AGENTIC_QA_PROJECT --repo OWNER/REPO --body "PROJECT_UUID"
gh variable set AGENTIC_QA_SUITE   --repo OWNER/REPO --body "SUITE_UUID"

gh secret set AGENTIC_QA_TOKEN --repo OWNER/REPO
```

Leaving `--body` off the secret makes `gh` prompt for the value, so it never lands in your shell history.

## Inputs

Both channels take these:

| Name | Required | Default | Description |
|---|---|---|---|
| `host` | yes | | Base URL of your installation |
| `token` | yes | | API token |
| `project-id` | yes | | Project UUID |
| `check-suite-id` | yes | | Check suite UUID |
| `channel` | | `web` | `web` or `mobile` |
| `session-name` | | workflow name, short SHA and run number | Display name for the session |
| `await-completion` | | `true` | Wait for results. `false` starts the run and exits |
| `continue-on-failure` | | `false` | Report results but always exit 0 |
| `fail-on-blocked` | | `true` | Treat blocked checks as failures |
| `timeout-seconds` | | `1800` | How long to wait |
| `poll-interval-seconds` | | `15` | Seconds between status polls |
| `junit-path` | | | Write a JUnit XML report here |

### Web only

| Name | Required | Default | Description |
|---|---|---|---|
| `url` | | | URL to test. Required unless `environment-id` is set |
| `environment-id` | | | Environment whose URL is the target. Ignored when `url` is set |
| `workflow-type` | | `web` | `web`, `accessibility`, or `localization` |
| `browser-type` | | installation default | e.g. `chrome` |
| `viewport` | | installation default | e.g. `1280x800` |
| `use-replays` | | `false` | Replay the latest recording per check instead of fresh AI execution |

### Mobile only

| Name | Required | Default | Description |
|---|---|---|---|
| `product-id` | for mobile | | Mobile product UUID |
| `device-serial` | | | Run on this exact device, by UDID/serial |
| `device-platform` | | | Auto-select a device for this platform, e.g. `android` or `ios` |
| `device-type` | | | Narrows auto-selection, e.g. `phone` or `tablet` |
| `os-version` | | | Narrows auto-selection to this OS version |
| `manufacturer` | | | Narrows auto-selection to this manufacturer |
| `device-backend` | | `mobitru` | Device provider |
| `app-binary-id` | | | UUID of an uploaded binary to install before the run |
| `app-package` | | | Package name (Android) or Bundle ID (iOS) of an app already on the device |
| `mobile-browser` | | `false` | Test the device browser instead of an app |
| `prerequisites` | | | Free-form setup notes to run before the checks, e.g. login steps |

Setting a web input on a mobile run logs a warning and changes nothing — the mobile API takes no URL, browser, viewport, workflow type or replay flag.

## Mobile runs

A mobile run needs `channel: mobile`, a `product-id` for a mobile product, and two independent choices.

**Which device.** Either `device-serial` for one exact device, or `device-platform` to let the installation pick one — narrow that with `device-type`, `os-version` and `manufacturer`. If you set both, the serial wins and the criteria are dropped.

**What runs on it.** Exactly one of:

- `app-binary-id` — install an uploaded APK or IPA first.
- `app-package` — an app already installed on the device. Needs `device-serial`, since it has to be a device you picked.
- `mobile-browser: true` — the device's own browser. Nothing is installed.

The action rejects zero sources and more than one. The API treats an unset source as "install a binary" and only notices the missing upload at start time, which would leave you a session that cannot run, so it is settled before anything is created.

## Outputs

| Name | Description |
|---|---|
| `session-id` | UUID of the created session |
| `session-url` | Link to the session in the UI |
| `status` | `completed`, `failed`, `cancelled`, `started`, or `timed-out` |
| `checks-total` | Number of check executions |
| `checks-passed` / `checks-failed` / `checks-blocked` | Per-state counts |

## Check results

Each check ends in one of three states:

- **passed** — the check held.
- **failed** — the check did not hold. Fails the build.
- **blocked** — the check never ran to a verdict, usually a technical problem rather than a defect. Fails the build by default; set `fail-on-blocked: false` to treat it as a warning.

## Examples

Gate a pull request and publish the report:

```yaml
name: Smoke
on: pull_request

jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: test-IO/agentic-qa-github-action@v1
        id: qa
        with:
          host: ${{ vars.AGENTIC_QA_HOST }}
          token: ${{ secrets.AGENTIC_QA_TOKEN }}
          project-id: ${{ vars.AGENTIC_QA_PROJECT }}
          check-suite-id: ${{ vars.AGENTIC_QA_SUITE }}
          url: https://staging.example.com
          junit-path: reports/agentic-qa.xml

      - if: always()
        uses: actions/upload-artifact@v4
        with:
          name: agentic-qa
          path: reports/agentic-qa.xml
```

Run web, accessibility and localization side by side:

```yaml
strategy:
  fail-fast: false
  matrix:
    workflow-type: [web, accessibility, localization]
steps:
  - uses: test-IO/agentic-qa-github-action@v1
    with:
      workflow-type: ${{ matrix.workflow-type }}
      # ...
```

Run several check suites. Each call to the action is one session, so a matrix gives you one session per suite, all in parallel:

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - name: smoke
        suite: ${{ vars.AGENTIC_QA_SUITE_SMOKE }}
      - name: checkout
        suite: ${{ vars.AGENTIC_QA_SUITE_CHECKOUT }}
steps:
  - uses: test-IO/agentic-qa-github-action@v1
    with:
      host: ${{ vars.AGENTIC_QA_HOST }}
      token: ${{ secrets.AGENTIC_QA_TOKEN }}
      project-id: ${{ vars.AGENTIC_QA_PROJECT }}
      check-suite-id: ${{ matrix.suite }}
      url: https://staging.example.com
      session-name: ${{ matrix.name }} ${{ github.run_number }}
      junit-path: reports/${{ matrix.name }}.xml

  - if: always()
    uses: actions/upload-artifact@v4
    with:
      name: agentic-qa-${{ matrix.name }}
      path: reports/${{ matrix.name }}.xml
```

Name the sessions yourself. The default name is the workflow, the short SHA and the run number, which is the same string for every session in one run, so without `session-name` they are indistinguishable in the UI. The artifact name has to differ per leg too — `upload-artifact@v4` rejects duplicates. Job outputs do not survive a matrix, since GitHub overwrites them leg by leg, so collect the JUnit files as artifacts instead of reading `steps.*.outputs` from a later job.

To run the suites one after another in a single job, give every step its own `id`, `session-name` and `junit-path`:

```yaml
steps:
  - uses: test-IO/agentic-qa-github-action@v1
    id: smoke
    with:
      check-suite-id: ${{ vars.AGENTIC_QA_SUITE_SMOKE }}
      session-name: smoke ${{ github.run_number }}
      junit-path: reports/smoke.xml
      # host, token, project-id, url ...

  - if: always()
    uses: test-IO/agentic-qa-github-action@v1
    id: checkout
    with:
      check-suite-id: ${{ vars.AGENTIC_QA_SUITE_CHECKOUT }}
      session-name: checkout ${{ github.run_number }}
      junit-path: reports/checkout.xml
      # ...
```

The `if: always()` matters here: the action exits non-zero when checks fail, so without it a failing suite skips every suite after it. The distinct `id` is what lets you read one session's outputs, as in `${{ steps.smoke.outputs.checks-failed }}`.

Run a mobile suite on an auto-selected Android phone, installing a binary:

```yaml
- uses: test-IO/agentic-qa-github-action@v1
  with:
    host: ${{ vars.AGENTIC_QA_HOST }}
    token: ${{ secrets.AGENTIC_QA_TOKEN }}
    project-id: ${{ vars.AGENTIC_QA_PROJECT }}
    check-suite-id: ${{ vars.AGENTIC_QA_MOBILE_SUITE }}
    channel: mobile
    product-id: ${{ vars.AGENTIC_QA_MOBILE_PRODUCT }}
    device-platform: android
    device-type: phone
    app-binary-id: ${{ vars.AGENTIC_QA_APP_BINARY }}
```

Or on one pinned device, against an app that is already installed:

```yaml
- uses: test-IO/agentic-qa-github-action@v1
  with:
    channel: mobile
    product-id: ${{ vars.AGENTIC_QA_MOBILE_PRODUCT }}
    device-serial: R5CT10ABCDE
    app-package: com.example.app
    # host, token, project-id, check-suite-id ...
```

Web and mobile side by side. They need different inputs, so give each its own job rather than one matrix:

```yaml
jobs:
  web:
    runs-on: ubuntu-latest
    steps:
      - uses: test-IO/agentic-qa-github-action@v1
        with:
          check-suite-id: ${{ vars.AGENTIC_QA_SUITE }}
          url: https://staging.example.com
          # host, token, project-id ...

  mobile:
    runs-on: ubuntu-latest
    steps:
      - uses: test-IO/agentic-qa-github-action@v1
        with:
          channel: mobile
          check-suite-id: ${{ vars.AGENTIC_QA_MOBILE_SUITE }}
          product-id: ${{ vars.AGENTIC_QA_MOBILE_PRODUCT }}
          device-platform: ios
          mobile-browser: true
          # host, token, project-id ...
```

A check suite belongs to one product, and a product is either web or mobile, so the suite decides the channel — you cannot point a web suite at `channel: mobile` or the reverse.

Run mobile sessions in parallel across platforms. Each platform needs its own suite and its own binary, so carry both in the matrix:

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - name: android
        platform: android
        suite: ${{ vars.AGENTIC_QA_SUITE_ANDROID }}
        binary: ${{ vars.AGENTIC_QA_BINARY_ANDROID }}
      - name: ios
        platform: ios
        suite: ${{ vars.AGENTIC_QA_SUITE_IOS }}
        binary: ${{ vars.AGENTIC_QA_BINARY_IOS }}
steps:
  - uses: test-IO/agentic-qa-github-action@v1
    with:
      host: ${{ vars.AGENTIC_QA_HOST }}
      token: ${{ secrets.AGENTIC_QA_TOKEN }}
      project-id: ${{ vars.AGENTIC_QA_PROJECT }}
      channel: mobile
      product-id: ${{ vars.AGENTIC_QA_MOBILE_PRODUCT }}
      check-suite-id: ${{ matrix.suite }}
      device-platform: ${{ matrix.platform }}
      app-binary-id: ${{ matrix.binary }}
      session-name: ${{ matrix.name }} ${{ github.run_number }}
      junit-path: reports/${{ matrix.name }}.xml
```

Parallel mobile runs compete for devices, so a few rules apply that web does not have:

**Use `device-platform`, not `device-serial`.** Auto-selection lists the available devices and picks one at random precisely to spread concurrent sessions across the pool. A pinned serial skips that: two sessions pinning the same device both proceed to reservation, and the one that loses fails outright, because a device is held for three hours and reservation does not queue or retry.

**Keep the leg count below the pool.** Selection and reservation are separate steps, so two legs can still pick the same device and one loses the race — the wider the pool, the rarer that is. Every extra `device-type`, `os-version` or `manufacturer` filter narrows the pool and makes it more likely. When nothing matches at all the step fails with `No devices available matching criteria`.

Report without blocking the merge:

```yaml
- uses: test-IO/agentic-qa-github-action@v1
  with:
    continue-on-failure: true
    # ...
```

Fire and forget, for a nightly run you inspect in the UI:

```yaml
- uses: test-IO/agentic-qa-github-action@v1
  with:
    await-completion: false
    # ...
```

## Things to know

**Tokens expire after one month.** This is fixed on the platform side, and there is no renew endpoint. When a token lapses the action stops with a clear message, but someone has to mint a new one and update the secret. Put a reminder in your calendar.

**Timeouts leave the session running.** The API has no cancel endpoint, so if `timeout-seconds` is reached the action gives up but the run continues on the server. Stop it from the UI using the `session-url` output.

**Listing app binaries needs an owner token.** `GET /products/:id/mobile_binary_files` is owner-only, though `app-binary-id` works with any token that can reach the product. Look the ID up once and store it as a repository variable.

**There is no device-location filter.** The API documents `search_criteria[location]` for picking a datacenter, but does not accept it, so the action does not offer it. Pin a `device-serial` if you need a specific device.

**Private installations need a reachable host.** GitHub-hosted runners must be able to open an HTTPS connection to `host`. If your installation sits behind a firewall or VPN, use a self-hosted runner.

**Requirements.** `bash`, `curl` and `jq`. All are present on GitHub-hosted runners.

## Development

```bash
tests/run_tests.sh
```

The tests run `scripts/run.sh` end to end against `tests/stub_api.py`, a small stand-in for the REST API. They cover the pass and fail gates, blocked handling, timeouts, expired tokens, JUnit output and escaping, both channels' request bodies, and the mobile input validation.

`scripts/run.sh` uses bash 4 parameter expansion, so run the tests with bash 4 or newer. That is what GitHub-hosted runners have; macOS ships bash 3.2, where you need `brew install bash` and `/opt/homebrew/bin/bash tests/run_tests.sh`.

## Licence

No licence has been chosen yet. Add one before promoting this repository for outside use.
