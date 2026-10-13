# erupt-sdk

Erupt cloud node SDKs for languages other than Java. A node owns models and data; the erupt server
renders the admin UI, logs users in and checks menus. Wire contract: `erupt-cloud/PROTOCOL.md` in the
erupt repository.

| Dir | Status |
|-----|--------|
| `schema/` | `erupt-annotations.schema.json` and `erupt-node-defaults.json`, generated in the erupt repo by erupt-test `NodeSchemaTest` / `NodeDefaultsTest`; synced by `python/tools/gen_types.py` |
| `python/` | Level 0 prototype |

## Keeping in step with erupt

`schema/` is the whole contract between the two repositories. After an annotation change erupt regenerates
it (`mvn -pl erupt-test -Pnode-schema test`); here the `sync-schema` workflow (weekly, or run by hand with
a branch / tag of erupts/erupt) pulls it, regenerates every language's code and opens a pull request.
The `python` workflow fails on any generated file that no longer matches `schema/`.
