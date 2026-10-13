# Conformance

One set of HTTP checks that every language's node SDK must pass. `run.py` plays the erupt server
(registration with a `/node-health` probe, `erupt-power` per session token, deregistration) and sends the
requests the real server would forward.

```bash
python conformance/run.py -- python3 python/examples/conformance.py
(cd go && go build -o /tmp/erupt-go-conformance ./examples/conformance) && python conformance/run.py -- /tmp/erupt-go-conformance
python conformance/run.py -- node ts/dist/examples/conformance.js
python conformance/run.py -- php php/examples/conformance.php
(cd dotnet && dotnet build -c Release) && python conformance/run.py -- dotnet dotnet/examples/Conformance/bin/Release/net8.0/Conformance.dll
```

The command starts the fixture below, reading `ERUPT_ACCESS_TOKEN`, `ERUPT_SERVER` and `PORT` from the
environment, listening on `127.0.0.1:$PORT`, registering `nodeAddress` `http://127.0.0.1:$PORT`, and
deregistering on SIGINT. Set `CONFORMANCE_TRACE=1` for stack traces.

## Fixture

Node name `conformance`. Every repository is in memory (PHP: a temporary SQLite file, since `php -S` keeps
nothing between requests).

**Category**: `id` pk; `name` Name (INPUT, search); `parent` Parent (NUMBER). Seeded in this order:
`Tech` (parent null), `Python` (parent 1), `Life` (parent null), so ids 1, 2, 3.

**PublishForm** (title "Publish Options", operation form only, not registered): `note` Note (INPUT, not null).

**Article**, default order `id desc`, fields in this order:

| Field | Title | Type | Flags |
|-------|-------|------|-------|
| `id` | | pk | |
| `title` | Title | INPUT | search, not null, sortable, raw edit `{"inputType": {"length": 64}}` |
| `status` | Status | CHOICE `draft` Draft, `published` Published | search |
| `views` | Views | NUMBER | sortable |
| `featured` | Featured | BOOLEAN | search |
| `publish_date` | Publish Date | DATE | search |
| `review_at` | Review At | DATE_TIME | |
| `body` | Body | TEXTAREA | hidden from the table |
| `category` | Category | REFERENCE_TABLE to Category, label `name` | search |
| `topic` | Topic | REFERENCE_TREE to Category, label `name`, pid `parent` | |

Operations, in this order:

| Code | Title | Mode | Other | Effect |
|------|-------|------|-------|--------|
| `publish` | Publish | MULTI | icon `fa fa-paper-plane`, form PublishForm, if_expr `item.status !== 'published'` | sets `status` to `published` on every row |
| `feature` | Feature | SINGLE | no confirm dialog | returns the script `alert('featured')` |
| `rebuild` | Rebuild | BUTTON | shown only when the user's account is `root` | none |

**Note**, power `delete` off: `id` pk; `text` Text (INPUT).
