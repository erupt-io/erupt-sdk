<?php
/**
 * The showcase (SHOWCASE.md) in one command: seeds the SQLite file, serves examples/showcase/router.php with
 * `php -S`, then registers from this process until SIGINT, when it deregisters and stops the server.
 *
 *   ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 PORT=9090 php examples/showcase.php
 *   python3 conformance/showcase.py -- php php/examples/showcase.php
 */

// one file for both processes: `php -S` starts from its own working directory
$db = getenv('ERUPT_DB') ?: 'showcase.db';
putenv('ERUPT_DB=' . (str_starts_with($db, '/') ? $db : getcwd() . "/$db"));
$node = require __DIR__ . '/showcase/app.php';
Erupt\Examples\Showcase\seed();

$port = (int) (getenv('PORT') ?: 9090);
$server = proc_open([PHP_BINARY, '-S', "0.0.0.0:$port", __DIR__ . '/showcase/router.php'], [['file', '/dev/null', 'r'], STDOUT, STDERR],
    $pipes, null, getenv());
for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port, $errno, $error, 0.1); $i++) {
    usleep(100000);
}
try {
    $node->heartbeat($port);
} finally {
    proc_terminate($server);
    proc_close($server);
}
