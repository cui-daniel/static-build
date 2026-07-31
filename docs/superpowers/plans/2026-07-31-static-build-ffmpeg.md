# static-build-ffmpeg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds a fully statically-linked ffmpeg 8.1.2 (Linux amd64) from source with a standard GPL codec set, packaged as a workflow artifact.

**Architecture:** Single workflow file mirroring the existing `static-build-rsync.yml` shape — `workflow_dispatch` trigger, `ubuntu-latest` runner in an `alpine:3.20` container, apk-installed `-dev` static libraries, ffmpeg compiled from source with `--enable-static` + `--pkg-config-flags=--static`, stripped, verified static, and uploaded. Verification is done two ways: `actionlint` for workflow schema, and a local Docker smoke build (mirrors CI exactly) to prove the binary is fully static with all libs enabled before pushing.

**Tech Stack:** GitHub Actions, `actions/upload-artifact@v4`, Alpine 3.20 (musl), ffmpeg 8.1.2, apk static `-dev` packages, actionlint, Docker (for local smoke test).

**Spec:** `docs/superpowers/specs/2026-07-31-static-build-ffmpeg-design.md`

**Note on TDD here:** There is no unit-test framework for a CI YAML. The "tests" are (1) `actionlint` validating the workflow schema/semantics, and (2) a local Docker build that reproduces the CI steps and asserts the binary is fully static (`ldd` shows no dynamic deps) with all `--enable-lib*` present. Treat the assertion commands and their expected output as the tests.

---

## File Structure

- **Create:** `.github/workflows/static-build-ffmpeg.yml` — the entire deliverable. One job, six steps (install deps → download → build → strip & verify → package → upload). No other files are created or modified.

The working tree currently has unrelated uncommitted changes (the rsync workflow migration: deleted root `static-build-rsync.yml`, untracked `.github/workflows/static-build-rsync.yml`, macOS `._*` junk). **Do not touch those.** Every commit in this plan stages only `.github/workflows/static-build-ffmpeg.yml` by explicit path.

---

### Task 1: Create the workflow file

**Files:**
- Create: `.github/workflows/static-build-ffmpeg.yml`

- [ ] **Step 1: Create the workflow file with full content**

Write `.github/workflows/static-build-ffmpeg.yml`:

```yaml
# Static ffmpeg build (Linux amd64, GPL).
# Produces a fully statically-linked ffmpeg + ffprobe + SHA256SUMS.
# License: linked against GPL libs (x264/x265/aom/...) -> binary is GPL.
#          fdk-aac is intentionally NOT enabled (non-free).

name: static-build-ffmpeg

on:
  workflow_dispatch:

env:
  FFMPEG_VERSION: "8.1.2"

jobs:
  build:
    runs-on: ubuntu-latest
    container: alpine:3.20

    steps:
      - name: Install build dependencies
        run: |
          apk add --no-cache \
            build-base pkgconf nasm yasm tar xz wget file \
            x264-dev x265-dev libvpx-dev aom-dev lame-dev opus-dev \
            libvorbis-dev libtheora-dev libwebp-dev libass-dev freetype-dev \
            fribidi-dev harfbuzz-dev fontconfig-dev libogg-dev

      - name: Download ffmpeg
        run: |
          wget "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
          tar -xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"

      - name: Build static ffmpeg
        run: |
          cd "ffmpeg-${FFMPEG_VERSION}"
          ./configure \
            --disable-debug --disable-doc \
            --disable-shared --enable-static \
            --enable-gpl --enable-version3 \
            --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
            --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora \
            --enable-libwebp --enable-libass --enable-libfreetype \
            --extra-cflags="-static" \
            --extra-ldflags="-static" \
            --extra-ldexeflags="-static" \
            --pkg-config-flags="--static"
          make -j"$(nproc)"

      - name: Strip and verify static linking
        run: |
          cd "ffmpeg-${FFMPEG_VERSION}"
          strip ffmpeg ffprobe
          file ffmpeg ffprobe
          ldd ffmpeg ffprobe || true
          ./ffmpeg -version | head -20

      - name: Package
        run: |
          mkdir -p dist
          cp "ffmpeg-${FFMPEG_VERSION}/ffmpeg" "ffmpeg-${FFMPEG_VERSION}/ffprobe" dist/
          sha256sum dist/ffmpeg dist/ffprobe > dist/SHA256SUMS
          cat dist/SHA256SUMS

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: ffmpeg-linux-amd64-static
          path: dist/
```

- [ ] **Step 2: Verify it is valid YAML (parses)**

Run (from repo root):
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/static-build-ffmpeg.yml')); print('YAML OK')"
```
Expected output: `YAML OK`. If it errors, fix indentation (ffmpeg YAML is whitespace-sensitive).

---

### Task 2: Lint the workflow with actionlint

**Files:** none (validation only)

`actionlint` validates GitHub Actions schema and semantics (job/step keys, action versions, expression syntax) beyond plain YAML parsing.

- [ ] **Step 1: Run actionlint via Docker**

Run:
```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no output, exit code 0 (clean). 

If Docker is unavailable, install actionlint another way and run `actionlint .github/workflows/static-build-ffmpeg.yml`:
```bash
# fallback options (pick one):
#   brew install actionlint
#   go install github.com/rhysd/actionlint/cmd/actionlint@latest
#   curl -sSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash
```

If actionlint reports errors (common: invalid `uses:` version, unknown key), fix them in the YAML and re-run until clean.

---

### Task 3: Local Docker smoke build — verify static linking + libs

**Files:** none (verification only)

This mirrors the CI steps exactly, in the same `alpine:3.20` image, to prove the build produces a fully static binary with all requested libs **before** relying on GitHub Actions. This directly verifies spec §5 (musl static-linking risk) and §6 (acceptance: static + `--enable-lib*` present).

> Requires Docker. Takes ~10–20 min (aom/x265 link + ffmpeg compile). If Docker is genuinely unavailable, skip this task and use Task 5 (CI) as the verification — but prefer running it; it's the fastest feedback loop for static-link issues.

- [ ] **Step 1: Run the full build in a local alpine:3.20 container**

Run from repo root:
```bash
docker run --rm \
  -e FFMPEG_VERSION=8.1.2 \
  -v "$PWD:/work" -w /work \
  alpine:3.20 sh -euxc '
    apk add --no-cache \
      build-base pkgconf nasm yasm tar xz wget file \
      x264-dev x265-dev libvpx-dev aom-dev lame-dev opus-dev \
      libvorbis-dev libtheora-dev libwebp-dev libass-dev freetype-dev \
      fribidi-dev harfbuzz-dev fontconfig-dev libogg-dev
    wget "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    tar -xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"
    cd "ffmpeg-${FFMPEG_VERSION}"
    ./configure \
      --disable-debug --disable-doc \
      --disable-shared --enable-static \
      --enable-gpl --enable-version3 \
      --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
      --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora \
      --enable-libwebp --enable-libass --enable-libfreetype \
      --extra-cflags="-static" \
      --extra-ldflags="-static" \
      --extra-ldexeflags="-static" \
      --pkg-config-flags="--static"
    make -j"$(nproc)"
    strip ffmpeg ffprobe
    echo "=== file ==="; file ffmpeg ffprobe
    echo "=== ldd ==="; ldd ffmpeg ffprobe || true
    echo "=== version ==="; ./ffmpeg -version | head -20
  '
```
Expected:
- `configure` finishes with a configuration summary listing each `--enable-libx264/libx265/libvpx/libaom/libmp3lame/libopus/libvorbis/libtheora/libwebp/libass/libfreetype`.
- `make` completes (exit 0).
- `file ffmpeg ffprobe` prints `... statically linked ...` for both.
- `ldd ffmpeg ffprobe` prints `not a dynamic executable` (or similar) for both — that is the pass condition.
- `./ffmpeg -version` first line is `ffmpeg version 8.1.2 ...` and the configuration line shows all `--enable-lib*`.

- [ ] **Step 2: If ldd shows dynamic dependencies (static link failed)**

This is the spec's known risk. Inspect what's unresolved, then add the needed libs/flags and re-run Step 1. Typical fixes:
- Missing transitive static dep → add its `-dev` package to the `apk add` line.
- Unresolved `pthread`/`m`/`dl` → add `--extra-libs="-lpthread -lm -ldl"` to `./configure`.
Apply the same fix to **both** the smoke command above and the workflow YAML in Task 1, then re-run until `ldd` reports no dynamic deps. Do not commit until the smoke build is fully static.

---

### Task 4: Commit the workflow

**Files:**
- Commit: `.github/workflows/static-build-ffmpeg.yml`

- [ ] **Step 1: Stage only the new workflow file (avoid the unrelated rsync changes in the working tree)**

Run:
```bash
git add .github/workflows/static-build-ffmpeg.yml
git status --short
```
Expected: only `.github/workflows/static-build-ffmpeg.yml` is staged (`A  .github/workflows/static-build-ffmpeg.yml`). The rsync deletion/untracked files must remain unstaged.

- [ ] **Step 2: Commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
Add static-build-ffmpeg workflow

Builds a fully statically-linked ffmpeg 8.1.2 (Linux amd64) from source
in an alpine:3.20 container with a standard GPL codec set
(x264/x265/vpx/aom/mp3lame/opus/vorbis/theora/webp/ass/freetype).
Verified static via local Docker smoke build.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```
Expected: a new commit is created touching only `.github/workflows/static-build-ffmpeg.yml`.

---

### Task 5: Push, trigger on Actions, verify the artifact

**Files:** none (CI run + download)

This is the end-to-end acceptance test (spec §6).

- [ ] **Step 1: Push and trigger the workflow**

Run:
```bash
git push origin main
gh workflow run static-build-ffmpeg.yml
gh run watch
```
(If `gh` isn't authenticated, trigger via the Actions UI: Repositories → Actions → "static-build-ffmpeg" → Run workflow.)
Expected: the run goes green. If a step fails, read the log, fix the YAML (most likely the same static-link flags as Task 3 Step 2), push, and re-run.

- [ ] **Step 2: Download and verify the artifact**

Run:
```bash
gh run download $(gh run list -w static-build-ffmpeg.yml -L 1 --json databaseID -q '.[0].databaseID') \
  -n ffmpeg-linux-amd64-static -D /tmp/ffmpeg-artifact
cd /tmp/ffmpeg-artifact
file ffmpeg ffprobe                       # expect: statically linked
ldd ffmpeg ffprobe || true                # expect: not a dynamic executable
sha256sum -c SHA256SUMS                   # expect: ffmpeg: OK / ffprobe: OK
./ffmpeg -version | head -3               # expect: version 8.1.2 + config line
```
Expected: all checks pass — fully static, checksums verify, version 8.1.2 with all `--enable-lib*` shown. If everything passes, the feature is complete.
