"""The erupt server's view of a build, for the conformance suite: checks annotation JSON against
schema/erupt-annotations.schema.json and completes a protocol v2 build (declared attributes only) the way the
server does before the browser reads it (erupt-cloud/PROTOCOL.md §12.3). Standard library only, independent of
every SDK."""
import copy
import json
from pathlib import Path

_SCHEMA_DIR = Path(__file__).resolve().parent.parent / "schema"
DEFS = json.loads((_SCHEMA_DIR / "erupt-annotations.schema.json").read_text("utf-8"))["$defs"]
# The resolved annotations Java emits per edit type (erupt-test NodeDefaultsTest): Java's own defaults, nested
# annotations included, which the schema alone does not carry (Edit.search defaults to @Search(false))
TEMPLATES = json.loads((_SCHEMA_DIR / "erupt-node-defaults.json").read_text("utf-8"))

# @Transient in Java, so absent from the schema, yet sent by a v2 node for the server alone (§12.3, §5.4)
SERVER_ONLY = {"Link": {"column", "joinColumn"}, "ReferenceTableType": {"dependColumn"}}

_PRIMITIVES = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
}


def check(name, value, path=None, partial=True):
    """Raise ``ValueError`` unless ``value`` fits definition ``name``. ``partial`` lets every attribute be omitted
    (a v2 declaration); otherwise the attributes Java always emits must be present."""
    _check({"$ref": "#/$defs/" + name}, value, path or name, partial)


def _check(schema, value, path, partial):
    if "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[1]
        d = DEFS[name]
        if "enum" in d:
            if value not in d["enum"]:
                raise ValueError(f"{path}: '{value}' is not a {name}, expected one of {', '.join(d['enum'])}")
            return
        if not isinstance(value, dict):
            raise ValueError(f"{path}: expected an object ({name})")
        props = d["properties"]
        for key, item in value.items():
            if key in SERVER_ONLY.get(name, ()):
                continue
            if key not in props:
                raise ValueError(f"{path}: {name} has no attribute '{key}'")
            _check(props[key], item, f"{path}.{key}", partial)
        if not partial:
            missing = [k for k in d.get("required", ()) if k not in value]
            if missing:
                raise ValueError(f"{path}: missing {', '.join(missing)}")
        return
    kind = schema["type"]
    if kind == "array":
        if not isinstance(value, list):
            raise ValueError(f"{path}: expected an array")
        for i, item in enumerate(value):
            _check(schema["items"], item, f"{path}[{i}]", partial)
    elif kind == "object":
        if not isinstance(value, dict):
            raise ValueError(f"{path}: expected an object")
        for key, item in value.items() if "additionalProperties" in schema else ():
            _check(schema["additionalProperties"], item, f"{path}.{key}", partial)
    elif not _PRIMITIVES[kind](value):
        raise ValueError(f"{path}: expected {kind}, got {json.dumps(value)}")


def check_declared(build, where):
    """Every object of a v2 build is a valid partial annotation (§12.3 step 2)."""
    for m in models(build):
        check("Erupt", m.get("eruptJson") or {}, f"{where}.{m['eruptName']}")
        for f in m.get("eruptFieldModels") or []:
            check("EruptField", f.get("eruptFieldJson") or {}, f"{where}.{m['eruptName']}.{f['fieldName']}")


def models(build):
    return [build["eruptModel"], *(build.get("operationErupts") or {}).values()]


def _merge(target, override):
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)
    return target


def _defaults(name):
    return {k: v["default"] for k, v in DEFS[name]["properties"].items() if "default" in v}


def _complete(name, value):
    """An annotation object completed from the schema's defaults, nested annotation objects it carries included (a view
    of a vis entry), as AnnotationProcess reads it back."""
    d = DEFS[name]
    done = {k: copy.deepcopy(v["default"]) for k, v in d["properties"].items() if "default" in v}
    for key, item in value.items():
        prop = d["properties"].get(key, {})
        # an annotation object, or an array of them (an input's selectable affixes), is completed member by member
        ref = (prop.get("items") or {}).get("$ref") if prop.get("type") == "array" else prop.get("$ref")
        nested = ref and ref.rsplit("/", 1)[1]
        if nested and "properties" in DEFS[nested]:
            if isinstance(item, dict):
                item = _complete(nested, item)
            elif isinstance(item, list):
                item = [_complete(nested, v) if isinstance(v, dict) else v for v in item]
        done[key] = item
    return done


# ViewProxy.byEdit: the view type an AUTO view takes from its field's edit
_VIEW_BY_EDIT = {"CHOICE": "TEXT", "SIGNATURE": "IMAGE_BASE64", "HTML_EDITOR": "HTML", "CODE_EDITOR": "CODE", "MAP": "MAP",
                 "COLOR": "COLOR", "ICON": "ICON", "KEY_VALUE": "KEY_VALUE", "MARKDOWN": "MARKDOWN", "PASSWORD": "PASSWORD",
                 **dict.fromkeys(("TAB_TABLE_ADD", "MULTI_FORM", "TAB_TREE", "TAB_TABLE_REFER", "CHECKBOX", "TRANSFER",
                                  "MULTI_CHOICE"), "TAB_VIEW")}


def _view_type(edit, field_return_name):
    """What the server makes of an AUTO view (NodeBuilds.resolveAutos): by the edit, then by the stored type."""
    kind = edit["type"]
    if edit.get("title"):
        if kind == "ATTACHMENT":
            return "IMAGE" if edit["attachmentType"]["type"] == "IMAGE" else "ATTACHMENT"
        if kind == "DATE":
            return "DATE_TIME" if edit["dateType"]["type"] == "DATE_TIME" else "DATE"
        if kind in _VIEW_BY_EDIT:
            return _VIEW_BY_EDIT[kind]
    if (field_return_name or "").lower() == "boolean":
        return "BOOLEAN"
    if field_return_name == "Date":
        return "DATE_TIME" if edit["dateType"]["type"] == "DATE_TIME" else "DATE"
    return "NUMBER" if field_return_name == "number" else "TEXT"


def _java_edit(kind):
    """@Edit's own defaults for an edit type: its template (each carries its type's sub-annotation), with what the
    template declared beyond Java's defaults undone."""
    edit = copy.deepcopy(TEMPLATES["fields"].get(kind, TEMPLATES["fields"]["INPUT"])["eruptFieldJson"]["edit"])
    edit["search"] = {**edit["search"], "value": False, "operator": "AUTO"}
    for key in ("boolType", "dateType"):
        if key in edit:
            edit[key] = {**edit[key], "type": "AUTO"}
    return edit


def _java_view():
    view = TEMPLATES["fields"]["INPUT"]["eruptFieldJson"]["views"][0]
    return {**_defaults("View"), "tpl": copy.deepcopy(view["tpl"])}


def complete(build):
    """A v2 build as the browser reads it, as the server makes it (NodeBuilds): every object completed from Java's
    defaults, the AUTO values a local erupt's proxies resolve resolved alike, the drills' server-only link attributes
    removed (§12.3), power completed from PowerObject's (every right on)."""
    build = copy.deepcopy(build)
    for m in models(build):
        erupt = _merge(copy.deepcopy(TEMPLATES["erupt"]), m.get("eruptJson") or {})
        # the template was generated with a form class of its own: an operation without one is Java's void
        operation = {**TEMPLATES["rowOperation"], "eruptClass": "void"}
        erupt["rowOperation"] = [_merge(copy.deepcopy(operation), op) for op in erupt.get("rowOperation") or []]
        drills = []
        for drill in erupt.get("drills") or []:
            link = {k: v for k, v in {**_defaults("Link"), **(drill.get("link") or {})}.items() if k not in SERVER_ONLY["Link"]}
            drills.append({**_defaults("Drill"), **drill, "link": link})
        erupt["drills"] = drills
        erupt["vis"] = [_complete("Vis", v) for v in erupt.get("vis") or []]
        # every other annotation object the model declares (tree, linkTree, dragSort, ...)
        for key, prop in DEFS["Erupt"]["properties"].items():
            nested = prop.get("$ref", "").rsplit("/", 1)[-1]
            if nested in DEFS and "properties" in DEFS[nested] and isinstance(erupt.get(key), dict):
                erupt[key] = _complete(nested, erupt[key])
        m["eruptJson"] = erupt
        for f in m.get("eruptFieldModels") or []:
            declared = f.get("eruptFieldJson") or {}
            edit = _merge(_java_edit((declared.get("edit") or {}).get("type", "INPUT")), declared.get("edit") or {})
            # the annotation objects of the edit (keyValueType, ...): a template carries only its own type's
            for key, prop in DEFS["Edit"]["properties"].items():
                nested = prop.get("$ref", "").rsplit("/", 1)[-1]
                if nested in DEFS and "properties" in DEFS[nested] and isinstance(edit.get(key), dict):
                    edit[key] = _complete(nested, edit[key])
            if edit["search"]["operator"] == "AUTO":
                edit["search"]["operator"] = "RANGE" if edit["type"] == "DATE" else "EQ"
            if "boolType" in edit and edit["boolType"]["type"] == "AUTO":
                edit["boolType"]["type"] = "SWITCH" if edit["notNull"] else "RADIO"
            views = [_merge(_java_view(), v) for v in declared.get("views") or []]
            for view in views:
                if view["type"] == "AUTO":
                    view["type"] = _view_type(edit, f.get("fieldReturnName"))
            f["eruptFieldJson"] = {**{k: v for k, v in declared.items() if k not in ("edit", "views")}, "edit": edit, "views": views}
    build["power"] = {**TEMPLATES["power"], **(build.get("power") or {})}
    return build
