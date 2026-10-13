<?php

namespace Erupt;

/** @internal an HTTP status without a body */
final class Reply extends \Exception
{
    public function __construct(public readonly int $status)
    {
        parent::__construct("HTTP $status");
    }
}
