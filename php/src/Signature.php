<?php

namespace Erupt;

/**
 * Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
 * the node's access token, so the token need not travel and the signed headers cannot be forged.
 */
final class Signature
{
    public const HEADER_TIMESTAMP = 'Erupt-Timestamp';
    public const HEADER_SIGNATURE = 'Erupt-Signature';
    public const HEADER_ENFORCED = 'Erupt-Enforced';
    public const WINDOW_SECONDS = 300;
    private const UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD';

    /** @param ?string $body the raw bytes, or null for a multipart upload the server re-encodes (not covered) */
    public static function sign(string $accessToken, string $method, string $pathAndQuery, int $timestamp,
                                ?string $enforced, ?string $user, ?string $body): string
    {
        $canonical = implode("\n", [
            strtoupper($method), $pathAndQuery, (string) $timestamp, $enforced ?? '',
            hash('sha256', $user ?? ''),
            $body === null ? self::UNSIGNED_PAYLOAD : hash('sha256', $body),
        ]);
        return hash_hmac('sha256', $canonical, $accessToken);
    }

    public static function verify(string $accessToken, string $method, string $pathAndQuery, ?string $timestamp,
                                  ?string $enforced, ?string $user, ?string $body, string $signature, int $now): bool
    {
        $timestamp = trim((string) $timestamp);
        if (!preg_match('/^-?\d+$/', $timestamp)) {
            return false;
        }
        if (abs($now - (int) $timestamp) > self::WINDOW_SECONDS) {
            return false;
        }
        return hash_equals(self::sign($accessToken, $method, $pathAndQuery, (int) $timestamp, $enforced, $user, $body), trim($signature));
    }
}
