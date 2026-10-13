<?php
// PdoRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
// workflow starts both as service containers); connection settings come from the standard PG* variables and
// MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE. Needs pdo_pgsql and pdo_mysql.
declare(strict_types=1);

require __DIR__ . '/../autoload.php';

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Cond;
use Erupt\Model;
use Erupt\PdoRepository;
use Erupt\Query;

if (!getenv('ERUPT_TEST_DATABASES')) {
    echo "skipped: set ERUPT_TEST_DATABASES to run against PostgreSQL and MySQL\n";
    exit(0);
}

#[Erupt('Post', name: 'DbPost')]
final class DbPost
{
    #[Field(pk: true)] public int $id;
    #[Field('Title', search: true)] public string $title;
    #[Field('Views')] public ?int $views;
    #[Field('Live')] public bool $live;
    #[Field('Day', type: 'DATE')] public ?string $day;
    #[Field('At')] public ?\DateTimeImmutable $at;
}

function env(string $name, string $fallback): string
{
    $value = getenv($name);
    return $value === false || $value === '' ? $fallback : $value;
}

function same(mixed $expected, mixed $actual, string $what): void
{
    if ($expected !== $actual) {
        throw new \RuntimeException("$what: expected " . json_encode($expected) . ', got ' . json_encode($actual));
    }
}

$databases = [
    'postgres' => [
        fn() => new \PDO(sprintf('pgsql:host=%s;port=%s;dbname=%s', env('PGHOST', '127.0.0.1'), env('PGPORT', '5432'), env('PGDATABASE', 'erupt')),
            env('PGUSER', 'postgres'), env('PGPASSWORD', '')),
        ['DROP TABLE IF EXISTS "db_post"',
            'CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, "live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))'],
    ],
    'mysql' => [
        fn() => new \PDO(sprintf('mysql:host=%s;port=%s;dbname=%s', env('MYSQL_HOST', '127.0.0.1'), env('MYSQL_PORT', '3306'), env('MYSQL_DATABASE', 'erupt')),
            env('MYSQL_USER', 'root'), env('MYSQL_PASSWORD', '')),
        ['DROP TABLE IF EXISTS `db_post`',
            'CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, `live` BOOLEAN, `day` DATE, `at` DATETIME(3))'],
    ],
];

$failed = 0;
foreach ($databases as $name => [$connect, $ddl]) {
    try {
        $pdo = $connect();
        foreach ($ddl as $sql) {
            $pdo->exec($sql);
        }
        $repo = new PdoRepository($pdo, 'db_post', autoCreate: false);
        $repo->bind(Model::of(DbPost::class));
        $repo->add(['title' => '100% pure', 'views' => 3, 'live' => true, 'day' => '2026-01-05', 'at' => '2026-01-05T10:30:00.123']);
        $repo->add(['title' => 'wow!', 'views' => 1, 'live' => false, 'day' => '2026-03-01', 'at' => null]);
        $repo->add(['title' => 'a_b', 'views' => null, 'live' => false, 'day' => null, 'at' => null]);
        $titles = fn(array $conds = [], array $sort = [['title', false]]) => array_column($repo->page(new Query($conds, $sort, 0, 10))[1], 'title');

        same(['100% pure', 'wow!', 'a_b'], $titles([], []), 'default order is primary key ascending');
        same(['100% pure'], $titles([new Cond('title', 'LIKE', '%')]), 'LIKE escapes %');
        same(['wow!'], $titles([new Cond('title', 'LIKE', '!')]), 'LIKE escapes !');
        same(['a_b'], $titles([new Cond('title', 'LIKE', '_')]), 'LIKE escapes _');
        same(['a_b', 'wow!'], $titles([new Cond('title', 'NOT_LIKE', 'pure')]), 'NOT_LIKE');
        same(['100% pure', 'wow!'], $titles([new Cond('views', 'IN', [1, 3])]), 'IN');
        same([], $titles([new Cond('views', 'IN', [])]), 'empty IN');
        same(['wow!'], $titles([new Cond('day', 'RANGE', ['2026-02-01', '2026-12-31'])]), 'RANGE');
        same(['100% pure'], $titles([new Cond('live', 'EQ', true)]), 'boolean');
        same(['100% pure'], $titles([new Cond('views', 'GT', 2)]), 'GT');
        same(['a_b'], $titles([new Cond('views', 'NULL')]), 'NULL');
        [$total, $page] = $repo->page(new Query([], [['views', true]], 1, 1));
        same([3, 1], [$total, count($page)], 'total and page size');

        same(['id' => 1, 'title' => '100% pure', 'views' => 3, 'live' => true, 'day' => '2026-01-05', 'at' => '2026-01-05T10:30:00.123'],
            $repo->get(1), 'round trip');
        $repo->update(1, ['title' => 'renamed', 'live' => false]);
        same(['renamed', false], [$repo->get(1)['title'], $repo->get(1)['live']], 'update');
        $repo->delete([1, 2]);
        same(['a_b'], $titles(), 'delete');
        same(null, $repo->get(1), 'deleted');
        echo "  ok    $name\n";
    } catch (\Throwable $e) {
        $failed++;
        echo "  FAIL  $name: {$e->getMessage()}\n";
    }
}
exit($failed ? 1 : 0);
