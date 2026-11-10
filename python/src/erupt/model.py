"""Model declaration: ``@erupt`` classes with ``Field`` attributes and ``@operation`` methods, compiled into
erupt build JSON.

Nothing here re-implements annotation semantics. The build carries only what a model declares; the server
completes every annotation from its Java defaults and checks it (erupt-cloud/PROTOCOL.md §12.3, protocol v2).
"""
import copy
import datetime
import json
import re
import typing
from typing import Optional

from ._types import Edit, EditType, RowOperationMode, View

_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# edit type -> python type a value is coerced to
_PY_TYPES = {
    "INPUT": str, "TEXTAREA": str, "CHOICE": str, "NUMBER": float,
    "BOOLEAN": bool, "DATE": datetime.date, "DATE_TIME": datetime.datetime,
    "TAGS": str, "AUTO_COMPLETE": str, "ATTACHMENT": str, "HTML_EDITOR": str, "MARKDOWN": str, "CODE_EDITOR": str,
    "COLOR": str, "ICON": str, "SIGNATURE": str, "MAP": str, "HIDDEN": str, "RATE": float, "SLIDER": float,
}

# fieldReturnName by edit type (PROTOCOL.md §7.1); a reference names its target, the rest are "String"
_RETURN_NAMES = {"NUMBER": "number", "RATE": "number", "SLIDER": "number", "BOOLEAN": "Boolean", "DATE": "Date",
                 "DATE_TIME": "Date"}

# rights a model may switch off (@Erupt power, PowerObject)
_POWERS = ("add", "edit", "delete", "query", "viewDetails", "export", "importable", "print", "copy", "cellEdit",
           "batchEdit", "ai", "comment", "revision")

_INFER = [(bool, "BOOLEAN"), (int, "NUMBER"), (float, "NUMBER"),
          (datetime.datetime, "DATE_TIME"), (datetime.date, "DATE"), (str, "INPUT")]

_REFERENCES = ("REFERENCE_TABLE", "REFERENCE_TREE")
# many records of another model, stored as the JSON list of their keys
_COLLECTIONS = ("CHECKBOX", "TAB_TREE", "TRANSFER")
# the edit attribute that names a fetchHandler, by the type that fetches options
_FETCHED = {"CHOICE": "choiceType", "MULTI_CHOICE": "multiChoiceType", "TAGS": "tagsType"}

_SUPPORTED = (*_PY_TYPES, *_REFERENCES, *_COLLECTIONS, "MULTI_CHOICE", "BUTTON")


def _check_enum(literal, value, path):
    """A misspelt enum value fails where the model is declared; everything else the server checks (§12.3)."""
    allowed = typing.get_args(literal)
    if value not in allowed:
        raise ValueError(f"{path}: '{value}' is not one of {', '.join(allowed)}")


def _is_json(hint):
    """``list`` / ``dict`` (bare or parameterised) hold a JSON value: MULTI_CHOICE, KEY_VALUE."""
    return (typing.get_origin(hint) or hint) in (list, dict)



def _merge(target, override):
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)
    return target


class Field:
    """One column. ``title`` labels both the table column and the form input; ``view`` / ``edit`` take raw
    annotation attributes (``{"inputType": {"length": 64}}``) for anything the shortcuts do not cover.

    A field annotated with another ``@erupt`` class references one of its records: the repository stores the
    referenced primary key, the UI shows ``label``. ``tree`` names the referenced model's parent field and
    turns the picker into a tree.

    A ``list`` / ``dict`` annotation holds a JSON value (MULTI_CHOICE, KEY_VALUE): stored as JSON text by SQL
    repositories, served as JSON. ``virtual=True`` declares a form-only element (DIVIDE, CALLOUT, EMPTY, GROUP)
    that is in the build but never read or written."""

    def __init__(self, title="", *, type: Optional[EditType] = None, pk=False, search=False, not_null=False,
                 sortable=False, table=True, form=True, choices=None, ref=None, label="name", tree=None,
                 view: Optional[View] = None, edit: Optional[Edit] = None, virtual=False,
                 fetch=None, onchange=None, complete=None, click=None):
        self.title, self.type, self.pk, self.virtual, self.json = title, type, pk, virtual or type == "BUTTON", False
        # the field's own code, run by the node when the server invokes it
        self.fetch, self.onchange, self.complete, self.click = fetch, onchange, complete, click
        self.search, self.not_null, self.sortable = search, not_null, sortable
        self.table, self.form = table, form
        self.choices = dict(choices) if choices else None
        self.ref, self.label, self.tree = ref, label, tree
        self.view, self.edit = view or {}, edit or {}
        self.name = None

    def resolve_type(self, hint):
        if self.ref is None and hasattr(hint, "__erupt__"):
            self.ref = hint
        if self.type in _COLLECTIONS:
            return self.type
        if self.ref is not None:
            return "REFERENCE_TREE" if self.tree else "REFERENCE_TABLE"
        if self.type:
            return self.type
        if self.choices or self.fetch:
            return "MULTI_CHOICE" if _is_json(hint) else "CHOICE"
        for py, edit_type in _INFER:
            if isinstance(hint, type) and issubclass(hint, py):
                return edit_type
        return "INPUT"

    @property
    def target(self):
        """The referenced model, for a reference field."""
        return self.ref.__erupt__

    def build(self):
        """The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults."""
        if self.pk:
            return {"fieldName": self.name, "fieldReturnName": "number", "componentValue": None,
                    "eruptFieldJson": {"edit": {"title": "", "type": "NUMBER"}}}
        # a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
        edit = {"title": self.title, "type": "DATE" if self.type == "DATE_TIME" else self.type}
        if self.type in ("DATE", "DATE_TIME"):
            edit["dateType"] = {"type": self.type}
        if self.not_null:
            edit["notNull"] = True
        if not self.form:
            edit["show"] = False
        if self.search:
            edit["search"] = {"value": True}
        view = {"title": self.title}
        if self.sortable:
            view["sortable"] = True
        return_name = _RETURN_NAMES.get(self.type, "String")
        if self.type == "REFERENCE_TABLE":
            edit["referenceTableType"] = {"id": self.target.pk, "label": self.label}
        elif self.type == "REFERENCE_TREE":
            edit["referenceTreeType"] = {"id": self.target.pk, "label": self.label, "pid": self.tree}
        if self.type in _REFERENCES + _COLLECTIONS:
            # the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            return_name = self.target.name
            view["column"] = self.label
        if self.fetch and self.type in _FETCHED:
            edit[_FETCHED[self.type]] = {"fetchHandler": ["invoke"]}
        if self.onchange:
            edit["onchange"] = "invoke"
        _merge(edit, self.edit)
        _merge(view, self.view)
        # a BUTTON is a form element only: no table column
        views = [view] if self.table and self.type != "BUTTON" else []
        options = None
        if self.choices:  # CHOICE, or MULTI_CHOICE over a list
            options = [{"value": str(v), "label": label, "desc": None, "color": None, "disable": False}
                       for v, label in self.choices.items()]
        return {"fieldName": self.name, "fieldReturnName": return_name, "componentValue": options,
                "eruptFieldJson": {"edit": edit, "views": views}}

    def coerce(self, value):
        """A JSON value as the server sends it (PROTOCOL.md §12.4) to the python value the repository stores: a date
        as ``date`` / ``datetime``, a key as its key type. The server has checked it; a key in a path segment, a
        delete body or an operation's ids arrives as the browser sent it, so it may fail here."""
        if self.type in _REFERENCES:
            return self.target.fields[self.target.pk].coerce(value)
        if self.type in _COLLECTIONS:
            pk = self.target.fields[self.target.pk]
            return [pk.coerce(v) for v in (value or [])]
        if value is None or value == "":
            return None
        if self.json:
            return value
        if self.pk:
            return int(value)
        py = _PY_TYPES[self.type]
        if py is float:
            return int(value) if float(value).is_integer() else float(value)
        if py is datetime.datetime:
            return _parse_datetime(value)
        if py is datetime.date:
            return _parse_datetime(value).date()
        return value


def _parse_datetime(value):
    text = str(value).replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(text, fmt)
        except ValueError:
            pass
    raise ValueError(f"illegal date '{value}'")


def to_json_value(value):
    if isinstance(value, datetime.datetime):
        return value.strftime("%Y-%m-%dT%H:%M:%S.") + f"{value.microsecond // 1000:03d}"
    if isinstance(value, datetime.date):
        return value.strftime("%Y-%m-%d")
    return value


class Operation:
    """A row operation declared with ``@operation``."""

    def __init__(self, fn, title, code, mode, icon, tip, confirm, form, show, if_expr, raw):
        _check_enum(RowOperationMode, mode, f"@operation {fn.__name__}.mode")
        self.fn, self.title, self.code = fn, title, code or fn.__name__
        self.mode, self.icon, self.tip, self.confirm = mode, icon, tip, confirm
        self.form, self.show, self.if_expr, self.raw = form, show, if_expr, raw

    @property
    def form_model(self):
        return self.form.__erupt__ if self.form else None

    def visible(self, user):
        return self.show is None or bool(self.show(user))

    def build(self):
        tpl = {"code": self.code, "title": self.title, "mode": self.mode, "tip": self.tip, "ifExpr": self.if_expr,
               "eruptClass": self.form_model.name if self.form else "void"}
        if self.icon:
            tpl["icon"] = self.icon
        if self.confirm is False:
            tpl["callHint"] = ""  # the browser runs it without asking
        elif isinstance(self.confirm, str):
            tpl["callHint"] = self.confirm
        return _merge(tpl, self.raw)


def operation(title, *, code=None, mode: RowOperationMode = "MULTI", icon=None, tip="", confirm=True, form=None, show=None, if_expr="",
              **raw):
    """Declare a row operation on an ``@erupt`` class. The method receives an ``OperationContext`` (``rows``,
    ``param``, ``repo``, ``user``); a returned string is run as JavaScript in the browser, so only return code
    you wrote. ``mode``: SINGLE (row button), MULTI (row and toolbar), MULTI_ONLY (toolbar), BUTTON (toolbar, no
    rows). ``form``: an ``@erupt`` class whose fields are asked for before running. ``confirm``: False skips
    the confirm dialog, a string replaces its text. ``show(user)`` hides the operation and refuses to run it.
    ``if_expr``: browser-side JS over ``item`` that disables (or hides) the row button. Other keyword
    arguments are raw ``@RowOperation`` attributes (see ``erupt._types.RowOperation``)."""

    def wrap(fn):
        fn.__erupt_operation__ = Operation(fn, title, code, mode, icon, tip, confirm, form, show, if_expr, raw)
        return fn

    return wrap


class DataProxy:
    """Hooks around a model's data, as erupt's Java ``DataProxy``: subclass it, override what you need and pass
    it as ``@erupt(..., data_proxy=...)``. A record is the dict the repository stores, a row the dict the
    browser reads; change them in place. Raise ``Fail`` to refuse with a message."""

    def search_condition(self, condition):
        """Default values of the search bar, ``condition[field] = value``."""

    def before_fetch(self, conditions):
        """SQL ANDed to a table page's WHERE, as written: ``"status <> 'deleted'"``, or with its values bound,
        ``("owner = ?", [uid])``. ``conditions`` are the search bar's. Only SQL repositories apply it."""

    def after_fetch(self, rows):
        """The rows of a table page, before they are sent."""

    def add_behavior(self, record):
        """The values a new record's form opens with."""

    def edit_behavior(self, record):
        """A record read by its key, for the edit form or the detail view."""

    def validate(self, record):
        """A record about to be added or updated."""

    def before_add(self, record):
        pass

    def after_add(self, record):
        pass

    def before_update(self, record):
        pass

    def after_update(self, record):
        pass

    def before_delete(self, record):
        pass

    def after_delete(self, record):
        pass


class Model:
    def __init__(self, cls, name, title, power, order_by, raw, data_proxy=()):
        if not _IDENTIFIER.match(name):
            raise ValueError(f"erupt name '{name}' must be an identifier")
        self.cls, self.name, self.title = cls, name, title
        proxies = data_proxy if isinstance(data_proxy, (list, tuple)) else [data_proxy]
        self.proxies = [p() if isinstance(p, type) else p for p in proxies]
        for p in self.proxies:
            if not isinstance(p, DataProxy):
                raise ValueError(f"{name}: data_proxy must be a DataProxy")
        unknown = set(power or {}) - set(_POWERS)
        if unknown:
            raise ValueError(f"@erupt {name}.power: no right {', '.join(sorted(unknown))}, expected some of {', '.join(_POWERS)}")
        # the rights it switches off; the server enforces them and the user's (§12.5)
        self.power = dict(power or {})
        raw, vis = self._pull_vis(raw)
        raw, drills = self._pull_drills(raw)
        self.raw = raw
        hints = getattr(cls, "__annotations__", {})
        # fields: stored and served; declared: all of them in order, virtual ones included, for the build
        self.fields, self.declared, self.operations = {}, [], {}
        for attr, value in vars(cls).items():
            if isinstance(value, Field):
                if not _IDENTIFIER.match(attr):
                    raise ValueError(f"field '{attr}' must be an identifier")
                value.name = attr
                path = f"{name}.{attr}"
                if value.type is not None and value.type != "DATE_TIME":
                    _check_enum(EditType, value.type, f"{path}.type")
                value.type = None if value.pk else value.resolve_type(hints.get(attr))
                if value.type and value.type not in _SUPPORTED:
                    raise ValueError(f"{name}.{attr}: edit type {value.type} is not supported yet")
                if value.search and value.type in _COLLECTIONS:
                    # a list of keys matched as text never finds a number: refused instead of searching for nothing
                    raise ValueError(f"{name}.{attr}: a {value.type} holds keys and cannot be searched")
                if value.type in _REFERENCES + _COLLECTIONS:
                    self._check_reference(value)
                if (value.fetch and value.type not in _FETCHED) or (value.complete and value.type != "AUTO_COMPLETE") \
                        or (value.click and value.type != "BUTTON"):
                    raise ValueError(f"{path}: fetch, complete and click belong to CHOICE / MULTI_CHOICE / TAGS, "
                                     f"AUTO_COMPLETE and BUTTON")
                value.json = value.type in _COLLECTIONS or _is_json(hints.get(attr))
                self.declared.append(value)
                if not value.virtual:
                    self.fields[attr] = value
            elif hasattr(value, "__erupt_operation__"):
                op = value.__erupt_operation__
                if op.code in self.operations:
                    raise ValueError(f"{name}: operation code '{op.code}' declared twice")
                if op.form is not None and not hasattr(op.form, "__erupt__"):
                    raise ValueError(f"{name}.{op.code}: form must be an @erupt class")
                self.operations[op.code] = op
        pks = [f for f in self.fields.values() if f.pk]
        if len(pks) > 1:
            raise ValueError(f"{name}: at most one Field(pk=True)")
        # a model without a primary key can only serve as an operation form
        self.pk = pks[0].name if pks else None
        self.order_by = self._parse_order(order_by)
        # the server filters by the tree beside the table (§12.4); the field it names is checked here, where it is written
        tree_field = (raw.get("linkTree") or {}).get("field")
        if tree_field and (self.fields.get(tree_field) is None or self.fields[tree_field].type not in _REFERENCES):
            raise ValueError(f"{name}: linkTree.field '{tree_field}' must be a reference field")
        # drill code -> its linkCondition, which the node adds to a drilled table (§12.4)
        self.drills = drills
        # view code -> (filters, sort) the node applies to that view's table queries
        self.vis = {code: ([(f, []) for f in filters], self._parse_order(sort)) for code, (filters, sort) in vis.items()}

    @staticmethod
    def _pull_drills(raw):
        """A drill's ``link`` goes to the server whole: it reads the source row and joins on ``column`` /
        ``joinColumn`` (§12.4). Its ``linkCondition`` is the node's query language: kept here, applied to a drilled
        table. A drill without a ``code`` is addressed by its title."""
        drills, entries = {}, []
        for entry in raw.get("drills") or []:
            link = entry.get("link") or {}
            if not link.get("joinColumn") or not link.get("linkErupt"):
                raise ValueError(f"drill '{entry.get('title')}' needs link.linkErupt and link.joinColumn")
            entry = {"code": entry.get("title", ""), **entry}
            drills[entry["code"]] = link.get("linkCondition") or ""
            entries.append(entry)
        return ({**raw, "drills": entries} if "drills" in raw else raw), drills

    @staticmethod
    def _pull_vis(raw):
        """``filter`` and ``orderBy`` of a ``vis`` entry run on the node, as Java keeps them off the build
        (``@Transient``): taken out before the schema check. A view without a ``code`` is addressed by its title."""
        vis, entries = {}, []
        for entry in raw.get("vis") or []:
            entry = {"code": entry.get("title", ""), **entry}
            filters = entry.pop("filter", None) or []
            vis[entry["code"]] = ([filters] if isinstance(filters, str) else list(filters), entry.pop("orderBy", None))
            entries.append(entry)
        return ({**raw, "vis": entries} if "vis" in raw else raw), vis

    def hook(self, name, *args):
        """Run one DataProxy hook on every proxy, in declaration order."""
        for p in self.proxies:
            getattr(p, name)(*args)

    def filters(self, conditions):
        """The SQL every proxy's ``before_fetch`` adds, as ``[(sql, params)]``."""
        filters = []
        for p in self.proxies:
            sql = p.before_fetch(conditions)
            if sql:
                filters.append((sql, []) if isinstance(sql, str) else (sql[0], list(sql[1])))
        return filters

    def _parse_order(self, order_by):
        """``"views desc, id"`` -> ``[("views", True), ("id", False)]``, fields checked against the model."""
        sort = []
        for part in filter(None, (p.strip() for p in (order_by or "").split(","))):
            words = part.split()
            if len(words) > 2 or words[0] not in self.fields or (len(words) == 2 and words[1].lower() not in ("asc", "desc")):
                raise ValueError(f"{self.name}: illegal order_by '{part}'")
            sort.append((words[0], len(words) == 2 and words[1].lower() == "desc"))
        return sort

    def _check_reference(self, f):
        if not hasattr(f.ref, "__erupt__"):
            raise ValueError(f"{self.name}.{f.name}: ref must be an @erupt class declared before this one")
        target = f.target
        if target.pk is None:
            raise ValueError(f"{self.name}.{f.name}: {target.name} has no primary key")
        for key in [f.label] + ([f.tree] if f.tree else []):
            if key not in target.fields:
                raise ValueError(f"{self.name}.{f.name}: {target.name} has no field '{key}'")

    def build_erupt(self, operations=()):
        erupt_json = {"primaryKeyCol": self.pk or "id", "rowOperation": [op.build() for op in operations]}
        _merge(erupt_json, self.raw)
        return {
            "eruptName": self.name,
            "eruptJson": erupt_json,
            "eruptFieldModels": [f.build() for f in self.declared],
            "searchCondition": self._search_condition(),
            "extraRow": False,
            "tags": {},
        }

    def _search_condition(self):
        condition = {}
        self.hook("search_condition", condition)
        return condition

    def build_model(self, power, user=None):
        operations = [op for op in self.operations.values() if op.visible(user)]
        return {
            "eruptModel": self.build_erupt(operations),
            "power": power,
            "tabErupts": None, "combineErupts": None,
            "operationErupts": {op.code: op.form_model.build_erupt() for op in operations if op.form} or None,
        }


def erupt(title, *, name=None, power=None, order_by=None, data_proxy=(), **raw):
    """Declare a class as an erupt model. ``name`` defaults to the class name and is what the server
    addresses (``node.Name``); ``power`` switches features off (``{"delete": False}``); ``order_by`` is the
    default table order, applied by the node (``"views desc, id"``); ``data_proxy`` is one ``DataProxy`` or a
    list of them (instances or classes), run around every read and write of the model; remaining keyword
    arguments are raw ``@Erupt`` attributes merged onto the defaults (``layout={"pageSize": 30}``, see
    ``erupt._types.Erupt``); an unknown attribute or value fails here, not in the browser."""

    def wrap(cls):
        cls.__erupt__ = Model(cls, name or cls.__name__, title, power, order_by, raw, data_proxy)
        return cls

    return wrap
