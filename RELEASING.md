# Releasing

Each language is versioned and released on its own. A tag `<lang>/v<version>` runs that language's full CI
(generation check, unit tests, conformance), checks that the tag equals the version in the package
metadata and in the version the node reports to the server, publishes, and creates a GitHub release.

```bash
# 1. bump the version in the files below, merge to main
# 2. tag main and push the tag
git tag python/v0.2.0 && git push origin python/v0.2.0
```

| Tag | Registry | Version lives in |
|-----|----------|------------------|
| `python/vX.Y.Z` | PyPI `erupt-sdk` | `python/pyproject.toml`, `__version__` in `python/src/erupt/node.py` |
| `ts/vX.Y.Z` | npm `erupt-sdk` | `ts/package.json`, `VERSION` in `ts/src/node.ts` |
| `go/vX.Y.Z` | Go module proxy, `github.com/erupt-io/erupt-sdk/go` | `Version` in `go/node.go` (the tag itself is the release) |
| `php/vX.Y.Z` | Packagist `erupt-io/erupt-sdk`, through the split repository | `VERSION` in `php/src/Node.php` |
| `rust/vX.Y.Z` | crates.io `erupt-sdk` | `rust/Cargo.toml`, `VERSION` in `rust/src/node.rs` |
| `dotnet/vX.Y.Z` | NuGet `Erupt.Sdk` | `<Version>` in `dotnet/src/Erupt.Sdk/Erupt.Sdk.csproj`, `Version` in `dotnet/src/Erupt.Sdk/Node.cs` |

Java has no release here: `xyz.erupt:erupt-cloud-node` ships with erupt.

## One-time setup

No registry token is stored in this repository. Publishing uses OpenID Connect trusted publishing, so each
registry is told once that this repository's `release.yml` may publish the package. Each job runs in a
GitHub environment of the same name (`pypi`, `npm`, `nuget`, `packagist`, `crates-io`); add required reviewers there to
approve every release by hand.

- **PyPI**: on pypi.org add a pending trusted publisher for project `erupt-sdk`: owner `erupt-io`,
  repository `erupt-sdk`, workflow `release.yml`, environment `pypi`.
- **npm**: npm trusted publishing is configured on an existing package, so the first version is published
  by hand (`cd ts && npm ci && npm run build && npm publish --access public`). Then in the package settings on
  npmjs.com add a trusted publisher: GitHub Actions, `erupt-io/erupt-sdk`, workflow `release.yml`,
  environment `npm`.
- **NuGet**: on nuget.org add a trusted publishing policy for repository `erupt-io/erupt-sdk`, workflow
  `release.yml`, environment `nuget`, and set the repository variable `NUGET_USER` to the nuget.org account
  name that owns the policy.
- **Packagist**: Packagist reads a repository root, so `php/` is pushed to a read-only split repository.
  Create `erupt-io/erupt-sdk-php` (or set the repository variable `PHP_SPLIT_REPO`), create a fine-grained
  token with contents write on that repository only and save it as the `packagist` environment secret
  `PHP_SPLIT_TOKEN`, then submit the split repository on packagist.org and enable its GitHub hook.
- **crates.io**: trusted publishing is configured on an existing crate, so publish the first version by hand
  (`cd rust && cargo publish`). Then in the crate settings on crates.io add a trusted publisher:
  `erupt-io/erupt-sdk`, workflow `release.yml`, environment `crates-io`.
- **Go**: nothing; the module proxy picks the tag up.
- **GitHub**: Settings → Actions → General → allow GitHub Actions to create pull requests (used by
  `sync-schema.yml`).
