# Local Build

The automated rolling workflow builds OpenAsar with `scripts/pack.js`, stamps a semver prerelease version, strips the source tree, and packs the final `app.asar`.

For local builds, use `scripts/pack.js`, which follows the same flow without modifying your working tree in place.

## Requirements

- `node`
- `asar`

Example install for the same `asar` version used by CI:

```bash
npm i -g asar@3.2.0
```

## Build With Normal Auto-Update Behavior

This keeps the default OpenAsar self-update behavior enabled.

```bash
node scripts/pack.js --version nightly-$(git rev-parse --short HEAD) --output tmp/app.asar
```

Unless overridden, builds update from:

```text
GooseMod/OpenAsar
```

## Build With A Custom Update Repo

Use this when you want a build to self-update from your own fork releases instead of upstream.

```bash
node scripts/pack.js --update-repo owner/repo --version nightly-$(git rev-parse --short HEAD) --output tmp/app.asar
```

## Build With A Custom Update Channel

`--update-channel` selects the GitHub Release tag used for self-updates instead of deriving it from the version prefix.

For example, the rolling build uses the moving `rolling-nightly` release:

```bash
node scripts/pack.js \
  --update-repo owner/repo \
  --update-channel rolling-nightly \
  --version 0.1.1-nightly.42+abcdef0 \
  --output tmp/app.asar
```

## Build With Auto-Update Disabled

Use this for local testing when you do not want the built `app.asar` to replace itself on launch.

```bash
node scripts/pack.js --disable-autoupdate --version nightly-$(git rev-parse --short HEAD)-localtest --output tmp/app.asar
```

## Release Channels

### Rolling Nightly

The `Rolling Nightly` workflow runs on relevant pushes to `main` and can also be dispatched manually. It:

- derives the next patch line from the latest stable `vX.Y.Z` tag
- stamps versions such as `0.1.1-nightly.42+abcdef0`
- runs stable and canary startup tests on Linux and Windows
- moves the `rolling-nightly` tag to the tested commit
- updates the existing `Rolling Nightly` GitHub prerelease and `app.asar` asset

The moving tag keeps the download URL stable without creating an immutable tag for every nightly build.

### Stable Releases

The `Release` workflow is manual. It must be dispatched from `main`, and the current commit must already be the successfully tested `rolling-nightly` commit.

The workflow accepts a `major`, `minor`, or `patch` bump, plus an optional explicit semantic version such as `1.0.0`. It creates an immutable `vX.Y.Z` tag and a normal, non-prerelease GitHub Release with generated release notes.

## Output

Local build commands above produce:

```text
tmp/app.asar
```
