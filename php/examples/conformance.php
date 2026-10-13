<?php
/**
 * Conformance launcher: seeds a temporary SQLite file, serves the fixture with `php -S`, then registers
 * from this process until SIGINT, when it deregisters and stops the server.
 *
 *   python conformance/run.py -- php php/examples/conformance.php
 */

use Erupt\Model;
use Erupt\Examples\Conformance\Category;

$db = sys_get_temp_dir() . '/erupt-php-conformance-' . getmypid() . '.sqlite';
putenv("ERUPT_DB=$db");
$node = require __DIR__ . '/conformance/app.php'; // creates the tables
$category = new Erupt\PdoRepository(new PDO("sqlite:$db"), 'category');
$category->bind(Model::of(Category::class));
foreach ([['name' => 'Tech', 'parent' => null], ['name' => 'Python', 'parent' => 1], ['name' => 'Life', 'parent' => null]] as $row) {
    $category->add($row);
}

$port = (int) getenv('PORT');
$quiet = getenv('CONFORMANCE_TRACE') ? STDERR : ['file', '/dev/null', 'w'];
$server = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", __DIR__ . '/conformance/router.php'],
    [['file', '/dev/null', 'r'], $quiet, $quiet], $pipes, null, getenv());
for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port, $errno, $error, 0.1); $i++) {
    usleep(100000);
}
try {
    $node->heartbeat($port);
} finally {
    proc_terminate($server);
    proc_close($server);
    @unlink($db);
}
