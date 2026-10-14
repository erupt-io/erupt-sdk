//! PostgreSQL through the synchronous `postgres` crate (feature `postgres`). Parameters are converted to the
//! types the server reports for them: PostgreSQL refuses a text parameter for a date or integer column.
use std::sync::Mutex;

use chrono::{NaiveDate, NaiveDateTime};
use postgres::types::{ToSql, Type};
use postgres::{Client, Row};
use serde_json::Value;

use crate::values::{as_f64, parse_date_time, text};
use crate::{Error, Record, Result};

use super::SqlExecutor;

pub struct PostgresExecutor {
    client: Mutex<Client>,
}

impl PostgresExecutor {
    /// Connect without TLS, e.g. `"host=localhost user=postgres dbname=erupt"`.
    pub fn connect(params: &str) -> Result<Self> {
        Ok(PostgresExecutor::from(
            Client::connect(params, postgres::NoTls).map_err(other)?,
        ))
    }
}

impl From<Client> for PostgresExecutor {
    fn from(client: Client) -> Self {
        PostgresExecutor {
            client: Mutex::new(client),
        }
    }
}

fn other(e: impl std::fmt::Display) -> Error {
    Error::Other(format!("database error: {e}"))
}

fn date_time(value: &Value) -> Result<NaiveDateTime> {
    let d = value
        .as_str()
        .and_then(parse_date_time)
        .ok_or_else(|| other(format!("illegal date {value}")))?;
    NaiveDate::from_ymd_opt(d.year, d.month, d.day)
        .and_then(|day| day.and_hms_milli_opt(d.hour, d.minute, d.second, d.millis))
        .ok_or_else(|| other(format!("illegal date {value}")))
}

fn convert(value: &Value, ty: &Type) -> Result<Box<dyn ToSql + Sync>> {
    if value.is_null() {
        // a NULL still needs the column's type
        return Ok(match *ty {
            Type::BOOL => Box::new(None::<bool>),
            Type::INT2 => Box::new(None::<i16>),
            Type::INT4 => Box::new(None::<i32>),
            Type::INT8 => Box::new(None::<i64>),
            Type::FLOAT4 => Box::new(None::<f32>),
            Type::FLOAT8 => Box::new(None::<f64>),
            Type::DATE => Box::new(None::<NaiveDate>),
            Type::TIMESTAMP => Box::new(None::<NaiveDateTime>),
            _ => Box::new(None::<String>),
        });
    }
    let n = || as_f64(value).ok_or_else(|| other(format!("expected a number, got {value}")));
    Ok(match *ty {
        Type::BOOL => Box::new(match value {
            Value::Bool(b) => *b,
            other => as_f64(other).map(|n| n != 0.0).unwrap_or(false),
        }),
        Type::INT2 => Box::new(n()? as i16),
        Type::INT4 => Box::new(n()? as i32),
        Type::INT8 => Box::new(n()? as i64),
        Type::FLOAT4 => Box::new(n()? as f32),
        Type::FLOAT8 => Box::new(n()?),
        Type::DATE => Box::new(date_time(value)?.date()),
        Type::TIMESTAMP => Box::new(date_time(value)?),
        _ => Box::new(text(value)),
    })
}

fn read(row: &Row, i: usize) -> Result<Value> {
    let ty = row.columns()[i].type_().clone();
    let value = match ty {
        Type::BOOL => row
            .try_get::<_, Option<bool>>(i)
            .map_err(other)?
            .map(Value::Bool),
        Type::INT2 => row
            .try_get::<_, Option<i16>>(i)
            .map_err(other)?
            .map(Value::from),
        Type::INT4 => row
            .try_get::<_, Option<i32>>(i)
            .map_err(other)?
            .map(Value::from),
        Type::INT8 => row
            .try_get::<_, Option<i64>>(i)
            .map_err(other)?
            .map(Value::from),
        Type::FLOAT4 => row
            .try_get::<_, Option<f32>>(i)
            .map_err(other)?
            .map(|f| Value::from(f as f64)),
        Type::FLOAT8 => row
            .try_get::<_, Option<f64>>(i)
            .map_err(other)?
            .map(Value::from),
        Type::DATE => row
            .try_get::<_, Option<NaiveDate>>(i)
            .map_err(other)?
            .map(|d| Value::String(d.format("%Y-%m-%d").to_string())),
        Type::TIMESTAMP => row
            .try_get::<_, Option<NaiveDateTime>>(i)
            .map_err(other)?
            .map(|t| Value::String(t.format("%Y-%m-%dT%H:%M:%S%.3f").to_string())),
        _ => row
            .try_get::<_, Option<String>>(i)
            .map_err(other)?
            .map(Value::String),
    };
    Ok(value.unwrap_or(Value::Null))
}

impl PostgresExecutor {
    fn run<T>(
        &self,
        sql: &str,
        params: &[Value],
        f: impl FnOnce(&mut Client, &postgres::Statement, &[&(dyn ToSql + Sync)]) -> Result<T>,
    ) -> Result<T> {
        let mut client = self.client.lock().expect("postgres lock");
        let statement = client.prepare(sql).map_err(other)?;
        let boxed = params
            .iter()
            .zip(statement.params())
            .map(|(v, ty)| convert(v, ty))
            .collect::<Result<Vec<_>>>()?;
        let refs: Vec<&(dyn ToSql + Sync)> = boxed.iter().map(|b| b.as_ref()).collect();
        f(&mut client, &statement, &refs)
    }
}

impl SqlExecutor for PostgresExecutor {
    fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Record>> {
        self.run(sql, params, |client, statement, refs| {
            let rows = client.query(statement, refs).map_err(other)?;
            rows.iter()
                .map(|row| {
                    let mut record = Record::new();
                    for (i, column) in row.columns().iter().enumerate() {
                        record.insert(column.name().to_string(), read(row, i)?);
                    }
                    Ok(record)
                })
                .collect()
        })
    }

    fn execute(&self, sql: &str, params: &[Value]) -> Result<()> {
        self.run(sql, params, |client, statement, refs| {
            client.execute(statement, refs).map(|_| ()).map_err(other)
        })
    }
}
