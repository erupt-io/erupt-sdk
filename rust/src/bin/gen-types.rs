//! Generate `src/types.rs` from the erupt annotation schema. The crate embeds no schema: the server completes
//! and checks every build (erupt-cloud/PROTOCOL.md §12.3).
//!
//! ```text
//! cargo run --bin gen-types -- <erupt repo>/schema          # regenerate types
//! cargo run --bin gen-types -- <erupt repo>/schema --check  # fail when they are out of date (CI)
//! ```
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[path = "../../tools/generate.rs"]
mod generate;

const SCHEMA: &str = "erupt-annotations.schema.json";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let check = args.iter().any(|a| a == "--check");
    let Some(dir) = args.iter().find(|a| !a.starts_with("--")) else {
        eprintln!("usage: gen-types <schema dir> [--check]");
        return ExitCode::from(2);
    };
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let schema: serde_json::Value = match std::fs::read_to_string(Path::new(dir).join(SCHEMA))
        .map_err(|e| e.to_string())
        .and_then(|text| serde_json::from_str(&text).map_err(|e| e.to_string()))
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{dir}/{SCHEMA}: {e}");
            return ExitCode::from(2);
        }
    };
    let expected: Vec<(PathBuf, String)> =
        vec![(crate_dir.join("src/types.rs"), generate::generate(&schema))];
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
