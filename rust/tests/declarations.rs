use std::path::Path;

use erupt::types::{Edit, InputType, RowOperationMode};
use erupt::{Error, Field, Model, Operation};
use serde_json::json;

#[path = "../tools/generate.rs"]
mod generate;

fn declaration_error(builder: erupt::ModelBuilder) -> String {
    match builder.build() {
        Err(Error::Declaration(m)) => m,
        Err(e) => panic!("expected a declaration error, got {e}"),
        Ok(_) => panic!("expected a declaration error"),
    }
}

fn base() -> erupt::ModelBuilder {
    Model::new("Bad", "Bad").field("id", Field::pk())
}

#[test]
fn rejects_unknown_annotation_values() {
    let cases = [
        (
            base().field(
                "t",
                Field::input("T").edit(json!({"search": {"operator": "ABOUT"}})),
            ),
            "t.edit.search.operator: 'ABOUT' is not one of",
        ),
        (
            base().field("t", Field::input("T").edit(json!({"type": "NOPE"}))),
            "t.edit.type: 'NOPE' is not one of",
        ),
        (
            base().raw(json!({"drills": [{"title": "D", "link": {"linkErupt": "X"}}]})),
            "drill 'D' needs link.linkErupt and link.joinColumn",
        ),
        (
            base().raw(json!({"drills": [{"title": "D", "link": {"joinColumn": "x"}}]})),
            "needs link.linkErupt",
        ),
        (base().order_by("missing desc"), "illegal order_by"),
        (
            base().raw(json!({"vis": [{"title": "V", "orderBy": "missing"}]})),
            "illegal order_by",
        ),
        (
            base().raw(json!({"vis": [{"title": "V", "filter": 1}]})),
            "a vis filter must be SQL text",
        ),
        (
            base().power(json!({"remove": false})),
            "illegal power 'remove'",
        ),
        (
            base().power(json!({"delete": "no"})),
            "illegal power 'delete'",
        ),
        (base().field("id2", Field::pk()), "at most one"),
        (
            base()
                .field("t", Field::input("T"))
                .field("t", Field::input("T")),
            "unique",
        ),
        (
            base().operation(
                Operation::new("go", "Go")
                    .raw(json!({"mode": "SOMETIMES"}))
                    .handler(|_| Ok(None)),
            ),
            "Bad.go.mode: 'SOMETIMES' is not one of",
        ),
        (
            base().operation(Operation::new("go", "Go")),
            "without a handler",
        ),
        (Model::new("not a name", "X"), "identifier"),
        (
            base().field("t", Field::input("T").fetch(|_| Ok(vec![]))),
            "fetch, fetch_tags, complete and click belong to",
        ),
        (
            base().field("t", Field::choice("T", &[]).fetch_tags(|_| Ok(vec![]))),
            "belong to",
        ),
        (
            base().field("t", Field::input("T").click(|_| Ok(json!({})))),
            "belong to",
        ),
        (
            base().field("t", Field::input("T").complete(|_, _| Ok(vec![]))),
            "belong to",
        ),
    ];
    for (builder, message) in cases {
        let error = declaration_error(builder);
        assert!(
            error.contains(message),
            "{error} does not contain {message}"
        );
    }
}

#[test]
fn references_are_checked() {
    let target = Model::new("Cat", "Cat")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .build()
        .unwrap();
    let form = Model::new("Form", "Form")
        .field("x", Field::input("X"))
        .build()
        .unwrap();
    assert!(
        declaration_error(base().field("c", Field::reference(&target, "C").label("title")))
            .contains("has no field 'title'")
    );
    assert!(
        declaration_error(base().field("c", Field::reference(&target, "C").tree("parent")))
            .contains("has no field 'parent'")
    );
    assert!(
        declaration_error(base().field("c", Field::reference(&form, "C")))
            .contains("has no primary key")
    );
    assert!(declaration_error(
        base()
            .field("c", Field::input("C"))
            .raw(json!({"linkTree": {"field": "c"}}))
    )
    .contains("linkTree.field 'c' must be a reference field"));
}

#[test]
fn typed_and_raw_overrides_pass_through() {
    let typed = Edit {
        input_type: Some(InputType {
            length: Some(9),
            ..Default::default()
        }),
        ..Default::default()
    };
    // attribute names are the server's to check (PROTOCOL.md §12.3): an unknown one passes here
    let model = Model::new("Ok", "Ok")
        .raw(json!({"layout": {"pageSize": 30}, "orderBy": "id"}))
        .field("id", Field::pk())
        .field(
            "t",
            Field::input("T")
                .edit(typed)
                .view(json!({"sortable": "yes"})),
        )
        .field(
            "u",
            Field::input("U").edit(json!({"inputTyp": {"length": 9}})),
        )
        .operation(
            Operation::new("go", "Go")
                .mode(RowOperationMode::Button)
                .handler(|_| Ok(None)),
        )
        .build()
        .unwrap();
    assert_eq!("Ok", model.name());
    assert_eq!(Some("id"), model.pk());
}

#[test]
fn generated_types_are_current() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let schema: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("../schema/erupt-annotations.schema.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        generate::generate(&schema),
        std::fs::read_to_string(dir.join("src/types.rs")).unwrap(),
        "run cargo run --bin gen-types -- ../schema"
    );
}
