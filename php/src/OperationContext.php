<?php

namespace Erupt;

/** What an operation method receives. */
final class OperationContext
{
    public function __construct(
        /** Selected records as the repository returned them; empty for BUTTON mode. */
        public readonly array $rows,
        /** Coerced form values, or null without a form. */
        public readonly ?array $param,
        public readonly Repository $repo,
        public readonly Model $model,
        public readonly ?array $user,
    ) {
    }
}
