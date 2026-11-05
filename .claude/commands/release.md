---
description: Release erupt-sdk packages — bump, tag one language at a time, watch release.yml, verify each registry
argument-hint: <version, e.g. 0.2.0> [lang...]  (langs: python ts go php dotnet rust ruby swift; default = every released one)
allowed-tools: Bash, Read, Grep, Edit
---

# erupt-sdk release

Arguments: **$ARGUMENTS** — the first word is the version (`VER`), the rest the languages (`LANGS`).
No version given: run `scripts/release.sh status`, propose the next patch version and ask the user to confirm.
No languages given: every language that is already on its registry (see the `status` column REGISTRY).

All publishing happens in `.github/workflows/release.yml` through trusted publishing; this machine holds no
registry token. `scripts/release.sh` does the bump/commit/tag; this command drives it and checks the result.
One-time registry setup lives in `RELEASING.md`.

| Lang | Tag | Lands on | Verify |
|------|-----|----------|--------|
| python | `python/vVER` | PyPI `erupt-sdk` | `https://pypi.org/pypi/erupt-sdk/VER/json` |
| ts | `ts/vVER` | npm `erupt-sdk` | `https://registry.npmjs.org/erupt-sdk/VER` |
| go | `go/vVER` | Go module proxy | `https://proxy.golang.org/github.com/erupt-io/erupt-sdk/go/@v/vVER.info` |
| php | `php/vVER` | `erupt-io/erupt-sdk-php` tag `vVER` → Packagist | `https://repo.packagist.org/p2/erupt-io/erupt-sdk.json` |
| dotnet | `dotnet/vVER` | NuGet `Erupt.Sdk` | `https://api.nuget.org/v3-flatcontainer/erupt.sdk/index.json` (validation can take 30+ min) |
| rust | `rust/vVER` | crates.io `erupt-sdk` | `https://crates.io/api/v1/crates/erupt-sdk/VER` |
| ruby | `ruby/vVER` | RubyGems `erupt-sdk` | `https://rubygems.org/api/v2/rubygems/erupt-sdk/versions/VER.json` |
| swift | `swift/vVER` | `erupt-io/erupt-sdk-swift` tag `VER` | `git ls-remote --tags https://github.com/erupt-io/erupt-sdk-swift.git` |

## 1. Preflight (read-only; stop and report on any red check)

- `gh auth status` succeeds; repository is `erupt-io/erupt-sdk` (`git remote -v`).
- On `main`, no tracked changes, level with `origin/main` after `git pull --ff-only`.
- No `<lang>/vVER` tag exists locally or remotely (`git ls-remote --tags origin`).
- `VER` is semver; for ruby a pre-release is written `1.2.3.rc1`, never with `-`.
- Go stays on v0/v1: a v2+ tag would need a `/v2` module path. Refuse and explain.
- First release of ts or rust (not on the registry yet): stop. npm and crates.io need one manual publish
  (`scripts/release.sh bootstrap ts|rust` after the user ran `npm login` / `cargo login` themselves),
  then a trusted publisher on the registry. Do not continue for that language.
- php / swift: the environment secrets `PHP_SPLIT_TOKEN` (env `packagist`) / `SWIFT_SPLIT_TOKEN` (env
  `swiftpm`) exist — `gh secret list --env <env> -R erupt-io/erupt-sdk` (names only).
- Recent CI on `main` is green for each language: `gh run list -R erupt-io/erupt-sdk --branch main --limit 20`.

## 2. Dry run, then confirm

Run `scripts/release.sh --dry-run VER LANGS...` and show the user the version diff and the tags it would
push. Ask for an explicit go before step 3: tags trigger publishing, and a published version can never be
re-used on any registry.

## 3. Release

`scripts/release.sh VER LANGS...` — bumps the version files, commits `Release ... vVER` on `main`, pushes,
then pushes one tag at a time (GitHub starts no workflow for a push of more than three tags).

The script commits straight to `main`. If the user wants the bump through a pull request instead: run the
dry-run bump on a `release/vVER` branch, open the PR, wait for the merge, then run the script on `main`
(it skips the commit when the files already hold `VER` and only tags).

## 4. Watch

Watch the `release` runs, one per tag, until all complete; report each terminal state
(`success|failure|cancelled`). Each run is that language's full CI (generation check, unit tests,
conformance) followed by the publish job and a GitHub release.

## 5. Verify

For every language, query the Verify URL in the table and report the version found. A registry still
returning 404 right after a green run: say so and re-check later (NuGet validation, Packagist crawl,
pkg.go.dev indexing) — do not treat that alone as a failure.

## 6. On failure

Read `gh run view <id> --log-failed`. Then:

- **Failed before the publish job** (CI, setup, version check): nothing was published. Fix through a PR; once
  merged, and with the user's go, move the tag to the new `main`:
  `git push origin :refs/tags/<lang>/vVER && git tag -d <lang>/vVER && git tag <lang>/vVER && git push origin <lang>/vVER`.
  First check `gh release view <lang>/vVER` fails — a GitHub release means something shipped.
- **Failed in or after the publish step**: check the registry first. Published → never re-tag; fix forward
  with the next patch version. Not published → as above.

Known causes seen before:

- `setup-<lang>` cannot find a version on `ubuntu-latest` (it moved to 26.04; Python 3.9 has no build there)
  → pin the runner of that language's workflow.
- RubyGems rejects the exchange or the push: a pending trusted publisher expires after ~12 h and its first
  push must name the owner (`RUBYGEMS_OWNER`, default `255640`); recreate it on rubygems.org.
- NuGet: the trusted publishing policy must be used within 7 days of creation; `NUGET_USER` must be the
  policy owner's nuget.org name.
- php / swift push denied **to `github-actions[bot]`**: the checkout's persisted `GITHUB_TOKEN` was used
  instead of the split token — the checkout step needs `persist-credentials: false`. Denied to a user: the
  split token expired, lacks Contents write, or awaits the org's fine-grained token approval. To check a new
  token before saving it, ask for `info/refs?service=git-receive-pack` on the mirror with it (200 = can push);
  the REST `permissions.push` field reflects the user, not the token.

## Rules

- Never read, print, write or pass a token on the command line. Secrets are set by the user with
  `gh secret set` in their own terminal. If the user explicitly asks to take a token from the clipboard, pipe
  it straight in (`pbpaste | tr -d '\r\n' | gh secret set NAME --env ENV -R erupt-io/erupt-sdk`) after
  checking only its shape, never echoing it.
- A token pasted into the chat is leaked: do not use it; ask the user to revoke it and make a new one.
- Registry sign-ups, logins, OAuth grants and password prompts are the user's.
- End with a table: language, tag, run result, version on the registry, link.
