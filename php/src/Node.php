<?php

namespace Erupt;

/**
 * Erupt cloud node: answers the requests the erupt server forwards (handle() / run()) and registers with
 * the server from a long-running process (heartbeat()). Under php-fpm or `php -S` each request builds a
 * fresh Node, so run the heartbeat as its own process. The wire contract is erupt-cloud/PROTOCOL.md, protocol v2
 * (§12): the server signs every call, enforces the user's rights and the model's, checks and normalizes queries
 * and records, and turns drills and link trees into conditions. The node stores and reads rows and runs its own code.
 */
final class Node
{
    public const VERSION = '0.1.0';

    /** The node protocol this SDK speaks (PROTOCOL.md §12.2). */
    public const PROTOCOL_VERSION = 2;

    // Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    private const UNSUPPORTED_POWER = ['print' => false, 'ai' => false];

    // operators a condition may use: a name the node puts into a query, checked whoever calls (§12.6)
    private const OPS = ['EQ', 'NEQ', 'GT', 'GTE', 'LT', 'LTE', 'LIKE', 'NOT_LIKE', 'RANGE', 'IN', 'NOT_IN', 'NULL', 'NOT_NULL'];

    // A guard of the node's own: the server checks a page size too, but no call should make a node read without end
    private const MAX_PAGE_SIZE = 1000;

    // verb, path, endpoint, what the server must vouch for in Erupt-Enforced (§12.2)
    private const ROUTES = [
        ['GET', '#^/erupt-api/build/([^/]+)$#', 'build', []],
        ['POST', '#^/erupt-api/data/table/([^/]+)$#', 'table', ['power', 'query']],
        ['GET', '#^/erupt-api/data/init-value/([^/]+)$#', 'initValue', ['power']],
        ['GET', '#^/erupt-api/data/([^/]+)/([^/]+)$#', 'get', ['power']],
        ['POST', '#^/erupt-api/data/modify/([^/]+)$#', 'add', ['power', 'record']],
        ['POST', '#^/erupt-api/data/modify/([^/]+)/update$#', 'update', ['power', 'record']],
        ['POST', '#^/erupt-api/data/modify/([^/]+)/delete$#', 'delete', ['power']],
        ['POST', '#^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$#', 'invoke', ['power']],
    ];

    private static ?array $user = null;
    /** the session token of the request being served */
    private static ?string $token = null;

    /** @var list<string> */
    private readonly array $servers;
    /** @var array<string, array{0: Model, 1: Repository}> */
    private array $models = [];
    private int $nextServer = 0;
    private bool $stopping = false;
    private string $instanceId;

    /** @param string|list<string> $servers erupt server addresses, round-robined */
    public function __construct(
        public readonly string $name,
        private readonly string $accessToken,
        string|array $servers,
        private ?string $address = null,
        private readonly int $heartbeatSeconds = 15,
    ) {
        if ($accessToken === '') {
            throw new \InvalidArgumentException('access token is required');
        }
        $this->servers = array_map(fn($s) => rtrim($s, '/'), (array) $servers);
        $this->instanceId = bin2hex(random_bytes(3));
    }

    /** The acting user of the request being served: ['uid', 'account', 'name', 'tenantId']. */
    public static function currentUser(): ?array
    {
        return self::$user;
    }

    /** @param class-string $class an #[Erupt] class with a primary key */
    public function register(string $class, Repository $repository): self
    {
        $model = Model::of($class);
        if (isset($this->models[$model->name])) {
            throw new \InvalidArgumentException("erupt '$model->name' registered twice");
        }
        if ($model->pk === null) {
            throw new \InvalidArgumentException("$model->name has no #[Field(pk: true)]; only an operation form may omit it");
        }
        $repository->bind($model);
        $this->models[$model->name] = [$model, $repository];
        return $this;
    }

    // ---------------------------------------------------------------- serving

    /** Serve the current PHP SAPI request (php-fpm, `php -S`): read the globals, emit the response. */
    public function run(): void
    {
        $headers = function_exists('getallheaders') ? getallheaders() : [];
        if (!$headers) {
            foreach ($_SERVER as $key => $value) {
                if (str_starts_with($key, 'HTTP_')) {
                    $headers[str_replace('_', '-', substr($key, 5))] = $value;
                }
            }
        }
        $target = $_SERVER['REQUEST_URI'] ?? '/';
        $response = $this->handle($_SERVER['REQUEST_METHOD'] ?? 'GET', parse_url($target, PHP_URL_PATH) ?: '/',
            $headers, (string) file_get_contents('php://input'), $_GET, $target);
        http_response_code($response->status);
        header('Content-Type: ' . $response->contentType);
        echo $response->body;
    }

    /**
     * Framework-neutral entry: one forwarded request in, one Response out.
     *
     * @param array<string, string> $headers any case
     * @param array<string, mixed> $query parsed query string
     * @param ?string $target the raw request target (path and query, as received below the mount point) a signed
     *                        call is verified against; defaults to $path plus the re-encoded $query
     */
    public function handle(string $method, string $path, array $headers, string $body = '', array $query = [], ?string $target = null): Response
    {
        $headers = array_change_key_case($headers, CASE_LOWER);
        $target ??= $path . ($query === [] ? '' : '?' . http_build_query($query));
        try {
            [$status, $payload] = $this->dispatch(strtoupper($method), $path, $headers, $body, $query, $target);
        } catch (Reply $reply) {
            [$status, $payload] = [$reply->status, ''];
        } catch (Fail $e) {
            [$status, $payload] = [200, self::r(false, $e->getMessage())];
        } catch (\Throwable $e) { // never leak internals: message only, the stack stays in the node log
            error_log("erupt node error: $e");
            [$status, $payload] = [500, ['path' => $path, 'status' => 500, 'error' => 'erupt exception', 'message' => $e->getMessage()]];
        } finally {
            self::$user = null;
            self::$token = null;
        }
        return is_string($payload)
            ? new Response($status, 'text/plain; charset=utf-8', $payload)
            : new Response($status, 'application/json; charset=utf-8', Json::encode($payload));
    }

    private function dispatch(string $method, string $path, array $headers, string $body, array $query, string $target): array
    {
        if ($path === '/node-health') {
            return [200, $this->name];
        }
        if (!str_starts_with($path, '/erupt-api/')) {
            throw new Reply(404);
        }
        // server-to-server only: an Origin header means a browser reached the node directly
        if (($headers['origin'] ?? '') !== '') {
            throw new Reply(403);
        }
        $enforced = $this->authenticate($method, $headers, $body, $target);
        $erupt = $headers['erupt'] ?? null;
        foreach (self::ROUTES as [$verb, $pattern, $handler, $required]) {
            if ($verb !== $method || !preg_match($pattern, $path, $m)) {
                continue;
            }
            // what lets the node skip the checks the server made: never the negotiation alone (§12.2)
            if (array_diff($required, $enforced)) {
                throw new Reply(403);
            }
            $name = rawurldecode($m[1]);
            if ($erupt !== $name || !isset($this->models[$name])) {
                throw new Reply(404);
            }
            $parent = ($headers['eruptparent'] ?? '') ?: ($query['_eruptParent'] ?? '');
            // nesting is not supported yet, so a parent can only vouch for itself
            if (is_string($parent) && $parent !== '' && substr(strrchr(".$parent", '.'), 1) !== $name) {
                throw new Reply(404);
            }
            $user = $headers['user'] ?? '';
            self::$user = $user === '' ? null : json_decode((string) base64_decode($user, true), true);
            self::$token = $headers['token'] ?? null;
            [$model, $repo] = $this->models[$name];
            $args = array_map('rawurldecode', array_slice($m, 2));
            return [200, $this->$handler($model, $repo, new Request($headers, $body), ...$args)];
        }
        throw new Reply(404);
    }

    /**
     * Every call is signed (§12.2); its Erupt-Enforced is what the server vouches for.
     *
     * @return list<string>
     */
    private function authenticate(string $method, array $headers, string $body, string $target): array
    {
        $signature = $headers[strtolower(Signature::HEADER_SIGNATURE)] ?? null;
        if ($signature === null) {
            throw new Reply(403);
        }
        $multipart = str_contains((string) ($headers['content-type'] ?? ''), 'multipart/form-data');
        $enforced = $headers[strtolower(Signature::HEADER_ENFORCED)] ?? null;
        if (!Signature::verify($this->accessToken, $method, $target, $headers[strtolower(Signature::HEADER_TIMESTAMP)] ?? null,
            $enforced, $headers['user'] ?? null, $multipart ? null : $body, (string) $signature, time())) {
            throw new Reply(403);
        }
        return array_values(array_filter(explode(',', (string) $enforced)));
    }

    // ---------------------------------------------------------------- endpoints

    private function build(Model $model, Repository $repo, Request $request): array
    {
        // the rights the model switches off, and the features this SDK does not serve yet (§12.3)
        return $model->buildModel(array_merge($model->power, self::UNSUPPORTED_POWER), self::$user);
    }

    private function table(Model $model, Repository $repo, Request $request): array
    {
        return $this->page($model, $repo, $request->object());
    }

    private function page(Model $model, Repository $repo, array $body): array
    {
        $pageIndex = max((int) (($body['pageIndex'] ?? null) ?: 1), 1);
        $pageSize = min(max((int) (($body['pageSize'] ?? null) ?: 10), 1), self::MAX_PAGE_SIZE);
        $query = new Query([], [], ($pageIndex - 1) * $pageSize, $pageSize);
        // checked and normalized by the server, a drill's join and a link tree's keys among them (§12.4)
        foreach ((array) ($body['condition'] ?? []) as $c) {
            array_push($query->conditions, ...$this->conditions($model, is_array($c) ? $c : []));
        }
        foreach ((array) ($body['sort'] ?? []) as $s) {
            // "field.column" sorts by a reference's label: the server resolves labels, the node orders by the key
            $field = is_array($s) && is_string($s['field'] ?? null) ? $s['field'] : '';
            $f = $model->fields[explode('.', $field)[0]] ?? throw new Fail("illegal sort field '$field'");
            $query->sort[] = [$f->name, strtoupper((string) ($s['direction'] ?? 'ASC')) === 'DESC'];
        }
        // a @Vis view's own filter and order, a drill's linkCondition, then the DataProxy's
        [$filters, $sort] = is_string($body['vis'] ?? null) ? ($model->vis[$body['vis']] ?? [[], []]) : [[], []];
        if (!$query->sort) {
            $query->sort = $sort ?: $model->orderBy;
        }
        $query->filters = [...$this->drill($body), ...$filters, ...$model->filters($query->conditions)];
        [$total, $records] = $repo->page($query);
        $rows = $this->rows($model, $records);
        $model->hook('afterFetch', $rows);
        return ['pageIndex' => $pageIndex, 'pageSize' => $pageSize, 'total' => $total,
            'totalPage' => (int) ceil($total / $pageSize), 'list' => $rows,
            'sort' => null, 'alert' => null, 'extraContent' => null];
    }

    /**
     * A drilled table (§12.4): the server sent the join as a condition and names the drill, whose linkCondition
     * the node adds.
     *
     * @return list<array{0: string, 1: list<mixed>}>
     */
    private function drill(array $body): array
    {
        $drill = $body['drill'] ?? null;
        if (!$drill) {
            return [];
        }
        $source = is_array($drill) && is_string($drill['erupt'] ?? null) ? ($this->models[$drill['erupt']][0] ?? null) : null;
        $code = is_array($drill) && is_string($drill['code'] ?? null) ? $drill['code'] : null;
        $condition = $code === null ? null : ($source?->drills[$code] ?? null);
        if ($condition === null) {
            throw new Reply(403);
        }
        return $condition === '' ? [] : [[$condition, []]];
    }

    /** @return list<Cond> */
    private function conditions(Model $model, array $c): array
    {
        // a name the node puts into a query is one of its stored fields, whoever sends it (§12.6)
        $key = $c['key'] ?? null;
        $f = is_string($key) ? ($model->fields[$key] ?? null) : null;
        if ($f === null) {
            throw new Fail("illegal search field '" . (is_scalar($key) ? $key : json_encode($key)) . "'");
        }
        $op = $c['expression'] ?? null;
        if (!in_array($op, self::OPS, true)) {
            // never skipped: a repository building no condition would answer every row
            throw new Fail("illegal operator '" . (is_scalar($op) ? $op : json_encode($op)) . "'");
        }
        $value = $c['value'] ?? null;
        if ($f->json !== null && in_array($op, ['EQ', 'IN', 'NEQ', 'NOT_IN'], true)) {
            // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
            $like = in_array($op, ['EQ', 'IN'], true) ? 'LIKE' : 'NOT_LIKE';
            $values = is_array($value) && array_is_list($value) ? $value : [$value];
            return array_map(fn($v) => new Cond($f->name, $like, json_encode(is_scalar($v) ? (string) $v : json_encode($v))), $values);
        }
        if ($op === 'NULL' || $op === 'NOT_NULL') {
            return [new Cond($f->name, $op)];
        }
        if ($op === 'LIKE' || $op === 'NOT_LIKE') {
            return [new Cond($f->name, $op, is_scalar($value) ? (string) $value : json_encode($value))];
        }
        try {
            // values arrive as the JSON type their field stores; dates become the repository's date text
            $stored = in_array($op, ['RANGE', 'IN', 'NOT_IN'], true)
                ? array_map([$f, 'coerce'], is_array($value) ? array_values($value) : [$value])
                : $f->coerce($value);
        } catch (\InvalidArgumentException $e) {
            throw new Fail("{$f->decl->title}: {$e->getMessage()}");
        }
        return [new Cond($f->name, $op, $stored)];
    }

    private function initValue(Model $model, Repository $repo, Request $request): array
    {
        $record = array_fill_keys(array_keys($model->fields), null);
        $model->hook('addBehavior', $record);
        return $this->rows($model, [$record])[0];
    }

    private function get(Model $model, Repository $repo, Request $request, string $pk): array
    {
        $record = $repo->get(self::pk($model, $pk)) ?? throw new Fail('record not found');
        $model->hook('editBehavior', $record);
        return $this->rows($model, [$record])[0];
    }

    private function add(Model $model, Repository $repo, Request $request): array
    {
        $record = self::record($model, $request->object());
        $model->hook('validate', $record);
        $model->hook('beforeAdd', $record);
        $repo->add($record);
        $model->hook('afterAdd', $record);
        return self::r();
    }

    private function update(Model $model, Repository $repo, Request $request): array
    {
        $body = $request->object();
        $pk = self::pk($model, $body[$model->pk] ?? null);
        if ($repo->get($pk) === null) {
            throw new Fail('record not found');
        }
        $record = self::record($model, $body);
        $model->hook('validate', $record);
        $model->hook('beforeUpdate', $record);
        $repo->update($pk, $record);
        $model->hook('afterUpdate', $record);
        return self::r();
    }

    private function delete(Model $model, Repository $repo, Request $request): array
    {
        $body = $request->json();
        if (!is_array($body) || !array_is_list($body)) {
            throw new Fail('a list of ids is required');
        }
        $pks = array_map(fn($pk) => self::pk($model, $pk), $body);
        // the hooks see each record as it was; reading them costs nothing without a proxy
        $records = $model->proxies ? array_values(array_filter(array_map([$repo, 'get'], $pks), fn($r) => $r !== null)) : [];
        foreach ($records as &$record) {
            $model->hook('beforeDelete', $record);
        }
        $repo->delete($pks);
        foreach ($records as &$record) {
            $model->hook('afterDelete', $record);
        }
        return self::r();
    }

    /**
     * The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
     * operation code, or a field's fetched options, onchange, auto-complete or button with the form's values.
     */
    private function invoke(Model $model, Repository $repo, Request $request, string $kind, string $field): array
    {
        if ($kind === 'operation') {
            return $this->operation($model, $repo, $request, $field);
        }
        if ($kind === 'operation-form') {
            return self::r(data: $this->operationFormValue($model, $field));
        }
        $f = current(array_filter($model->declared, fn(FieldSpec $f) => $f->name === $field)) ?: null;
        $fn = $f?->code[$kind] ?? throw new Reply(404);
        $body = $request->object();
        $form = is_array($body['form'] ?? null) ? $body['form'] : [];
        if ($kind === 'autocomplete') {
            return self::r(data: array_values($fn($form, is_scalar($body['value'] ?? null) ? (string) $body['value'] : '')));
        }
        $answer = $fn($form);
        if ($kind === 'options') {
            // value => label, as the choices of a field; a TAGS answers its list of tags
            $answer = $f->type === 'TAGS' ? array_values($answer)
                : array_map(fn($v, $label) => ['value' => (string) $v, 'label' => $label], array_keys($answer), $answer);
        }
        return self::r(data: $answer);
    }

    /**
     * Records to browser rows. A reference stays its key: the server resolves its label, the flattened
     * <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
     */
    private function rows(Model $model, array $records): array
    {
        $rows = [];
        foreach ($records as $record) {
            $row = [];
            foreach ($model->fields as $name => $f) {
                $row[$name] = $f->toJson($record[$name] ?? null);
            }
            $rows[] = $row;
        }
        return $rows;
    }

    private function operationOf(Model $model, string $code): OperationSpec
    {
        $op = $model->operations[$code] ?? throw new Reply(404);
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        if (!$op->visible(self::$user)) {
            throw new Reply(403);
        }
        return $op;
    }

    private function operationFormValue(Model $model, string $code): ?array
    {
        // none without a form: the server answers the browser a 404, and it opens an empty one
        $form = $this->operationOf($model, $code)->formModel();
        return $form ? array_fill_keys(array_keys($form->fields), null) : null;
    }

    private function operation(Model $model, Repository $repo, Request $request, string $code): array
    {
        $op = $this->operationOf($model, $code);
        $body = $request->object();
        $param = null;
        if ($form = $op->formModel()) {
            $param = self::record($form, is_array($body['param'] ?? null) ? $body['param'] : []);
        }
        $rows = [];
        if ($op->decl->mode !== 'BUTTON') {
            $ids = $body['ids'] ?? null;
            if (!is_array($ids) || !array_is_list($ids) || !$ids) {
                throw new Fail('select at least one row');
            }
            if ($op->decl->mode === 'SINGLE' && count($ids) !== 1) {
                throw new Fail('select exactly one row');
            }
            foreach ($ids as $pk) {
                $rows[] = $repo->get(self::pk($model, $pk)) ?? throw new Fail("record '" . (is_scalar($pk) ? $pk : '') . "' not found");
            }
        }
        $result = $op->run(new OperationContext($rows, $param, $repo, $model, self::$user));
        return is_string($result) && $result !== '' ? self::r(true, null, $result) : self::r(true, 'Executed successfully');
    }

    private static function pk(Model $model, mixed $value): int|string
    {
        try {
            return $model->fields[$model->pk]->coerce($value) ?? throw new \InvalidArgumentException();
        } catch (\InvalidArgumentException) {
            throw new Fail("illegal id '" . (is_scalar($value) ? $value : json_encode($value)) . "'");
        }
    }

    /** A record the server checked and normalized (§12.4), as the repository stores it. */
    private static function record(Model $model, array $body): array
    {
        $record = [];
        foreach ($model->fields as $name => $f) {
            if ($f->isPk() || !$f->decl->form) {
                continue;
            }
            try {
                $record[$name] = $f->coerce($body[$name] ?? null);
            } catch (\InvalidArgumentException $e) {
                throw new Fail("{$f->decl->title}: {$e->getMessage()}");
            }
        }
        return $record;
    }

    private static function r(bool $success = true, ?string $message = null, mixed $data = null): array
    {
        return ['success' => $success, 'status' => $success ? 'SUCCESS' : 'ERROR', 'message' => $message, 'data' => $data, 'promptWay' => 'MESSAGE'];
    }

    // ---------------------------------------------------------------- server calls

    /** The config text set for this node on the erupt server (Node Config). */
    public function config(): string
    {
        return $this->serverText('/erupt-cloud-api/node-config/' . rawurlencode($this->name), ['Access-Token' => $this->accessToken]);
    }

    /** The config text of this node's group on the erupt server. */
    public function groupConfig(): string
    {
        return $this->serverText('/erupt-cloud-api/node-group-config/' . rawurlencode($this->name), ['Access-Token' => $this->accessToken]);
    }

    /** The acting user's full info from the erupt server (roles, org, post...), for the request being served. */
    public function userInfo(): ?array
    {
        $text = $this->serverText('/erupt-cloud-api/userinfo/' . rawurlencode($this->name), ['Access-Token' => $this->accessToken, 'token' => self::$token ?? '']);
        $info = $text === '' ? null : json_decode($text, true, 512, JSON_THROW_ON_ERROR);
        return is_array($info) ? $info : null;
    }

    private function serverText(string $path, array $headers): string
    {
        [$status, $body] = Http::request('GET', $this->server() . $path, $headers);
        if ($status !== 200) {
            throw new \RuntimeException("$path answered $status");
        }
        return $body;
    }

    // ---------------------------------------------------------------- registration

    private function server(): string
    {
        return $this->servers[$this->nextServer++ % count($this->servers)];
    }

    /** The address the server should call this node on; auto-detected from $port when not configured. */
    public function address(?int $port = null): string
    {
        if ($this->address === null) {
            if ($port === null) {
                throw new \InvalidArgumentException('pass the port, or configure the node address');
            }
            $this->address = self::nodeAddress(self::localIp($this->servers[0]), $port);
        }
        return rtrim($this->address, '/');
    }

    /** `http://ip:port`, with an IPv6 address in brackets as a URL requires. */
    public static function nodeAddress(string $ip, int $port): string
    {
        return 'http://' . (str_contains($ip, ':') ? "[$ip]" : $ip) . ":$port";
    }

    /** The interface address the server would see us on, preferring IPv4 ("localhost" may resolve to ::1 first). */
    public static function localIp(string $server): string
    {
        $host = trim((string) (parse_url($server, PHP_URL_HOST) ?: '127.0.0.1'), '[]');
        $targets = filter_var($host, FILTER_VALIDATE_IP) ? [$host] : (gethostbynamel($host) ?: []);
        usort($targets, fn($a, $b) => (int) str_contains($a, ':') <=> (int) str_contains($b, ':'));
        foreach ($targets as $ip) {
            $socket = @stream_socket_client('udp://' . (str_contains($ip, ':') ? "[$ip]" : $ip) . ':80', $errno, $error, 1);
            if ($socket === false) {
                continue;
            }
            $name = (string) stream_socket_get_name($socket, false);
            fclose($socket);
            $local = trim(substr($name, 0, (int) strrpos($name, ':')), '[]');
            if (filter_var($local, FILTER_VALIDATE_IP)) {
                return $local;
            }
        }
        return '127.0.0.1';
    }

    /**
     * One registration call; the server probes /node-health first, so the HTTP side must already be up. A server
     * that does not answer `{"protocolVersion": 2}` is older than this node: it would call it as v1, which it no
     * longer answers, so registering stops for good (stop(), and stopped() turns true) instead of falling back (§12.2).
     */
    public function registerOnce(?int $port = null): bool
    {
        $server = $this->server();
        $info = ['instanceId' => $this->instanceId, 'nodeName' => $this->name, 'accessToken' => $this->accessToken,
            'version' => 'php-' . self::VERSION, 'protocolVersion' => self::PROTOCOL_VERSION, 'nodeAddress' => [$this->address($port)],
            'eruptModules' => [], 'erupts' => array_keys($this->models), 'resources' => new \stdClass(), 'capabilities' => ['invoke']];
        try {
            [$status, $answer] = Http::request('POST', "$server/erupt-cloud-api/register-node", ['Content-Type' => 'application/json'], Json::encode($info), 10);
            if ($status < 200 || $status >= 300) {
                error_log("$server -> register failed: HTTP $status");
                return false;
            }
            if (!self::speaksV2($answer)) {
                error_log("$server does not speak node protocol v" . self::PROTOCOL_VERSION . ': upgrade the erupt server; registration stopped');
                $this->stop();
                return false;
            }
            return true;
        } catch (\Throwable $e) {
            error_log("$server -> register failed: {$e->getMessage()}");
        }
        return false;
    }

    /** Whether a register answer comes from a server that speaks this node's protocol (§12.2). */
    private static function speaksV2(string $answer): bool
    {
        $reply = json_decode($answer, true);
        return is_array($reply) && ($reply['protocolVersion'] ?? null) === self::PROTOCOL_VERSION;
    }

    /**
     * Register every heartbeat until SIGINT / SIGTERM (or stop(), or a server too old for protocol v2), then
     * deregister. Run it as a long-lived CLI process next to php-fpm / `php -S`; without ext-pcntl a signal ends
     * the process without deregistering.
     */
    public function heartbeat(?int $port = null): void
    {
        $address = $this->address($port);
        if (function_exists('pcntl_async_signals')) {
            pcntl_async_signals(true);
            pcntl_signal(SIGINT, fn() => $this->stop());
            pcntl_signal(SIGTERM, fn() => $this->stop());
        }
        error_log("erupt node '$this->name' at $address -> " . implode(', ', $this->servers));
        $failing = false;
        while (!$this->stopping) {
            $ok = $this->registerOnce();
            if ($ok && $failing) {
                error_log('erupt: connection success');
            }
            $failing = !$ok;
            $until = microtime(true) + ($ok ? $this->heartbeatSeconds : $this->heartbeatSeconds / 2);
            while (!$this->stopping && microtime(true) < $until) {
                usleep(100000);
            }
        }
        $this->deregister();
    }

    public function stop(): void
    {
        $this->stopping = true;
    }

    /** Whether registering has stopped: stop() was called, or a server answered that it is too old (§12.2). */
    public function stopped(): bool
    {
        return $this->stopping;
    }

    /** Tell the server this instance is gone, so it stops routing to it at once. */
    public function deregister(): void
    {
        try {
            Http::request('POST', $this->server() . '/erupt-cloud-api/remove-instance-node', ['Content-Type' => 'application/x-www-form-urlencoded'],
                http_build_query(['nodeName' => $this->name, 'accessToken' => $this->accessToken, 'locations' => $this->address]));
        } catch (\Throwable $e) {
            error_log("deregister failed: {$e->getMessage()}");
        }
    }
}
