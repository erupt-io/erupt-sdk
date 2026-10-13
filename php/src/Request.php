<?php

namespace Erupt;

/** @internal the parsed request an endpoint sees */
final class Request
{
    public function __construct(public readonly array $headers, private readonly string $body)
    {
    }

    public function json(): mixed
    {
        if (trim($this->body) === '') {
            return null;
        }
        try {
            return json_decode($this->body, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new Fail('malformed JSON body');
        }
    }

    /** The body as a JSON object; anything else counts as empty. */
    public function object(): array
    {
        $body = $this->json();
        return is_array($body) && ($body === [] || !array_is_list($body)) ? $body : [];
    }
}
