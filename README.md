# code-ranker-ci

Reusable GitHub Actions workflow for **code-ranker Reports**. Drop in one file, get an HTML report generated on your CI and posted as a sticky PR comment — no secrets, keyless OIDC.

Part of the [code-ranker](https://github.com/ffedoroff/code-ranker) Reports product.

## License

Proprietary. This repository may only be used to integrate your repositories with the code-ranker service. All other uses are prohibited. See [LICENSE](LICENSE) for details.

## How it works

On every pull request (and `main` push) the workflow:

1. Installs `code-ranker` (precompiled binary, seconds)
2. Builds a self-contained HTML report for your code
3. Uploads it keylessly via OIDC
4. Posts a sticky PR comment with the link (updates in place, never duplicates)

Advisory mode (`continue-on-error`): never breaks your CI.

## Setup

Copy the stub into your repo as `.github/workflows/code-ranker.yml`:

```yaml
name: code-ranker
on:
  pull_request:
  push:
    branches: [main]
jobs:
  report:
    uses: ffedoroff/code-ranker-ci/.github/workflows/report.yml@v1
    permissions:
      id-token: write        # OIDC keyless — no secret needed
      contents: read
      pull-requests: write   # sticky comment
```

If your default branch isn't `main`, update the `push` branches list.

> If installed via GitHub App, this file is already added by the onboarding PR.

## Keyless OIDC — why no secrets

GitHub Actions issues a short-lived OIDC token (audience `code-ranker-reports`) that proves the run's identity. Nothing goes in **Settings → Secrets**. The token lives minutes and is only accepted by our service.

## Versioning `@v1`

The stub pins the floating major tag `@v1`. Compatible improvements (new analysis flags, install speed, fixes) land automatically — we move `v1` to new releases.

- Backwards-compatible changes → patch/minor release, `v1` tag follows.
- Breaking changes → new major `v2`; **`v1` never breaks in place**.

For full reproducibility, pin to a SHA and use Dependabot:  
`uses: ffedoroff/code-ranker-ci/.github/workflows/report.yml@<sha>`

## Fork PRs

Forks don't receive an OIDC token from GitHub, so direct upload isn't possible. Fork support uses a separate privileged path via `workflow_run`: phase A builds the HTML as a plain artifact (no secrets); phase B runs in the base-repo context, uploads, and comments. **`pull_request_target` is never used.**

Most repos don't need this. If you do — see `caller-stub.yml` comments: add an upload-artifact step and a second stub `.github/workflows/code-ranker-fork.yml` that delegates to `ffedoroff/code-ranker-ci/.github/workflows/fork-report.yml@v1`.

## Repository files

| File | Role |
|---|---|
| `.github/workflows/report.yml` | Reusable workflow — same-repo path |
| `.github/workflows/fork-report.yml` | Reusable workflow — fork PR handler (phase B) |
| `caller-stub.yml` | Stub to copy into your repository |
