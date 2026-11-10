<?php
// `php -S` router standing in for the erupt server in tests
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
// registration: a v2 server answers its protocol version; one under /old is older and answers nothing
if ($path === '/erupt-cloud-api/register-node') {
    header('Content-Type: application/json');
    echo '{"protocolVersion": 2}';
    return;
}
if ($path === '/old/erupt-cloud-api/register-node' || str_ends_with($path, '/erupt-cloud-api/remove-instance-node')) {
    return;
}
// node config, group config and user info, for access token "secret"
$answers = ['/erupt-cloud-api/node-config/n' => 'cfg', '/erupt-cloud-api/node-group-config/n' => 'group cfg',
    '/erupt-cloud-api/userinfo/n' => '{"account": "admin", "roles": ["r"]}'];
if (isset($answers[$path]) && ($_SERVER['HTTP_ACCESS_TOKEN'] ?? '') === 'secret') {
    echo $answers[$path];
    return;
}
http_response_code(500);
