<?php
// Registration process, run next to the web server: PORT=9090 php examples/blog/heartbeat.php
(require __DIR__ . '/app.php')->heartbeat((int) (getenv('PORT') ?: 9090));
