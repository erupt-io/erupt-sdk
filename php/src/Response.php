<?php

namespace Erupt;

/** What Node::handle() answers; emit it with your framework's response object. */
final class Response
{
    public function __construct(public readonly int $status, public readonly string $contentType, public readonly string $body)
    {
    }
}
