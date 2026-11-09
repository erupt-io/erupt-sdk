<?php
/** Self-contained test runner: php tests/run.php */

namespace Erupt\Tests;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Cond;
use Erupt\DataProxy;
use Erupt\Fail;
use Erupt\FieldSpec;
use Erupt\Json;
use Erupt\MemoryRepository;
use Erupt\Model;
use Erupt\Node;
use Erupt\OperationContext;
use Erupt\PdoRepository;
use Erupt\Query;
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

#[Erupt('Widget')]
final class Widget
{
    #[Field(pk: true)] public int $id;
    #[Field('Name')] public string $name;
    #[Field('Basic', edit: ['type' => 'DIVIDE'], virtual: true)] public ?string $basic;
    #[Field('Roles', search: true, choices: ['ADMIN' => 'Admin', 'USER' => 'User', 'GUEST' => 'Guest'], edit: ['type' => 'MULTI_CHOICE'])]
    public array $roles;
    #[Field('Attributes', edit: ['type' => 'KEY_VALUE'])] public object $attrs;
}

final class MemoProxy extends DataProxy
{
    public static array $calls = [];

    public function searchCondition(array &$condition): void
    {
        $condition['text'] = 'hi';
    }

    public function afterFetch(array &$rows): void
    {
        foreach ($rows as &$row) {
            $row['text'] = strtoupper($row['text']);
        }
    }

    public function addBehavior(array &$record): void
    {
        $record['text'] = 'new';
    }

    public function editBehavior(array &$record): void
    {
        $record['text'] .= '?';
    }

    public function validate(array &$record): void
    {
        if ($record['text'] === 'forbidden') {
            throw new Fail('forbidden text');
        }
    }

    // the write hooks only record that they ran, with the text they saw
    public function beforeAdd(array &$record): void { self::$calls[] = ['beforeAdd', $record['text']]; }
    public function afterAdd(array &$record): void { self::$calls[] = ['afterAdd', $record['text']]; }
    public function beforeUpdate(array &$record): void { self::$calls[] = ['beforeUpdate', $record['text']]; }
    public function afterUpdate(array &$record): void { self::$calls[] = ['afterUpdate', $record['text']]; }
    public function beforeDelete(array &$record): void { self::$calls[] = ['beforeDelete', $record['text']]; }
    public function afterDelete(array &$record): void { self::$calls[] = ['afterDelete', $record['text']]; }
}

#[Erupt('Memo', dataProxy: MemoProxy::class)]
final class Memo
{
    #[Field(pk: true)] public int $id;
    #[Field('Text')] public string $text;
}

final class TaskProxy extends DataProxy
{
    public function beforeFetch(array $conditions): string|array|null
    {
        return ['owner = ?', [Node::currentUser()['account']]];
    }
}

final class OpenProxy extends DataProxy
{
    public function beforeFetch(array $conditions): string|array|null
    {
        return 'done = 0';
    }
}

#[Erupt('Task', dataProxy: [TaskProxy::class, OpenProxy::class], raw: ['vis' => [
    ['code' => 'q', 'title' => 'Question', 'type' => 'TABLE', 'filter' => "title = 'a?'"],
    ['title' => 'Reversed', 'type' => 'TABLE', 'filter' => ['1 = 1', '2 = 2'], 'orderBy' => 'title desc'],
]])]
final class Task
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true)] public string $title;
    #[Field('Owner')] public string $owner;
    #[Field('Done')] public bool $done;
}

#[Erupt('Doc', raw: ['linkTree' => ['field' => 'topic', 'dependNode' => true]])]
final class Doc
{
    #[Field(pk: true)] public int $id;
    #[Field('Title')] public string $title;
    #[Field('Topic', tree: 'parent')] public ?Tag $topic;
}

#[Erupt('Order')]
final class Order
{
    #[Field(pk: true)] public int $id;
    #[Field('Status', fetch: 'statusOptions')] public string $status;
    #[Field('Tags', type: 'TAGS', fetch: 'tagOptions')] public string $tags;
    #[Field('Qty', onchange: 'qtyChanged')] public int $qty;
    #[Field('Note')] public string $note;
    #[Field('City', type: 'AUTO_COMPLETE', complete: 'city')] public string $city;
    #[Field('Body', type: 'MARKDOWN')] public string $body;
    #[Field('Files', type: 'ATTACHMENT')] public string $files;
    #[Field('Tags', type: 'CHECKBOX', ref: Tag::class)] public array $cats;
    #[Field('Sections', type: 'TAB_TREE', ref: Tag::class)] public array $sections;
    #[Field('Calc', type: 'BUTTON', click: 'calc')] public ?string $calc;
    #[Field('Stop', type: 'BUTTON', click: 'refuse')] public ?string $stop;

    public static function statusOptions(array $form): array { return ['new' => 'New', ($form['note'] ?? '') ?: 'x' => 'From form']; }
    public static function tagOptions(array $form): array { return ['red', 'blue']; }
    public static function qtyChanged(array $form): array { return ['formData' => ['note' => "{$form['qty']} items"]]; }
    public static function city(array $form, string $typed): array { return array_values(array_filter(['Paris', 'Tokyo'], fn($c) => stripos($c, $typed) !== false)); }
    public static function calc(array $form): array { return ['eval' => 'alert(1)', 'formData' => ['qty' => 2]]; }
    public static function refuse(array $form): array { throw new Fail('not now'); }
}

#[Erupt('Author', raw: ['drills' => [['title' => 'Books', 'link' => ['linkErupt' => 'Book', 'joinColumn' => 'author.id', 'linkCondition' => "title <> 'c'"]]]])]
final class Author
{
    #[Field(pk: true)] public int $id;
    #[Field('Name')] public string $name;
}

#[Erupt('Book')]
final class Book
{
    #[Field(pk: true)] public int $id;
    #[Field('Title')] public string $title;
    #[Field('Author')] public ?Author $author;
    #[Field('Colour', type: 'COLOR')] public string $colour;
    #[Field('Stars', type: 'RATE')] public int $stars;
    #[Field('Secret', type: 'HIDDEN')] public string $secret;
    #[Field('Readers', type: 'TRANSFER', ref: Tag::class)] public array $readers;
    #[Field('Shelf', edit: ['referenceTableType' => ['dependField' => 'author', 'dependColumn' => 'parent']])] public ?Tag $shelf;
}

// attribute names and values the schema refuses: the server's to check now (PROTOCOL.md §12.3)
#[Erupt('Lenient', raw: ['layout' => ['pageSiz' => 10]])]
final class Lenient { #[Field(pk: true)] public int $id; #[Field('T', edit: ['inputTyp' => ['length' => 9]], view: ['sortable' => 'yes'])] public string $t; }
#[Erupt('Bad3')] final class BadEditType { #[Field(pk: true)] public int $id; #[Field('T', type: 'INPUTT')] public string $t; }
#[Erupt('Bad7', orderBy: 'missing desc')] final class BadOrder { #[Field(pk: true)] public int $id; }
#[Erupt('Bad10', raw: ['vis' => [['title' => 'V', 'type' => 'TABLE', 'orderBy' => 'missing']]])] final class BadVisOrder { #[Field(pk: true)] public int $id; }
#[Erupt('Bad8', power: ['remove' => false])] final class BadPower { #[Field(pk: true)] public int $id; }
#[Erupt('Bad9')] final class BadMode { #[Field(pk: true)] public int $id; #[Operation('Go', mode: 'ALL')] public static function go(): void {} }
#[Erupt('Bad11')] final class BadOpStatic { #[Field(pk: true)] public int $id; #[Operation('Go')] public function go(): void {} }
#[Erupt('Bad12')] final class BadLabel { #[Field(pk: true)] public int $id; #[Field('Tag', label: 'title')] public ?Tag $tag; }
#[Erupt('Bad13')] final class TwoPks { #[Field(pk: true)] public int $id; #[Field(pk: true)] public int $id2; }
#[Erupt('Bad14', raw: ['linkTree' => ['field' => 't']])] final class BadLinkTree { #[Field(pk: true)] public int $id; #[Field('T')] public string $t; }
#[Erupt('Bad15')] final class BadClick { #[Field(pk: true)] public int $id; #[Field('T', click: 'go')] public string $t; public static function go(): void {} }
#[Erupt('Bad16')] final class BadFetch { #[Field(pk: true)] public int $id; #[Field('T', type: 'TAGS', fetch: 'missing')] public string $t; }
#[Erupt('Bad17')] final class BadCheckbox { #[Field(pk: true)] public int $id; #[Field('T', type: 'CHECKBOX')] public array $t; }
#[Erupt('Bad18', raw: ['drills' => [['title' => 'D', 'link' => ['linkErupt' => 'Tag']]]])] final class BadDrill { #[Field(pk: true)] public int $id; }
#[Erupt('Bad19', power: ['print' => false, 'sing' => false])] final class BadPowerKey { #[Field(pk: true)] public int $id; }

// ---------------------------------------------------------------- runner

$tests = [];
$test = function (string $name, callable $fn) use (&$tests) { $tests[$name] = $fn; };
function eq(mixed $expected, mixed $actual, string $what = ''): void
{
    if ($expected !== $actual) {
        throw new \RuntimeException("$what: expected " . json_encode($expected) . ', got ' . json_encode($actual));
    }
}
/** tests/fake-server.php standing in for the erupt server: [process, port] */
function fakeServer(): array
{
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr(strrchr(stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__ . '/fake-server.php'],
        [['file', '/dev/null', 'r'], ['file', '/dev/null', 'w'], ['file', '/dev/null', 'w']], $pipes);
    for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port, $errno, $error, 0.1); $i++) {
        usleep(100000);
    }
    return [$server, $port];
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

/** The Erupt-Enforced a v2 server sends to an endpoint (PROTOCOL.md §12.2). */
function enforcedFor(string $method, string $target): string
{
    $path = (string) parse_url($target, PHP_URL_PATH);
    return match (true) {
        $method === 'GET' && str_starts_with($path, '/erupt-api/build/') => '',
        str_starts_with($path, '/erupt-api/data/table/') => 'power,query',
        $method === 'POST' && preg_match('#^/erupt-api/data/modify/[^/]+(/update)?$#', $path) === 1 => 'power,record',
        default => 'power',
    };
}

/**
 * A call to $node for $erupt signed as a v2 server signs it, with the Erupt-Enforced its endpoint needs unless
 * $enforced says otherwise; $headers are added unsigned. [status, decoded body]
 */
function signedCall(Node $node, string $erupt, string $method, string $target, mixed $body = null, ?string $enforced = null,
                    array $headers = [], string $user = 'dXNlcg=='): array
{
    $raw = is_string($body) ? $body : ($body === null ? '' : json_encode($body));
    $enforced ??= enforcedFor($method, $target);
    $ts = time();
    $headers += ['erupt' => $erupt, 'user' => $user, 'Erupt-Timestamp' => (string) $ts]
        + ($enforced === '' ? [] : ['Erupt-Enforced' => $enforced]);
    $headers['Erupt-Signature'] ??= Signature::sign('secret', $method, $target, $ts, $enforced, $user, $raw);
    $response = $node->handle($method, (string) parse_url($target, PHP_URL_PATH), $headers, $raw, [], $target);
    return [$response->status, json_decode($response->body, true) ?? $response->body];
}

// ---------------------------------------------------------------- tests

$test('declarations are checked', function () {
    $cases = [
        [BadEditType::class, '/is not a EditType/'],
        [BadOrder::class, '/illegal orderBy/'],
        [BadVisOrder::class, "/illegal orderBy 'missing'/"],
        [BadPower::class, '/unknown power remove/'],
        [BadPowerKey::class, '/unknown power sing, expected some of add, edit/'],
        [BadMode::class, '/is not a RowOperationMode/'],
        [BadOpStatic::class, '/public static/'],
        [BadLabel::class, "/has no field 'title'/"],
        [TwoPks::class, '/at most one/'],
        [BadLinkTree::class, "/linkTree.field 't' must be a reference field/"],
        [BadClick::class, '/click belong to .* BUTTON/'],
        [BadFetch::class, '/fetch must name a static method of BadFetch/'],
        [BadCheckbox::class, '/CHECKBOX needs ref/'],
        [BadDrill::class, "/drill 'D' needs link.linkErupt and link.joinColumn/"],
    ];
    foreach ($cases as [$class, $pattern]) {
        throws($pattern, fn() => Model::of($class), $class);
    }
    // attribute names and values are the server's to refuse: they travel as declared
    $m = Model::of(Lenient::class)->buildErupt();
    eq(['pageSiz' => 10], $m['eruptJson']['layout'], 'raw erupt as declared');
    eq([['length' => 9], [['title' => 'T', 'sortable' => 'yes']]],
        [$m['eruptFieldModels'][1]['eruptFieldJson']['edit']['inputTyp'], $m['eruptFieldModels'][1]['eruptFieldJson']['views']], 'raw field as declared');
});

$test('build is declared only', function () {
    $build = Model::of(Post::class)->buildModel(['delete' => false], null);
    $m = $build['eruptModel'];
    eq(['primaryKeyCol' => 'id', 'rowOperation' => [['code' => 'touch', 'title' => 'Touch', 'mode' => 'SINGLE', 'tip' => '', 'ifExpr' => '',
        'eruptClass' => 'void', 'callHint' => 'Sure?']], 'layout' => ['pageSize' => 30]], $m['eruptJson'], 'eruptJson');
    eq(['delete' => false], $build['power'], 'power: what the model switches off');
    $fields = array_column($m['eruptFieldModels'], null, 'fieldName');
    eq(['fieldName' => 'id', 'fieldReturnName' => 'number', 'componentValue' => null,
        'eruptFieldJson' => ['edit' => ['title' => '', 'type' => 'NUMBER']]], $fields['id'], 'pk');
    eq(['fieldName' => 'title', 'fieldReturnName' => 'String', 'componentValue' => null, 'eruptFieldJson' => [
        'edit' => ['title' => 'Title', 'type' => 'INPUT', 'notNull' => true, 'search' => ['value' => true], 'inputType' => ['length' => 9]],
        'views' => [['title' => 'Title', 'sortable' => true]]]], $fields['title'], 'title');
    eq(['edit' => ['title' => 'At', 'type' => 'DATE', 'dateType' => ['type' => 'DATE_TIME']], 'views' => [['title' => 'At']]],
        $fields['at']['eruptFieldJson'], 'DATE_TIME: a DATE that says so, no view type');
    eq(['title' => 'Day', 'type' => 'DATE', 'dateType' => ['type' => 'DATE'], 'search' => ['value' => true]],
        $fields['day']['eruptFieldJson']['edit'], 'DATE');
    eq(['Date', 'Date', 'number', 'Boolean', 'String'], array_map(fn($n) => $fields[$n]['fieldReturnName'], ['at', 'day', 'views', 'live', 'kind']), 'return names');
    eq(['fieldName' => 'tag', 'fieldReturnName' => 'Tag', 'componentValue' => null, 'eruptFieldJson' => [
        'edit' => ['title' => 'Tag', 'type' => 'REFERENCE_TABLE', 'search' => ['value' => true], 'referenceTableType' => ['id' => 'id', 'label' => 'name']],
        'views' => [['title' => 'Tag', 'column' => 'name']]]], $fields['tag'], 'reference');
    eq(['a', 'b'], array_column($fields['kind']['componentValue'], 'value'), 'choice options');
    eq('{}', json_encode(Model::of(Memo::class)->buildModel([], null)['eruptModel']['tags']), 'empty objects stay objects');
    $hidden = Model::of(Order::class)->buildErupt()['eruptFieldModels'];
    eq([[], ['title' => 'Calc', 'type' => 'BUTTON']], [$hidden[10]['eruptFieldJson']['views'], $hidden[10]['eruptFieldJson']['edit']], 'BUTTON: no column');
});

$test('generated files are current', function () {
    $schema = json_decode(file_get_contents(dirname(__DIR__, 2) . '/schema/erupt-annotations.schema.json'), true);
    foreach (\generate($schema) as $file => $content) {
        eq($content, file_get_contents(dirname(__DIR__) . "/src/Types/$file"), $file);
    }
});

$test('values become storage types', function () {
    $f = Model::of(Post::class)->fields;
    eq('2026-01-05T10:30:00.000', $f['at']->coerce('2026-01-05 10:30:00'), 'datetime');
    eq('2026-01-05T10:30:00.123', $f['at']->coerce('2026-01-05T10:30:00.123Z'), 'datetime with T / Z');
    eq('2026-01-05', $f['day']->coerce('2026-01-05 10:30'), 'date from a datetime');
    eq(3, $f['views']->coerce('3'), 'integral number, as a driver reads it');
    eq(2.5, $f['views']->coerce(2.5), 'float');
    eq(true, $f['live']->coerce(1), 'bool, as a driver reads it');
    eq(2, $f['tag']->coerce('2'), 'reference key');
    eq(null, $f['title']->coerce(''), 'empty');
    // no validation: the server checked the record (§12.4)
    eq('c', $f['kind']->coerce('c'), 'an option the server let through');
    foreach ([['day', 'someday'], ['views', 'many'], ['title', ['x']], ['id', 'abc']] as [$name, $value]) {
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

$posts = fn() => (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))
    ->register(Tag::class, new MemoryRepository([['name' => 'Tech'], ['name' => 'Php', 'parent' => 1]]))
    ->register(Post::class, new MemoryRepository());

$test('every call is signed with what its endpoint needs', function () use ($posts) {
    $node = $posts();
    $call = fn(string $method, string $target, mixed $body = null, ?string $enforced = null, array $headers = []) =>
        signedCall($node, 'Post', $method, $target, $body, $enforced, $headers);
    eq([200, 'n'], [($r = $node->handle('GET', '/node-health', []))->status, $r->body], 'health');
    eq(403, $call('GET', '/erupt-api/build/Post', null, null, ['Origin' => 'x'])[0], 'origin');
    // no plain Access-Token any more
    eq(403, $node->handle('GET', '/erupt-api/build/Post', ['Access-Token' => 'secret', 'erupt' => 'Post'])->status, 'unsigned');
    eq(200, $call('GET', '/erupt-api/build/Post?_probe=1')[0], 'signed build: nothing enforced');
    eq(403, $call('GET', '/erupt-api/build/Post', null, null, ['Erupt-Signature' => str_repeat('0', 64)])[0], 'wrong signature');
    eq(403, $call('GET', '/erupt-api/build/Post', null, '', ['Erupt-Enforced' => 'power'])[0], 'enforced added after signing');
    // each endpoint refuses a call whose Erupt-Enforced lacks what it needs
    foreach ([['POST', '/erupt-api/data/table/Post', [], 'power'], ['POST', '/erupt-api/data/modify/Post', ['title' => 'x'], 'power'],
                 ['POST', '/erupt-api/data/modify/Post/update', ['id' => 1], 'power,query'], ['POST', '/erupt-api/data/modify/Post/delete', [1], ''],
                 ['GET', '/erupt-api/data/Post/1', null, ''], ['GET', '/erupt-api/data/init-value/Post', null, 'query'],
                 ['POST', '/erupt-api/invoke/Post/operation/touch', ['ids' => [1]], 'record']] as [$method, $target, $body, $enforced]) {
        eq(403, $call($method, $target, $body, $enforced)[0], "$target under '$enforced'");
    }
    eq(404, $call('GET', '/erupt-api/build/Missing', null, null, ['erupt' => 'Missing'])[0], 'unknown erupt');
    eq(404, $call('GET', '/erupt-api/build/Tag')[0], 'header / path mismatch');
    eq(404, $call('GET', '/erupt-api/build/Post', null, null, ['eruptParent' => 'n.Tag'])[0], 'foreign parent');
    eq(200, $call('GET', '/erupt-api/build/Post', null, null, ['eruptParent' => 'n.Post'])[0], 'self parent');
    eq(404, $call('GET', '/erupt-api/nothing/here')[0], 'unknown path');
    eq(404, $call('POST', '/erupt-api/data/Post/operator/touch', ['ids' => [1]])[0], 'the old operation route');
    eq(404, $call('GET', '/erupt-api/data/Post/reference-tree/tag')[0], 'reference-tree is the server\'s');
    eq(404, $call('POST', '/erupt-api/data/Post/reference-table/tag', [])[0], 'the picker is the server\'s');
});

$test('handle() serves normalized requests', function () use ($posts) {
    $node = $posts();
    $call = fn(string $method, string $target, mixed $body = null) => signedCall($node, 'Post', $method, $target, $body);
    eq(true, $call('POST', '/erupt-api/data/modify/Post', ['title' => 'Hello', 'views' => 4, 'tag' => 2, 'at' => '2026-01-05 10:30:00'])[1]['success'], 'add');
    // the server checked the record: the node no longer refuses an empty notNull field
    eq(true, $call('POST', '/erupt-api/data/modify/Post', ['views' => 1])[1]['success'], 'no not-null check');
    [$status, $page] = $call('POST', '/erupt-api/data/table/Post', ['pageIndex' => 1, 'pageSize' => 10]);
    $row = $page['list'][1];
    // a reference travels as its key: the server resolves the label and the flattened column
    eq([200, 4, 2, '2026-01-05T10:30:00.000'], [$status, $row['views'], $row['tag'], $row['at']], 'row');
    eq(false, array_key_exists('tag_name', $row), 'no flattened reference column');
    $table = fn(array $body) => $call('POST', '/erupt-api/data/table/Post', $body)[1];
    $titles = fn(array $condition, array $sort = []) => array_column($table(['condition' => $condition, 'sort' => $sort])['list'], 'title');
    // conditions on any stored field, the primary key and fields without a search among them
    eq(['Hello'], $titles([['key' => 'at', 'expression' => 'RANGE', 'value' => ['2026-01-05 10:00:00', '2026-01-05 11:00:00']]]), 'RANGE on a date time');
    eq([], $titles([['key' => 'id', 'expression' => 'NULL']]), 'NULL on the primary key');
    eq(['Hello'], $titles([['key' => 'id', 'expression' => 'IN', 'value' => [1]]]), 'IN on the primary key');
    eq(['Hello'], $titles([['key' => 'title', 'expression' => 'LIKE', 'value' => 'ell']]), 'LIKE');
    eq(['Hello', null], $titles([], [['field' => 'tag.name', 'direction' => 'ASC']]), 'sort by a reference column: its key');
    eq(['Hello', null], $titles([], [['field' => 'views', 'direction' => 'DESC']]), 'sort');
    eq(2, count($titles([], [['field' => 'live', 'direction' => 'DESC']])), 'sort by a field that is not sortable');
    foreach (['DROP', null, 'AUTO'] as $op) {
        eq(false, $table(['condition' => [['key' => 'title', 'expression' => $op, 'value' => 'x']]])['success'], "operator " . json_encode($op) . ' refused');
    }
    eq(false, $table(['condition' => [['key' => 'nope', 'expression' => 'EQ', 'value' => 1]]])['success'], 'unknown field');
    eq(false, $table(['sort' => [['field' => 'nope', 'direction' => 'ASC']]])['success'], 'unknown sort field');
    eq(1000, $table(['pageSize' => 100000])['pageSize'], 'page size cap');
    eq(false, $call('GET', '/erupt-api/data/Post/abc')[1]['success'], 'illegal id');
    eq(false, $call('POST', '/erupt-api/data/modify/Post/delete', ['id' => 1])[1]['success'], 'delete needs a list');
    eq(false, $call('POST', '/erupt-api/invoke/Post/operation/touch', ['ids' => [1, 2]])[1]['success'], 'SINGLE takes one row');
    eq('ok()', $call('POST', '/erupt-api/invoke/Post/operation/touch', ['ids' => [1]])[1]['data'], 'script');
    eq('malformed JSON body', $call('POST', '/erupt-api/data/modify/Post', '{x')[1]['message'], 'malformed body');
    eq(404, $call('POST', '/erupt-api/invoke/Post/operation/missing', [])[0], 'unknown operation');
    eq([200, null], [($r = $call('POST', '/erupt-api/invoke/Post/operation-form/touch', []))[0], $r[1]['data']], 'an operation without a form');
});

$test('registration speaks protocol v2', function () {
    [$server, $port] = fakeServer();
    $log = ini_set('error_log', '/dev/null');
    try {
        $node = new Node('n', 'secret', "http://127.0.0.1:$port", 'http://127.0.0.1:1');
        eq([true, false], [$node->registerOnce(), $node->stopped()], 'a v2 server');
        $down = new Node('n', 'secret', "http://127.0.0.1:$port/down", 'http://127.0.0.1:1');
        eq([false, false], [$down->registerOnce(), $down->stopped()], 'a failing server is retried');
        // an older server answers no version: registering stops for good, no retry and no v1 fallback
        $old = new Node('n', 'secret', "http://127.0.0.1:$port/old", 'http://127.0.0.1:1', 1);
        $start = microtime(true);
        $old->heartbeat();
        eq(true, $old->stopped(), 'an older server stops it');
        eq(true, microtime(true) - $start < 0.5, 'without waiting for another heartbeat');
    } finally {
        ini_set('error_log', (string) $log);
        proc_terminate($server);
        proc_close($server);
    }
});

$test('virtual and JSON fields', function () {
    $db = tempnam(sys_get_temp_dir(), 'erupt-php');
    foreach ([new MemoryRepository(), new PdoRepository(new \PDO("sqlite:$db"), 'widget')] as $repo) {
        $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))->register(Widget::class, $repo);
        $call = fn(string $method, string $target, mixed $body = null) => signedCall($node, 'Widget', $method, $target, $body)[1];
        $build = $call('GET', '/erupt-api/build/Widget');
        $fields = $build['eruptModel']['eruptFieldModels'];
        eq(['id' => 'NUMBER', 'name' => 'INPUT', 'basic' => 'DIVIDE', 'roles' => 'MULTI_CHOICE', 'attrs' => 'KEY_VALUE'],
            array_column(array_map(fn($f) => [$f['fieldName'], $f['eruptFieldJson']['edit']['type']], $fields), 1, 0), 'types');
        eq(['Admin', 'User', 'Guest'], array_column($fields[3]['componentValue'], 'label'), 'options');
        eq(true, $call('POST', '/erupt-api/data/modify/Widget', ['name' => 'A', 'roles' => ['ADMIN', 'USER'], 'attrs' => ['env' => 'prod'], 'basic' => 'x'])['success'], 'add A');
        eq(true, $call('POST', '/erupt-api/data/modify/Widget', ['name' => 'B', 'roles' => ['GUEST'], 'attrs' => new \stdClass()])['success'], 'add B');
        $page = $call('POST', '/erupt-api/data/table/Widget', ['pageIndex' => 1, 'pageSize' => 10]);
        eq(['id' => 1, 'name' => 'A', 'roles' => ['ADMIN', 'USER'], 'attrs' => ['env' => 'prod']], $page['list'][0], 'row');
        $ts = time();
        $headers = ['erupt' => 'Widget', 'user' => 'u', 'Erupt-Timestamp' => (string) $ts, 'Erupt-Enforced' => 'power,query',
            'Erupt-Signature' => Signature::sign('secret', 'POST', '/erupt-api/data/table/Widget', $ts, 'power,query', 'u', '{}')];
        $response = $node->handle('POST', '/erupt-api/data/table/Widget', $headers, '{}');
        eq('{}', json_encode(json_decode($response->body)->list[1]->attrs), 'empty object stays {}');
        $found = $call('POST', '/erupt-api/data/table/Widget', ['condition' => [['key' => 'roles', 'expression' => 'IN', 'value' => ['GUEST']]]]);
        eq(['B'], array_column($found['list'], 'name'), 'search');
        eq(['env' => 'prod'], $call('GET', '/erupt-api/data/Widget/1')['attrs'], 'by id');
    }
    unlink($db);
});

$test('DataProxy hooks', function () {
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))->register(Memo::class, new MemoryRepository());
    $call = fn(string $method, string $target, mixed $body = null) => signedCall($node, 'Memo', $method, $target, $body)[1];
    eq(['text' => 'hi'], $call('GET', '/erupt-api/build/Memo')['eruptModel']['searchCondition'], 'searchCondition');
    eq('new', $call('GET', '/erupt-api/data/init-value/Memo')['text'], 'addBehavior');
    $r = $call('POST', '/erupt-api/data/modify/Memo', ['text' => 'forbidden']);
    eq([false, 'forbidden text'], [$r['success'], $r['message']], 'validate');
    eq(true, $call('POST', '/erupt-api/data/modify/Memo', ['text' => 'a'])['success'], 'add');
    $page = $call('POST', '/erupt-api/data/table/Memo', []);
    eq(['A'], array_column($page['list'], 'text'), 'afterFetch');
    $pk = $page['list'][0]['id'];
    eq('a?', $call('GET', "/erupt-api/data/Memo/$pk")['text'], 'editBehavior');
    eq(true, $call('POST', '/erupt-api/data/modify/Memo/update', ['id' => $pk, 'text' => 'b'])['success'], 'update');
    eq(true, $call('POST', '/erupt-api/data/modify/Memo/delete', [$pk])['success'], 'delete');
    eq([['beforeAdd', 'a'], ['afterAdd', 'a'], ['beforeUpdate', 'b'], ['afterUpdate', 'b'], ['beforeDelete', 'b'], ['afterDelete', 'b']],
        MemoProxy::$calls, 'write hooks in order');
});

$test('DataProxy beforeFetch', function () {
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))->register(Task::class, new PdoRepository(new \PDO('sqlite::memory:'), 'task'));
    $call = function (string $method, string $target, mixed $body, string $account = 'admin') use (&$node) {
        return signedCall($node, 'Task', $method, $target, $body, user: base64_encode(json_encode(['uid' => 1, 'account' => $account])));
    };
    foreach ([['a', 'admin', false], ['b', 'admin', true], ['c', 'root', false], ['a?', 'admin', false]] as [$title, $owner, $done]) {
        $call('POST', '/erupt-api/data/modify/Task', ['title' => $title, 'owner' => $owner, 'done' => $done]);
    }
    $page = $call('POST', '/erupt-api/data/table/Task', [])[1];
    eq([['a', 'a?'], 2], [array_column($page['list'], 'title'), $page['total']], 'owner and open only');
    $page = $call('POST', '/erupt-api/data/table/Task', ['condition' => [['key' => 'title', 'expression' => 'EQ', 'value' => 'a']]], 'root')[1];
    eq([], $page['list'], 'with search conditions');
    // a view's own filter and order run on the node, and stay out of the build
    eq(['a?'], array_column($call('POST', '/erupt-api/data/table/Task', ['vis' => 'q'])[1]['list'], 'title'), 'view filter as written');
    eq(['a?', 'a'], array_column($call('POST', '/erupt-api/data/table/Task', ['vis' => 'Reversed'])[1]['list'], 'title'), 'view filters and order');
    $vis = $call('GET', '/erupt-api/build/Task', null)[1]['eruptModel']['eruptJson']['vis'];
    eq([['q', 'Question', 'TABLE'], ['Reversed', 'Reversed', 'TABLE']], array_map(fn($v) => [$v['code'], $v['title'], $v['type']], $vis), 'view codes');
    eq(false, (bool) array_filter($vis, fn($v) => isset($v['filter']) || isset($v['orderBy'])), 'filter and orderBy off the build');
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))->register(Task::class, new MemoryRepository());
    eq(500, $call('POST', '/erupt-api/data/table/Task', [])[0], 'MemoryRepository refuses');
    $repo = new PdoRepository(new \PDO('sqlite::memory:'), 'task');
    $repo->bind(Model::of(Task::class));
    throws("/2 '\\?' for 1 params/", fn() => $repo->page(new Query(filters: [['owner = ? or owner = ?', ['admin']]])), 'placeholder count');
});

$test('LinkTree conditions arrive from the server', function () {
    $repo = new MemoryRepository([['title' => 'a', 'topic' => 1], ['title' => 'b', 'topic' => 2], ['title' => 'c', 'topic' => 3]]);
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))->register(Doc::class, $repo);
    $titles = fn(array $condition) => array_column(signedCall($node, 'Doc', 'POST', '/erupt-api/data/table/Doc', ['condition' => $condition])[1]['list'], 'title');
    // IN on linkTree.field with the picked keys; under dependNode with nothing picked, NULL on the primary key
    eq(['b'], $titles([['key' => 'topic', 'expression' => 'IN', 'value' => [2]]]), 'one key');
    eq(['a', 'b'], $titles([['key' => 'topic', 'expression' => 'IN', 'value' => [1, 2]]]), 'keys');
    eq([], $titles([['key' => 'id', 'expression' => 'NULL']]), 'dependNode: nothing picked');
    eq(['a', 'b', 'c'], array_column(signedCall($node, 'Doc', 'POST', '/erupt-api/data/table/Doc', ['linkTreeVal' => [2]])[1]['list'], 'title'), 'linkTreeVal is the server\'s');
});

$test('field types and invoke', function () {
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))
        ->register(Tag::class, new MemoryRepository())->register(Order::class, new PdoRepository(new \PDO('sqlite::memory:'), 'orders'));
    $call = fn(string $method, string $target, mixed $body = null) => signedCall($node, 'Order', $method, $target, $body);
    $fields = array_column($call('GET', '/erupt-api/build/Order')[1]['eruptModel']['eruptFieldModels'], null, 'fieldName');
    $edit = array_map(fn($f) => $f['eruptFieldJson']['edit'], $fields);
    eq(['fetchHandler' => ['invoke']], $edit['status']['choiceType'], 'choice fetchHandler');
    eq(['fetchHandler' => ['invoke']], $edit['tags']['tagsType'], 'tags fetchHandler');
    eq('invoke', $edit['qty']['onchange'], 'onchange');
    eq(['MARKDOWN', 'ATTACHMENT', 'BUTTON'], [$edit['body']['type'], $edit['files']['type'], $edit['calc']['type']], 'types');
    eq([[], 'Tag', 'Tag', 'name'], [$fields['calc']['eruptFieldJson']['views'], $fields['cats']['fieldReturnName'], $fields['sections']['fieldReturnName'],
        $fields['cats']['eruptFieldJson']['views'][0]['column']], 'button and collections');
    $invoke = fn(string $kind, string $field, array $form = [], ?string $value = null) =>
        $call('POST', "/erupt-api/invoke/Order/$kind/$field", ['form' => $form ?: new \stdClass(), 'value' => $value]);
    eq([['value' => 'new', 'label' => 'New'], ['value' => 'n', 'label' => 'From form']], $invoke('options', 'status', ['note' => 'n'])[1]['data'], 'options');
    eq(['red', 'blue'], $invoke('options', 'tags')[1]['data'], 'tags');
    eq(['formData' => ['note' => '3 items']], $invoke('onchange', 'qty', ['qty' => 3])[1]['data'], 'onchange');
    eq(['Paris'], $invoke('autocomplete', 'city', [], 'pa')[1]['data'], 'autocomplete');
    eq('alert(1)', $invoke('button', 'calc')[1]['data']['eval'], 'button');
    eq([false, 'not now'], [$invoke('button', 'stop')[1]['success'], $invoke('button', 'stop')[1]['message']], 'Fail');
    eq(404, $invoke('button', 'qty')[0], 'a field without that code');
    eq(404, $invoke('options', 'missing')[0], 'unknown field');
    // picked records arrive as their keys (§12.4) and are stored as such
    eq(true, $call('POST', '/erupt-api/data/modify/Order', ['cats' => [1, 2], 'sections' => [3], 'tags' => '["red"]'])[1]['success'], 'add');
    $row = $call('POST', '/erupt-api/data/table/Order', [])[1]['list'][0];
    eq([[1, 2], [3], false], [$row['cats'], $row['sections'], array_key_exists('calc', $row)], 'row');
    eq([5], Model::of(Order::class)->fields['cats']->coerce('[5]'), 'the JSON text a SQL repository reads back');
});

$books = function () {
    $book = new PdoRepository(new \PDO('sqlite::memory:'), 'book');
    $node = (new Node('n', 'secret', 'http://127.0.0.1:1', 'http://127.0.0.1:1'))
        ->register(Tag::class, new MemoryRepository([['name' => 'Tech'], ['name' => 'Php', 'parent' => 1]]))
        ->register(Author::class, new MemoryRepository([['name' => 'Ann'], ['name' => 'Bob']]))
        ->register(Book::class, $book);
    foreach ([['title' => 'a', 'author' => 1], ['title' => 'b', 'author' => 2], ['title' => 'c', 'author' => 1]] as $row) {
        $book->add($row);
    }
    return $node;
};

$test('drills arrive in the body', function () use ($books) {
    $node = $books();
    $table = fn(array $body) => signedCall($node, 'Book', 'POST', '/erupt-api/data/table/Book', $body);
    // the server sends the join as a condition and names the drill; the node adds its linkCondition
    $join = [['key' => 'author', 'expression' => 'EQ', 'value' => 1]];
    eq(['a'], array_column($table(['condition' => $join, 'drill' => ['erupt' => 'Author', 'code' => 'Books']])[1]['list'], 'title'), 'the drilled author\'s books');
    eq(['a', 'c'], array_column($table(['condition' => $join])[1]['list'], 'title'), 'the join alone');
    eq(403, $table(['condition' => $join, 'drill' => ['erupt' => 'Author', 'code' => 'nope']])[0], 'an undeclared drill');
    eq(403, $table(['drill' => ['erupt' => 'Missing', 'code' => 'Books']])[0], 'an unregistered source');
    eq(403, $table(['drill' => 'Books'])[0], 'a malformed drill');
    // the old headers mean nothing now
    eq(['a', 'b', 'c'], array_column(signedCall($node, 'Book', 'POST', '/erupt-api/data/table/Book', [], null,
        ['Drill' => 'Books', 'DrillSourceErupt' => 'Author', 'DrillValue' => '1'])[1]['list'], 'title'), 'drill headers');
    $drills = signedCall($node, 'Author', 'GET', '/erupt-api/build/Author')[1]['eruptModel']['eruptJson']['drills'];
    eq([['title' => 'Books', 'link' => ['linkErupt' => 'Book', 'joinColumn' => 'author.id', 'linkCondition' => "title <> 'c'"], 'code' => 'Books']],
        $drills, 'the whole link in the build, code from the title');
});

$test('simple types and dependColumn', function () use ($books) {
    $node = $books();
    $fields = signedCall($node, 'Book', 'GET', '/erupt-api/build/Book')[1]['eruptModel']['eruptFieldModels'];
    $edit = array_column(array_map(fn($f) => [$f['fieldName'], $f['eruptFieldJson']['edit']], $fields), 1, 0);
    eq(['COLOR', 'RATE', 'HIDDEN', 'TRANSFER'], array_map(fn($n) => $edit[$n]['type'], ['colour', 'stars', 'secret', 'readers']), 'types');
    eq(['id' => 'id', 'label' => 'name', 'dependField' => 'author', 'dependColumn' => 'parent'], $edit['shelf']['referenceTableType'], 'the server reads dependColumn off the build');
    eq(true, signedCall($node, 'Book', 'POST', '/erupt-api/data/modify/Book', ['title' => 'd', 'stars' => 4, 'readers' => [2]])[1]['success'], 'add');
    $row = signedCall($node, 'Book', 'POST', '/erupt-api/data/table/Book', [])[1]['list'][3];
    eq([4, [2]], [$row['stars'], $row['readers']], 'row');
});

$test('node config and user info', function () {
    [$server, $port] = fakeServer();
    try {
        $node = new Node('n', 'secret', "http://127.0.0.1:$port", 'http://127.0.0.1:1');
        eq('cfg', $node->config(), 'node config');
        eq('group cfg', $node->groupConfig(), 'group config');
        eq(['account' => 'admin', 'roles' => ['r']], $node->userInfo(), 'user info');
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
