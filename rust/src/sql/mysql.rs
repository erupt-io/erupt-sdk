//! MySQL through the `mysql` crate (feature `mysql`). Dates are bound as text, which MySQL converts; values
//! read back are normalized by the repository.
use mysql::prelude::Queryable;
use mysql::{Pool, Value as My};
use serde_json::Value;

use crate::{Error, Record, Result};

use super::SqlExecutor;

pub struct MysqlExecutor {
    pool: Pool,
}

impl MysqlExecutor {
    /// Connect with a URL such as `mysql://root@localhost:3306/erupt`.
    pub fn connect(url: &str) -> Result<Self> {
        Ok(MysqlExecutor::from(Pool::new(url).map_err(other)?))
    }
}

impl From<Pool> for MysqlExecutor {
    fn from(pool: Pool) -> Self {
        MysqlExecutor { pool }
    }
}

fn other(e: impl std::fmt::Display) -> Error {
    Error::Other(format!("database error: {e}"))
}

fn bind(params: &[Value]) -> mysql::Params {
    if params.is_empty() {
        return mysql::Params::Empty;
    }
    mysql::Params::Positional(
        params
            .iter()
            .map(|v| match v {
                Value::Null => My::NULL,
                Value::Bool(b) => My::Int(*b as i64),
                Value::Number(n) => n
                    .as_i64()
                    .map(My::Int)
                    .unwrap_or_else(|| My::Double(n.as_f64().unwrap_or(0.0))),
                Value::String(s) => My::Bytes(s.clone().into_bytes()),
                other => My::Bytes(other.to_string().into_bytes()),
            })
            .collect(),
    )
}

fn read(value: My) -> Value {
    match value {
        My::NULL => Value::Null,
        My::Int(n) => Value::from(n),
        My::UInt(n) => Value::from(n),
        My::Float(f) => Value::from(f as f64),
        My::Double(f) => Value::from(f),
        My::Bytes(b) => Value::String(String::from_utf8_lossy(&b).into_owned()),
        My::Date(y, mo, d, h, mi, s, us) => Value::String(format!(
            "{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}.{:03}",
            us / 1000
        )),
        My::Time(neg, days, h, mi, s, us) => Value::String(format!(
            "{}{}:{mi:02}:{s:02}.{:06}",
            if neg { "-" } else { "" },
            days * 24 + h as u32,
            us
        )),
    }
}

impl SqlExecutor for MysqlExecutor {
    fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Record>> {
        let mut conn = self.pool.get_conn().map_err(other)?;
        let rows: Vec<mysql::Row> = conn.exec(sql, bind(params)).map_err(other)?;
        Ok(rows
            .into_iter()
            .map(|row| {
                let names: Vec<String> = row
                    .columns_ref()
                    .iter()
                    .map(|c| c.name_str().into_owned())
                    .collect();
                names
                    .into_iter()
                    .zip(row.unwrap())
                    .map(|(name, value)| (name, read(value)))
                    .collect()
            })
            .collect())
    }

    fn execute(&self, sql: &str, params: &[Value]) -> Result<()> {
        let mut conn = self.pool.get_conn().map_err(other)?;
        conn.exec_drop(sql, bind(params)).map_err(other)
    }
}
