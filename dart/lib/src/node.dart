import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'model.dart';
import 'repository.dart';
import 'signature.dart';
import 'types.g.dart';

/// The version reported to the server.
const version = '0.1.0';

const _userKey = #eruptUser;

/// The acting user of the request being served.
User? currentUser() => Zone.current[_userKey] as User?;

// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
const _unsupportedPower = {'print': false, 'ai': false};

// Rights the server decides per user; the node ANDs them onto the declared power
const _serverPower = ['add', 'edit', 'delete', 'viewDetails', 'export', 'importable'];

const _maxPageSize = 1000;
const _maxBody = 16 << 20;
const _powerTtl = Duration(seconds: 5);

/// A request as the node reads it, from any HTTP server: [target] is the raw path below the node's mount
/// point plus the query, exactly as the erupt server signed it.
class NodeRequest {
  NodeRequest(this.method, this.target, this.header, this.body);

  final String method;
  final String target;

  /// A header value by lower-case name.
  final String? Function(String name) header;
  final List<int> body;

  String get path => target.split('?').first;

  String get query => target.contains('?') ? target.substring(target.indexOf('?') + 1) : '';
}

class NodeResponse {
  const NodeResponse(this.status, this.contentType, this.body);

  final int status;
  final String contentType;
  final List<int> body;
}

/// Answered with a bare status.
class _Reply implements Exception {
  const _Reply(this.status);

  final int status;
}

/// A business error shown to the user as an R message.
class _Fail implements Exception {
  const _Fail(this.message);

  final String message;
}

typedef _Handler = Future<Object?> Function(Model model, Repository repo, _Call call, List<String> args);

/// One request being served.
class _Call {
  _Call(this.request);

  final NodeRequest request;

  /// Checks the server ran before forwarding, trusted only under a valid signature.
  Set<String> enforced = const {};

  String? header(String name) => request.header(name);

  Object? json() {
    if (request.body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(request.body));
    } on FormatException {
      throw const _Fail('malformed JSON body');
    }
  }

  Map<String, dynamic> object() => switch (json()) { final Map<String, dynamic> map => map, _ => {} };
}

/// Logs a line; [level] is `info`, `warn` or `error`.
typedef NodeLogger = void Function(String level, String message);

void _stderrLog(String level, String message) => stderr.writeln('[erupt] ${level.toUpperCase()} $message');

/// Erupt cloud node runtime: registers with the server, then answers the requests it forwards. The wire
/// contract is erupt-cloud/PROTOCOL.md in the erupt repository.
///
/// [serve] runs a dart:io server of its own; to mount the node in an existing one, route the node's paths
/// (`/erupt-api/*`, `/node-health`) to [handleHttp] (dart:io) or [handle] (anything else, such as shelf), then
/// call [start] once it listens and [stop] on the way out.
class Node {
  /// [address] is what the server calls back (default `http://<interface ip>:<port>`); [requireSignature]
  /// refuses server calls without a valid Erupt-Signature, so the plain access token alone no longer passes
  /// (servers sign since erupt 2.3.x).
  Node(this.name, this._accessToken, List<String> servers,
      {String? address,
      this.heartbeat = const Duration(seconds: 15),
      this.requireSignature = false,
      NodeLogger? logger})
      : servers = [for (final s in servers) s.replaceAll(RegExp(r'/+$'), '')],
        address = address?.replaceAll(RegExp(r'/+$'), ''),
        _log = logger ?? _stderrLog {
    if (_accessToken.isEmpty) throw ArgumentError('accessToken is required');
    if (this.servers.isEmpty) throw ArgumentError('at least one erupt server is required');
  }

  final String name;
  final String _accessToken;
  final List<String> servers;
  final Duration heartbeat;
  final bool requireSignature;
  final NodeLogger _log;
  String? address;

  final models = <String, (Model, Repository)>{};
  final _powerCache = <String, (DateTime, Power)>{};
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  late final _instanceId =
      List.generate(3, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  var _tick = 0;
  Timer? _timer;
  var _running = false;

  late final List<(String, RegExp, _Handler)> _routes = [
    ('GET', RegExp(r'^/erupt-api/build/([^/]+)$'), _build),
    ('GET', RegExp(r'^/erupt-api/build/([^/]+)/([^/]+)$'), _buildByField),
    ('POST', RegExp(r'^/erupt-api/data/table/([^/]+)$'), _table),
    ('POST', RegExp(r'^/erupt-api/data/([^/]+)/reference-table/([^/]+)$'), _referenceTable),
    ('POST', RegExp(r'^/erupt-api/data/([^/]+)/operator/([^/]+)/form-value$'), _operationFormValue),
    ('POST', RegExp(r'^/erupt-api/data/([^/]+)/operator/([^/]+)$'), _operation),
    ('GET', RegExp(r'^/erupt-api/data/init-value/([^/]+)$'), _initValue),
    ('GET', RegExp(r'^/erupt-api/data/([^/]+)/([^/]+)$'), _get),
    ('POST', RegExp(r'^/erupt-api/data/modify/([^/]+)$'), _add),
    ('POST', RegExp(r'^/erupt-api/data/modify/([^/]+)/update$'), _update),
    ('POST', RegExp(r'^/erupt-api/data/modify/([^/]+)/delete$'), _delete),
  ];

  Node register(Model model, Repository repository) {
    if (models.containsKey(model.name)) throw ArgumentError("erupt '${model.name}' registered twice");
    if (model.pk == null) throw ArgumentError('${model.name} has no Field.pk(); only an operation form may omit it');
    repository.bind(model);
    models[model.name] = (model, repository);
    return this;
  }

  // ---------------------------------------------------------------- HTTP

  /// Answers one request.
  Future<NodeResponse> handle(NodeRequest request) async {
    int status;
    Object? body;
    try {
      (status, body) = await _dispatch(_Call(request));
    } on _Reply catch (e) {
      (status, body) = (e.status, '');
    } on _Fail catch (e) {
      (status, body) = (200, _r(success: false, message: e.message));
    } catch (e, stack) {
      // never leak internals: message only, the stack stays in the node log
      _log('error', 'erupt node error: $e\n$stack');
      final message = e is ArgumentError ? '${e.message}' : (e is FormatException ? e.message : '$e');
      (status, body) = (500, {'path': request.path, 'status': 500, 'error': 'erupt exception', 'message': message});
    }
    return body is String
        ? NodeResponse(status, 'text/plain; charset=utf-8', utf8.encode(body))
        : NodeResponse(status, 'application/json; charset=utf-8', utf8.encode(jsonEncode(body)));
  }

  /// Answers a dart:io request whose path is the node's own (not below a mount point).
  Future<void> handleHttp(HttpRequest request) async {
    final response = request.response;
    try {
      final body = BytesBuilder(copy: false);
      await for (final chunk in request) {
        body.add(chunk);
        if (body.length > _maxBody) throw const _Reply(413);
      }
      // dart:io keeps no raw request target; the parsed URI gives back what the server signed for the
      // encodings it uses (unreserved characters plain, upper-case escapes)
      final uri = request.uri;
      final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
      final r = await handle(NodeRequest(request.method, target, (n) => request.headers[n]?.first, body.takeBytes()));
      response
        ..statusCode = r.status
        ..headers.contentType = ContentType.parse(r.contentType)
        ..contentLength = r.body.length
        ..add(r.body);
    } on _Reply catch (e) {
      response.statusCode = e.status;
    }
    await response.close();
  }

  Future<(int, Object?)> _dispatch(_Call call) async {
    final path = call.request.path;
    if (path == '/node-health') return (200, name);
    if (!path.startsWith('/erupt-api/')) throw const _Reply(404);
    // server-to-server only: an Origin header means a browser reached the node directly
    if ((call.header('origin') ?? '').isNotEmpty) throw const _Reply(403);
    _authenticate(call);
    for (final (verb, pattern, handler) in _routes) {
      final match = pattern.firstMatch(path);
      if (verb != call.request.method || match == null) continue;
      final List<String> groups;
      try {
        groups = [for (var i = 1; i <= match.groupCount; i++) Uri.decodeComponent(match[i]!)];
      } catch (_) {
        throw const _Reply(404); // a malformed escape
      }
      final entry = models[groups.first];
      if (call.header('erupt') != groups.first || entry == null) throw const _Reply(404);
      final parent = call.header('eruptparent') ?? Uri.splitQueryString(call.request.query)['_eruptParent'];
      // nesting is not supported yet, so a parent can only vouch for itself
      if (parent != null && parent.isNotEmpty && parent.split('.').last != groups.first) throw const _Reply(404);
      final user = call.header('user');
      final acting = user == null || user.isEmpty
          ? null
          : User.fromJson(jsonDecode(utf8.decode(base64.decode(user))) as Map<String, dynamic>);
      final result =
          await runZoned(() => handler(entry.$1, entry.$2, call, groups.sublist(1)), zoneValues: {_userKey: acting});
      return (200, result);
    }
    throw const _Reply(404);
  }

  /// A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then.
  void _authenticate(_Call call) {
    final signature = call.header('erupt-signature');
    if (signature == null) {
      if (requireSignature || !sameSecret(call.header('access-token') ?? '', _accessToken)) throw const _Reply(403);
      return;
    }
    final multipart = (call.header('content-type') ?? '').contains('multipart/form-data');
    final enforced = call.header('erupt-enforced');
    final ok = Signature.verify(
        _accessToken,
        call.request.method,
        call.request.target,
        call.header('erupt-timestamp'),
        enforced,
        call.header('user'),
        multipart ? null : call.request.body,
        signature,
        DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (!ok) throw const _Reply(403);
    call.enforced = {
      for (final e in (enforced ?? '').split(','))
        if (e.isNotEmpty) e
    };
  }

  // ---------------------------------------------------------------- endpoints

  Future<Object?> _build(Model model, Repository repo, _Call call, List<String> args) async =>
      model.buildModel(await _power(model, call), currentUser());

  // the reference picker: build of the referenced model, requested under the host model's name
  Future<Object?> _buildByField(Model model, Repository repo, _Call call, List<String> args) async {
    final target = _referenceField(model, args[0]).target;
    return target.buildModel(await _power(target, call), currentUser());
  }

  Future<Object?> _table(Model model, Repository repo, _Call call, List<String> args) async {
    await _require(model, call, 'query');
    return _page(model, repo, call.object());
  }

  Future<Object?> _referenceTable(Model model, Repository repo, _Call call, List<String> args) async {
    final target = _referenceField(model, args[0], 'REFERENCE_TABLE').target;
    final entry = models[target.name];
    if (entry == null || !identical(entry.$1, target)) {
      throw StateError("referenced erupt '${target.name}' is not registered on this node");
    }
    return _page(target, entry.$2, call.object());
  }

  Field _referenceField(Model model, String field, [String? editType]) {
    final f = model.fields[field];
    if (f == null || !f.isReference || (editType != null && f.type != editType)) throw const _Reply(404);
    return f;
  }

  Future<Object?> _page(Model model, Repository repo, Map<String, dynamic> body) async {
    final pageIndex = max(_int(body['pageIndex'] ?? 1), 1);
    final pageSize = _int(body['pageSize'] ?? 10).clamp(1, _maxPageSize);
    final query = Query(offset: (pageIndex - 1) * pageSize, limit: pageSize);
    for (final c in _list(body['condition'])) {
      query.conditions.addAll(_conditions(model, c));
    }
    for (final s in _list(body['sort'])) {
      final f = s is Map ? model.fields[s['field']] : null;
      if (f == null || !(f.sortable || f.pk)) throw _Fail("illegal sort field '${s is Map ? s['field'] : s}'");
      query.sort.add((f.name, '${(s as Map)['direction']}'.toUpperCase() == 'DESC'));
    }
    if (query.sort.isEmpty) query.sort = [...model.order];
    final (total, records) = await repo.page(query);
    return {
      'pageIndex': pageIndex,
      'pageSize': pageSize,
      'total': total,
      'totalPage': (total + pageSize - 1) ~/ pageSize,
      'list': _rows(model, records),
      'sort': null,
      'alert': null,
      'extraContent': null,
    };
  }

  Future<Object?> _initValue(Model model, Repository repo, _Call call, List<String> args) async {
    await _require(model, call, 'add');
    return {for (final name in model.fields.keys) name: null};
  }

  Future<Object?> _get(Model model, Repository repo, _Call call, List<String> args) async {
    final granted = await _power(model, call);
    if (granted['edit'] != true && granted['viewDetails'] != true) throw const _Reply(403);
    final record = await repo.get(_pk(model, args[0]));
    if (record == null) throw const _Fail('record not found');
    return _rows(model, [record]).first;
  }

  Future<Object?> _add(Model model, Repository repo, _Call call, List<String> args) async {
    await _require(model, call, 'add');
    await repo.add(_record(model, call.object()));
    return _r();
  }

  Future<Object?> _update(Model model, Repository repo, _Call call, List<String> args) async {
    await _require(model, call, 'edit');
    final body = call.object();
    final pk = _pk(model, body[model.pk]);
    if (await repo.get(pk) == null) throw const _Fail('record not found');
    await repo.update(pk, _record(model, body));
    return _r();
  }

  Future<Object?> _delete(Model model, Repository repo, _Call call, List<String> args) async {
    await _require(model, call, 'delete');
    final ids = call.json();
    if (ids is! List) throw const _Fail('a list of ids is required');
    await repo.delete([for (final id in ids) _pk(model, id)]);
    return _r();
  }

  /// Records to browser rows. A reference stays its key: the server resolves its label, the flattened
  /// `<field>_<label>` column and the tree (erupt-cloud/PROTOCOL.md §7.3).
  List<Map<String, Object?>> _rows(Model model, List<EruptRecord> records) => [
        for (final record in records) {for (final f in model.fields.values) f.name: f.toJsonValue(record[f.name])},
      ];

  Operation _operationOf(Model model, String code) {
    final op = model.operations[code];
    if (op == null) throw const _Reply(404);
    // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
    if (!op.visible(currentUser())) throw const _Reply(403);
    return op;
  }

  Future<Object?> _operationFormValue(Model model, Repository repo, _Call call, List<String> args) async {
    final form = _operationOf(model, args[0]).form;
    if (form == null) throw const _Reply(404); // the browser ignores a 404 here and opens an empty form
    return {for (final name in form.fields.keys) name: null};
  }

  Future<Object?> _operation(Model model, Repository repo, _Call call, List<String> args) async {
    final op = _operationOf(model, args[0]);
    final body = call.object();
    final param = op.form == null
        ? null
        : _record(op.form!, switch (body['param']) { final Map<String, dynamic> p => p, _ => {} });
    final rows = <EruptRecord>[];
    if (op.mode != RowOperationMode.BUTTON) {
      final ids = body['ids'];
      if (ids is! List || ids.isEmpty) throw const _Fail('select at least one row');
      if (op.mode == RowOperationMode.SINGLE && ids.length != 1) throw const _Fail('select exactly one row');
      for (final id in ids) {
        rows.add(await repo.get(_pk(model, id)) ?? (throw _Fail("record '$id' not found")));
      }
    }
    // a handler is typed to return void, so a plain block needs no return; a script string still comes back
    final Object? result = await (op.handler
        as dynamic)(OperationContext(rows: rows, param: param, repo: repo, model: model, user: currentUser()));
    return result is String && result.isNotEmpty ? _r(data: result) : _r(message: 'Executed successfully');
  }

  Map<String, Object?> _r({bool success = true, String? message, Object? data}) => {
        'success': success,
        'status': success ? 'SUCCESS' : 'ERROR',
        'message': message,
        'data': data,
        'promptWay': 'MESSAGE'
      };

  // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

  Future<void> _require(Model model, _Call call, String right) async {
    if ((await _power(model, call))[right] != true) throw const _Reply(403);
  }

  Future<Power> _power(Model model, _Call call) async {
    final granted = {...model.power, ..._unsupportedPower};
    // the server checked the user's rights and restricts the build's power itself: the model's own
    // declaration is all that is left to apply here
    if (call.enforced.contains('power')) return granted;
    final token = call.header('token') ?? '';
    final key = '$token\u0000${model.name}';
    final cached = _powerCache[key];
    if (cached != null && cached.$1.isAfter(DateTime.now())) return cached.$2;
    var remote = <String, dynamic>{};
    try {
      final answer = await _serverCall('GET', _nextServer(), '/erupt-cloud-api/erupt-power',
          query: {'nodeName': name, 'eruptName': model.name}, headers: {'token': token});
      if (answer is Map<String, dynamic>) remote = answer;
    } catch (e) {
      // fail closed: without the server's verdict nothing is writable
      _log('warn', 'erupt-power unavailable: $e');
    }
    for (final right in _serverPower) {
      granted[right] = granted[right] == true && remote[right] == true;
    }
    if (_powerCache.length > 10000) _powerCache.clear();
    _powerCache[key] = (DateTime.now().add(_powerTtl), granted);
    return granted;
  }

  // ---------------------------------------------------------------- server calls

  String _nextServer() => servers[_tick++ % servers.length];

  /// GET with a query, or POST a JSON / form body; throws unless the server answers 2xx. Returns the JSON
  /// answer, if any.
  Future<Object?> _serverCall(String method, String server, String path,
      {Map<String, String>? query,
      Object? json,
      Map<String, String>? form,
      Map<String, String> headers = const {},
      Duration timeout = const Duration(seconds: 5)}) async {
    final uri = Uri.parse(server + path).replace(queryParameters: query);
    Future<Object?> call() async {
      final request = await _client.openUrl(method, uri);
      headers.forEach(request.headers.set);
      final (type, payload) = json != null
          ? (ContentType.json, jsonEncode(json))
          : form != null
              ? (
                  ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8'),
                  Uri(queryParameters: form).query
                )
              : (null, null);
      if (payload != null) {
        // a sized body: dart:io would send it chunked, which not every server reads
        final bytes = utf8.encode(payload);
        request.headers.contentType = type;
        request
          ..contentLength = bytes.length
          ..add(bytes);
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('$path answered HTTP ${response.statusCode}', uri: uri);
      }
      return text.isEmpty ? null : jsonDecode(text);
    }

    return call().timeout(timeout);
  }

  Map<String, Object?> _nodeInfo() => {
        'instanceId': _instanceId,
        'nodeName': name,
        'accessToken': _accessToken,
        'version': 'dart-$version',
        'nodeAddress': [address],
        'eruptModules': <String>[],
        'erupts': models.keys.toList(),
        'resources': <String, Object?>{},
      };

  Future<void> _heartbeat(bool failing) async {
    if (!_running) return;
    final server = _nextServer();
    var next = heartbeat;
    try {
      await _serverCall('POST', server, '/erupt-cloud-api/register-node',
          json: _nodeInfo(), timeout: const Duration(seconds: 10));
      if (failing) _log('info', '$server -> connection success');
      failing = false;
    } catch (e) {
      failing = true;
      next = heartbeat ~/ 2;
      _log('error', '$server -> register failed: $e');
    }
    if (_running) _timer = Timer(next, () => _heartbeat(failing));
  }

  /// Starts registering (and the heartbeat) for a node served on [port]; call it once [address] answers
  /// `/node-health`, which the server probes while registering.
  Future<void> start(int port) async {
    address ??= 'http://${await _localIp(servers.first)}:$port';
    _running = true;
    _log('info', "erupt node '$name' at $address -> ${servers.join(', ')}");
    unawaited(_heartbeat(false));
  }

  /// Stops the heartbeat and tells the server this instance is gone.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    try {
      await _serverCall('POST', _nextServer(), '/erupt-cloud-api/remove-instance-node',
          form: {'nodeName': name, 'accessToken': _accessToken, 'locations': address ?? ''});
    } catch (e) {
      _log('error', 'deregister failed: $e');
    }
    _client.close(force: true);
  }

  /// Serves on [port] until SIGINT / SIGTERM: HTTP first (the server probes /node-health while registering),
  /// then the heartbeat; on a signal deregisters and closes.
  Future<HttpServer> serve({int port = 9090, Object host = '0.0.0.0'}) async {
    final server = await HttpServer.bind(host, port);
    server.listen(handleHttp);
    await start(server.port);
    final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm];
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    Future<void> shutdown(ProcessSignal _) async {
      for (final s in subscriptions) {
        await s.cancel();
      }
      await stop();
      await server.close(force: true);
    }

    subscriptions.addAll([for (final s in signals) s.watch().listen(shutdown)]);
    return server;
  }

  /// The interface address the server would see us on.
  static Future<String> _localIp(String server) async {
    try {
      final uri = Uri.parse(server);
      final socket = await Socket.connect(uri.host, uri.port, timeout: const Duration(seconds: 2));
      final ip = socket.address.address;
      socket.destroy();
      return ip;
    } catch (_) {
      return '127.0.0.1';
    }
  }
}

// ---------------------------------------------------------------- helpers

List<Object?> _list(Object? value) => value is List ? value : const [];

int _int(Object? value) => switch (value) {
      int() => value,
      num() => value.toInt(),
      String() when int.tryParse(value.trim()) != null => int.parse(value.trim()),
      _ => throw _Fail("illegal number '$value'"),
    };

Object _pk(Model model, Object? value) {
  try {
    return model.fields[model.pk]!.coerce(value) ?? (throw _Fail("illegal id '$value'"));
  } on FormatException {
    throw _Fail("illegal id '$value'");
  }
}

Object? _coerce(Field f, Object? value) {
  try {
    return f.coerce(value);
  } on FormatException catch (e) {
    throw _Fail(e.message);
  }
}

EruptRecord _record(Model model, Map<String, dynamic> body) => {
      for (final f in model.fields.values)
        if (!f.pk && f.form)
          f.name: switch (_coerceTitled(f, body[f.name])) {
            null when f.notNull => throw _Fail('${f.title} cannot be empty'),
            final value => value,
          },
    };

Object? _coerceTitled(Field f, Object? value) {
  try {
    return f.coerce(value);
  } on FormatException catch (e) {
    throw _Fail('${f.title}: ${e.message}');
  }
}

// what a JSON value or a reference can be searched with
const _keyMatch = {QueryExpression.EQ, QueryExpression.IN, QueryExpression.NEQ, QueryExpression.NOT_IN};

List<Cond> _conditions(Model model, Object? c) {
  final m = c is Map ? c : const {};
  final f = model.fields[m['key']];
  if (f == null || f.pk || !f.search) throw _Fail("illegal search field '${m['key']}'");
  final opName = '${m['expression'] ?? 'EQ'}';
  final op = QueryExpression.values.where((e) => e.name == opName && e != QueryExpression.AUTO).firstOrNull;
  if (op == null) throw _Fail("illegal operator '$opName'");
  final value = m['value'];
  if (!f.json) return [_condition(f, op, value)];
  // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
  if (!_keyMatch.contains(op)) throw _Fail("illegal operator '$opName' for ${f.title}");
  final like = op == QueryExpression.EQ || op == QueryExpression.IN ? QueryExpression.LIKE : QueryExpression.NOT_LIKE;
  return [
    for (final v in value is List ? value : [value]) Cond(f.name, like, jsonEncode('$v'))
  ];
}

Cond _condition(Field f, QueryExpression op, Object? value) {
  if (op == QueryExpression.NULL || op == QueryExpression.NOT_NULL) return Cond(f.name, op);
  if (f.isReference && !_keyMatch.contains(op)) throw _Fail("illegal operator '${op.name}' for a reference");
  return switch (op) {
    QueryExpression.LIKE || QueryExpression.NOT_LIKE => Cond(f.name, op, '$value'),
    QueryExpression.RANGE when value is List && value.length == 2 =>
      Cond(f.name, op, [for (final v in value) _coerce(f, v)]),
    QueryExpression.RANGE => throw const _Fail('range needs two values'),
    QueryExpression.IN || QueryExpression.NOT_IN => Cond(f.name, op, [
        for (final v in value is List ? value : [value]) _coerce(f, v)
      ]),
    _ => Cond(f.name, op, _coerce(f, value)),
  };
}
