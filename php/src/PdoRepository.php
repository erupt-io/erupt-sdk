<?php

namespace Erupt;

/**
 * A table behind PDO. Identifiers come from the model (already whitelisted) and are quoted for the
 * driver; every value is a bound parameter; LIKE wildcards are escaped. With $autoCreate the table is
 * created on SQLite when missing; on other databases create it yourself. Dates are stored as text
 * (`2026-01-05`, `2026-01-05T10:30:00.000`), booleans as 0 / 1. Paging uses LIMIT / OFFSET.
 */
final class PdoRepository implements Repository
{
    private const SQL_OPS = ['EQ' => '=', 'NEQ' => '<>', 'GT' => '>', 'GTE' => '>=', 'LT' => '<', 'LTE' => '<='];
    private const SQLITE_TYPES = ['NUMBER' => 'NUMERIC', 'BOOLEAN' => 'INTEGER', 'REFERENCE_TABLE' => 'INTEGER', 'REFERENCE_TREE' => 'INTEGER'];

    private Model $model;

    public function __construct(private readonly \PDO $pdo, private readonly string $table, private readonly bool $autoCreate = true)
    {
        if (!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $table)) {
            throw new \InvalidArgumentException("illegal table name '$table'");
        }
        $this->pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
    }

    public function bind(Model $model): void
    {
        $this->model = $model;
        if (!$this->autoCreate || $this->pdo->getAttribute(\PDO::ATTR_DRIVER_NAME) !== 'sqlite') {
            return;
        }
        $columns = [];
        foreach ($model->fields as $f) {
            $columns[] = $this->q($f->name) . ' ' . ($f->isPk() ? 'INTEGER PRIMARY KEY AUTOINCREMENT' : (self::SQLITE_TYPES[$f->type] ?? 'TEXT'));
        }
        $this->pdo->exec('CREATE TABLE IF NOT EXISTS ' . $this->q($this->table) . ' (' . implode(', ', $columns) . ')');
    }

    private function q(string $identifier): string
    {
        $quote = $this->pdo->getAttribute(\PDO::ATTR_DRIVER_NAME) === 'mysql' ? '`' : '"';
        return $quote . str_replace($quote, $quote . $quote, $identifier) . $quote;
    }

    /** @return array{0: string, 1: list<mixed>} */
    private function where(array $conditions): array
    {
        $clauses = [];
        $params = [];
        foreach ($conditions as $c) {
            $col = $this->q($c->field);
            switch ($c->op) {
                case 'LIKE':
                case 'NOT_LIKE':
                    $clauses[] = "$col " . ($c->op === 'NOT_LIKE' ? 'NOT ' : '') . "LIKE ? ESCAPE '!'";
                    $params[] = '%' . strtr((string) $c->value, ['!' => '!!', '%' => '!%', '_' => '!_']) . '%';
                    break;
                case 'RANGE':
                    $clauses[] = "$col BETWEEN ? AND ?";
                    array_push($params, $c->value[0], $c->value[1]);
                    break;
                case 'IN':
                case 'NOT_IN':
                    if (!$c->value) {
                        $clauses[] = $c->op === 'IN' ? '1=0' : '1=1';
                        break;
                    }
                    $clauses[] = "$col " . ($c->op === 'NOT_IN' ? 'NOT ' : '') . 'IN (' . implode(', ', array_fill(0, count($c->value), '?')) . ')';
                    array_push($params, ...$c->value);
                    break;
                case 'NULL':
                case 'NOT_NULL':
                    $clauses[] = "$col IS " . ($c->op === 'NOT_NULL' ? 'NOT ' : '') . 'NULL';
                    break;
                default:
                    $clauses[] = "$col " . self::SQL_OPS[$c->op] . ' ?';
                    $params[] = $c->value;
            }
        }
        return [$clauses ? ' WHERE ' . implode(' AND ', $clauses) : '', $params];
    }

    public function page(Query $query): array
    {
        [$where, $params] = $this->where($query->conditions);
        $table = $this->q($this->table);
        $total = (int) $this->run("SELECT COUNT(*) FROM $table$where", $params)->fetchColumn();
        // nulls last ascending and first descending on every database, like MemoryRepository
        $order = implode(', ', array_map(fn($s) => '(' . $this->q($s[0]) . ' IS NULL)' . ($s[1] ? ' DESC, ' : ' ASC, ')
            . $this->q($s[0]) . ($s[1] ? ' DESC' : ' ASC'), $query->sort)) ?: $this->q($this->model->pk) . ' ASC';
        $statement = $this->pdo->prepare("SELECT * FROM $table$where ORDER BY $order LIMIT ? OFFSET ?");
        foreach (array_values($params) as $i => $value) {
            $this->bindValue($statement, $i + 1, $value);
        }
        $statement->bindValue(count($params) + 1, $query->limit, \PDO::PARAM_INT);
        $statement->bindValue(count($params) + 2, $query->offset, \PDO::PARAM_INT);
        $statement->execute();
        return [$total, array_map([$this, 'record'], $statement->fetchAll(\PDO::FETCH_ASSOC))];
    }

    public function get(int|string $pk): ?array
    {
        $row = $this->run('SELECT * FROM ' . $this->q($this->table) . ' WHERE ' . $this->q($this->model->pk) . ' = ?', [$pk])->fetch(\PDO::FETCH_ASSOC);
        return $row ? $this->record($row) : null;
    }

    public function add(array $record): void
    {
        unset($record[$this->model->pk]);
        $columns = implode(', ', array_map([$this, 'q'], array_keys($record)));
        $this->run('INSERT INTO ' . $this->q($this->table) . " ($columns) VALUES (" . implode(', ', array_fill(0, count($record), '?')) . ')', array_values($record));
    }

    public function update(int|string $pk, array $record): void
    {
        unset($record[$this->model->pk]);
        if (!$record) {
            return;
        }
        $sets = implode(', ', array_map(fn($k) => $this->q($k) . ' = ?', array_keys($record)));
        $this->run('UPDATE ' . $this->q($this->table) . " SET $sets WHERE " . $this->q($this->model->pk) . ' = ?', [...array_values($record), $pk]);
    }

    public function delete(array $pks): void
    {
        if (!$pks) {
            return;
        }
        $this->run('DELETE FROM ' . $this->q($this->table) . ' WHERE ' . $this->q($this->model->pk) . ' IN ('
            . implode(', ', array_fill(0, count($pks), '?')) . ')', array_values($pks));
    }

    private function record(array $row): array
    {
        foreach ($this->model->fields as $f) {
            if ($f->type === 'BOOLEAN' && isset($row[$f->name])) {
                $row[$f->name] = (bool) $row[$f->name];
            }
        }
        return $row;
    }

    private function run(string $sql, array $params): \PDOStatement
    {
        $statement = $this->pdo->prepare($sql);
        foreach (array_values($params) as $i => $value) {
            $this->bindValue($statement, $i + 1, $value);
        }
        $statement->execute();
        return $statement;
    }

    private function bindValue(\PDOStatement $statement, int $position, mixed $value): void
    {
        if ($value instanceof \DateTimeInterface) {
            $value = $value->format('Y-m-d\TH:i:s.v');
        }
        $type = match (true) {
            $value === null => \PDO::PARAM_NULL,
            is_bool($value) => \PDO::PARAM_BOOL,
            is_int($value) => \PDO::PARAM_INT,
            default => \PDO::PARAM_STR,
        };
        $statement->bindValue($position, is_bool($value) ? (int) $value : $value, is_bool($value) ? \PDO::PARAM_INT : $type);
    }
}
