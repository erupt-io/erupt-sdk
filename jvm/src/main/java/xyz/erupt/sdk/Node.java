package xyz.erupt.sdk;

import com.sun.net.httpserver.HttpServer;
import xyz.erupt.annotation.config.QueryExpression;
import xyz.erupt.annotation.exception.EruptException;
import xyz.erupt.annotation.fun.OperationHandler;
import xyz.erupt.annotation.fun.PowerObject;
import xyz.erupt.annotation.query.Condition;
import xyz.erupt.annotation.query.Direction;
import xyz.erupt.annotation.query.Sort;
import xyz.erupt.annotation.sub_erupt.RowOperation;

import java.io.IOException;
import java.io.OutputStream;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * An erupt cloud node: registers with the server, then answers the requests it forwards (erupt-cloud/PROTOCOL.md,
 * Level 0 plus references and row operations). Serve it with the JDK's HTTP server ({@link #serve}), or mount
 * {@link #handle} in any other HTTP stack and call {@link #connect}.
 *
 * <pre>{@code
 * new Node("blog", System.getenv("ERUPT_ACCESS_TOKEN"), "http://erupt-server:8080")
 *     .register(Article.class, new JdbcRepository<>(dataSource, "article"))
 *     .serve("0.0.0.0", 9090);
 * }</pre>
 */
public final class Node implements AutoCloseable, Model.Registry {

    public static final String VERSION = "0.1.0";

    private static final System.Logger LOG = System.getLogger("erupt");

    /** Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there. */
    private static final Set<String> UNSUPPORTED_POWER = Set.of("export", "importable", "cellEdit", "print", "ai");

    /** Rights the server decides per user; the node ANDs them onto the declared power. */
    private static final List<String> SERVER_POWER = List.of("add", "edit", "delete", "viewDetails", "export", "importable");

    private static final int MAX_PAGE_SIZE = 1000;

    private static final ThreadLocal<Scope> SCOPE = new ThreadLocal<>();

    private final String name, accessToken;
    private final List<String> servers;
    private final AtomicInteger serverCycle = new AtomicInteger();
    private final Map<String, Entry<?>> entries = new LinkedHashMap<>();
    private final Map<Class<?>, Model<?>> models = new ConcurrentHashMap<>();
    private final Map<Class<?>, Object> instances = new ConcurrentHashMap<>();
    private final Map<String, Object[]> powerCache = new ConcurrentHashMap<>();
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    private final List<Route> routes = new ArrayList<>();
    private final CountDownLatch stopped = new CountDownLatch(1);
    private String address;
    private Duration heartbeat = Duration.ofSeconds(15);
    private boolean requireSignature;
    private Function<Class<?>, Object> factory = Model.Registry::construct;
    private Thread heartbeatThread;
    private HttpServer server;
    private ExecutorService executor;
    private volatile boolean closed;

    /** {@code servers}: one or more erupt server base URLs, round-robined. */
    public Node(String name, String accessToken, String... servers) {
        if (accessToken == null || accessToken.isEmpty()) throw new IllegalArgumentException("accessToken is required");
        if (servers.length == 0) throw new IllegalArgumentException("at least one server address is required");
        this.name = name;
        this.accessToken = accessToken;
        this.servers = Arrays.stream(servers).map(s -> s.replaceAll("/+$", "")).toList();
        route("GET", "/erupt-api/build/([^/]+)", this::build);
        route("GET", "/erupt-api/build/([^/]+)/([^/]+)", this::buildByField);
        route("POST", "/erupt-api/data/table/([^/]+)", this::table);
        route("POST", "/erupt-api/data/([^/]+)/reference-table/([^/]+)", this::referenceTable);
        route("POST", "/erupt-api/data/([^/]+)/operator/([^/]+)/form-value", this::operationFormValue);
        route("POST", "/erupt-api/data/([^/]+)/operator/([^/]+)", this::operation);
        route("GET", "/erupt-api/data/init-value/([^/]+)", this::initValue);
        route("GET", "/erupt-api/data/([^/]+)/([^/]+)", this::get);
        route("POST", "/erupt-api/data/modify/([^/]+)", this::add);
        route("POST", "/erupt-api/data/modify/([^/]+)/update", this::update);
        route("POST", "/erupt-api/data/modify/([^/]+)/delete", this::delete);
    }

    // ---------------------------------------------------------------- configuration

    /** The base URL the server calls this node on; detected from the route to the first server when unset. */
    public Node address(String address) {
        this.address = address.replaceAll("/+$", "");
        return this;
    }

    public Node heartbeat(Duration heartbeat) {
        this.heartbeat = heartbeat;
        return this;
    }

    /** Refuses server calls without a valid Erupt-Signature, so the plain access token alone no longer passes. */
    public Node requireSignature(boolean requireSignature) {
        this.requireSignature = requireSignature;
        return this;
    }

    /**
     * Supplies handler instances ({@code DataProxy}, {@code OperationHandler}, {@code ChoiceFetchHandler},
     * {@code PowerHandler}, {@code ExprHandler}...): hand it your DI container's lookup. Each class is asked once.
     */
    public Node factory(Function<Class<?>, Object> factory) {
        this.factory = factory;
        return this;
    }

    /** Serves an {@code @Erupt} class from {@code repository}. Referenced models must be registered too. */
    public <T> Node register(Class<T> type, Repository<T> repository) {
        Model<T> model = model0(type);
        if (entries.containsKey(model.name)) throw new IllegalArgumentException("erupt '" + model.name + "' registered twice");
        if (model.pk() == null) throw new IllegalArgumentException(model.name + " has no primary key field '" + model.erupt.primaryKeyCol() + "'");
        repository.bind(model);
        entries.put(model.name, new Entry<>(model, repository));
        return this;
    }

    /** The repository a class is registered with. */
    @SuppressWarnings("unchecked")
    public <T> Repository<T> repository(Class<T> type) {
        Entry<?> e = entries.get(type.getSimpleName());
        if (e == null || e.model.type != type) throw new IllegalArgumentException(type.getSimpleName() + " is not registered on this node");
        return (Repository<T>) e.repo;
    }

    /** The node serving the current request, for handlers that need a repository. */
    public static Node current() {
        Scope s = SCOPE.get();
        return s == null ? null : s.node;
    }

    /** The acting user of the current request; null outside one or when the server sent none. */
    public static User currentUser() {
        Scope s = SCOPE.get();
        return s == null ? null : s.user;
    }

    @Override
    public Object instance(Class<?> type) {
        return instances.computeIfAbsent(type, factory);
    }

    @Override
    public Model<?> model(Class<?> type) {
        return model0(type);
    }

    @SuppressWarnings("unchecked")
    private <T> Model<T> model0(Class<T> type) {
        Model<?> m = models.get(type);
        if (m == null) models.put(type, m = new Model<>(type, this));
        return (Model<T>) m;
    }

    // ---------------------------------------------------------------- framework-neutral handler

    /**
     * One request. {@code target} is the raw path and query below the node's mount point, exactly as received
     * (the signature covers it); {@code header} looks a header up case-insensitively (null when absent).
     */
    public record Request(String method, String target, Function<String, String> header, byte[] body) {
    }

    public record Response(int status, String contentType, byte[] body) {
    }

    /** Answers one request; never throws. Mount it in any HTTP stack (servlet, Ktor, Vert.x, Javalin...). */
    public Response handle(Request req) {
        int q = req.target().indexOf('?');
        String path = q < 0 ? req.target() : req.target().substring(0, q);
        Object body;
        int status = 200;
        try {
            body = dispatch(req, path, q < 0 ? "" : req.target().substring(q + 1));
        } catch (Reply r) {
            status = r.status;
            body = "";
        } catch (EruptException e) {
            body = r(false, e.getMessage(), null);
        } catch (Exception e) { // never leak internals: message only, the stack stays in the node log
            LOG.log(System.Logger.Level.ERROR, "erupt node error", e);
            status = 500;
            Map<String, Object> error = new LinkedHashMap<>();
            error.put("path", path);
            error.put("status", 500);
            error.put("error", "erupt exception");
            error.put("message", e.getMessage());
            body = error;
        } finally {
            SCOPE.remove();
        }
        if (body instanceof String text) return new Response(status, "text/plain; charset=utf-8", text.getBytes(StandardCharsets.UTF_8));
        return new Response(status, "application/json; charset=utf-8", Json.write(body).getBytes(StandardCharsets.UTF_8));
    }

    private Object dispatch(Request req, String path, String query) throws Exception {
        if (path.equals("/node-health")) return name;
        if (!path.startsWith("/erupt-api/")) throw new Reply(404);
        // server-to-server only: an Origin header means a browser reached the node directly
        if (req.header().apply("Origin") != null) throw new Reply(403);
        Set<String> enforced = authenticate(req);
        String erupt = req.header().apply("erupt");
        for (Route route : routes) {
            Matcher m = route.pattern.matcher(path);
            if (!route.method.equals(req.method()) || !m.matches()) continue;
            String eruptName = decode(m.group(1));
            Entry<?> entry = entries.get(eruptName);
            if (!eruptName.equals(erupt) || entry == null) throw new Reply(404);
            String parent = req.header().apply("eruptParent");
            if (parent == null) parent = queryParam(query, "_eruptParent");
            // nesting is not supported yet, so a parent can only vouch for itself
            if (parent != null && !parent.isEmpty() && !parent.substring(parent.lastIndexOf('.') + 1).equals(eruptName)) throw new Reply(404);
            String userHeader = req.header().apply("user");
            User user = userHeader == null || userHeader.isEmpty() ? null
                    : User.of(Json.parse(new String(Base64.getDecoder().decode(userHeader.strip()), StandardCharsets.UTF_8)));
            SCOPE.set(new Scope(this, user, enforced, req.header().apply("token")));
            List<String> args = new ArrayList<>();
            for (int i = 2; i <= m.groupCount(); i++) args.add(decode(m.group(i)));
            return route.handler.handle(entry, req.body(), args);
        }
        throw new Reply(404);
    }

    /** A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then. */
    private Set<String> authenticate(Request req) {
        String signature = req.header().apply(Signature.HEADER_SIGNATURE);
        if (signature == null) {
            String token = req.header().apply("Access-Token");
            if (requireSignature || token == null || !MessageDigest.isEqual(token.getBytes(StandardCharsets.UTF_8), accessToken.getBytes(StandardCharsets.UTF_8))) {
                throw new Reply(403);
            }
            return Set.of();
        }
        String contentType = req.header().apply("Content-Type");
        boolean multipart = contentType != null && contentType.contains("multipart/form-data");
        String enforced = req.header().apply(Signature.HEADER_ENFORCED);
        String timestamp = req.header().apply(Signature.HEADER_TIMESTAMP);
        if (timestamp == null || !Signature.verify(accessToken, req.method(), req.target(), timestamp, enforced, req.header().apply("user"),
                multipart ? null : req.body() == null ? new byte[0] : req.body(), signature, System.currentTimeMillis() / 1000)) {
            throw new Reply(403);
        }
        return enforced == null ? Set.of() : Arrays.stream(enforced.split(",")).map(String::strip).filter(s -> !s.isEmpty()).collect(Collectors.toSet());
    }

    // ---------------------------------------------------------------- endpoints

    private Object build(Entry<?> e, byte[] body, List<String> args) {
        return e.model.buildModel(power(e.model));
    }

    private Object buildByField(Entry<?> e, byte[] body, List<String> args) {
        // the reference picker: build of the referenced model, requested under the host model's name
        Model<?> target = referenceField(e.model, args.get(0), false).target();
        return target.buildModel(power(target));
    }

    private Object table(Entry<?> e, byte[] body, List<String> args) {
        require(e.model, "query");
        return page(e, readMap(body));
    }

    private Object referenceTable(Entry<?> e, byte[] body, List<String> args) {
        FieldDef f = referenceField(e.model, args.get(0), true);
        return page(entry(f.target()), readMap(body));
    }

    private static FieldDef referenceField(Model<?> model, String field, boolean tableOnly) {
        FieldDef f = model.fields.get(field);
        if (f == null || !f.isReference() || tableOnly && f.type != xyz.erupt.annotation.sub_field.EditType.REFERENCE_TABLE) throw new Reply(404);
        return f;
    }

    private Entry<?> entry(Model<?> model) {
        Entry<?> e = entries.get(model.name);
        if (e == null || e.model != model) throw new IllegalStateException("referenced erupt '" + model.name + "' is not registered on this node");
        return e;
    }

    private <T> Object page(Entry<T> e, Map<?, ?> body) {
        Model<T> model = e.model;
        int pageIndex = Math.max(toInt(body.get("pageIndex"), 1), 1);
        int pageSize = Math.min(Math.max(toInt(body.get("pageSize"), 10), 1), MAX_PAGE_SIZE);
        List<Condition> conditions = new ArrayList<>();
        for (Object c : list(body.get("condition"))) conditions.add(condition(model, c instanceof Map<?, ?> m ? m : Map.of()));
        List<Sort> sort = new ArrayList<>();
        for (Object o : list(body.get("sort"))) {
            Map<?, ?> s = o instanceof Map<?, ?> m ? m : Map.of();
            FieldDef f = model.fields.get(String.valueOf(s.get("field")));
            if (f == null || !f.sortable()) throw new EruptException("illegal sort field '" + s.get("field") + "'");
            sort.add(new Sort(f.name, "DESC".equalsIgnoreCase(String.valueOf(s.get("direction"))) ? Direction.DESC : Direction.ASC));
        }
        if (sort.isEmpty()) sort.addAll(model.orderBy);
        Repository.Page<T> page = e.repo.page(new Query(conditions, sort, (pageIndex - 1) * pageSize, pageSize));
        List<Map<String, Object>> rows = new ArrayList<>(page.records().stream().map(model::toRow).toList());
        model.proxies(p -> p.afterFetch(rows));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("pageIndex", pageIndex);
        out.put("pageSize", pageSize);
        out.put("total", page.total());
        out.put("totalPage", (page.total() + pageSize - 1) / pageSize);
        out.put("list", rows);
        out.put("sort", null);
        out.put("alert", null);
        out.put("extraContent", null);
        return out;
    }

    private static Condition condition(Model<?> model, Map<?, ?> c) {
        FieldDef f = model.fields.get(String.valueOf(c.get("key")));
        if (f == null || !f.searchable()) throw new EruptException("illegal search field '" + c.get("key") + "'");
        QueryExpression op;
        try {
            op = c.get("expression") == null || "".equals(c.get("expression")) ? QueryExpression.EQ : QueryExpression.valueOf(String.valueOf(c.get("expression")));
        } catch (IllegalArgumentException e) {
            op = QueryExpression.AUTO;
        }
        if (op == QueryExpression.AUTO) throw new EruptException("illegal operator '" + c.get("expression") + "'");
        Object value = c.get("value");
        if (op == QueryExpression.NULL || op == QueryExpression.NOT_NULL) return new Condition(f.name, null, op);
        if (f.isReference() && !Set.of(QueryExpression.EQ, QueryExpression.NEQ, QueryExpression.IN, QueryExpression.NOT_IN).contains(op)) {
            throw new EruptException("illegal operator '" + op + "' for a reference");
        }
        if (op == QueryExpression.LIKE || op == QueryExpression.NOT_LIKE) return new Condition(f.name, Values.text(value), op);
        try {
            if (op == QueryExpression.RANGE) {
                if (!(value instanceof List<?> l) || l.size() != 2) throw new IllegalArgumentException("range needs two values");
                return new Condition(f.name, l.stream().map(f::toCondition).toList(), op);
            }
            if (op == QueryExpression.IN || op == QueryExpression.NOT_IN) {
                List<?> l = value instanceof List<?> list ? list : List.of(value);
                return new Condition(f.name, l.stream().map(f::toCondition).toList(), op);
            }
            return new Condition(f.name, f.toCondition(value), op);
        } catch (IllegalArgumentException e) {
            throw new EruptException(e.getMessage());
        }
    }

    private <T> Object initValue(Entry<T> e, byte[] body, List<String> args) {
        require(e.model, "add");
        T record = e.model.newInstance();
        e.model.proxies(p -> p.addBehavior(record));
        return e.model.toRow(record);
    }

    private <T> Object get(Entry<T> e, byte[] body, List<String> args) {
        Map<String, Object> power = power(e.model);
        if (!(Boolean) power.get("edit") && !(Boolean) power.get("viewDetails")) throw new Reply(403);
        T record = e.repo.get(pk(e.model, args.get(0)));
        if (record == null) throw new EruptException("record not found");
        e.model.proxies(p -> p.editBehavior(record));
        return e.model.toRow(record);
    }

    private <T> Object add(Entry<T> e, byte[] body, List<String> args) {
        require(e.model, "add");
        T record = e.model.fill(e.model.newInstance(), readMap(body));
        e.model.proxies(p -> p.validate(record));
        e.model.proxies(p -> p.beforeAdd(record));
        e.repo.add(record);
        e.model.proxies(p -> p.afterAdd(record));
        return r(true, null, null);
    }

    private <T> Object update(Entry<T> e, byte[] body, List<String> args) {
        require(e.model, "edit");
        Map<?, ?> data = readMap(body);
        T record = e.repo.get(pk(e.model, data.get(e.model.pk())));
        if (record == null) throw new EruptException("record not found");
        e.model.fill(record, data);
        e.model.proxies(p -> p.validate(record));
        e.model.proxies(p -> p.beforeUpdate(record));
        e.repo.update(record);
        e.model.proxies(p -> p.afterUpdate(record));
        return r(true, null, null);
    }

    private <T> Object delete(Entry<T> e, byte[] body, List<String> args) {
        require(e.model, "delete");
        if (!(read(body) instanceof List<?> ids)) throw new EruptException("a list of ids is required");
        List<Object> pks = new ArrayList<>();
        List<T> records = new ArrayList<>();
        for (Object id : ids) {
            Object pk = pk(e.model, id);
            pks.add(pk);
            T record = e.repo.get(pk);
            if (record != null) records.add(record);
        }
        records.forEach(r -> e.model.proxies(p -> p.beforeDelete(r)));
        e.repo.delete(pks);
        records.forEach(r -> e.model.proxies(p -> p.afterDelete(r)));
        return r(true, null, null);
    }

    private RowOperation operationOf(Model<?> model, String code) {
        RowOperation op = model.operations().get(code);
        if (op != null) return op;
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        boolean declared = Arrays.stream(model.erupt.rowOperation()).anyMatch(o -> code.equals(o.code().isEmpty() ? Integer.toString(o.title().hashCode()) : o.code()));
        throw new Reply(declared ? 403 : 404);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private <T> Object operationFormValue(Entry<T> e, byte[] body, List<String> args) {
        RowOperation op = operationOf(e.model, args.get(0));
        if (op.eruptClass() == void.class) throw new Reply(404); // the browser ignores a 404 here and opens an empty form
        Model form = model(op.eruptClass());
        Object value = form.newInstance();
        if (!op.operationHandler().isInterface()) {
            Object given = ((OperationHandler) instance(op.operationHandler())).eruptFormValue(List.of(), value, op.operationParam());
            if (given != null) value = given;
        }
        return form.toRow(value);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private <T> Object operation(Entry<T> e, byte[] body, List<String> args) {
        RowOperation op = operationOf(e.model, args.get(0));
        Map<?, ?> data = readMap(body);
        Object form = null;
        if (op.eruptClass() != void.class) {
            Model formModel = model(op.eruptClass());
            form = formModel.fill(formModel.newInstance(), data.get("param") instanceof Map<?, ?> m ? m : Map.of());
        }
        List<T> rows = new ArrayList<>();
        if (op.mode() != RowOperation.Mode.BUTTON) {
            if (!(data.get("ids") instanceof List<?> ids) || ids.isEmpty()) throw new EruptException("select at least one row");
            if (op.mode() == RowOperation.Mode.SINGLE && ids.size() != 1) throw new EruptException("select exactly one row");
            for (Object id : ids) {
                T record = e.repo.get(pk(e.model, id));
                if (record == null) throw new EruptException("record '" + id + "' not found");
                rows.add(record);
            }
        }
        String script = op.operationHandler().isInterface() ? null
                : ((OperationHandler) instance(op.operationHandler())).exec(rows, form, op.operationParam());
        return script == null || script.isEmpty() ? r(true, "Executed successfully", null) : r(true, null, script);
    }

    private static Object pk(Model<?> model, Object value) {
        try {
            Object pk = model.pkField().fromJson(value);
            if (pk == null) throw new IllegalArgumentException();
            return pk;
        } catch (IllegalArgumentException e) {
            throw new EruptException("illegal id '" + value + "'");
        }
    }

    // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

    private void require(Model<?> model, String right) {
        if (!(Boolean) power(model).get(right)) throw new Reply(403);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> power(Model<?> model) {
        Map<String, Object> power = powerMap(model.power());
        UNSUPPORTED_POWER.forEach(k -> power.put(k, false));
        Scope scope = SCOPE.get();
        // the server checked the user's rights and restricts the build's power itself: the model's own
        // declaration is all that is left to apply here
        if (scope.enforced.contains("power")) return power;
        String token = scope.token == null ? "" : scope.token;
        String key = token + "\n" + model.name;
        Object[] cached = powerCache.get(key);
        if (cached != null && (long) cached[0] > System.nanoTime()) return new LinkedHashMap<>((Map<String, Object>) cached[1]);
        Map<?, ?> remote;
        try {
            remote = serverGet("/erupt-cloud-api/erupt-power?nodeName=" + encode(name) + "&eruptName=" + encode(model.name), token);
        } catch (Exception e) { // fail closed: without the server's verdict nothing is writable
            LOG.log(System.Logger.Level.WARNING, "erupt-power unavailable: " + e);
            remote = Map.of();
        }
        for (String right : SERVER_POWER) power.put(right, (Boolean) power.get(right) && Boolean.TRUE.equals(remote.get(right)));
        if (powerCache.size() > 10_000) powerCache.clear();
        powerCache.put(key, new Object[]{System.nanoTime() + 5_000_000_000L, power});
        return new LinkedHashMap<>(power);
    }

    /** Every right PowerObject carries, whatever the erupt-annotation version. */
    private static Map<String, Object> powerMap(PowerObject p) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (java.lang.reflect.Field f : PowerObject.class.getDeclaredFields()) {
            if (f.getType() != boolean.class || java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue;
            try {
                f.setAccessible(true);
                m.put(f.getName(), f.getBoolean(p));
            } catch (ReflectiveOperationException | RuntimeException e) {
                throw new IllegalStateException(e);
            }
        }
        return m;
    }

    // ---------------------------------------------------------------- server calls and lifecycle

    private String nextServer() {
        return servers.get(Math.floorMod(serverCycle.getAndIncrement(), servers.size()));
    }

    private Map<?, ?> serverGet(String pathAndQuery, String token) throws IOException, InterruptedException {
        HttpRequest req = HttpRequest.newBuilder(URI.create(nextServer() + pathAndQuery)).timeout(Duration.ofSeconds(5)).header("token", token).GET().build();
        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) throw new IOException("HTTP " + resp.statusCode());
        return Json.parse(resp.body()) instanceof Map<?, ?> m ? m : Map.of();
    }

    /** Starts registering with the server and heart-beating; for a node mounted in another HTTP stack. */
    public synchronized Node connect() {
        if (heartbeatThread != null) return this;
        if (address == null) throw new IllegalStateException("set address(...) to where the server reaches this node");
        String instanceId = HexFormat.of().formatHex(new SecureRandom().generateSeed(3));
        heartbeatThread = new Thread(() -> heartbeatLoop(instanceId), "erupt-heartbeat");
        heartbeatThread.setDaemon(true);
        heartbeatThread.start();
        return this;
    }

    private void heartbeatLoop(String instanceId) {
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("instanceId", instanceId);
        info.put("nodeName", name);
        info.put("accessToken", accessToken);
        info.put("version", "jvm-" + VERSION);
        info.put("nodeAddress", List.of(address));
        info.put("eruptModules", List.of());
        info.put("erupts", List.copyOf(entries.keySet()));
        info.put("resources", Map.of());
        String payload = Json.write(info);
        boolean failing = false;
        while (!closed) {
            String server = nextServer();
            long wait = heartbeat.toMillis();
            try {
                HttpResponse<Void> resp = http.send(HttpRequest.newBuilder(URI.create(server + "/erupt-cloud-api/register-node"))
                        .timeout(Duration.ofSeconds(10)).header("Content-Type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(payload)).build(), HttpResponse.BodyHandlers.discarding());
                if (resp.statusCode() / 100 != 2) throw new IOException("HTTP " + resp.statusCode());
                if (failing) LOG.log(System.Logger.Level.INFO, server + " -> connection success");
                failing = false;
            } catch (InterruptedException e) {
                return;
            } catch (Exception e) {
                failing = true;
                wait /= 2;
                LOG.log(System.Logger.Level.ERROR, server + " -> register failed: " + e);
            }
            try {
                Thread.sleep(wait);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    /** Serves on the JDK HTTP server and connects; returns at once. {@link #close} undoes it. */
    public synchronized Node start(String host, int port) throws IOException {
        if (address == null) address = "http://" + localIp() + ":" + port;
        server = HttpServer.create(new InetSocketAddress(host, port), 0);
        executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "erupt-node");
            t.setDaemon(true);
            return t;
        });
        server.setExecutor(executor);
        server.createContext("/", exchange -> {
            try (exchange) {
                byte[] in = exchange.getRequestBody().readAllBytes();
                URI uri = exchange.getRequestURI();
                String target = uri.getRawPath() + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery());
                Response resp = handle(new Request(exchange.getRequestMethod(), target, exchange.getRequestHeaders()::getFirst, in));
                exchange.getResponseHeaders().set("Content-Type", resp.contentType());
                exchange.sendResponseHeaders(resp.status(), resp.body().length == 0 ? -1 : resp.body().length);
                if (resp.body().length > 0) {
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(resp.body());
                    }
                }
            }
        });
        // HTTP first: the server probes /node-health while registering
        server.start();
        connect();
        LOG.log(System.Logger.Level.INFO, "erupt node '" + name + "' at " + address + " -> " + String.join(", ", servers));
        return this;
    }

    /** {@link #start}, deregistering on JVM shutdown (Ctrl-C, SIGTERM), and blocks until closed. */
    public void serve(String host, int port) throws IOException, InterruptedException {
        start(host, port);
        Runtime.getRuntime().addShutdownHook(new Thread(this::close, "erupt-shutdown"));
        stopped.await();
    }

    /** Deregisters from the server and stops serving (in-flight requests get up to two seconds). */
    @Override
    public synchronized void close() {
        if (closed) return;
        closed = true;
        if (heartbeatThread != null) {
            heartbeatThread.interrupt();
            String form = "nodeName=" + encode(name) + "&accessToken=" + encode(accessToken) + "&locations=" + encode(address);
            try {
                http.send(HttpRequest.newBuilder(URI.create(nextServer() + "/erupt-cloud-api/remove-instance-node")).timeout(Duration.ofSeconds(5))
                        .header("Content-Type", "application/x-www-form-urlencoded").POST(HttpRequest.BodyPublishers.ofString(form)).build(),
                        HttpResponse.BodyHandlers.discarding());
            } catch (Exception e) {
                LOG.log(System.Logger.Level.ERROR, "deregister failed: " + e);
            }
        }
        if (server != null) {
            server.stop(2);
            executor.shutdown();
        }
        stopped.countDown();
    }

    /** The interface address the server would see us on. */
    private String localIp() {
        try (DatagramSocket s = new DatagramSocket()) {
            URI uri = URI.create(servers.get(0));
            s.connect(new InetSocketAddress(uri.getHost() == null ? "127.0.0.1" : uri.getHost(), 80));
            String ip = s.getLocalAddress().getHostAddress();
            return ip.equals("0.0.0.0") || ip.equals("::") ? "127.0.0.1" : ip;
        } catch (IOException | RuntimeException e) {
            return "127.0.0.1";
        }
    }

    // ---------------------------------------------------------------- helpers

    private static Map<String, Object> r(boolean success, String message, Object data) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("success", success);
        r.put("status", success ? "SUCCESS" : "ERROR");
        r.put("message", message);
        r.put("data", data);
        r.put("promptWay", "MESSAGE");
        return r;
    }

    private static Object read(byte[] body) {
        if (body == null || body.length == 0) return null;
        try {
            return Json.parse(new String(body, StandardCharsets.UTF_8));
        } catch (IllegalArgumentException e) {
            throw new EruptException("malformed JSON body");
        }
    }

    private static Map<?, ?> readMap(byte[] body) {
        return read(body) instanceof Map<?, ?> m ? m : Map.of();
    }

    private static List<?> list(Object value) {
        return value instanceof List<?> l ? l : List.of();
    }

    private static int toInt(Object value, int fallback) {
        try {
            return value == null ? fallback : (int) Double.parseDouble(Values.text(value));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String decode(String s) {
        return URLDecoder.decode(s.replace("+", "%2B"), StandardCharsets.UTF_8);
    }

    private static String encode(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }

    private static String queryParam(String query, String key) {
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && decode(pair.substring(0, eq)).equals(key)) return decode(pair.substring(eq + 1));
        }
        return null;
    }

    private void route(String method, String regex, Handler handler) {
        routes.add(new Route(method, Pattern.compile(regex), handler));
    }

    @FunctionalInterface
    private interface Handler {
        Object handle(Entry<?> entry, byte[] body, List<String> args) throws Exception;
    }

    private record Route(String method, Pattern pattern, Handler handler) {
    }

    private record Entry<T>(Model<T> model, Repository<T> repo) {
    }

    private record Scope(Node node, User user, Set<String> enforced, String token) {
    }

    private static final class Reply extends RuntimeException {
        final int status;

        Reply(int status) {
            super(null, null, false, false);
            this.status = status;
        }
    }
}
