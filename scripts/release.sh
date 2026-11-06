#!/usr/bin/env bash
# One-command release of erupt-sdk packages. Publishing itself runs in .github/workflows/release.yml
# (trusted publishing, no token on this machine); this script bumps every version file, commits, and
# pushes one <lang>/v<version> tag per language.
#
#   scripts/release.sh 0.2.0                      release every language at 0.2.0
#   scripts/release.sh 0.2.0 python ts rust       release only these
#   scripts/release.sh --dry-run 0.2.0 ruby       show the version diff, change nothing
#   scripts/release.sh bootstrap [ts] [rust]      first publish by hand (npm and crates.io require one)
#   scripts/release.sh status                     versions in the repository vs. on each registry
set -euo pipefail

ALL=(python ts go php dotnet rust ruby swift)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# replace the first capture group's value in a file; the version comes in through the environment
set_line() { # file perl-regex-with-(prefix)(value)(suffix)
  V="$NEW" perl -0pi -e "s/$2/\${1}\$ENV{V}\${3}/m" "$1"
  grep -q "$NEW" "$1" || die "$1: version not written"
}

bump() { # lang
  case $1 in
    python)
      set_line python/pyproject.toml '(^version = ")([^"]*)(")'
      set_line python/src/erupt/node.py '(__version__ = ")([^"]*)(")' ;;
    ts)
      (cd ts && npm version "$NEW" --no-git-tag-version --allow-same-version >/dev/null)
      set_line ts/src/node.ts '(export const VERSION = ")([^"]*)(")' ;;
    go)
      set_line go/node.go '(const Version = ")([^"]*)(")' ;;
    php)
      set_line php/src/Node.php "(public const VERSION = ')([^']*)(')" ;;
    dotnet)
      set_line dotnet/src/Erupt.Sdk/Erupt.Sdk.csproj '(<Version>)([^<]*)(<\/Version>)'
      set_line dotnet/src/Erupt.Sdk/Node.cs '(public const string Version = ")([^"]*)(")' ;;
    rust)
      set_line rust/Cargo.toml '(\[package\]\nname = "erupt-sdk"\nversion = ")([^"]*)(")'
      set_line rust/Cargo.lock '(name = "erupt-sdk"\nversion = ")([^"]*)(")'
      set_line rust/src/node.rs '(pub const VERSION: &str = ")([^"]*)(")' ;;
    ruby)
      set_line ruby/lib/erupt/version.rb '(VERSION = ")([^"]*)(")' ;;
    swift)
      set_line swift/Sources/EruptSDK/Node.swift '(public static let version = ")([^"]*)(")' ;;
  esac
}

current() { # lang -> version in the repository
  case $1 in
    python) sed -n 's/^version = "\(.*\)"/\1/p' python/pyproject.toml ;;
    ts)     sed -n 's/^  "version": "\(.*\)",/\1/p' ts/package.json ;;
    go)     sed -n 's/^const Version = "\(.*\)"/\1/p' go/node.go ;;
    php)    sed -n "s/.*public const VERSION = '\(.*\)';/\1/p" php/src/Node.php ;;
    dotnet) sed -n 's/.*<Version>\(.*\)<\/Version>.*/\1/p' dotnet/src/Erupt.Sdk/Erupt.Sdk.csproj ;;
    rust)   sed -n '3s/^version = "\(.*\)"/\1/p' rust/Cargo.toml ;;
    ruby)   sed -n 's/.*VERSION = "\(.*\)"/\1/p' ruby/lib/erupt/version.rb ;;
    swift)  sed -n 's/.*public static let version = "\(.*\)"/\1/p' swift/Sources/EruptSDK/Node.swift ;;
  esac
}

published() { # lang -> latest version on the registry, or "-"
  local q='curl -fsS -A erupt-sdk-release'
  case $1 in
    python) $q https://pypi.org/pypi/erupt-sdk/json 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1 ;;
    ts)     $q https://registry.npmjs.org/erupt-sdk/latest 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' ;;
    go)     $q https://proxy.golang.org/github.com/erupt-io/erupt-sdk/go/@latest 2>/dev/null | sed -n 's/.*"Version":"v\([^"]*\)".*/\1/p' ;;
    php)    $q https://repo.packagist.org/p2/erupt-io/erupt-sdk.json 2>/dev/null | sed -n 's/[^[]*\[{"name":"erupt-io\/erupt-sdk"[^}]*"version":"v\{0,1\}\([^"]*\)".*/\1/p' ;;
    dotnet) $q https://api.nuget.org/v3-flatcontainer/erupt.sdk/index.json 2>/dev/null | tr -d ' \n' | sed -n 's/.*"\([^"]*\)"\]}/\1/p' ;;
    rust)   $q https://crates.io/api/v1/crates/erupt-sdk 2>/dev/null | sed -n 's/.*"max_version":"\([^"]*\)".*/\1/p' ;;
    ruby)   $q https://rubygems.org/api/v1/gems/erupt-sdk.json 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' ;;
    swift)  git ls-remote --tags --refs https://github.com/erupt-io/erupt-sdk-swift.git 2>/dev/null | sed 's|.*refs/tags/||' | sort -V | tail -1 ;;
  esac
}

status() {
  printf '%-8s %-12s %s\n' LANG REPOSITORY REGISTRY
  for l in "${ALL[@]}"; do
    local p; p=$(published "$l" || true)
    printf '%-8s %-12s %s\n' "$l" "$(current "$l")" "${p:--}"
  done
}

bootstrap() { # npm and crates.io configure trusted publishing on an existing package only
  local langs=("$@"); [ ${#langs[@]} -gt 0 ] || langs=(ts rust)
  for l in "${langs[@]}"; do
    case $l in
      ts)
        npm whoami >/dev/null 2>&1 || die "run 'npm login' first"
        info "npm: publishing erupt-sdk $(current ts)"
        (cd ts && npm ci && npm run build && npm test && npm publish --access public) ;;
      rust)
        info "crates.io: publishing erupt-sdk $(current rust) (needs 'cargo login' with a crates.io token)"
        (cd rust && cargo publish --locked) ;;
      *) die "bootstrap is only needed for ts and rust" ;;
    esac
  done
  echo "Done. Now add the trusted publisher on npmjs.com / crates.io (see RELEASING.md)."
  echo "Do not tag the version just published; release the next one with this script."
}

release() {
  local dry=0
  [ "${1:-}" = --dry-run ] && { dry=1; shift; }
  NEW=${1:-}; shift || true
  [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || die "version must look like 1.2.3 or 1.2.3-rc.1"
  local langs=("$@"); [ ${#langs[@]} -gt 0 ] || langs=("${ALL[@]}")
  for l in "${langs[@]}"; do
    [[ " ${ALL[*]} " == *" $l "* ]] || die "unknown language '$l' (one of: ${ALL[*]})"
    [ "$l" = ruby ] && [[ "$NEW" == *-* ]] && die "RubyGems writes a pre-release as 1.2.3.rc1, not with '-'"
    git rev-parse -q --verify "refs/tags/$l/v$NEW" >/dev/null && die "tag $l/v$NEW already exists"
  done
  git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"

  if [ $dry = 0 ]; then
    [ "$(git branch --show-current)" = main ] || die "release from main"
    git pull --ff-only -q
  fi

  for l in "${langs[@]}"; do bump "$l"; done

  if [ $dry = 1 ]; then
    git --no-pager diff --stat; git --no-pager diff
    git checkout -q -- .
    info "dry run: would tag ${langs[*]/%//v$NEW}"
    return
  fi

  if ! git diff --quiet; then
    git commit -qam "Release ${langs[*]} v$NEW"
    git push -q origin main
  fi
  # GitHub starts no workflow for a push carrying more than three tags, so push them one by one
  for l in "${langs[@]}"; do
    git tag "$l/v$NEW"
    git push -q origin "$l/v$NEW"
    info "pushed $l/v$NEW"
  done
  echo "Publishing runs in GitHub Actions: $(gh repo view --json url -q .url 2>/dev/null || echo 'the repository')/actions/workflows/release.yml"
}

case ${1:-} in
  ""|-h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  status) status ;;
  bootstrap) shift; bootstrap "$@" ;;
  *) release "$@" ;;
esac
