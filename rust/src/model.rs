//! Model declaration, compiled into erupt build JSON. Nothing here re-implements annotation semantics: the build
//! carries only what a model declares, and the server completes every annotation from its Java defaults and
//! checks it (erupt-cloud/PROTOCOL.md §12.3, protocol v2).
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::Arc;

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::repo::{Cond, Filter, Repository};
use crate::types::{EditType, QueryExpression, RowOperationMode};
use crate::values::{as_f64, number, parse_date_time, text};
use crate::{Error, Record, Result};

pub(crate) const REFERENCES: [&str; 2] = ["REFERENCE_TABLE", "REFERENCE_TREE"];
/// many records of another model, stored as the JSON list of their keys
const COLLECTIONS: [&str; 3] = ["CHECKBOX", "TAB_TREE", "TRANSFER"];
/// The edit types this SDK serves (a date with a time is declared as `DATE_TIME`)
const SUPPORTED: [&str; 27] = [
    "ATTACHMENT",
    "AUTO_COMPLETE",
    "BOOLEAN",
    "BUTTON",
    "CHECKBOX",
    "CHOICE",
    "CODE_EDITOR",
    "COLOR",
    "DATE",
    "DATE_TIME",
    "HIDDEN",
    "HTML_EDITOR",
    "ICON",
    "INPUT",
    "MAP",
    "MARKDOWN",
    "MULTI_CHOICE",
    "NUMBER",
    "RATE",
    "REFERENCE_TABLE",
    "REFERENCE_TREE",
    "SIGNATURE",
    "SLIDER",
    "TAB_TREE",
    "TAGS",
    "TEXTAREA",
    "TRANSFER",
];
/// Rights a model may switch off (`@Erupt(power)`, `PowerObject`)
const POWERS: [&str; 14] = [
    "add",
    "edit",
    "delete",
    "query",
    "viewDetails",
    "export",
    "importable",
    "print",
    "copy",
    "cellEdit",
    "batchEdit",
    "ai",
    "comment",
    "revision",
];

/// A misspelt enum value fails where the model is declared; every other attribute is the server's to check
/// (PROTOCOL.md §12.3).
fn check_enum<T: FromStr>(value: Option<&Value>, path: &str, values: &[&str]) -> Result<()> {
    match value {
        None | Some(Value::Null) => Ok(()),
        Some(Value::String(s)) if T::from_str(s).is_ok() => Ok(()),
        Some(other) => Err(Error::Declaration(format!(
            "{path}: '{}' is not one of {}",
            text(other),
            values.join(", ")
        ))),
    }
}

/// A field's own code, run when the server invokes it (erupt-cloud/PROTOCOL.md §5.5): the form's values and
/// the call's `value` to the answer's `data`.
type FieldCode = Arc<dyn Fn(&Record, &Value) -> Result<Value> + Send + Sync>;

fn identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub(crate) fn merge(target: &mut Value, overrides: &Value) {
    if let (Some(t), Some(o)) = (target.as_object_mut(), overrides.as_object()) {
        for (key, value) in o {
            match (t.get_mut(key), value) {
                (Some(existing), Value::Object(_)) if existing.is_object() => {
                    merge(existing, value)
                }
                _ => {
                    t.insert(key.clone(), value.clone());
                }
            }
        }
    }
}

fn to_json(value: impl Serialize, what: &str) -> Value {
    serde_json::to_value(value).unwrap_or_else(|e| panic!("{what} does not serialize: {e}"))
}

/// One column. The title labels both the table column and the form input; `view` / `edit` take raw
/// annotation attributes (`json!({"inputType": {"length": 64}})` or a generated `types::Edit`).
#[derive(Clone)]
pub struct Field {
    pub(crate) name: String,
    pub(crate) title: String,
    /// template key: an edit type, `DATE_TIME`, or empty for the primary key
    pub(crate) kind: String,
    pub(crate) search: bool,
    pub(crate) not_null: bool,
    pub(crate) sortable: bool,
    pub(crate) table: bool,
    pub(crate) form: bool,
    pub(crate) choices: Vec<(String, String)>,
    /// in the build only (DIVIDE, CALLOUT, EMPTY, GROUP): no column, never read or written
    pub(crate) transient: bool,
    /// a JSON array or object (MULTI_CHOICE, KEY_VALUE), kept as JSON text by SQL repositories
    pub(crate) json: bool,
    pub(crate) target: Option<Arc<Model>>,
    pub(crate) label: String,
    pub(crate) tree: Option<String>,
    view: Value,
    edit: Value,
    fetch: Option<FieldCode>,
    /// `fetch` answers TAGS' tags rather than CHOICE / MULTI_CHOICE options
    fetch_tags: bool,
    onchange: Option<FieldCode>,
    complete: Option<FieldCode>,
    click: Option<FieldCode>,
}

impl Field {
    fn new(kind: &str, title: &str) -> Self {
        Field {
            name: String::new(),
            title: title.to_string(),
            kind: kind.to_string(),
            search: false,
            not_null: false,
            sortable: false,
            table: true,
            form: true,
            choices: Vec::new(),
            // a BUTTON is a form element only
            transient: kind == "BUTTON",
            json: false,
            target: None,
            label: "name".to_string(),
            tree: None,
            view: json!({}),
            edit: json!({}),
            fetch: None,
            fetch_tags: false,
            onchange: None,
            complete: None,
            click: None,
        }
    }

    /// The integer primary key, hidden from table and form.
    pub fn pk() -> Self {
        Field::new("", "")
    }
    pub fn input(title: &str) -> Self {
        Field::new("INPUT", title)
    }
    pub fn textarea(title: &str) -> Self {
        Field::new("TEXTAREA", title)
    }
    pub fn number(title: &str) -> Self {
        Field::new("NUMBER", title)
    }
    pub fn boolean(title: &str) -> Self {
        Field::new("BOOLEAN", title)
    }
    pub fn date(title: &str) -> Self {
        Field::new("DATE", title)
    }
    pub fn date_time(title: &str) -> Self {
        Field::new("DATE_TIME", title)
    }
    /// A select over `(value, label)` pairs.
    pub fn choice(title: &str, choices: &[(&str, &str)]) -> Self {
        let mut f = Field::new("CHOICE", title);
        f.choices = choices
            .iter()
            .map(|(v, l)| (v.to_string(), l.to_string()))
            .collect();
        f
    }
    /// A multi-select over `(value, label)` pairs, kept as a JSON list of the values.
    pub fn multi_choice(title: &str, choices: &[(&str, &str)]) -> Self {
        let mut f = Field::choice(title, choices);
        f.kind = "MULTI_CHOICE".to_string();
        f.json = true;
        f
    }
    /// Any edit type the SDK supports, by its schema name.
    pub fn of(edit_type: EditType, title: &str) -> Self {
        Field::new(edit_type.as_str(), title)
    }
    /// A record of another model, picked from a table; the repository stores its primary key.
    pub fn reference(target: &Arc<Model>, title: &str) -> Self {
        let mut f = Field::new("REFERENCE_TABLE", title);
        f.target = Some(target.clone());
        f
    }
    /// Records of another model, ticked in a list; stored as the JSON list of their primary keys.
    pub fn checkbox(target: &Arc<Model>, title: &str) -> Self {
        Field::collection("CHECKBOX", target, title)
    }
    /// Records of another model, picked in its own tree (`.raw(json!({"tree": ...}))` on it); stored as the
    /// JSON list of their primary keys.
    pub fn tab_tree(target: &Arc<Model>, title: &str) -> Self {
        Field::collection("TAB_TREE", target, title)
    }
    /// Records of another model, moved across two lists; stored as the JSON list of their primary keys.
    pub fn transfer(target: &Arc<Model>, title: &str) -> Self {
        Field::collection("TRANSFER", target, title)
    }
    fn collection(kind: &str, target: &Arc<Model>, title: &str) -> Self {
        let mut f = Field::new(kind, title);
        f.target = Some(target.clone());
        f.json = true;
        f
    }

    pub fn search(mut self) -> Self {
        self.search = true;
        self
    }
    pub fn not_null(mut self) -> Self {
        self.not_null = true;
        self
    }
    pub fn sortable(mut self) -> Self {
        self.sortable = true;
        self
    }
    /// Keep the field out of the table (still in the form).
    pub fn hide_table(mut self) -> Self {
        self.table = false;
        self
    }
    /// Keep the field out of the form (read only for users).
    pub fn hide_form(mut self) -> Self {
        self.form = false;
        self
    }
    /// Declared in the build only, like a JPA `@Transient` field: a layout field (DIVIDE, CALLOUT, EMPTY,
    /// GROUP via a raw edit type) that has no column and is never read or written.
    pub fn transient(mut self) -> Self {
        self.transient = true;
        self
    }
    /// The value is a JSON array or object (KEY_VALUE via a raw edit type), kept as JSON text
    /// by SQL repositories and returned as JSON. A search for values (EQ / IN, NEQ / NOT_IN) matches the
    /// records whose JSON holds every one of them (does not hold any), as the quoted text `"value"`.
    pub fn json(mut self) -> Self {
        self.json = true;
        self
    }
    /// The referenced model's field shown for a reference (`name` by default).
    pub fn label(mut self, label: &str) -> Self {
        self.label = label.to_string();
        self
    }
    /// Turn a reference into a tree picker over the referenced model's parent field.
    pub fn tree(mut self, pid: &str) -> Self {
        self.tree = Some(pid.to_string());
        self.kind = "REFERENCE_TREE".to_string();
        self
    }
    /// CHOICE / MULTI_CHOICE: the `(value, label)` options, fetched with the form's values when it opens.
    pub fn fetch(
        mut self,
        fetch: impl Fn(&Record) -> Result<Vec<(String, String)>> + Send + Sync + 'static,
    ) -> Self {
        self.fetch = Some(Arc::new(move |form, _| {
            Ok(fetch(form)?
                .into_iter()
                .map(|(value, label)| json!({"value": value, "label": label}))
                .collect())
        }));
        self.fetch_tags = false;
        self
    }
    /// TAGS: the tags offered, fetched with the form's values when it opens.
    pub fn fetch_tags(
        mut self,
        fetch: impl Fn(&Record) -> Result<Vec<String>> + Send + Sync + 'static,
    ) -> Self {
        self.fetch = Some(Arc::new(move |form, _| Ok(json!(fetch(form)?))));
        self.fetch_tags = true;
        self
    }
    /// Run when the field changes in the form: answer `{"formData": {...}, "editExpr": {...}}`.
    pub fn onchange(
        mut self,
        onchange: impl Fn(&Record) -> Result<Value> + Send + Sync + 'static,
    ) -> Self {
        self.onchange = Some(Arc::new(move |form, _| onchange(form)));
        self
    }
    /// AUTO_COMPLETE: the suggestions for what was typed.
    pub fn complete(
        mut self,
        complete: impl Fn(&Record, &str) -> Result<Vec<String>> + Send + Sync + 'static,
    ) -> Self {
        self.complete = Some(Arc::new(move |form, typed| {
            Ok(json!(complete(form, typed.as_str().unwrap_or(""))?))
        }));
        self
    }
    /// BUTTON: run on a click; answer `{"eval": "js", "formData": {...}, "editExpr": {...}}`. `eval` runs as
    /// JavaScript in the browser, so only put code you wrote there.
    pub fn click(
        mut self,
        click: impl Fn(&Record) -> Result<Value> + Send + Sync + 'static,
    ) -> Self {
        self.click = Some(Arc::new(move |form, _| click(form)));
        self
    }
    /// Raw `@View` attributes, merged onto what the field declares; the server checks them.
    pub fn view(mut self, view: impl Serialize) -> Self {
        merge(&mut self.view, &to_json(view, "view"));
        self
    }
    /// Raw `@Edit` attributes, merged onto what the field declares; the server checks them.
    pub fn edit(mut self, edit: impl Serialize) -> Self {
        merge(&mut self.edit, &to_json(edit, "edit"));
        self
    }

    pub(crate) fn is_pk(&self) -> bool {
        self.kind.is_empty()
    }

    pub(crate) fn is_reference(&self) -> bool {
        REFERENCES.contains(&self.kind.as_str())
    }

    fn is_collection(&self) -> bool {
        COLLECTIONS.contains(&self.kind.as_str())
    }

    /// Run the field's code for an invoke `kind`; None when it has none.
    pub(crate) fn invoke(&self, kind: &str, form: &Record, value: &Value) -> Option<Result<Value>> {
        let code = match kind {
            "options" => &self.fetch,
            "onchange" => &self.onchange,
            "autocomplete" => &self.complete,
            "button" => &self.click,
            _ => return None,
        };
        code.as_ref().map(|code| code(form, value))
    }

    pub(crate) fn target(&self) -> &Model {
        self.target.as_deref().expect("reference target")
    }

    /// The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults.
    fn build(&self) -> Value {
        if self.is_pk() {
            return json!({"fieldName": self.name, "fieldReturnName": "number", "componentValue": null,
                          "eruptFieldJson": {"edit": {"title": "", "type": "NUMBER"}}});
        }
        let kind = self.kind.as_str();
        // a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
        let mut edit =
            json!({"title": self.title, "type": if kind == "DATE_TIME" { "DATE" } else { kind }});
        if matches!(kind, "DATE" | "DATE_TIME") {
            edit["dateType"] = json!({"type": kind});
        }
        if self.not_null {
            edit["notNull"] = json!(true);
        }
        if !self.form {
            edit["show"] = json!(false);
        }
        if self.search {
            edit["search"] = json!({"value": true});
        }
        let mut view = json!({"title": self.title});
        if self.sortable {
            view["sortable"] = json!(true);
        }
        let mut return_name = match kind {
            "NUMBER" | "RATE" | "SLIDER" => "number",
            "BOOLEAN" => "Boolean",
            "DATE" | "DATE_TIME" => "Date",
            _ => "String",
        };
        if let Some(target) = &self.target {
            let id = target.pk.as_deref().unwrap_or("id");
            match &self.tree {
                Some(pid) if self.is_reference() => {
                    edit["referenceTreeType"] = json!({"id": id, "label": self.label, "pid": pid})
                }
                _ if self.is_reference() => {
                    edit["referenceTableType"] = json!({"id": id, "label": self.label})
                }
                _ => {}
            }
            // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            return_name = &target.name;
            view["column"] = json!(self.label);
        }
        if self.fetch.is_some() {
            let attr = match kind {
                "CHOICE" => "choiceType",
                "MULTI_CHOICE" => "multiChoiceType",
                _ => "tagsType",
            };
            edit[attr] = json!({"fetchHandler": ["invoke"]});
        }
        if self.onchange.is_some() {
            edit["onchange"] = json!("invoke");
        }
        merge(&mut edit, &self.edit);
        merge(&mut view, &self.view);
        // a BUTTON is a form element only: no table column
        let views = if self.table && kind != "BUTTON" {
            json!([view])
        } else {
            json!([])
        };
        // a CHOICE or MULTI_CHOICE: the options travel as componentValue
        let options = if self.choices.is_empty() {
            Value::Null
        } else {
            self.choices
                .iter()
                .map(|(v, l)| json!({"value": v, "label": l, "desc": null, "color": null, "disable": false}))
                .collect()
        };
        json!({"fieldName": self.name, "fieldReturnName": return_name, "componentValue": options,
               "eruptFieldJson": {"edit": edit, "views": views}})
    }

    /// A JSON value as the server sends it (PROTOCOL.md §12.4) to the value the repository stores: a date in the
    /// repository's representation, a number, a key as its key type. The server has checked it; a key in a path
    /// segment, a delete body or an operation's ids arrives as the browser sent it, so it may fail here.
    pub(crate) fn coerce(&self, value: &Value) -> std::result::Result<Value, String> {
        if self.is_reference() {
            let target = self.target();
            let pk = target.pk.as_deref().unwrap_or("id");
            return target.field(pk).expect("target pk").coerce(value);
        }
        if self.is_collection() {
            let target = self.target();
            let key = target
                .field(target.pk.as_deref().unwrap_or("id"))
                .expect("target pk");
            return match value {
                Value::Null => Ok(json!([])),
                Value::Array(items) => items
                    .iter()
                    .map(|item| key.coerce(item))
                    .collect::<std::result::Result<_, _>>()
                    .map(Value::Array),
                other => Err(format!("illegal value '{}'", text(other))),
            };
        }
        if value.is_null() || value.as_str() == Some("") {
            return Ok(Value::Null);
        }
        if self.json {
            return Ok(value.clone());
        }
        if self.is_pk() {
            return match value {
                Value::Number(n) if n.as_f64().map(|f| f.fract() == 0.0).unwrap_or(false) => {
                    Ok(number(n.as_f64().unwrap_or(0.0)))
                }
                Value::String(s) if s.trim().parse::<i64>().is_ok() => {
                    Ok(Value::from(s.trim().parse::<i64>().unwrap_or(0)))
                }
                other => Err(format!("illegal integer '{}'", text(other))),
            };
        }
        match self.kind.as_str() {
            "NUMBER" | "RATE" | "SLIDER" => as_f64(value)
                .map(number)
                .ok_or_else(|| format!("illegal number '{}'", text(value))),
            "DATE" | "DATE_TIME" => {
                let parsed = value
                    .as_str()
                    .and_then(parse_date_time)
                    .ok_or_else(|| format!("illegal date '{}'", text(value)))?;
                Ok(json!(if self.kind == "DATE" {
                    parsed.date_string()
                } else {
                    parsed.date_time_string()
                }))
            }
            _ => Ok(value.clone()),
        }
    }
}

/// How an operation asks before it runs.
#[derive(Clone)]
enum Confirm {
    Default,
    Skip,
    Text(String),
}

/// What an operation handler receives.
pub struct OpContext<'a> {
    /// Selected records as the repository returned them; empty for BUTTON mode.
    pub rows: Vec<Record>,
    /// Coerced form values, or None without a form.
    pub param: Option<Record>,
    pub repo: &'a dyn Repository,
    pub model: &'a Model,
    pub user: Option<Value>,
}

type Handler = Arc<dyn Fn(&OpContext) -> Result<Option<String>> + Send + Sync>;
type Show = Arc<dyn Fn(Option<&Value>) -> bool + Send + Sync>;

/// A row operation. A handler returning `Some(script)` has the script run as JavaScript in the browser, so
/// only return code you wrote.
#[derive(Clone)]
pub struct Operation {
    pub(crate) code: String,
    title: String,
    pub(crate) mode: RowOperationMode,
    icon: Option<String>,
    tip: String,
    confirm: Confirm,
    pub(crate) form: Option<Arc<Model>>,
    show: Option<Show>,
    if_expr: String,
    raw: Value,
    pub(crate) handler: Option<Handler>,
}

impl Operation {
    pub fn new(code: &str, title: &str) -> Self {
        Operation {
            code: code.to_string(),
            title: title.to_string(),
            mode: RowOperationMode::Multi,
            icon: None,
            tip: String::new(),
            confirm: Confirm::Default,
            form: None,
            show: None,
            if_expr: String::new(),
            raw: json!({}),
            handler: None,
        }
    }
    /// SINGLE (row button), MULTI (row and toolbar, the default), MULTI_ONLY (toolbar), BUTTON (no rows).
    pub fn mode(mut self, mode: RowOperationMode) -> Self {
        self.mode = mode;
        self
    }
    pub fn icon(mut self, icon: &str) -> Self {
        self.icon = Some(icon.to_string());
        self
    }
    pub fn tip(mut self, tip: &str) -> Self {
        self.tip = tip.to_string();
        self
    }
    /// Run without the confirm dialog.
    pub fn no_confirm(mut self) -> Self {
        self.confirm = Confirm::Skip;
        self
    }
    /// Replace the confirm dialog's text.
    pub fn confirm(mut self, text: &str) -> Self {
        self.confirm = Confirm::Text(text.to_string());
        self
    }
    /// Ask for these fields (a model without a primary key) before running.
    pub fn form(mut self, form: &Arc<Model>) -> Self {
        self.form = Some(form.clone());
        self
    }
    /// Browser-side JS over `item` that disables (or hides) the row button.
    pub fn if_expr(mut self, expr: &str) -> Self {
        self.if_expr = expr.to_string();
        self
    }
    /// Hide the operation from users this returns false for; hidden operations also refuse to run.
    pub fn show(mut self, show: impl Fn(Option<&Value>) -> bool + Send + Sync + 'static) -> Self {
        self.show = Some(Arc::new(show));
        self
    }
    /// Raw `@RowOperation` attributes, merged onto what the operation declares; the server checks them.
    pub fn raw(mut self, raw: impl Serialize) -> Self {
        merge(&mut self.raw, &to_json(raw, "operation"));
        self
    }
    pub fn handler(
        mut self,
        handler: impl Fn(&OpContext) -> Result<Option<String>> + Send + Sync + 'static,
    ) -> Self {
        self.handler = Some(Arc::new(handler));
        self
    }

    pub(crate) fn visible(&self, user: Option<&Value>) -> bool {
        self.show.as_ref().map(|s| s(user)).unwrap_or(true)
    }

    fn build(&self) -> Value {
        let mut op = json!({
            "code": self.code, "title": self.title, "mode": self.mode.as_str(), "tip": self.tip,
            "ifExpr": self.if_expr,
            "eruptClass": self.form.as_ref().map(|f| f.name.as_str()).unwrap_or("void"),
        });
        if let Some(icon) = &self.icon {
            op["icon"] = json!(icon);
        }
        match &self.confirm {
            Confirm::Default => {}
            Confirm::Skip => op["callHint"] = json!(""),
            Confirm::Text(t) => op["callHint"] = json!(t),
        }
        merge(&mut op, &self.raw);
        op
    }
}

/// Hooks around a model's data, as erupt's Java `DataProxy`: implement what you need and add it with
/// [`ModelBuilder::data_proxy`]. A record is what the repository stores, a row what the browser reads; change
/// them in place. `Err(Error::fail(msg))` refuses with `msg`.
#[allow(unused_variables)]
pub trait DataProxy: Send + Sync {
    /// Default values of the search bar, `condition[field] = value`.
    fn search_condition(&self, condition: &mut Record) {}
    /// SQL ANDed to a table page's WHERE, as written: `Filter::new("owner = ?", vec![uid])`, or
    /// `"status <> 'deleted'".into()`. `conditions` are the search bar's. Only SQL repositories apply it.
    fn before_fetch(&self, conditions: &[Cond]) -> Result<Option<Filter>> {
        Ok(None)
    }
    /// The rows of a table page, before they are sent.
    fn after_fetch(&self, rows: &mut [Record]) -> Result<()> {
        Ok(())
    }
    /// The values a new record's form opens with.
    fn add_behavior(&self, record: &mut Record) -> Result<()> {
        Ok(())
    }
    /// A record read by its key, for the edit form or the detail view.
    fn edit_behavior(&self, record: &mut Record) -> Result<()> {
        Ok(())
    }
    /// A record about to be added or updated.
    fn validate(&self, record: &Record) -> Result<()> {
        Ok(())
    }
    fn before_add(&self, record: &mut Record) -> Result<()> {
        Ok(())
    }
    fn after_add(&self, record: &Record) -> Result<()> {
        Ok(())
    }
    fn before_update(&self, record: &mut Record) -> Result<()> {
        Ok(())
    }
    fn after_update(&self, record: &Record) -> Result<()> {
        Ok(())
    }
    fn before_delete(&self, record: &Record) -> Result<()> {
        Ok(())
    }
    fn after_delete(&self, record: &Record) -> Result<()> {
        Ok(())
    }
}

/// A declared erupt model. Built with [`Model::new`]; shared as `Arc<Model>`.
pub struct Model {
    pub(crate) name: String,
    #[allow(dead_code)]
    title: String,
    pub(crate) pk: Option<String>,
    pub(crate) fields: Vec<Field>,
    /// the rights the model switches off; the server enforces them and the user's (PROTOCOL.md §12.5)
    pub(crate) power: Map<String, Value>,
    pub(crate) order_by: Vec<(String, bool)>,
    /// view code -> the filters and order the node applies to that view's table pages
    pub(crate) vis: HashMap<String, (Vec<Filter>, Order)>,
    /// drill code -> its `linkCondition` (SQL as written), which the node adds to a drilled table
    pub(crate) drills: HashMap<String, String>,
    raw: Value,
    pub(crate) operations: Vec<Operation>,
    pub(crate) proxies: Vec<Arc<dyn DataProxy>>,
}

/// Collects a model's declaration; [`ModelBuilder::build`] validates it.
pub struct ModelBuilder {
    name: String,
    title: String,
    fields: Vec<(String, Field)>,
    power: Value,
    order_by: String,
    raw: Value,
    operations: Vec<Operation>,
    proxies: Vec<Arc<dyn DataProxy>>,
}

impl Model {
    /// `name` is what the server addresses (`node.Name`), an identifier; `title` is for people.
    #[allow(clippy::new_ret_no_self)]
    pub fn new(name: &str, title: &str) -> ModelBuilder {
        ModelBuilder {
            name: name.to_string(),
            title: title.to_string(),
            fields: Vec::new(),
            power: json!({}),
            order_by: String::new(),
            raw: json!({}),
            operations: Vec::new(),
            proxies: Vec::new(),
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// The primary key field, if the model has one (an operation form may not).
    pub fn pk(&self) -> Option<&str> {
        self.pk.as_deref()
    }

    pub(crate) fn field(&self, name: &str) -> Option<&Field> {
        self.fields.iter().find(|f| f.name == name)
    }

    /// The fields a repository keeps, in declaration order: every field but the transient ones.
    pub(crate) fn stored(&self) -> impl Iterator<Item = &Field> {
        self.fields.iter().filter(|f| !f.transient)
    }

    /// Run one DataProxy hook on every proxy, in declaration order.
    pub(crate) fn hook(&self, mut hook: impl FnMut(&dyn DataProxy) -> Result<()>) -> Result<()> {
        self.proxies.iter().try_for_each(|p| hook(p.as_ref()))
    }

    /// The SQL every proxy's `before_fetch` adds, in declaration order.
    pub(crate) fn filters(&self, conditions: &[Cond]) -> Result<Vec<Filter>> {
        self.proxies
            .iter()
            .filter_map(|p| p.before_fetch(conditions).transpose())
            .collect()
    }

    pub(crate) fn build_erupt(&self, operations: &[&Operation]) -> Value {
        let mut erupt = json!({
            "primaryKeyCol": self.pk.as_deref().unwrap_or("id"),
            "rowOperation": operations.iter().map(|o| o.build()).collect::<Vec<_>>(),
        });
        merge(&mut erupt, &self.raw);
        let mut condition = Record::new();
        for p in &self.proxies {
            p.search_condition(&mut condition);
        }
        json!({
            "eruptName": self.name,
            "eruptJson": erupt,
            "eruptFieldModels": self.fields.iter().map(Field::build).collect::<Vec<_>>(),
            "searchCondition": condition,
            "extraRow": false,
            "tags": {},
        })
    }

    pub(crate) fn build_model(&self, power: &Map<String, Value>, user: Option<&Value>) -> Value {
        let operations: Vec<&Operation> =
            self.operations.iter().filter(|o| o.visible(user)).collect();
        let forms: Map<String, Value> = operations
            .iter()
            .filter_map(|o| {
                o.form
                    .as_ref()
                    .map(|f| (o.code.clone(), f.build_erupt(&[])))
            })
            .collect();
        json!({
            "eruptModel": self.build_erupt(&operations),
            "power": power,
            "tabErupts": null,
            "combineErupts": null,
            "operationErupts": if forms.is_empty() { Value::Null } else { Value::Object(forms) },
        })
    }
}

impl ModelBuilder {
    pub fn field(mut self, name: &str, field: Field) -> Self {
        self.fields.push((name.to_string(), field));
        self
    }
    /// Switch features off, e.g. `json!({"delete": false})`.
    pub fn power(mut self, power: Value) -> Self {
        merge(&mut self.power, &power);
        self
    }
    /// Default table order, applied by the node: `"views desc, id"`.
    pub fn order_by(mut self, order_by: &str) -> Self {
        self.order_by = order_by.to_string();
        self
    }
    /// Raw `@Erupt` attributes, sent as declared and checked by the server, e.g. `json!({"layout": {"pageSize": 30}})`. A `vis`
    /// entry may also carry `filter` (one SQL string or a list, ANDed as written) and `orderBy` (as
    /// [`order_by`](Self::order_by)): the node applies them to that view's table pages, and they stay out of
    /// the build, as Java keeps them `@Transient`. A view without a `code` is addressed by its title.
    pub fn raw(mut self, raw: impl Serialize) -> Self {
        merge(&mut self.raw, &to_json(raw, "erupt"));
        self
    }
    pub fn operation(mut self, operation: Operation) -> Self {
        self.operations.push(operation);
        self
    }
    /// Hooks run around every read and write of the model; several run in the order added.
    pub fn data_proxy(mut self, proxy: impl DataProxy + 'static) -> Self {
        self.proxies.push(Arc::new(proxy));
        self
    }

    pub fn build(self) -> Result<Arc<Model>> {
        let fail = |m: String| Err(Error::Declaration(m));
        let name = &self.name;
        if !identifier(name) {
            return fail(format!("erupt name '{name}' must be an identifier"));
        }
        let (raw, vis) =
            pull_vis(self.raw).map_err(|m| Error::Declaration(format!("{name}: {m}")))?;
        let (raw, drills) =
            pull_drills(raw).map_err(|m| Error::Declaration(format!("{name}: {m}")))?;
        let power = self.power.as_object().cloned().unwrap_or_default();
        for (key, value) in &power {
            if !POWERS.contains(&key.as_str()) || !value.is_boolean() {
                return fail(format!(
                    "{name}: illegal power '{key}', expected some of {}",
                    POWERS.join(", ")
                ));
            }
        }
        let mut fields = Vec::new();
        let mut seen = HashSet::new();
        for (field_name, mut f) in self.fields {
            let path = format!("{name}.{field_name}");
            if !identifier(&field_name) || !seen.insert(field_name.clone()) {
                return fail(format!("{path}: field names must be unique identifiers"));
            }
            if !f.is_pk() && !SUPPORTED.contains(&f.kind.as_str()) {
                return fail(format!("{path}: edit type {} is not supported yet", f.kind));
            }
            if f.transient && (f.search || f.sortable || f.not_null) {
                return fail(format!(
                    "{path}: a transient field cannot be searched, sorted or required"
                ));
            }
            if f.json && f.sortable {
                return fail(format!("{path}: a JSON field cannot be sorted"));
            }
            // a list of keys matched as text never finds a number: refused instead of searching for nothing
            if f.search && COLLECTIONS.contains(&f.kind.as_str()) {
                return fail(format!(
                    "{path}: a {} holds keys and cannot be searched",
                    f.kind
                ));
            }
            let fetched = match f.kind.as_str() {
                "CHOICE" | "MULTI_CHOICE" => !f.fetch_tags,
                "TAGS" => f.fetch_tags,
                _ => false,
            };
            if (f.fetch.is_some() && !fetched)
                || (f.complete.is_some() && f.kind != "AUTO_COMPLETE")
                || (f.click.is_some() && f.kind != "BUTTON")
            {
                return fail(format!(
                    "{path}: fetch, fetch_tags, complete and click belong to CHOICE / MULTI_CHOICE, TAGS, \
                     AUTO_COMPLETE and BUTTON"
                ));
            }
            check_enum::<EditType>(
                f.edit.get("type"),
                &format!("{path}.edit.type"),
                EditType::VALUES,
            )?;
            check_enum::<QueryExpression>(
                f.edit.get("search").and_then(|s| s.get("operator")),
                &format!("{path}.edit.search.operator"),
                QueryExpression::VALUES,
            )?;
            if (f.is_reference() || f.is_collection()) && f.target.is_none() {
                return fail(format!("{path}: {} needs a target model", f.kind));
            }
            if let Some(target) = &f.target {
                if target.pk.is_none() {
                    return fail(format!("{path}: {} has no primary key", target.name));
                }
                for key in std::iter::once(&f.label).chain(f.tree.as_ref()) {
                    if target.field(key).is_none() {
                        return fail(format!("{path}: {} has no field '{key}'", target.name));
                    }
                }
            } else if f.tree.is_some() {
                return fail(format!("{path}: tree() needs a reference"));
            }
            f.name = field_name;
            fields.push(f);
        }
        let pks: Vec<&Field> = fields.iter().filter(|f| f.is_pk()).collect();
        if pks.len() > 1 {
            return fail(format!("{name}: at most one Field::pk()"));
        }
        let pk = pks.first().map(|f| f.name.clone());
        let order_by = parse_order(name, &fields, &self.order_by)?;
        let vis = vis
            .into_iter()
            .map(|(code, filters, sort)| Ok((code, (filters, parse_order(name, &fields, &sort)?))))
            .collect::<Result<_>>()?;
        // the server filters by the tree beside the table (§12.4); the field it names is checked here, where it
        // is written
        let tree_field = raw
            .get("linkTree")
            .and_then(|t| t.get("field"))
            .and_then(Value::as_str)
            .filter(|f| !f.is_empty());
        if let Some(field) = tree_field {
            if !fields.iter().any(|f| f.name == field && f.is_reference()) {
                return fail(format!(
                    "{name}: linkTree.field '{field}' must be a reference field"
                ));
            }
        }
        let mut codes = HashSet::new();
        for op in &self.operations {
            let path = format!("{name}.{}", op.code);
            if !identifier(&op.code) || !codes.insert(op.code.clone()) {
                return fail(format!(
                    "{path}: operation codes must be unique identifiers"
                ));
            }
            if op.handler.is_none() {
                return fail(format!("{path}: operation without a handler"));
            }
            check_enum::<RowOperationMode>(
                op.raw.get("mode"),
                &format!("{path}.mode"),
                RowOperationMode::VALUES,
            )?;
        }
        Ok(Arc::new(Model {
            name: self.name,
            title: self.title,
            pk,
            fields,
            power,
            order_by,
            vis,
            drills,
            raw,
            operations: self.operations,
            proxies: self.proxies,
        }))
    }
}

/// `(field, descending)`, in order
type Order = Vec<(String, bool)>;
/// a `vis` entry's code, filters and `orderBy`, as declared
type RawView = (String, Vec<Filter>, String);

/// `"views desc, id"` -> `[("views", true), ("id", false)]`, fields checked against the model.
fn parse_order(name: &str, fields: &[Field], order: &str) -> Result<Order> {
    let fail = |m: String| Err(Error::Declaration(m));
    let mut parsed = Vec::new();
    for part in order.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let words: Vec<&str> = part.split_whitespace().collect();
        let desc = match words.get(1).map(|w| w.to_ascii_lowercase()) {
            None => false,
            Some(w) if w == "asc" => false,
            Some(w) if w == "desc" => true,
            Some(_) => return fail(format!("{name}: illegal order_by '{part}'")),
        };
        if words.len() > 2 || !fields.iter().any(|f| f.name == words[0]) {
            return fail(format!("{name}: illegal order_by '{part}'"));
        }
        parsed.push((words[0].to_string(), desc));
    }
    Ok(parsed)
}

/// `filter` and `orderBy` of a `vis` entry run on the node, as Java keeps them off the build (`@Transient`):
/// taken out of what is sent. A view without a `code` gets its title.
fn pull_vis(mut raw: Value) -> std::result::Result<(Value, Vec<RawView>), String> {
    let mut vis = Vec::new();
    for entry in raw
        .get_mut("vis")
        .and_then(Value::as_array_mut)
        .into_iter()
        .flatten()
    {
        let Some(entry) = entry.as_object_mut() else {
            continue; // the server reports it
        };
        if !entry.contains_key("code") {
            let title = entry.get("title").cloned().unwrap_or(json!(""));
            entry.insert("code".to_string(), title);
        }
        let filters = match entry.remove("filter") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::String(sql)) => vec![sql.as_str().into()],
            Some(Value::Array(list)) => list
                .iter()
                .map(|f| f.as_str().map(Filter::from))
                .collect::<Option<_>>()
                .ok_or("a vis filter must be SQL text or a list of it")?,
            Some(_) => return Err("a vis filter must be SQL text or a list of it".into()),
        };
        let sort = match entry.remove("orderBy") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(order)) => order,
            Some(_) => return Err("a vis orderBy must be text".into()),
        };
        vis.push((text(&entry["code"]), filters, sort));
    }
    Ok((raw, vis))
}

/// A drill's `link` goes to the server whole: it reads the source row and joins on `column` / `joinColumn`
/// (PROTOCOL.md §12.4). Its `linkCondition` is the node's query language: kept here, applied to a drilled table.
/// A drill without a `code` is addressed by its title.
fn pull_drills(mut raw: Value) -> std::result::Result<(Value, HashMap<String, String>), String> {
    let mut drills = HashMap::new();
    for entry in raw
        .get_mut("drills")
        .and_then(Value::as_array_mut)
        .into_iter()
        .flatten()
    {
        let Some(entry) = entry.as_object_mut() else {
            continue; // the server reports it
        };
        let link = entry.get("link").cloned().unwrap_or(Value::Null);
        let filled = |key: &str| {
            link.get(key)
                .and_then(Value::as_str)
                .is_some_and(|v| !v.is_empty())
        };
        if !filled("linkErupt") || !filled("joinColumn") {
            return Err(format!(
                "drill '{}' needs link.linkErupt and link.joinColumn",
                text(entry.get("title").unwrap_or(&Value::Null))
            ));
        }
        if !entry.contains_key("code") {
            let title = entry.get("title").cloned().unwrap_or(json!(""));
            entry.insert("code".to_string(), title);
        }
        let condition = link
            .get("linkCondition")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        drills.insert(text(&entry["code"]), condition);
    }
    Ok((raw, drills))
}

/// Records to JSON rows: every declared field present (null when missing).
pub(crate) fn json_value(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}
