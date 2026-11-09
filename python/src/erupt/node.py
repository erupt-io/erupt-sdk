"""Erupt cloud node runtime: registers with the server, then answers the requests it forwards.
The wire contract is erupt-cloud/PROTOCOL.md, protocol v2 (§12): the server signs every call, enforces the user's
rights and the model's, checks and normalizes queries and records, and turns drills and link trees into conditions.
The node stores and reads rows and runs its own code."""
import base64
import contextvars
import io
import itertools
import json
import logging
import math
import re
import socket
import threading
import time
import traceback
import urllib.parse
import urllib.request
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

from . import _signature
from .model import to_json_value
from .repo import Cond, Query

log = logging.getLogger("erupt")

__version__ = "0.1.0"

# the node protocol this SDK speaks (PROTOCOL.md §12.2)
PROTOCOL_VERSION = 2

_user = contextvars.ContextVar("erupt_user", default=None)
_token = contextvars.ContextVar("erupt_token", default=None)

# Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
_UNSUPPORTED_POWER = {"print": False, "ai": False}

# the operators a condition may name: like a field name, it goes into a query, so it is checked whoever sends it
_OPS = {"EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"}

# a guard of the node's own: the server checks a page size too, but no call should make a node read without end
_MAX_PAGE_SIZE = 1000



def current_user():
    """The acting user of the request being served: ``{"uid", "account", "name", "tenantId"}``."""
    return _user.get()


class OperationContext:
    """What an ``@operation`` method receives."""

    def __init__(self, rows, param, repo, model, user):
        self.rows = rows    # selected records as the repository returned them; empty for BUTTON mode
        self.param = param  # coerced form values, or None without a form
        self.repo, self.model, self.user = repo, model, user


class _Reply(Exception):
    def __init__(self, status, body):
        self.status, self.body = status, body


# invoke kind -> the Field attribute holding its code
_INVOKED = {"options": "fetch", "onchange": "onchange", "autocomplete": "complete", "button": "click"}


class Fail(Exception):
    """A business error shown to the user as a message: raise it from a DataProxy hook or an operation."""


def _r(success=True, message=None, data=None):
    return {"success": success, "status": "SUCCESS" if success else "ERROR", "message": message, "data": data,
            "promptWay": "MESSAGE"}


class Node:

    def __init__(self, name, access_token, servers, *, address=None, heartbeat=15):
        """``access_token`` is the key the server signs every call with (PROTOCOL.md §4.3)."""
        if not access_token:
            raise ValueError("access_token is required")
        self.name, self.access_token = name, access_token
        self.servers = [s.rstrip("/") for s in ([servers] if isinstance(servers, str) else servers)]
        self.address, self.heartbeat = address, heartbeat
        self.models = {}
        self._server_cycle = itertools.cycle(self.servers)
        self._stop = threading.Event()
        # verb, path, endpoint, what the server must vouch for in Erupt-Enforced (§12.2)
        power, query, record = frozenset({"power"}), frozenset({"power", "query"}), frozenset({"power", "record"})
        self._routes = [
            ("GET", re.compile(r"^/erupt-api/build/([^/]+)$"), self._build, frozenset()),
            ("POST", re.compile(r"^/erupt-api/data/table/([^/]+)$"), self._table, query),
            ("GET", re.compile(r"^/erupt-api/data/init-value/([^/]+)$"), self._init_value, power),
            ("GET", re.compile(r"^/erupt-api/data/([^/]+)/([^/]+)$"), self._get, power),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)$"), self._add, record),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)/update$"), self._update, record),
            ("POST", re.compile(r"^/erupt-api/data/modify/([^/]+)/delete$"), self._delete, power),
            ("POST", re.compile(r"^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$"), self._invoke, power),
        ]

    def register(self, cls, repository):
        model = getattr(cls, "__erupt__", None)
        if model is None:
            raise ValueError(f"{cls.__name__} is not decorated with @erupt")
        if model.name in self.models:
            raise ValueError(f"erupt '{model.name}' registered twice")
        if model.pk is None:
            raise ValueError(f"{model.name} has no Field(pk=True); only an operation form may omit it")
        repository.bind(model)
        self.models[model.name] = (model, repository)
        return self

    def __call__(self, environ, start_response):
        try:
            status, body = self._dispatch(environ)
        except _Reply as reply:
            status, body = reply.status, reply.body
        except Fail as e:
            status, body = 200, _r(False, str(e))
        except Exception as e:  # never leak internals: message only, stack stays in the node log
            log.error("erupt node error\n%s", traceback.format_exc())
            status, body = 500, {"path": environ.get("PATH_INFO"), "status": 500, "error": "erupt exception",
                                 "message": str(e)}
        if isinstance(body, str):
            payload, content_type = body.encode(), "text/plain; charset=utf-8"
        else:
            payload, content_type = json.dumps(body, ensure_ascii=False).encode(), "application/json; charset=utf-8"
        start_response(f"{status} {_REASONS.get(status, '')}", [("Content-Type", content_type),
                                                                 ("Content-Length", str(len(payload)))])
        return [payload]

    def _dispatch(self, environ):
        path, method = environ.get("PATH_INFO", ""), environ["REQUEST_METHOD"]
        if path == "/node-health":
            return 200, self.name
        if not path.startswith("/erupt-api/"):
            raise _Reply(404, "")
        # server-to-server only: an Origin header means a browser reached the node directly
        if environ.get("HTTP_ORIGIN"):
            raise _Reply(403, "")
        enforced = self._authenticate(environ)
        erupt = environ.get("HTTP_ERUPT")
        for verb, pattern, handler, required in self._routes:
            match = pattern.match(path)
            if verb == method and match:
                # what lets the node skip the checks the server made: never the negotiation alone (§12.2)
                if not required <= enforced:
                    raise _Reply(403, "")
                name = urllib.parse.unquote(match.group(1))
                if erupt != name or name not in self.models:
                    raise _Reply(404, "")
                parent = environ.get("HTTP_ERUPTPARENT") or _query_param(environ, "_eruptParent")
                # nesting is not supported yet, so a parent can only vouch for itself
                if parent and parent.rsplit(".", 1)[-1] != name:
                    raise _Reply(404, "")
                user = environ.get("HTTP_USER")
                _user.set(json.loads(base64.b64decode(user)) if user else None)
                _token.set(environ.get("HTTP_TOKEN"))
                model, repo = self.models[name]
                args = [urllib.parse.unquote(g) for g in match.groups()[1:]]
                return 200, handler(model, repo, environ, *args)
        raise _Reply(404, "")

    def _authenticate(self, environ):
        """Every call is signed (§12.2); its Erupt-Enforced is what the server vouches for."""
        signature = environ.get("HTTP_ERUPT_SIGNATURE")
        if signature is None:
            raise _Reply(403, "")
        length = int(environ.get("CONTENT_LENGTH") or 0)
        body = environ["wsgi.input"].read(length) if length > 0 else b""
        environ["wsgi.input"] = io.BytesIO(body)  # handed on to the endpoint unchanged
        multipart = "multipart/form-data" in environ.get("CONTENT_TYPE", "")
        enforced = environ.get("HTTP_ERUPT_ENFORCED")
        if not _signature.verify(self.access_token, environ["REQUEST_METHOD"], _path_and_query(environ),
                                 environ.get("HTTP_ERUPT_TIMESTAMP"), enforced, environ.get("HTTP_USER"),
                                 None if multipart else body, signature, int(time.time())):
            raise _Reply(403, "")
        return frozenset(filter(None, (enforced or "").split(",")))

    # ---------------------------------------------------------------- endpoints

    def _build(self, model, repo, environ):
        # the rights the model switches off, and the features this SDK does not serve yet (§12.3)
        return model.build_model({**model.power, **_UNSUPPORTED_POWER}, current_user())

    def _table(self, model, repo, environ):
        return self._page(model, repo, _read_json(environ) or {})

    def _page(self, model, repo, body):
        page_index = max(int(body.get("pageIndex") or 1), 1)
        page_size = min(max(int(body.get("pageSize") or 10), 1), _MAX_PAGE_SIZE)
        query = Query(offset=(page_index - 1) * page_size, limit=page_size)
        # checked and normalized by the server, a drill's join and a link tree's keys among them (§12.4)
        for c in body.get("condition") or []:
            query.conditions.extend(self._conditions(model, c))
        for s in body.get("sort") or []:
            # "field.column" sorts by a reference's label: the server resolves labels, the node orders by the key
            f = model.fields.get(str(s.get("field") or "").split(".")[0])
            if f is None:
                raise Fail(f"illegal sort field '{s.get('field')}'")
            query.sort.append((f.name, str(s.get("direction", "ASC")).upper() == "DESC"))
        # a @Vis view's own filter and order, a drill's linkCondition, then the DataProxy's
        filters, sort = model.vis.get(body.get("vis"), ([], []))
        if not query.sort:
            query.sort = list(sort or model.order_by)
        query.filters = self._drill(body) + filters + model.filters(query.conditions)
        total, records = repo.page(query)
        rows = self._rows(model, records)
        model.hook("after_fetch", rows)
        return {"pageIndex": page_index, "pageSize": page_size, "total": total,
                "totalPage": math.ceil(total / page_size), "list": rows,
                "sort": None, "alert": None, "extraContent": None}

    def _drill(self, body):
        """A drilled table (§12.4): the server sent the join as a condition and names the drill, whose linkCondition
        the node adds."""
        drill = body.get("drill")
        if not drill:
            return []
        source = self.models.get(drill.get("erupt") or "")
        condition = source[0].drills.get(drill.get("code")) if source else None
        if condition is None:
            raise _Reply(403, "")
        return [(condition, [])] if condition else []

    @staticmethod
    def _conditions(model, c):
        # a name the node puts into a query is one of its stored fields, whoever sends it (§12.6)
        f = model.fields.get(c.get("key"))
        if f is None:
            raise Fail(f"illegal search field '{c.get('key')}'")
        op, value = c.get("expression"), c.get("value")
        if op not in _OPS:
            raise Fail(f"illegal operator '{op}'")
        if f.json and op in ("EQ", "IN", "NEQ", "NOT_IN"):
            # a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
            like = "LIKE" if op in ("EQ", "IN") else "NOT_LIKE"
            return [Cond(f.name, like, json.dumps(str(v))) for v in (value if isinstance(value, list) else [value])]
        if op in ("NULL", "NOT_NULL"):
            return [Cond(f.name, op)]
        if op in ("LIKE", "NOT_LIKE"):
            return [Cond(f.name, op, str(value))]
        try:
            # values arrive as the JSON type their field stores; dates become the repository's date types
            stored = [f.coerce(v) for v in value] if op in ("RANGE", "IN", "NOT_IN") else f.coerce(value)
        except (TypeError, ValueError) as e:
            raise Fail(f"{f.title}: {e}")
        return [Cond(f.name, op, stored)]

    def _init_value(self, model, repo, environ):
        record = {name: None for name in model.fields}
        model.hook("add_behavior", record)
        return self._rows(model, [record])[0]

    def _get(self, model, repo, environ, pk):
        record = repo.get(self._pk(model, pk))
        if record is None:
            raise Fail("record not found")
        model.hook("edit_behavior", record)
        return self._rows(model, [record])[0]

    def _add(self, model, repo, environ):
        record = self._record(model, _read_json(environ) or {})
        model.hook("validate", record)
        model.hook("before_add", record)
        repo.add(record)
        model.hook("after_add", record)
        return _r()

    def _update(self, model, repo, environ):
        body = _read_json(environ) or {}
        pk = self._pk(model, body.get(model.pk))
        if repo.get(pk) is None:
            raise Fail("record not found")
        record = self._record(model, body)
        model.hook("validate", record)
        model.hook("before_update", record)
        repo.update(pk, record)
        model.hook("after_update", record)
        return _r()

    def _delete(self, model, repo, environ):
        body = _read_json(environ)
        if not isinstance(body, list):
            raise Fail("a list of ids is required")
        pks = [self._pk(model, pk) for pk in body]
        # the hooks see each record as it was; reading them costs nothing without a proxy
        records = [r for r in (repo.get(pk) for pk in pks) if r is not None] if model.proxies else []
        for record in records:
            model.hook("before_delete", record)
        repo.delete(pks)
        for record in records:
            model.hook("after_delete", record)
        return _r()

    def _invoke(self, model, repo, environ, kind, name):
        """The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
        operation code, or a field's fetched options, onchange, auto-complete or button with the form's values."""
        if kind == "operation":
            return self._operation(model, repo, environ, name)
        if kind == "operation-form":
            return _r(data=self._operation_form_value(model, name))
        f = next((f for f in model.declared if f.name == name), None)
        fn = getattr(f, _INVOKED.get(kind, ""), None) if f else None
        if fn is None:
            raise _Reply(404, "")
        body = _read_json(environ) or {}
        form = body.get("form") or {}
        if kind == "autocomplete":
            return _r(data=list(fn(form, body.get("value") or "")))
        answer = fn(form)
        if kind == "options" and f.type != "TAGS":
            # {value: label} or [(value, label)], as the choices of a field
            answer = [{"value": str(v), "label": label} for v, label in (answer.items() if isinstance(answer, dict) else answer)]
        return _r(data=answer)

    @staticmethod
    def _rows(model, records):
        """Records to browser rows. A reference stays its key: the server resolves its label, the flattened
        <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3)."""
        return [{name: to_json_value(record.get(name)) for name in model.fields} for record in records]

    def _operation_of(self, model, code):
        op = model.operations.get(code)
        # a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        if op is None or not op.visible(current_user()):
            raise _Reply(404 if op is None else 403, "")
        return op

    def _operation_form_value(self, model, code):
        op = self._operation_of(model, code)
        # none without a form: the server answers the browser a 404, and it opens an empty one
        return {name: None for name in op.form_model.fields} if op.form else None

    def _operation(self, model, repo, environ, code):
        op = self._operation_of(model, code)
        body = _read_json(environ) or {}
        param = None
        if op.form:
            param = self._record(op.form_model, body.get("param") or {})
        rows = []
        if op.mode != "BUTTON":
            ids = body.get("ids")
            if not isinstance(ids, list) or not ids:
                raise Fail("select at least one row")
            if op.mode == "SINGLE" and len(ids) != 1:
                raise Fail("select exactly one row")
            for pk in ids:
                record = repo.get(self._pk(model, pk))
                if record is None:
                    raise Fail(f"record '{pk}' not found")
                rows.append(record)
        result = op.fn(OperationContext(rows, param, repo, model, current_user()))
        if isinstance(result, str) and result:
            return _r(data=result)
        return _r(message="Executed successfully")

    @staticmethod
    def _pk(model, value):
        try:
            return model.fields[model.pk].coerce(value)
        except (TypeError, ValueError):
            raise Fail(f"illegal id '{value}'")

    @staticmethod
    def _record(model, body):
        """A record the server checked and normalized (§12.4), as the repository stores it."""
        record = {}
        for f in model.fields.values():
            if f.pk or not f.form:
                continue
            try:
                record[f.name] = f.coerce(body.get(f.name))
            except (TypeError, ValueError) as e:
                raise Fail(f"{f.title}: {e}")
        return record

    # ---------------------------------------------------------------- server calls

    def config(self):
        """The config text set for this node on the erupt server (Node Config)."""
        return self._server_text(f"/erupt-cloud-api/node-config/{self.name}", {"Access-Token": self.access_token})

    def group_config(self):
        """The config text of this node's group on the erupt server."""
        return self._server_text(f"/erupt-cloud-api/node-group-config/{self.name}", {"Access-Token": self.access_token})

    def user_info(self):
        """The acting user's full info from the erupt server (roles, org, post...), for the request being served."""
        text = self._server_text(f"/erupt-cloud-api/userinfo/{self.name}",
                                 {"Access-Token": self.access_token, "token": _token.get() or ""})
        return json.loads(text) if text else None

    def _server_text(self, path, headers):
        with urllib.request.urlopen(urllib.request.Request(next(self._server_cycle) + path, headers=headers), timeout=5) as resp:
            return resp.read().decode("utf-8")

    def _node_info(self):
        return {"instanceId": self._instance_id, "nodeName": self.name, "accessToken": self.access_token,
                "version": f"python-{__version__}", "protocolVersion": PROTOCOL_VERSION, "nodeAddress": [self.address],
                "eruptModules": [], "erupts": list(self.models), "resources": {}, "capabilities": ["invoke"]}

    def _heartbeat_loop(self):
        failing = False
        while not self._stop.is_set():
            server = next(self._server_cycle)
            try:
                req = urllib.request.Request(server + "/erupt-cloud-api/register-node", method="POST",
                                             data=json.dumps(self._node_info()).encode(),
                                             headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    answer = resp.read()
                if not _speaks_v2(answer):
                    # an older server: it would call this node as v1, which it no longer answers (§12.2)
                    log.error("%s does not speak node protocol v%s: upgrade the erupt server; registration stopped",
                              server, PROTOCOL_VERSION)
                    return
                if failing:
                    log.info("%s -> connection success", server)
                failing = False
                self._stop.wait(self.heartbeat)
            except Exception as e:
                failing = True
                log.error("%s -> register failed: %s", server, e)
                self._stop.wait(self.heartbeat / 2)

    def _deregister(self):
        form = urllib.parse.urlencode({"nodeName": self.name, "accessToken": self.access_token,
                                       "locations": self.address}).encode()
        try:
            urllib.request.urlopen(urllib.request.Request(next(self._server_cycle) + "/erupt-cloud-api/remove-instance-node",
                                                          data=form, method="POST"), timeout=5).close()
        except Exception as e:
            log.error("deregister failed: %s", e)

    def serve(self, host="0.0.0.0", port=9090):
        """Serve forever: HTTP first (the server probes /node-health while registering), then heartbeat."""
        import secrets
        self._instance_id = secrets.token_hex(3)
        self.address = (self.address or f"http://{_local_ip(self.servers[0])}:{port}").rstrip("/")
        httpd = make_server(host, port, self, server_class=_ThreadingWSGIServer, handler_class=_QuietHandler)
        threading.Thread(target=self._heartbeat_loop, name="erupt-heartbeat", daemon=True).start()
        log.info("erupt node '%s' at %s -> %s", self.name, self.address, ", ".join(self.servers))
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            self._stop.set()
            self._deregister()
            httpd.server_close()


class _ThreadingWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True


class _QuietHandler(WSGIRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


_REASONS = {200: "OK", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"}


def _speaks_v2(answer):
    """Whether a register answer comes from a server that speaks this node's protocol (§12.2)."""
    try:
        reply = json.loads(answer or b"null")
    except ValueError:
        return False
    return isinstance(reply, dict) and reply.get("protocolVersion") == PROTOCOL_VERSION


def _read_json(environ):
    length = int(environ.get("CONTENT_LENGTH") or 0)
    if length <= 0:
        return None
    try:
        return json.loads(environ["wsgi.input"].read(length))
    except ValueError:
        raise Fail("malformed JSON body")


def _path_and_query(environ):
    """The request target as the server signed it: the raw path below the mount point, plus the query."""
    raw = environ.get("RAW_URI") or environ.get("REQUEST_URI")
    if raw:
        mount = environ.get("SCRIPT_NAME", "")
        return raw[len(mount):] if mount and raw.startswith(mount) else raw
    query = environ.get("QUERY_STRING", "")
    return urllib.parse.quote(environ.get("PATH_INFO", ""), safe="/") + ("?" + query if query else "")


def _query_param(environ, name):
    values = urllib.parse.parse_qs(environ.get("QUERY_STRING", "")).get(name)
    return values[0] if values else None


def _local_ip(server):
    """The interface address the server would see us on."""
    host = urllib.parse.urlparse(server).hostname or "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((host, 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
