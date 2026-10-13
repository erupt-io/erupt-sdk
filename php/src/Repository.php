<?php

namespace Erupt;

/** Implement these methods to put an erupt model on any storage. A record is an associative array keyed by field name. */
interface Repository
{
    public function bind(Model $model): void;

    /** @return array{0: int, 1: list<array<string, mixed>>} total and the requested page of records */
    public function page(Query $query): array;

    public function get(int|string $pk): ?array;

    public function add(array $record): void;

    public function update(int|string $pk, array $record): void;

    /** @param list<int|string> $pks */
    public function delete(array $pks): void;
}
