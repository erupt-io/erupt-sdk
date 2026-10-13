<?php

namespace Erupt;

final class Cond
{
    /** @param string $op EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL */
    public function __construct(public readonly string $field, public readonly string $op, public readonly mixed $value = null)
    {
    }
}
