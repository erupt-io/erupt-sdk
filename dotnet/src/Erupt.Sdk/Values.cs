using System.Collections;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Erupt;

/// <summary>Conversions between JSON, the plain values repositories store, and the wire formats erupt uses.</summary>
internal static class Values
{
    internal const string DateFormat = "yyyy-MM-dd";

    // DATE_TIME on the wire: naive wall-clock time with milliseconds, never shifted by a time zone
    internal const string DateTimeFormat = "yyyy-MM-dd'T'HH:mm:ss.fff";

    private static readonly string[] Accepted =
        ["yyyy-MM-dd HH:mm:ss.FFFFFFF", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"];

    /// <summary>JSON to the plain CLR values a request carries: string, bool, long, double, lists and dictionaries.</summary>
    internal static object? Plain(JsonNode? node) => node switch
    {
        null => null,
        JsonObject obj => obj.ToDictionary(e => e.Key, e => Plain(e.Value)),
        JsonArray array => array.Select(Plain).ToList(),
        JsonValue value => value.GetValueKind() switch
        {
            JsonValueKind.String => value.GetValue<string>(),
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number => long.TryParse(value.ToJsonString(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var l)
                ? l
                : double.Parse(value.ToJsonString(), CultureInfo.InvariantCulture),
            _ => null,
        },
        _ => null,
    };

    /// <summary>Stored values to JSON, dates in erupt's formats.</summary>
    internal static JsonNode? ToJson(object? value) => value switch
    {
        null => null,
        JsonNode node => node.DeepClone(),
        string s => JsonValue.Create(s),
        bool b => JsonValue.Create(b),
        DateOnly d => JsonValue.Create(d.ToString(DateFormat, CultureInfo.InvariantCulture)),
        DateTime t => JsonValue.Create(t.ToString(DateTimeFormat, CultureInfo.InvariantCulture)),
        IDictionary map => new JsonObject(map.Keys.Cast<object>().Select(k => KeyValuePair.Create(Convert.ToString(k, CultureInfo.InvariantCulture)!, ToJson(map[k])))),
        IEnumerable list => new JsonArray(list.Cast<object?>().Select(ToJson).ToArray()),
        _ => Normalize(value) switch
        {
            long l => JsonValue.Create(l),
            double d => JsonValue.Create(d),
            var other => JsonValue.Create(Convert.ToString(other, CultureInfo.InvariantCulture)),
        },
    };

    /// <summary>Numbers to long (integral) or double, so equal values compare equal whatever their CLR type.</summary>
    internal static object? Normalize(object? value) => value switch
    {
        int or long or short or byte or sbyte or ushort or uint => Convert.ToInt64(value, CultureInfo.InvariantCulture),
        ulong u => u <= long.MaxValue ? (object)(long)u : (double)u,
        float or double or decimal => Number(Convert.ToDouble(value, CultureInfo.InvariantCulture)),
        _ => value,
    };

    internal static object Number(double value) =>
        Math.Floor(value) == value && value is >= long.MinValue and <= long.MaxValue ? (object)(long)value : value;

    /// <summary>Python's <c>str()</c> of a stored value, used for labels, ids and LIKE matching.</summary>
    internal static string Str(object? value) => value switch
    {
        null => "None",
        bool b => b ? "True" : "False",
        string s => s,
        DateOnly or DateTime => ToJson(value)!.GetValue<string>(),
        _ => Convert.ToString(Normalize(value), CultureInfo.InvariantCulture) ?? "",
    };

    internal static DateTime ParseDateTime(object value)
    {
        var text = Str(value).Replace('T', ' ').TrimEnd('Z');
        if (DateTime.TryParseExact(text, Accepted, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
            return DateTime.SpecifyKind(parsed, DateTimeKind.Unspecified);
        throw new FormatException($"illegal date '{Str(value)}'");
    }

    internal static bool Same(object? a, object? b) => a is null || b is null ? a is null && b is null : Compare(a, b) == 0;

    /// <summary>Orders two non-null values of the same kind; numbers compare numerically.</summary>
    internal static int Compare(object a, object b)
    {
        a = Normalize(a)!;
        b = Normalize(b)!;
        if (a is long or double && b is long or double)
            return Convert.ToDouble(a, CultureInfo.InvariantCulture).CompareTo(Convert.ToDouble(b, CultureInfo.InvariantCulture));
        if (a is string sa && b is string sb) return string.CompareOrdinal(sa, sb);
        if (a.GetType() == b.GetType() && a is IComparable comparable) return comparable.CompareTo(b);
        throw new InvalidOperationException($"cannot compare {a.GetType().Name} with {b.GetType().Name}");
    }
}
