using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Erupt;

/// <summary>How a node registers with the erupt server.</summary>
public sealed class NodeOptions
{
    /// <summary>The node name created on the server (Node Config).</summary>
    public required string Name { get; init; }

    /// <summary>The node's access token from the server; keep it out of source control.</summary>
    public required string AccessToken { get; init; }

    /// <summary>erupt server base URLs, used round-robin.</summary>
    public required IReadOnlyList<string> Servers { get; init; }

    /// <summary>The URL the server reaches this node on; detected (preferring IPv4) when null.</summary>
    public string? Address { get; set; }

    public TimeSpan Heartbeat { get; init; } = TimeSpan.FromSeconds(15);
}

/// <summary>
/// An erupt cloud node: registers with the server, then answers the requests it forwards. The wire contract is
/// erupt-cloud/PROTOCOL.md, protocol v2 (§12): the server signs every call, enforces the user's rights and the model's,
/// checks and normalizes queries and records, and turns drills and link trees into conditions. The node stores and
/// reads rows and runs its own code. Mount it with <c>app.MapEruptNode(node)</c> or run it with <see cref="RunAsync"/>.
/// </summary>
public sealed partial class EruptNode
{
    public const string Version = "0.1.0";

    /// <summary>The node protocol this SDK speaks (PROTOCOL.md §12.2).</summary>
    public const int ProtocolVersion = 2;

    // Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    private static readonly string[] Unsupported = ["print", "ai"];

    // an operator is a name the node puts into a query: an unknown one fails, whoever sends it, never matches every row
    private static readonly HashSet<string> Ops = ["EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"];

    // a guard of the node's own: the server checks a page size too, but no call should make a node read without end
    private const int MaxPageSize = 1000;

    private static readonly AsyncLocal<EruptUser?> User = new();

    private static readonly AsyncLocal<string?> Token = new();

    private readonly Dictionary<string, (EruptModel Model, IRepository Repo)> _models = [];
    private readonly List<(string Method, Regex Pattern, Func<Request, string[], Task<JsonNode?>> Handler, string[] Required)> _routes;
    private readonly string[] _servers;
    private int _next;

    internal HttpClient Http { get; set; } = new() { Timeout = TimeSpan.FromSeconds(5) };

    internal ILogger Logger { get; set; } = NullLogger.Instance;

    internal string InstanceId { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(3)).ToLowerInvariant();

    public NodeOptions Options { get; }

    public EruptNode(NodeOptions options)
    {
        if (string.IsNullOrEmpty(options.AccessToken)) throw new ArgumentException("AccessToken is required");
        if (options.Servers.Count == 0) throw new ArgumentException("at least one server is required");
        Options = options;
        _servers = options.Servers.Select(s => s.TrimEnd('/')).ToArray();
        // verb, path, endpoint, what the server must vouch for in Erupt-Enforced (§12.2)
        string[] power = ["power"], query = ["power", "query"], record = ["power", "record"];
        _routes =
        [
            ("GET", Route("^/erupt-api/build/([^/]+)$"), Build, []),
            ("POST", Route("^/erupt-api/data/table/([^/]+)$"), Table, query),
            ("GET", Route("^/erupt-api/data/init-value/([^/]+)$"), InitValue, power),
            ("GET", Route("^/erupt-api/data/([^/]+)/([^/]+)$"), Get, power),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)$"), Add, record),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)/update$"), Update, record),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)/delete$"), Delete, power),
            ("POST", Route("^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$"), Invoke, power),
        ];
    }

    /// <summary>The acting user of the request being served (also inside repositories).</summary>
    public static EruptUser? CurrentUser => User.Value;

    public IReadOnlyCollection<string> ModelNames => _models.Keys;

    public EruptNode Register<T>(IRepository repository) => Register(EruptModel.Of<T>(), repository);

    /// <summary>Serve <paramref name="model"/> from <paramref name="repository"/>. Register referenced models first.</summary>
    public EruptNode Register(EruptModel model, IRepository repository)
    {
        if (_models.ContainsKey(model.Name)) throw new ArgumentException($"erupt '{model.Name}' registered twice");
        if (model.Pk is null) throw new ArgumentException($"{model.Name} has no [Pk]; only an operation form may omit it");
        foreach (var f in model.Fields.Where(f => f.IsReference && f.Target.Name != model.Name))
            if (!_models.ContainsKey(f.Target.Name))
                throw new ArgumentException($"{model.Name}.{f.Name}: register {f.Target.Name} before the models referencing it");
        repository.Bind(model);
        _models[model.Name] = (model, repository);
        return this;
    }

    private static Regex Route(string pattern) => new(pattern, RegexOptions.CultureInvariant);

    // ---------------------------------------------------------------- HTTP

    private sealed record Request(HttpContext Http, EruptModel Model, IRepository Repo, JsonNode? Body);

    private sealed class Reply(int status) : Exception
    {
        internal int Status { get; } = status;
    }

    private static JsonObject R(bool success = true, string? message = null, JsonNode? data = null) => new()
    {
        ["success"] = success, ["status"] = success ? "SUCCESS" : "ERROR", ["message"] = message, ["data"] = data,
        ["promptWay"] = "MESSAGE",
    };

    /// <summary>Serve one forwarded request (<c>/node-health</c> and <c>/erupt-api/**</c>).</summary>
    public async Task HandleAsync(HttpContext context)
    {
        int status;
        object? body;
        try
        {
            (status, body) = await Dispatch(context);
        }
        catch (Reply reply)
        {
            (status, body) = (reply.Status, "");
        }
        catch (EruptFailure failure)
        {
            (status, body) = (200, R(false, failure.Message));
        }
        catch (Exception e) // never leak internals: message only, the stack stays in the node log
        {
            Logger.LogError(e, "erupt node error");
            (status, body) = (500, new JsonObject
            {
                ["path"] = context.Request.Path.Value, ["status"] = 500, ["error"] = "erupt exception", ["message"] = e.Message,
            });
        }
        context.Response.StatusCode = status;
        if (body is string text)
        {
            context.Response.ContentType = "text/plain; charset=utf-8";
            await context.Response.WriteAsync(text);
        }
        else
        {
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(body is JsonNode node ? node.ToJsonString(Json.Options) : "null");
        }
    }

    private async Task<(int, object?)> Dispatch(HttpContext context)
    {
        var request = context.Request;
        var path = request.Path.Value ?? "";
        if (path == "/node-health") return (200, Options.Name);
        if (!path.StartsWith("/erupt-api/", StringComparison.Ordinal)) throw new Reply(404);
        // server-to-server only: an Origin header means a browser reached the node directly
        if (!string.IsNullOrEmpty(request.Headers.Origin)) throw new Reply(403);
        var raw = await ReadBody(request);
        var enforced = Authenticate(request, raw);
        var erupt = request.Headers["erupt"].ToString();
        foreach (var (method, pattern, handler, required) in _routes)
        {
            var match = pattern.Match(path);
            if (method != request.Method || !match.Success) continue;
            // what lets the node skip the checks the server made: never the negotiation alone (§12.2)
            if (!required.All(enforced.Contains)) throw new Reply(403);
            var name = match.Groups[1].Value;
            if (erupt != name || !_models.TryGetValue(name, out var entry)) throw new Reply(404);
            var parent = request.Headers["eruptParent"].ToString();
            if (parent.Length == 0) parent = request.Query["_eruptParent"].ToString();
            // nesting is not supported yet, so a parent can only vouch for itself
            if (parent.Length > 0 && parent.Split('.')[^1] != name) throw new Reply(404);
            var user = request.Headers["user"].ToString();
            User.Value = user.Length > 0 ? JsonSerializer.Deserialize<EruptUser>(Convert.FromBase64String(user)) : null;
            Token.Value = request.Headers["token"].ToString();
            var body = ParseJson(raw);
            var args = match.Groups.Cast<Group>().Skip(2).Select(g => g.Value).ToArray();
            return (200, await handler(new Request(context, entry.Model, entry.Repo, body), args));
        }
        throw new Reply(404);
    }

    private static async Task<byte[]> ReadBody(HttpRequest request)
    {
        using var buffer = new MemoryStream();
        await request.Body.CopyToAsync(buffer);
        return buffer.ToArray();
    }

    /// <summary>Every call is signed (§12.2); its Erupt-Enforced is what the server vouches for.</summary>
    private HashSet<string> Authenticate(HttpRequest request, byte[] body)
    {
        var signature = request.Headers[Signature.HeaderSignature].ToString();
        if (signature.Length == 0) throw new Reply(403);
        var multipart = (request.ContentType ?? "").Contains("multipart/form-data", StringComparison.OrdinalIgnoreCase);
        var enforced = request.Headers[Signature.HeaderEnforced].ToString();
        var pathAndQuery = request.Path.ToUriComponent() + request.QueryString.ToUriComponent();
        if (!Signature.Verify(Options.AccessToken, request.Method, pathAndQuery, request.Headers[Signature.HeaderTimestamp].ToString(),
                enforced, request.Headers["user"].ToString(), multipart ? null : body, signature, DateTimeOffset.UtcNow.ToUnixTimeSeconds()))
            throw new Reply(403);
        return enforced.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
    }

    private static JsonNode? ParseJson(byte[] raw)
    {
        var text = Encoding.UTF8.GetString(raw);
        if (text.Length == 0) return null;
        try
        {
            return JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            throw new EruptFailure("malformed JSON body");
        }
    }

    private static JsonObject BodyObject(Request r) => r.Body switch
    {
        null => [],
        JsonObject obj => obj,
        _ => throw new EruptFailure("a JSON object is required"),
    };

    // ---------------------------------------------------------------- endpoints

    // the rights the model switches off, and the features this SDK does not serve yet (§12.3)
    private static Task<JsonNode?> Build(Request r, string[] _)
    {
        var power = r.Model.PowerJson.DeepClone().AsObject();
        foreach (var feature in Unsupported) power[feature] = false;
        return Task.FromResult<JsonNode?>(r.Model.BuildModel(power, CurrentUser));
    }

    private async Task<JsonNode?> Table(Request r, string[] _) => await Page(r.Model, r.Repo, BodyObject(r), r.Http.RequestAborted);

    private async Task<JsonNode> Page(EruptModel model, IRepository repo, JsonObject body, CancellationToken ct)
    {
        var pageIndex = Math.Max(Int(body["pageIndex"], 1), 1);
        var pageSize = Math.Min(Math.Max(Int(body["pageSize"], 10), 1), MaxPageSize);
        var query = new Query { Offset = (pageIndex - 1) * pageSize, Limit = pageSize };
        // checked and normalized by the server, a drill's join and a link tree's keys among them (§12.4)
        foreach (var c in body["condition"] as JsonArray ?? []) query.Conditions.AddRange(Condition(model, c as JsonObject ?? []));
        foreach (var s in body["sort"] as JsonArray ?? [])
        {
            // "field.column" sorts by a reference's label: the server resolves labels, the node orders by the key
            var name = Values.Plain(s?["field"]) as string;
            if (name is null || !model.FieldMap.TryGetValue(name.Split('.')[0], out var f) || f.Virtual)
                throw new EruptFailure($"illegal sort field '{name}'");
            query.Sort.Add((f.Name, Values.Str(Values.Plain(s?["direction"]) ?? "ASC").ToUpperInvariant() == "DESC"));
        }
        // a @Vis view's own filter and order, a drill's linkCondition, then the DataProxy's
        var (filters, sort) = model.Views.GetValueOrDefault(Values.Plain(body["vis"]) as string ?? "", ([], []));
        if (query.Sort.Count == 0) query.Sort = [.. sort.Count > 0 ? sort : model.OrderBy];
        query.Filters.AddRange(Drill(body));
        query.Filters.AddRange(filters);
        query.Filters.AddRange(model.Filters(query.Conditions));
        var (total, records) = await repo.PageAsync(query, ct);
        var rows = await Rows(model, records, ct);
        model.Hook(p => p.AfterFetch(rows.Cast<JsonObject>().ToList()));
        return new JsonObject
        {
            ["pageIndex"] = pageIndex, ["pageSize"] = pageSize, ["total"] = total,
            ["totalPage"] = (long)Math.Ceiling(total / (double)pageSize), ["list"] = rows,
            ["sort"] = null, ["alert"] = null, ["extraContent"] = null,
        };
    }

    private static int Int(JsonNode? node, int fallback) =>
        Values.Plain(node) is { } value && value is not "" and not false ? Convert.ToInt32(value, CultureInfo.InvariantCulture) : fallback;

    /// <summary>
    /// A drilled table (§12.4): the server sent the join as a condition and names the drill, whose linkCondition the
    /// node adds. The source model must be served here and declare that drill.
    /// </summary>
    private List<SqlFilter> Drill(JsonObject body)
    {
        if (body["drill"] is not JsonObject drill) return [];
        if (!_models.TryGetValue(Values.Plain(drill["erupt"]) as string ?? "", out var source)
            || !source.Model.Drills.TryGetValue(Values.Plain(drill["code"]) as string ?? "", out var condition))
            throw new Reply(403);
        return condition.Length > 0 ? [new SqlFilter(condition)] : [];
    }

    private static IEnumerable<Cond> Condition(EruptModel model, JsonObject c)
    {
        // a name the node puts into a query is one of its stored fields, whoever sends it (§12.6)
        var key = Values.Plain(c["key"]) as string;
        if (key is null || !model.FieldMap.TryGetValue(key, out var f) || f.Virtual) throw new EruptFailure($"illegal search field '{key}'");
        var op = Values.Plain(c["expression"]) as string ?? "";
        if (!Ops.Contains(op)) throw new EruptFailure($"illegal operator '{op}'");
        var value = Values.Plain(c["value"]);
        if (f.IsJson && !f.IsCollection && op is "EQ" or "IN" or "NEQ" or "NOT_IN")
        {
            // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its JSON text
            var like = op is "EQ" or "IN" ? "LIKE" : "NOT_LIKE";
            return (value as List<object?> ?? [value]).Select(v => new Cond(f.Name, like, Values.ToJson(Values.Str(v))!.ToJsonString())).ToList();
        }
        if (op is "NULL" or "NOT_NULL") return [new Cond(f.Name, op)];
        if (op is "LIKE" or "NOT_LIKE") return [new Cond(f.Name, op, Values.Str(value))];
        try
        {
            // values arrive as the JSON type their field stores; dates become the repository's date types
            return op is "RANGE" or "IN" or "NOT_IN"
                ? [new Cond(f.Name, op, (value as List<object?> ?? [value]).Select(f.Coerce).ToList())]
                : [new Cond(f.Name, op, f.Coerce(value))];
        }
        catch (FormatException e)
        {
            throw new EruptFailure($"{f.Title}: {e.Message}");
        }
    }

    private async Task<JsonNode?> InitValue(Request r, string[] _)
    {
        var record = new Record(r.Model.Stored.ToDictionary(f => f.Name, _ => (object?)null));
        r.Model.Hook(p => p.AddBehavior(record));
        return (await Rows(r.Model, [record], r.Http.RequestAborted))[0];
    }

    private async Task<JsonNode?> Get(Request r, string[] args)
    {
        var record = await r.Repo.GetAsync(Pk(r.Model, args[0])!, r.Http.RequestAborted) ?? throw new EruptFailure("record not found");
        r.Model.Hook(p => p.EditBehavior(record));
        return (await Rows(r.Model, [record], r.Http.RequestAborted))[0];
    }

    private async Task<JsonNode?> Add(Request r, string[] _)
    {
        var record = ToRecord(r.Model, BodyObject(r));
        r.Model.Hook(p => p.Validate(record));
        r.Model.Hook(p => p.BeforeAdd(record));
        await r.Repo.AddAsync(record, r.Http.RequestAborted);
        r.Model.Hook(p => p.AfterAdd(record));
        return R();
    }

    private async Task<JsonNode?> Update(Request r, string[] _)
    {
        var body = BodyObject(r);
        var pk = Pk(r.Model, Values.Plain(body[r.Model.Pk!]));
        if (pk is null || await r.Repo.GetAsync(pk, r.Http.RequestAborted) is null) throw new EruptFailure("record not found");
        var record = ToRecord(r.Model, body);
        r.Model.Hook(p => p.Validate(record));
        r.Model.Hook(p => p.BeforeUpdate(record));
        await r.Repo.UpdateAsync(pk, record, r.Http.RequestAborted);
        r.Model.Hook(p => p.AfterUpdate(record));
        return R();
    }

    private async Task<JsonNode?> Delete(Request r, string[] _)
    {
        if (r.Body is not JsonArray ids) throw new EruptFailure("a list of ids is required");
        var pks = ids.Select(id => Pk(r.Model, Values.Plain(id))!).ToList();
        // the hooks see each record as it was; reading them costs nothing without a proxy
        var records = new List<Record>();
        if (r.Model.Proxies.Count > 0)
            foreach (var pk in pks)
                if (await r.Repo.GetAsync(pk, r.Http.RequestAborted) is { } record) records.Add(record);
        foreach (var record in records) r.Model.Hook(p => p.BeforeDelete(record));
        await r.Repo.DeleteAsync(pks, r.Http.RequestAborted);
        foreach (var record in records) r.Model.Hook(p => p.AfterDelete(record));
        return R();
    }

    /// <summary>
    /// The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the operation
    /// code, or a field's fetched options, onchange, auto-complete or button with the form's values.
    /// </summary>
    private static async Task<JsonNode?> Invoke(Request r, string[] args)
    {
        if (args[0] == "operation") return await Operation(r, args[1]);
        if (args[0] == "operation-form") return R(data: OperationFormValue(r.Model, args[1]));
        if (!r.Model.FieldMap.TryGetValue(args[1], out var f) || !f.Invoked.TryGetValue(args[0], out var code)) throw new Reply(404);
        var body = BodyObject(r);
        var form = new Record(Values.Plain(body["form"]) as Dictionary<string, object?> ?? []);
        return R(data: await code(form, Values.Plain(body["value"]) as string ?? ""));
    }

    /// <summary>
    /// Records to browser rows. A reference stays its key: the server resolves its label, the flattened
    /// &lt;field&gt;_&lt;label&gt; column and the tree (erupt-cloud/PROTOCOL.md §7.3).
    /// </summary>
    private static Task<JsonArray> Rows(EruptModel model, IReadOnlyList<Record> records, CancellationToken ct)
    {
        var rows = new JsonArray();
        foreach (var record in records)
        {
            var row = new JsonObject();
            foreach (var f in model.Stored) row[f.Name] = Values.ToJson(record.GetValueOrDefault(f.Name));
            rows.Add(row);
        }
        return Task.FromResult(rows);
    }

    private static OperationDef OperationOf(EruptModel model, string code)
    {
        var op = model.Operations.FirstOrDefault(o => o.Code == code) ?? throw new Reply(404);
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        return op.Visible(CurrentUser) ? op : throw new Reply(403);
    }

    private static JsonObject? OperationFormValue(EruptModel model, string code) =>
        // none without a form: the server answers the browser a 404, and it opens an empty one
        OperationOf(model, code).Form is { } form ? new JsonObject(form.Fields.Select(f => KeyValuePair.Create(f.Name, (JsonNode?)null))) : null;

    private static async Task<JsonNode?> Operation(Request r, string code)
    {
        var op = OperationOf(r.Model, code);
        var body = BodyObject(r);
        Record? param = null;
        if (op.Form is not null) param = ToRecord(op.Form, body["param"] as JsonObject ?? []);
        var rows = new List<Record>();
        if (op.Mode != RowOperationMode.BUTTON)
        {
            if (body["ids"] is not JsonArray { Count: > 0 } ids) throw new EruptFailure("select at least one row");
            if (op.Mode == RowOperationMode.SINGLE && ids.Count != 1) throw new EruptFailure("select exactly one row");
            foreach (var id in ids)
            {
                var record = await r.Repo.GetAsync(Pk(r.Model, Values.Plain(id))!, r.Http.RequestAborted);
                rows.Add(record ?? throw new EruptFailure($"record '{Values.Str(Values.Plain(id))}' not found"));
            }
        }
        var result = await op.Handler(new OperationContext
        {
            Rows = rows, Param = param, Repo = r.Repo, Model = r.Model, User = CurrentUser, CancellationToken = r.Http.RequestAborted,
        });
        return string.IsNullOrEmpty(result) ? R(message: "Executed successfully") : R(data: result);
    }

    private static object? Pk(EruptModel model, object? value)
    {
        try
        {
            return FieldDef.CoercePk(value) ?? throw new FormatException();
        }
        catch (FormatException)
        {
            throw new EruptFailure($"illegal id '{Values.Str(value)}'");
        }
    }

    /// <summary>A record the server checked and normalized (§12.4), as the repository stores it.</summary>
    private static Record ToRecord(EruptModel model, JsonObject body)
    {
        var record = new Record();
        foreach (var f in model.Stored.Where(f => !f.IsPk && f.Form))
        {
            try
            {
                record[f.Name] = f.Coerce(Values.Plain(body[f.Name]));
            }
            catch (FormatException e)
            {
                throw new EruptFailure($"{f.Title}: {e.Message}");
            }
        }
        return record;
    }

    // ---------------------------------------------------------------- server calls

    /// <summary>The config text set for this node on the erupt server (Node Config).</summary>
    public Task<string> ConfigAsync(CancellationToken ct = default) =>
        ServerText($"/erupt-cloud-api/node-config/{Uri.EscapeDataString(Options.Name)}", null, ct);

    /// <summary>The config text of this node's group on the erupt server.</summary>
    public Task<string> GroupConfigAsync(CancellationToken ct = default) =>
        ServerText($"/erupt-cloud-api/node-group-config/{Uri.EscapeDataString(Options.Name)}", null, ct);

    /// <summary>The acting user's full info from the erupt server (roles, org, post...), for the request being served.</summary>
    public async Task<JsonObject?> UserInfoAsync(CancellationToken ct = default)
    {
        var text = await ServerText($"/erupt-cloud-api/userinfo/{Uri.EscapeDataString(Options.Name)}", Token.Value ?? "", ct);
        return text.Length > 0 ? JsonNode.Parse(text) as JsonObject : null;
    }

    private async Task<string> ServerText(string path, string? token, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, NextServer() + path);
        request.Headers.TryAddWithoutValidation("Access-Token", Options.AccessToken);
        if (token is not null) request.Headers.TryAddWithoutValidation("token", token);
        using var response = await Http.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(ct);
    }

    // ---------------------------------------------------------------- registration

    internal string NextServer() => _servers[(int)((uint)Interlocked.Increment(ref _next) % _servers.Length)];

    /// <summary>The address the server should call: configured, else this machine's address towards the server.</summary>
    internal void ResolveAddress(int port)
    {
        if (Options.Address is not null)
        {
            Options.Address = Options.Address.TrimEnd('/');
            return;
        }
        Options.Address = "http://" + HostPort(LocalIp(_servers[0]), port);
    }

    /// <summary>host:port, an IPv6 host bracketed as a URL requires.</summary>
    internal static string HostPort(IPAddress ip, int port) =>
        (ip.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{ip}]" : ip.ToString()) + ":" + port.ToString(CultureInfo.InvariantCulture);

    /// <summary>The interface address the server would see us on, IPv4 first ("localhost" may resolve to ::1 first).</summary>
    internal static IPAddress LocalIp(string server)
    {
        try
        {
            var host = new Uri(server).Host.Trim('[', ']');
            var candidates = IPAddress.TryParse(host, out var literal) ? [literal] : Dns.GetHostAddresses(host);
            var target = candidates.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? candidates.First();
            using var socket = new Socket(target.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
            socket.Connect(target, 80);
            return ((IPEndPoint)socket.LocalEndPoint!).Address;
        }
        catch (Exception e) when (e is SocketException or UriFormatException or InvalidOperationException)
        {
            return IPAddress.Loopback;
        }
    }

    internal JsonObject NodeInfo() => new()
    {
        ["instanceId"] = InstanceId, ["nodeName"] = Options.Name, ["accessToken"] = Options.AccessToken,
        ["version"] = "dotnet-" + Version, ["protocolVersion"] = ProtocolVersion, ["nodeAddress"] = new JsonArray(Options.Address),
        ["eruptModules"] = new JsonArray(), ["erupts"] = new JsonArray(_models.Keys.Select(k => (JsonNode)k).ToArray()),
        ["resources"] = new JsonObject(), ["capabilities"] = new JsonArray("invoke"),
    };

    /// <summary>
    /// Register every <see cref="NodeOptions.Heartbeat"/> until cancelled (half the interval after a failure). Stops for
    /// good when the server does not speak this node's protocol (§12.2): it would call the node as v1, which it no longer
    /// answers.
    /// </summary>
    internal async Task HeartbeatAsync(CancellationToken ct)
    {
        var failing = false;
        while (!ct.IsCancellationRequested)
        {
            var server = NextServer();
            try
            {
                using var content = new StringContent(NodeInfo().ToJsonString(), Encoding.UTF8, "application/json");
                using var response = await Http.PostAsync(server + "/erupt-cloud-api/register-node", content, ct);
                response.EnsureSuccessStatusCode();
                if (!SpeaksProtocol(await response.Content.ReadAsStringAsync(ct)))
                {
                    Logger.LogError("{Server} does not speak node protocol v{Version}: upgrade the erupt server; registration stopped", server, ProtocolVersion);
                    return;
                }
                if (failing) Logger.LogInformation("{Server} -> connection success", server);
                failing = false;
                await Task.Delay(Options.Heartbeat, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
            {
                failing = true;
                Logger.LogError("{Server} -> register failed: {Message}", server, e.Message);
                try
                {
                    await Task.Delay(Options.Heartbeat / 2, ct);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    /// <summary>Whether a register answer comes from a server that speaks this node's protocol (§12.2).</summary>
    internal static bool SpeaksProtocol(string answer)
    {
        try
        {
            return JsonNode.Parse(answer) is JsonObject reply && reply["protocolVersion"] is JsonValue v
                   && v.GetValueKind() == JsonValueKind.Number && v.ToJsonString() == ProtocolVersion.ToString(CultureInfo.InvariantCulture);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>Tell the server to stop routing to this instance.</summary>
    internal async Task DeregisterAsync()
    {
        try
        {
            using var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["nodeName"] = Options.Name, ["accessToken"] = Options.AccessToken, ["locations"] = Options.Address ?? "",
            });
            using var response = await Http.PostAsync(NextServer() + "/erupt-cloud-api/remove-instance-node", content);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            Logger.LogError("deregister failed: {Message}", e.Message);
        }
    }
}
