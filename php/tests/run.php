<?php
/** Self-contained test runner: php tests/run.php */

namespace Erupt\Tests;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Cond;
use Erupt\FieldSpec;
use Erupt\MemoryRepository;
use Erupt\Model;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;
use Erupt\Query;
use Erupt\Schema;
use Erupt\Signature;

require __DIR__ . '/../autoload.php';
require_once __DIR__ . '/../tools/gen-types.php';

// ---------------------------------------------------------------- fixtures

#[Erupt('Tag')]
final class Tag
{
    #[Field(pk: true)] public int $id;
    #[Field('Name', search: true)] public string $name;
    #[Field('Parent')] public ?int $parent;
}

#[Erupt('Post', orderBy: 'id desc', raw: ['layout' => ['pageSize' => 30]])]
final class Post
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true, notNull: true, sortable: true, edit: ['inputType' => ['length' => 9]])] public string $title;
    #[Field('Views', search: true, sortable: true)] public int $views;
    #[Field('Live', search: true)] public bool $live;
    #[Field('Day', type: 'DATE', search: true)] public string $day;
    #[Field('At')] public \DateTimeImmutable $at;
    #[Field('Kind', choices: ['a' => 'A', 'b' => 'B'], search: true)] public string $kind;
    #[Field('Tag', search: true)] public ?Tag $tag;

    #[Operation('Touch', mode: 'SINGLE', confirm: 'Sure?')]
    public static function touch(OperationContext $op): string
    {
        return 'ok()';
    }
}

#[Erupt('Bad1')] final class BadEditKey { #[Field(pk: true)] public int $id; #[Field('T', edit: ['inputTyp' => ['length' => 9]])] public string $t; }
#[Erupt('Bad2')] final class BadViewType { #[Field(pk: true)] public int $id; #[Field('T', view: ['sortable' => 'yes'])] public string $t; }
#[Erupt('Bad3')] final class BadEditType { #[Field(pk: true)] public int $id; #[Field('T', type: 'INPUTT')] public string $t; }
#[Erupt('Bad4')] final class BadOperator { #[Field(pk: true)] public int $id; #[Field('T', edit: ['search' => ['operator' => 'ABOUT']])] public string $t; }
#[Erupt('Bad5', raw: ['orderBy' => 'id'])] final class BadRaw { #[Field(pk: true)] public int $id; }
#[Erupt('Bad6', raw: ['layout' => ['pageSize' => '10']])] final class BadRawType { #[Field(pk: true)] public int $id; }
#[Erupt('Bad7', orderBy: 'missing desc')] final class BadOrder { #[Field(pk: true)] public int $id; }
#[Erupt('Bad8', power: ['remove' => false])] final class BadPower { #[Field(pk: true)] public int $id; }
#[Erupt('Bad9')] final class BadMode { #[Field(pk: true)] public int $id; #[Operation('Go', mode: 'ALL')] public static function go(): void {} }
#[Erupt('Bad10')] final class BadOpRaw { #[Field(pk: true)] public int $id; #[Operation('Go', raw: ['colour' => 'red'])] public static function go(): void {} }
#[Erupt('Bad11')] final class BadOpStatic { #[Field(pk: true)] public int $id; #[Operation('Go')] public function go(): void {} }
#[Erupt('Bad12')] final class BadLabel { #[Field(pk: true)] public int $id; #[Field('Tag', label: 'title')] public ?Tag $tag; }
#[Erupt('Bad13')] final class TwoPks { #[Field(pk: true)] public int $id; #[Field(pk: true)] public int $id2; }

// ---------------------------------------------------------------- runner

$tests = [];
$test = function (string $name, callable $fn) use (&$tests) { $tests[$name] = $fn; };
function eq(mixed $expected, mixed $actual, string $what = ''): void
{
    if ($expected !== $actual) {
        throw new \RuntimeException("$what: expected " . json_encode($expected) . ', got ' . json_encode($actual));
    }
}
function throws(string $pattern, callable $fn, string $what = ''): void
{
    try {
        $fn();
    } catch (\InvalidArgumentException $e) {
        if (!preg_match($pattern, $e->getMessage())) {
            throw new \RuntimeException("$what: message '{$e->getMessage()}' does not match $pattern");
        }
        return;
    }
    throw new \RuntimeException("$what: nothing thrown");
}

// ---------------------------------------------------------------- tests

$test('declarations are checked against the schema', function () {
    $cases = [
        [BadEditKey::class, "/Edit has no attribute 'inputTyp'/"],
        [BadViewType::class, '/expected boolean/'],
        [BadEditType::class, '/is not a EditType/'],
        [BadOperator::class, '/is not a QueryExpression/'],
        [BadRaw::class, "/Erupt has no attribute 'orderBy'/"],
        [BadRawType::class, '/expected integer/'],
        [BadOrder::class, '/illegal orderBy/'],
        [BadPower::class, '/unknown power remove/'],
        [BadMode::class, '/is not a RowOperationMode/'],
        [BadOpRaw::class, "/RowOperation has no attribute 'colour'/"],
        [BadOpStatic::class, '/public static/'],
        [BadLabel::class, "/has no field 'title'/"],
        [TwoPks::class, '/at most one/'],
    ];
    foreach ($cases as [$class, $pattern]) {
        throws($pattern, fn() => Model::of($class), $class);
    }
});

$test('build follows the templates and the schema', function () {
    $build = Model::of(Post::class)->buildModel(Schema::defaults()['power'], null);
    $m = $build['eruptModel'];
    eq(30, $m['eruptJson']['layout']['pageSize'], 'raw erupt');
    eq('{}', json_encode($m['eruptJson']['extra']), 'empty objects stay objects');
    $fields = array_column($m['eruptFieldModels'], null, 'fieldName');
    eq(['NUMBER', 'INPUT', 'NUMBER', 'BOOLEAN', 'DATE', 'DATE', 'CHOICE', 'REFERENCE_TABLE'],
        array_map(fn($f) => $f['eruptFieldJson']['edit']['type'], array_values($fields)), 'types');
    eq('DATE_TIME', $fields['at']['eruptFieldJson']['edit']['dateType']['type'], 'DATE_TIME template');
    eq(9, $fields['title']['eruptFieldJson']['edit']['inputType']['length'], 'raw edit');
    eq('Tag', $fields['tag']['fieldReturnName'], 'reference return name');
    eq('Sure?', $m['eruptJson']['rowOperation'][0]['callHint'], 'confirm text');
    Schema::check('Erupt', $m['eruptJson'], 'Post', false);
    foreach ($m['eruptFieldModels'] as $f) {
        Schema::check('EruptField', $f['eruptFieldJson'], $f['fieldName'], false);
    }
});

$test('generated files are current', function () {
    $root = dirname(__DIR__);
    $schema = json_decode(file_get_contents("$root/resources/erupt-annotations.schema.json"), true);
    foreach (\generate($schema) as $file => $content) {
        eq($content, file_get_contents("$root/src/Types/$file"), $file);
    }
});

$test('values are coerced like the python SDK', function () {
    $f = Model::of(Post::class)->fields;
    eq('2026-01-05T10:30:00.000', $f['at']->coerce('2026-01-05 10:30:00'), 'datetime');
    eq('2026-01-05T10:30:00.123', $f['at']->coerce('2026-01-05T10:30:00.123Z'), 'datetime with T / Z');
    eq('2026-01-05', $f['day']->coerce('2026-01-05 10:30'), 'date from a datetime');
    eq(3, $f['views']->coerce('3'), 'integral number');
    eq(2.5, $f['views']->coerce(2.5), 'float');
    eq(true, $f['live']->coerce('true'), 'bool');
    eq(2, $f['tag']->coerce(['id' => '2', 'name' => 'x']), 'reference object');
    eq(null, $f['title']->coerce(''), 'empty');
    foreach ([['day', 'someday'], ['day', '2026-02-30'], ['views', 'many'], ['kind', 'c'], ['title', ['x']]] as [$name, $value]) {
        throws('/./', fn() => $f[$name]->coerce($value), "$name " . json_encode($value));
    }
});

$test('node address prefers IPv4 and brackets IPv6', function () {
    $ip = Node::localIp('http://localhost:18080');
    eq(true, filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false, "localhost resolved to $ip");
    eq('http://[::1]:9090', Node::nodeAddress('::1', 9090), 'IPv6 in brackets');
    eq('::1', trim(parse_url(Node::nodeAddress('::1', 9090), PHP_URL_HOST), '[]'), 'a valid URL');
    eq("http://$ip:9090", (new Node('n', 't', 'http://localhost:18080'))->address(9090), 'auto-detected address');
});

$repositories = function (): array {
    $pdo = new \PDO('sqlite::memory:');
    return ['memory' => new MemoryRepository(), 'pdo' => new PdoRepository($pdo, 'post')];
};

$test('repositories filter, sort and page alike', function () use ($repositories) {
    foreach ($repositories() as $kind => $repo) {
        $repo->bind(Model::of(Post::class));
        foreach ([['title' => '100% pure', 'views' => 3, 'live' => true, 'day' => '2026-01-01'],
                     ['title' => '100 points', 'views' => 1, 'live' => false, 'day' => '2026-03-01'],
                     ['title' => 'a_b', 'views' => null, 'live' => false, 'day' => null]] as $row) {
            $repo->add($row);
        }
        $titles = fn(array $conds, array $sort = []) => array_column($repo->page(new Query($conds, $sort, 0, 10))[1], 'title');
        eq(['100% pure'], $titles([new Cond('title', 'LIKE', '100%')]), "$kind LIKE escapes %");
        eq(['a_b'], $titles([new Cond('title', 'LIKE', '_')]), "$kind LIKE escapes _");
        eq([], $titles([new Cond('title', 'IN', [])]), "$kind empty IN");
        eq(['100 points'], $titles([new Cond('day', 'RANGE', ['2026-02-01', '2026-12-31'])]), "$kind RANGE");
        eq(['100% pure'], $titles([new Cond('live', 'EQ', true)]), "$kind bool");
        eq(['a_b'], $titles([new Cond('views', 'NULL')]), "$kind NULL");
        eq(['100 points', '100% pure', 'a_b'], $titles([], [['views', false]]), "$kind nulls last");
        eq(3, $repo->page(new Query([], [], 0, 1))[0], "$kind total");
        eq(['100% pure', '100 points', 'a_b'], $titles([]), "$kind default order is primary key ascending");
        $repo->update(1, ['title' => 'renamed']);
        eq('renamed', $repo->get(1)['title'], "$kind update");
        eq(true, $repo->get(1)['live'], "$kind bool round trip");
        $repo->delete([1, 2]);
        eq(['a_b'], $titles([]), "$kind delete");
    }
});

$test('PdoRepository leaves the error mode alone and still raises errors', function () {
    $pdo = new \PDO('sqlite::memory:');
    $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_SILENT);
    $repo = new PdoRepository($pdo, 'post', autoCreate: false);
    $repo->bind(Model::of(Post::class));
    eq(\PDO::ERRMODE_SILENT, $pdo->getAttribute(\PDO::ATTR_ERRMODE), 'error mode untouched');
    $failure = function (string $mode) use ($repo): string {
        try {
            $repo->get(1);
        } catch (\RuntimeException $e) {  // PDOException extends RuntimeException
            return $e->getMessage();
        }
        throw new \RuntimeException("missing table under $mode: nothing thrown");
    };
    eq(1, preg_match('/^database error HY000: no such table/', $failure('ERRMODE_SILENT')), 'raised under ERRMODE_SILENT');
    $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
    eq(1, preg_match('/no such table/', $failure('ERRMODE_EXCEPTION')), 'raised under ERRMODE_EXCEPTION');
});

$test('signature agrees with the Java vectors', function () {
    $doc = json_decode((string) file_get_contents(__DIR__ . '/../../conformance/signature-vectors.json'), true);
    foreach ($doc['vectors'] as $v) {
        eq($v['signature'], Signature::sign($doc['accessToken'], $v['method'], $v['pathAndQuery'], $v['timestamp'], $v['enforced'],
            $v['user'], $v['body']), $v['case']);
        eq(true, Signature::verify($doc['accessToken'], $v['method'], $v['pathAndQuery'], (string) $v['timestamp'], $v['enforced'],
            $v['user'], $v['body'], $v['signature'], $v['timestamp'] + 300), $v['case'] . ' inside the window');
        eq(false, Signature::verify($doc['accessToken'], $v['method'], $v['pathAndQuery'], (string) $v['timestamp'], $v['enforced'],
            $v['user'], $v['body'], $v['signature'], $v['timestamp'] + 301), $v['case'] . ' outside the window');
    }
});

$test('handle() serves the protocol', function () {
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr(strrchr(stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__ . '/fake-server.php'],
        [['file', '/dev/null', 'r'], ['file', '/dev/null', 'w'], ['file', '/dev/null', 'w']], $pipes);
    for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port, $errno, $error, 0.1); $i++) {
        usleep(100000);
    }
    try {
        $node = (new Node('n', 'secret', "http://127.0.0.1:$port", 'http://127.0.0.1:1'))
            ->register(Tag::class, new MemoryRepository([['name' => 'Tech'], ['name' => 'Php', 'parent' => 1]]))
            ->register(Post::class, new MemoryRepository());
        $call = function (string $method, string $path, mixed $body = null, array $headers = []) use ($node) {
            $r = $node->handle($method, $path, $headers + ['Access-Token' => 'secret', 'erupt' => 'Post', 'token' => 't1'],
                $body === null ? '' : json_encode($body));
            return [$r->status, json_decode($r->body, true) ?? $r->body];
        };
        eq([200, 'n'], $call('GET', '/node-health'), 'health');
        eq(403, $call('GET', '/erupt-api/build/Post', null, ['Origin' => 'x'])[0], 'origin');
        eq(403, $call('GET', '/erupt-api/build/Post', null, ['Access-Token' => 'nope'])[0], 'token');
        eq(403, $call('POST', '/erupt-api/data/modify/Post', ['title' => 'x'], ['token' => 'down'])[0], 'fails closed');
        eq(true, $call('POST', '/erupt-api/data/modify/Post', ['title' => 'Hello', 'views' => '4', 'tag' => ['id' => 2, 'name' => 'Php'],
            'at' => '2026-01-05 10:30:00'])[1]['success'], 'add');
        [$status, $page] = $call('POST', '/erupt-api/data/table/Post', ['pageIndex' => 1, 'pageSize' => 10]);
        $row = $page['list'][0];
        // a reference travels as its key: the server resolves the label and the flattened column
        eq([200, 4, 2, '2026-01-05T10:30:00.000'], [$status, $row['views'], $row['tag'], $row['at']], 'row');
        eq(false, array_key_exists('tag_name', $row), 'no flattened reference column');
        eq(false, $call('POST', '/erupt-api/data/Post/operator/touch', ['ids' => [1, 2]])[1]['success'], 'SINGLE takes one row');
        eq('ok()', $call('POST', '/erupt-api/data/Post/operator/touch', ['ids' => [1]])[1]['data'], 'script');
        $malformed = $node->handle('POST', '/erupt-api/data/modify/Post', ['Access-Token' => 'secret', 'erupt' => 'Post', 'token' => 't1'], '{x');
        eq([200, 'malformed JSON body'], [$malformed->status, json_decode($malformed->body, true)['message']], 'malformed body');
        eq(404, $call('POST', '/erupt-api/data/Post/operator/missing', [])[0], 'unknown operation');
        eq(404, $call('GET', '/erupt-api/data/Post/reference-tree/tag')[0], 'reference-tree is the server\'s');
        eq(['Tech', 'Php'], array_column($call('POST', '/erupt-api/data/Post/reference-table/tag', [])[1]['list'], 'name'), 'picker');
        // signed calls: no token needed; Erupt-Enforced: power skips the (failing) erupt-power callback
        $signed = function (string $method, string $target, mixed $body, ?string $enforced, array $over = []) use ($node) {
            $raw = $body === null ? '' : json_encode($body);
            $ts = time();
            $headers = ['erupt' => 'Post', 'token' => 'down', 'user' => 'dXNlcg==', 'Erupt-Timestamp' => (string) $ts]
                + ($enforced === null ? [] : ['Erupt-Enforced' => $enforced]);
            $headers['Erupt-Signature'] = Signature::sign('secret', $method, $target, $ts, $enforced, 'dXNlcg==', $raw);
            $path = (string) parse_url($target, PHP_URL_PATH);
            return $node->handle($method, $path, $over + $headers, $raw, [], $target)->status;
        };
        eq(200, $signed('GET', '/erupt-api/build/Post?_probe=1', null, null), 'signed, no token');
        eq(200, $signed('POST', '/erupt-api/data/modify/Post', ['title' => 'Signed'], 'power,record'), 'enforced power: no callback');
        eq(403, $signed('POST', '/erupt-api/data/modify/Post', ['title' => 'Signed'], null), 'signed without power: fails closed');
        eq(403, $signed('GET', '/erupt-api/build/Post', null, null, ['Erupt-Signature' => str_repeat('0', 64)]), 'wrong signature');
        eq(403, $signed('GET', '/erupt-api/build/Post', null, null, ['Erupt-Enforced' => 'power']), 'enforced added after signing');
        eq(403, $call('POST', '/erupt-api/data/modify/Post', ['title' => 'x'], ['token' => 'down', 'Erupt-Enforced' => 'power'])[0],
            'unsigned Erupt-Enforced ignored');
        $strict = (new Node('n', 'secret', "http://127.0.0.1:$port", 'http://127.0.0.1:1', requireSignature: true))
            ->register(Tag::class, new MemoryRepository())->register(Post::class, new MemoryRepository());
        eq(403, $strict->handle('GET', '/erupt-api/build/Post', ['Access-Token' => 'secret', 'erupt' => 'Post'])->status, 'requireSignature');
    } finally {
        proc_terminate($server);
        proc_close($server);
    }
});

$failed = 0;
foreach ($tests as $name => $fn) {
    try {
        $fn();
        echo "  ok    $name\n";
    } catch (\Throwable $e) {
        $failed++;
        echo "  FAIL  $name: {$e->getMessage()}\n";
    }
}
echo (count($tests) - $failed) . '/' . count($tests) . " passed\n";
exit($failed ? 1 : 0);
