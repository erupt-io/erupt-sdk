<?php

namespace Erupt;

/**
 * JSON with PHP arrays, keeping the one distinction arrays lose: an empty object stays a stdClass, so
 * `{}` in the erupt templates is not sent back as `[]`.
 */
final class Json
{
    public static function decode(string $text): mixed
    {
        return self::arrays(json_decode($text, false, 512, JSON_THROW_ON_ERROR));
    }

    public static function encode(mixed $value): string
    {
        return json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    }

    private static function arrays(mixed $value): mixed
    {
        if ($value instanceof \stdClass) {
            $vars = get_object_vars($value);
            return $vars ? array_map([self::class, 'arrays'], $vars) : new \stdClass();
        }
        return is_array($value) ? array_map([self::class, 'arrays'], $value) : $value;
    }
}
