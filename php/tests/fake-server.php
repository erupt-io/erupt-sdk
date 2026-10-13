<?php
// `php -S` router standing in for the erupt server in tests: full power for session token "t1"
if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/erupt-cloud-api/erupt-power' && ($_SERVER['HTTP_TOKEN'] ?? '') === 't1') {
    header('Content-Type: application/json');
    echo json_encode(['add' => true, 'edit' => true, 'delete' => true, 'viewDetails' => true, 'export' => true, 'importable' => true]);
    return;
}
http_response_code(500);
