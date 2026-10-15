//! Value conversions shared by the node and the repositories. Dates are naive wall-clock strings:
//! DATE `YYYY-MM-DD`, DATE_TIME `YYYY-MM-DDTHH:MM:SS.mmm`; they compare correctly as text.
use std::cmp::Ordering;

use serde_json::{Number, Value};

/// A parsed wall-clock timestamp.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DateTime {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub millis: u32,
}

impl DateTime {
    pub fn date_string(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }

    pub fn date_time_string(&self) -> String {
        format!(
            "{}T{:02}:{:02}:{:02}.{:03}",
            self.date_string(),
            self.hour,
            self.minute,
            self.second,
            self.millis
        )
    }
}

/// Accepts what python's `_parse_datetime` accepts: `T` or space between date and time, an optional
/// trailing `Z`, seconds and a fraction optional, or a bare date.
pub fn parse_date_time(text: &str) -> Option<DateTime> {
    let text = text.trim_end_matches('Z').replacen('T', " ", 1);
    let (date, time) = match text.split_once(' ') {
        Some((d, t)) => (d, Some(t)),
        None => (text.as_str(), None),
    };
    let mut d = date.split('-');
    let (year, month, day) = (
        num(d.next()?, 4)? as i32,
        num(d.next()?, 2)?,
        num(d.next()?, 2)?,
    );
    if d.next().is_some()
        || !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
    {
        return None;
    }
    let (mut hour, mut minute, mut second, mut millis) = (0, 0, 0, 0);
    if let Some(time) = time {
        let (hms, fraction) = match time.split_once('.') {
            Some((hms, f)) => (hms, Some(f)),
            None => (time, None),
        };
        let mut t = hms.split(':');
        hour = num(t.next()?, 2)?;
        minute = num(t.next()?, 2)?;
        let s = t.next();
        if t.next().is_some() || hour > 23 || minute > 59 {
            return None;
        }
        match (s, fraction) {
            (Some(s), f) => {
                second = num(s, 2)?;
                if second > 59 {
                    return None;
                }
                if let Some(f) = f {
                    if f.is_empty() || f.len() > 6 || !f.bytes().all(|b| b.is_ascii_digit()) {
                        return None;
                    }
                    millis = format!("{f:0<3}")[..3].parse().ok()?;
                }
            }
            (None, Some(_)) => return None,
            (None, None) => {}
        }
    }
    Some(DateTime {
        year,
        month,
        day,
        hour,
        minute,
        second,
        millis,
    })
}

fn num(text: &str, digits: usize) -> Option<u32> {
    (text.len() == digits && text.bytes().all(|b| b.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Integral numbers become i64 whatever the source; other finite numbers stay f64.
pub fn number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        Value::from(value as i64)
    } else {
        Number::from_f64(value)
            .map(Value::Number)
            .unwrap_or(Value::Null)
    }
}

pub fn as_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|f| f.is_finite()),
        _ => None,
    }
}

/// `str(value)` of python: the text a LIKE matches against.
pub fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Null => "None".into(),
        other => other.to_string(),
    }
}

/// Equality with 2 == 2.0.
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        _ => a == b,
    }
}

/// Ordering of values of one field; None when they cannot be compared.
pub fn compare(a: &Value, b: &Value) -> Option<Ordering> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64()?.partial_cmp(&y.as_f64()?),
        (Value::String(x), Value::String(y)) => Some(x.cmp(y)),
        (Value::Bool(x), Value::Bool(y)) => Some(x.cmp(y)),
        _ => None,
    }
}
