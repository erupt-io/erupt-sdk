<?php
// Registration process, run next to the web server (php-fpm, or `php -S 0.0.0.0:9090 examples/showcase/router.php`):
//   PORT=9090 php examples/showcase/heartbeat.php
// It seeds empty tables first, so the web server's requests never race on it. ../showcase.php runs both in one command.
$node = require __DIR__ . '/app.php';
\Erupt\Examples\Showcase\seed();
$node->heartbeat((int) (getenv('PORT') ?: 9090));
