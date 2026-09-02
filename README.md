# Agentic QA GitHub Action

Run an [Agentic QA](https://test.io/ai-in-qa/agentic-qa) check suite from a workflow and fail the build when checks fail.

The action creates a test session on your installation, starts it, waits for it to finish, and turns the per-check results into a build result, a job summary, and optionally a JUnit report.

```yaml
- uses: Romaaan3/aqaction@v1
  with:
    host: ${{ vars.AGENTIC_QA_HOST }}
    token: ${{ secrets.AGENTIC_QA_TOKEN }}
    project-id: ${{ vars.AGENTIC_QA_PROJECT }}
    check-suite-id: ${{ vars.AGENTIC_QA_SUITE }}
    url: https://staging.example.com
```

Agentic QA is single-tenant: every customer runs their own installation, so `host` is always yours.

## Setup

**1. Create a CI user.** Tokens belong to a user and carry that user's access, so use a dedicated account rather than a person's. Give it a role on only the projects CI needs — an owner or engineer token reaches every project on the installation.

**2. Mint a token.** In the Agentic QA UI, go to **System Configuration → API / MCP Config**, create a token, and click **Show API Config**. Leave *destructive actions* off; CI never needs it. Only admins can create tokens.

**3. Store the settings.** Token as a repository **secret**; host, project and suite IDs as repository **variables**.

**4. Find the IDs.** Both are UUIDs from your installation:

```bash
curl -s "$HOST/api/v1/projects" -H "Authorization: ApiKey $TOKEN" | jq '.projects[] | {id, name}'
curl -s "$HOST/api/v1/projects/$PROJECT_ID/check_suites" -H "Authorization: ApiKey $TOKEN" | jq '.check_suites[] | {id, name}'
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `host` | yes | | Base URL of your installation |
| `token` | yes | | API token |
| `project-id` | yes | | Project UUID |
| `check-suite-id` | yes | | Check suite UUID |
| `url` | | | URL to test. Required unless `environment-id` is set |
| `environment-id` | | | Environment whose URL is the target. Ignored when `url` is set |
| `session-name` | | workflow name, short SHA and run number | Display name for the session |
| `workflow-type` | | `web` | `web`, `accessibility`, or `localization` |
| `browser-type` | | installation default | e.g. `chrome` |
| `viewport` | | installation default | e.g. `1280x800` |
| `use-replays` | | `false` | Replay the latest recording per check instead of fresh AI execution |
| `await-completion` | | `true` | Wait for results. `false` starts the run and exits |
| `continue-on-failure` | | `false` | Report results but always exit 0 |
| `fail-on-blocked` | | `true` | Treat blocked checks as failures |
| `timeout-seconds` | | `1800` | How long to wait |
| `poll-interval-seconds` | | `15` | Seconds between status polls |
| `junit-path` | | | Write a JUnit XML report here |

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
      - uses: Romaaan3/aqaction@v1
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
  - uses: Romaaan3/aqaction@v1
    with:
      workflow-type: ${{ matrix.workflow-type }}
      # ...
```

Report without blocking the merge:

```yaml
- uses: Romaaan3/aqaction@v1
  with:
    continue-on-failure: true
    # ...
```

Fire and forget, for a nightly run you inspect in the UI:

```yaml
- uses: Romaaan3/aqaction@v1
  with:
    await-completion: false
    # ...
```

## Things to know

**Tokens expire after one month.** This is fixed on the platform side, and there is no renew endpoint. When a token lapses the action stops with a clear message, but someone has to mint a new one and update the secret. Put a reminder in your calendar.

**Timeouts leave the session running.** The API has no cancel endpoint, so if `timeout-seconds` is reached the action gives up but the run continues on the server. Stop it from the UI using the `session-url` output.

**Private installations need a reachable host.** GitHub-hosted runners must be able to open an HTTPS connection to `host`. If your installation sits behind a firewall or VPN, use a self-hosted runner.

**Requirements.** `bash`, `curl` and `jq`. All are present on GitHub-hosted runners.

## Development

```bash
tests/run_tests.sh
```

The tests run `scripts/run.sh` end to end against `tests/stub_api.py`, a small stand-in for the REST API. They cover the pass and fail gates, blocked handling, timeouts, expired tokens, JUnit output and escaping, and the request body sent to the API.

## Licence

No licence has been chosen yet. Add one before promoting this repository for outside use.
