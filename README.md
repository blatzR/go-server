# Docker Build & Trivy Vulnerability Scanning Pipeline

| Field | Value |
|---|---|
| **Status** | In Progress |
| **Owner** | Rahul Babu (rahul.babu@you.co) |
| **Last Updated** | 2026-07-23 |
| **Repo** | `hello-world-go` |
| **Related file(s)** | `Dockerfile`, `.github/workflows/docker-trivy.yml` |

---

## 1. Overview

This page documents the CI/CD pipeline that builds the `hello-world-go` Docker image and scans it for known vulnerabilities using [Trivy](https://github.com/aquasecurity/trivy), along with the investigation and changes made to date. It is intended as a working log so the reasoning behind each decision is traceable, not just the end state of the YAML file.

## 2. Goals

- Build the Docker image on every PR to `main`.
- Scan the built image for CVEs before it can be considered mergeable.
- Surface scan results in a durable, shareable format.
- Fail CI when **fixable** HIGH/CRITICAL vulnerabilities are present, without blocking on issues with no available fix.

## 3. Current Workflow (`.github/workflows/docker-trivy.yml`)

Triggered on:  `pull_request` into `main`, and manual `workflow_dispatch`.

| Step | Purpose |
|---|---|
| Checkout repository | Standard checkout |
| Set up Docker Buildx | Enables layer caching via `type=gha` |
| Build Docker image | Builds from `./Dockerfile`, tagged `hello-world-go:<sha>`, loaded into the local Docker daemon (not pushed) |
| Download Trivy HTML template | Fetches `contrib/html.tpl` from the Trivy repo into the workspace (see §5.3 for why) |
| Run Trivy scan (HTML report) | Scans CRITICAL/HIGH/MEDIUM, renders an HTML report, never fails the build (`exit-code: 0`) |
| Convert Trivy report to PDF | Installs `wkhtmltopdf`, converts the HTML report to `trivy-report.pdf` |
| Upload Trivy PDF report as artifact | Uploads the PDF via `actions/upload-artifact@v4`, 30-day retention |
| Run Trivy scan (fail build on fixable HIGH/CRITICAL) | Table-format scan, CRITICAL/HIGH only, `ignore-unfixed: true`, `exit-code: 1` — this is the actual merge gate |

## 4. Decision Log

### 4.1 Why two Trivy scans instead of one

The original workflow ran Trivy twice because "report everything" and "fail the build" are different concerns with different thresholds:

- **Reporting scan** — CRITICAL/HIGH/MEDIUM, never fails the build. Exists purely for visibility/tracking.
- **Gating scan** — CRITICAL/HIGH only, `ignore-unfixed: true`, fails the build. Only breaks CI for issues that are both serious *and* actionable (a fix exists).

This split is intentional and has been preserved through all subsequent changes — only the *destination* of the reporting scan's output has changed (see below).

### 4.2 Moving off the GitHub Security tab

**Original behavior:** the reporting scan emitted SARIF, uploaded via `github/codeql-action/upload-sarif@v3` into the repo's Security tab. This required the job to hold `security-events: write` permission.

**Change requested:** export results as a PDF artifact instead of pushing to GitHub Security.

**Why not convert SARIF directly to PDF:** SARIF is a machine-readable JSON schema intended for tools (GitHub Security, IDEs, etc.) to consume — there is no standard "SARIF → PDF" renderer. Attempting to shoehorn one in would have meant building a custom renderer for no real benefit.

**Solution:** switched the reporting scan's `format` from `sarif` to `template`, using Trivy's own bundled HTML report template (`contrib/html.tpl`), then converting that HTML to PDF with `wkhtmltopdf`, then uploading the PDF via `actions/upload-artifact@v4`.

As part of this change, `security-events: write` was removed from the job's `permissions` block and the `upload-sarif` step was deleted entirely, since nothing writes to Security anymore.

### 4.3 `contrib/html.tpl` not found

**Symptom:**
```
unable to write results: failed to initialize template writer: error retrieving template
from path: open contrib/html.tpl: no such file or directory
```

**Root cause:** `@contrib/html.tpl` is a path convention that only resolves if Trivy's own source tree is checked out locally (as it would be if you'd cloned `aquasecurity/trivy`). `aquasecurity/trivy-action` only downloads the standalone `trivy` binary onto the runner — there is no `contrib/` directory anywhere in the workspace for that reference to resolve against.

**Fix:** added a step before the scan that downloads the template directly:
```yaml
- name: Download Trivy HTML template
  run: |
    mkdir -p contrib
    curl -sSL -o contrib/html.tpl https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/html.tpl
```
This makes `@contrib/html.tpl` resolve to a real file relative to the job's working directory.

## 5. Known Risks / Open Items

| Item | Risk | Suggested follow-up |
|---|---|---|
| Template pinned to `main` branch of the Trivy repo | The action is pinned to `trivy-action@0.28.0`, but the template is pulled from `main` — the two can drift out of sync if Trivy changes the template schema upstream | Pin the raw.githubusercontent.com URL to the Trivy release tag matching `trivy-action@0.28.0`, rather than `main` |
| `wkhtmltopdf` is unmaintained (uses an old QtWebKit engine) | HTML/CSS in the report may not render pixel-perfect compared to a modern browser | Acceptable for a tabular vulnerability report; revisit with a headless-Chrome/Puppeteer conversion step if fidelity becomes an issue |
| **Dockerfile has not yet been fixed** | See §6 below — several issues identified but not yet applied | Prioritize before next scan cycle, since these are likely the source of most current findings |
| Stray `docker-trivy.yml` file at repo root (outside `.github/workflows/`) | Possible leftover/duplicate, not referenced by GitHub Actions | Confirm whether it's intentional; remove if not |

## 6. Dockerfile Findings (Not Yet Applied)

A review of the current `Dockerfile` (`ubuntu:22.04` base + `apt install golang-go`) surfaced the following, none of which have been fixed yet:

1. **No multi-stage build** — final image ships the full Go toolchain and apt cache alongside the compiled binary, inflating both image size and CVE surface.
2. **Outdated Go via `apt install golang-go`** — Ubuntu 22.04's repo Go package lags upstream by multiple versions, missing toolchain security patches.
3. **Container runs as root** — no `USER` directive.
4. **No apt cache cleanup** — `/var/lib/apt/lists/*` left in a layer.
5. **`COPY . .` with no `.dockerignore`** — copies the entire build context, including anything not meant for the image.
6. **Base image not pinned by digest** — `ubuntu:22.04` floats over time.
7. **Missing `--no-install-recommends`** on `apt install`.

**Recommendation:** switch to a multi-stage build (`golang` image to compile → `distroless/static` or `alpine` to run). This is expected to significantly reduce the findings currently driving the gating scan's failures.

## 7. Next Steps

- [ ] Pin the Trivy HTML template fetch to a specific release tag instead of `main`.
- [ ] Apply the multi-stage Dockerfile rewrite (§6).
- [ ] Confirm/remove the stray root-level `docker-trivy.yml`.
- [ ] Re-run the pipeline post-Dockerfile-fix and diff the PDF report against the current baseline.

## 8. References

- [Trivy Action (aquasecurity/trivy-action)](https://github.com/aquasecurity/trivy-action)
- [Trivy HTML report template source](https://github.com/aquasecurity/trivy/blob/main/contrib/html.tpl)
- [GitHub Actions: upload-artifact](https://github.com/actions/upload-artifact)
