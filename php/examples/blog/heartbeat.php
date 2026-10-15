<?php
// Registration process, run next to the web server: PORT=9090 php examples/blog/heartbeat.php
// It seeds empty tables first, so the web server's requests never race on it.
$node = require __DIR__ . '/app.php';
\Erupt\Examples\Blog\seed();
$node->heartbeat((int) (getenv('PORT') ?: 9090));
