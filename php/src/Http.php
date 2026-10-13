<?php

namespace Erupt;

/** The few outgoing calls a node makes to the erupt server, over PHP streams (no ext-curl needed). */
final class Http
{
    /** @return array{0: int, 1: string} status and body; throws \RuntimeException when the server is unreachable */
    public static function request(string $method, string $url, array $headers = [], ?string $body = null, float $timeout = 5): array
    {
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = "$name: $value";
        }
        $context = stream_context_create(['http' => [
            'method' => $method, 'header' => implode("\r\n", $lines), 'content' => $body ?? '',
            'timeout' => $timeout, 'ignore_errors' => true, 'follow_location' => 0,
        ]]);
        $response = @file_get_contents($url, false, $context);
        $responseHeaders = function_exists('http_get_last_response_headers') ? http_get_last_response_headers() : ($http_response_header ?? null);
        if ($response === false || !$responseHeaders) {
            throw new \RuntimeException("$url unreachable");
        }
        preg_match('#^HTTP/\S+\s+(\d{3})#', $responseHeaders[0], $m);
        return [(int) ($m[1] ?? 0), $response];
    }
}
