package erupt

import (
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
	"time"
)

const (
	dateLayout     = "2006-01-02"
	dateTimeLayout = "2006-01-02T15:04:05.000"
)

// The formats a date or datetime may arrive in; "T" is read as a space and a trailing "Z" dropped.
// Values are naive wall-clock times, kept in UTC so nothing shifts.
var inputLayouts = []string{"2006-01-02 15:04:05.999999999", "2006-01-02 15:04:05", "2006-01-02 15:04", "2006-01-02"}

func parseDateTime(v any) (time.Time, error) {
	if t, ok := v.(time.Time); ok {
		return t, nil
	}
	text := strings.TrimRight(strings.ReplaceAll(str(v), "T", " "), "Z")
	for _, layout := range inputLayouts {
		if t, err := time.ParseInLocation(layout, text, time.UTC); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("illegal date '%s'", str(v))
}

// str renders a JSON scalar the way the browser sent it.
func str(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case json.Number:
		return t.String()
	case float64:
		if t == math.Trunc(t) && math.Abs(t) < 1e15 {
			return strconv.FormatInt(int64(t), 10)
		}
		return strconv.FormatFloat(t, 'f', -1, 64)
	case float32:
		return str(float64(t))
	case time.Time:
		return t.Format(dateTimeLayout)
	}
	return fmt.Sprint(v)
}

// toFloat reads any numeric value.
func toFloat(v any) (float64, bool) {
	switch t := v.(type) {
	case json.Number:
		f, err := t.Float64()
		return f, err == nil
	case float64:
		return t, true
	case float32:
		return float64(t), true
	case int, int8, int16, int32, int64:
		return float64(reflect.ValueOf(t).Int()), true
	case uint, uint8, uint16, uint32, uint64:
		return float64(reflect.ValueOf(t).Uint()), true
	}
	return 0, false
}

// normalizeKey makes 2, int64(2) and 2.0 the same map key.
func normalizeKey(v any) any {
	if f, ok := toFloat(v); ok && f == math.Trunc(f) {
		return int64(f)
	}
	return v
}

// compare orders two stored values; ok is false when they are not comparable.
func compare(a, b any) (int, bool) {
	if fa, ok := toFloat(a); ok {
		fb, ok := toFloat(b)
		if !ok {
			return 0, false
		}
		return cmp3(fa < fb, fa > fb), true
	}
	switch x := a.(type) {
	case string:
		y, ok := b.(string)
		return cmp3(x < y, x > y), ok
	case bool:
		y, ok := b.(bool)
		return cmp3(!x && y, x && !y), ok
	case time.Time:
		y, ok := b.(time.Time)
		return cmp3(x.Before(y), x.After(y)), ok
	}
	return 0, false
}

func cmp3(less, greater bool) int {
	if less {
		return -1
	}
	if greater {
		return 1
	}
	return 0
}

func equal(a, b any) bool {
	c, ok := compare(a, b)
	return ok && c == 0
}
