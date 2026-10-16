//! SQLite through rusqlite (feature `sqlite`). One connection behind a mutex.
use std::sync::Mutex;

use rusqlite::types::{Value as Sqlite, ValueRef};
use rusqlite::Connection;
use serde_json::Value;

use crate::{Error, Record, Result};

use super::SqlExecutor;

pub struct SqliteExecutor {
    conn: Mutex<Connection>,
}

impl SqliteExecutor {
    /// Open (or create) a database file; `":memory:"` for a private in-memory database.
    pub fn open(path: &str) -> Result<Self> {
        Ok(SqliteExecutor::from(Connection::open(path).map_err(other)?))
    }
}

impl From<Connection> for SqliteExecutor {
    fn from(conn: Connection) -> Self {
        SqliteExecutor {
            conn: Mutex::new(conn),
        }
    }
}

fn other(e: rusqlite::Error) -> Error {
    Error::Other(format!("database error: {e}"))
}

fn bind(params: &[Value]) -> Vec<Sqlite> {
    params
        .iter()
        .map(|v| match v {
            Value::Null => Sqlite::Null,
            Value::Bool(b) => Sqlite::Integer(*b as i64),
            Value::Number(n) => n
                .as_i64()
                .map(Sqlite::Integer)
                .unwrap_or_else(|| Sqlite::Real(n.as_f64().unwrap_or(0.0))),
            Value::String(s) => Sqlite::Text(s.clone()),
            other => Sqlite::Text(other.to_string()),
        })
        .collect()
}

impl SqlExecutor for SqliteExecutor {
    fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Record>> {
        let conn = self.conn.lock().expect("sqlite lock");
        let mut statement = conn.prepare(sql).map_err(other)?;
        let names: Vec<String> = statement
            .column_names()
            .iter()
            .map(|s| s.to_string())
            .collect();
        let mut rows = statement
            .query(rusqlite::params_from_iter(bind(params)))
            .map_err(other)?;
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(other)? {
            let mut record = Record::new();
            for (i, name) in names.iter().enumerate() {
                let value = match row.get_ref(i).map_err(other)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => Value::from(n),
                    ValueRef::Real(f) => serde_json::Number::from_f64(f)
                        .map(Value::Number)
                        .unwrap_or(Value::Null),
                    ValueRef::Text(t) => Value::String(String::from_utf8_lossy(t).into_owned()),
                    ValueRef::Blob(_) => {
                        return Err(Error::Other(format!(
                            "column {name}: blobs are not supported"
                        )))
                    }
                };
                record.insert(name.clone(), value);
            }
            out.push(record);
        }
        Ok(out)
    }

    fn execute(&self, sql: &str, params: &[Value]) -> Result<()> {
        let conn = self.conn.lock().expect("sqlite lock");
        conn.execute(sql, rusqlite::params_from_iter(bind(params)))
            .map(|_| ())
            .map_err(other)
    }
}
