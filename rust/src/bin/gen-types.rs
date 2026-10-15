//! Sync the erupt schemas into the crate and generate `src/types.rs` from them.
//!
//! ```text
//! cargo run --bin gen-types -- <erupt repo>/schema          # copy schemas, regenerate types
//! cargo run --bin gen-types -- <erupt repo>/schema --check  # fail when anything is out of date (CI)
//! ```
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[path = "../../tools/generate.rs"]
mod generate;

const SCHEMAS: [&str; 2] = ["erupt-annotations.schema.json", "erupt-node-defaults.json"];

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let check = args.iter().any(|a| a == "--check");
    let Some(dir) = args.iter().find(|a| !a.starts_with("--")) else {
        eprintln!("usage: gen-types <schema dir> [--check]");
        return ExitCode::from(2);
    };
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut expected: Vec<(PathBuf, String)> = Vec::new();
    for name in SCHEMAS {
        match std::fs::read_to_string(Path::new(dir).join(name)) {
            Ok(text) => expected.push((crate_dir.join(name), text)),
            Err(e) => {
                eprintln!("cannot read {dir}/{name}: {e}");
                return ExitCode::from(2);
            }
        }
    }
    let schema: serde_json::Value = match serde_json::from_str(&expected[0].1) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{dir}/{}: {e}", SCHEMAS[0]);
            return ExitCode::from(2);
        }
    };
    expected.push((crate_dir.join("src/types.rs"), generate::generate(&schema)));
    let stale: Vec<&(PathBuf, String)> = expected
        .iter()
        .filter(|(path, text)| {
            std::fs::read_to_string(path)
                .map(|t| &t != text)
                .unwrap_or(true)
        })
        .collect();
    if check {
        for (path, _) in &stale {
            println!("stale: {}", path.display());
        }
        return if stale.is_empty() {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    for (path, text) in stale {
        if let Err(e) = std::fs::write(path, text) {
            eprintln!("cannot write {}: {e}", path.display());
            return ExitCode::FAILURE;
        }
        println!("wrote {}", path.display());
    }
    ExitCode::SUCCESS
}
