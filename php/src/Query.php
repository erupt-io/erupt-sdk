<?php

namespace Erupt;

/**
 * A page request handed to a repository. Field names in it have been checked against the model, so a
 * repository may use them as identifiers; values always travel as parameters.
 */
final class Query
{
    public function __construct(
        /** @var list<Cond> */
        public array $conditions = [],
        /** @var list<array{0: string, 1: bool}> [field, descending] */
        public array $sort = [],
        public int $offset = 0,
        public int $limit = 10,
    ) {
    }
}
