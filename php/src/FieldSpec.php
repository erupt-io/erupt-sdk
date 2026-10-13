<?php

namespace Erupt;

use Erupt\Attribute\Field;

/** A compiled #[Field]: builds its erupt field JSON and coerces browser values. */
final class FieldSpec
{
    public const REFERENCES = ['REFERENCE_TABLE', 'REFERENCE_TREE'];

    /** edit type -> python-equivalent value kind */
    private const KINDS = [
        'INPUT' => 'string', 'TEXTAREA' => 'string', 'CHOICE' => 'string', 'NUMBER' => 'number',
        'BOOLEAN' => 'bool', 'DATE' => 'date', 'DATE_TIME' => 'datetime',
    ];

    public readonly ?string $type;

    public function __construct(public readonly string $name, public readonly Field $decl, ?string $type)
    {
        $this->type = $type;
    }

    public function isPk(): bool
    {
        return $this->decl->pk;
    }

    public function isReference(): bool
    {
        return in_array($this->type, self::REFERENCES, true);
    }

    /** The referenced model, for a reference field. */
    public function target(): Model
    {
        return Model::of($this->decl->ref);
    }

    public function build(): array
    {
        $d = $this->decl;
        $tpl = Schema::defaults()['fields'][$d->pk ? 'id' : $this->type];
        $tpl['fieldName'] = $this->name;
        $tpl['componentValue'] = null;
        if ($d->pk) {
            return $tpl;
        }
        $edit = $tpl['eruptFieldJson']['edit'];
        $view = $tpl['eruptFieldJson']['views'][0];
        $edit['title'] = $d->title;
        $edit['notNull'] = $d->notNull;
        $edit['show'] = $d->form;
        $edit['search']['value'] = $d->search;
        $view['title'] = $d->title;
        $view['sortable'] = $d->sortable;
        if ($this->type === 'DATE') {
            $view['type'] = 'DATE';
        } elseif ($this->isReference()) {
            $target = $this->target();
            $tpl['fieldReturnName'] = $target->name;
            $key = $this->type === 'REFERENCE_TABLE' ? 'referenceTableType' : 'referenceTreeType';
            $edit[$key]['id'] = $target->pk;
            $edit[$key]['label'] = $d->label;
            if ($this->type === 'REFERENCE_TREE') {
                $edit[$key]['pid'] = $d->tree;
            }
            $view['column'] = $d->label;
        }
        $tpl['eruptFieldJson']['edit'] = Model::merge($edit, $d->edit);
        $tpl['eruptFieldJson']['views'] = $d->table ? [Model::merge($view, $d->view)] : [];
        if ($this->type === 'CHOICE') {
            $tpl['componentValue'] = [];
            foreach ($d->choices ?? [] as $value => $label) {
                $tpl['componentValue'][] = ['value' => (string) $value, 'label' => $label, 'desc' => null, 'color' => null, 'disable' => false];
            }
        }
        return $tpl;
    }

    /**
     * Turn a JSON value from the browser into the value the repository stores; throws
     * \InvalidArgumentException. Dates are stored as wall-clock strings: DATE `2026-01-05`, DATE_TIME
     * `2026-01-05T10:30:00.000`.
     */
    public function coerce(mixed $value): mixed
    {
        if ($this->isReference()) {
            // the browser sends the picked record as {<id>: ..., <label>: ...}
            $target = $this->target();
            if (is_array($value)) {
                $value = $value[$target->pk] ?? null;
            }
            return $target->fields[$target->pk]->coerce($value);
        }
        if ($value === null || $value === '') {
            return null;
        }
        if ($this->decl->pk) {
            if (is_int($value) || (is_float($value) && floor($value) == $value)) {
                return (int) $value;
            }
            if (is_string($value) && preg_match('/^\s*-?\d+\s*$/', $value)) {
                return (int) $value;
            }
            throw new \InvalidArgumentException("illegal integer '" . self::show($value) . "'");
        }
        switch (self::KINDS[$this->type]) {
            case 'bool':
                return is_bool($value) ? $value : in_array(strtolower(is_scalar($value) ? (string) $value : ''), ['true', '1'], true);
            case 'number':
                if (is_bool($value)) {
                    return (int) $value;
                }
                if (!is_int($value) && !is_float($value) && !(is_string($value) && is_numeric(trim($value)))) {
                    throw new \InvalidArgumentException("illegal number '" . self::show($value) . "'");
                }
                $number = (float) (is_string($value) ? trim($value) : $value);
                return is_finite($number) && floor($number) == $number && abs($number) < 2 ** 53 ? (int) $number : $number;
            case 'datetime':
                return self::parseDate($value)->format('Y-m-d\TH:i:s.v');
            case 'date':
                return self::parseDate($value)->format('Y-m-d');
        }
        if (!is_scalar($value)) {
            throw new \InvalidArgumentException('expected text');
        }
        $text = is_bool($value) ? ($value ? 'True' : 'False') : (string) $value;
        if ($this->type === 'CHOICE' && $this->decl->choices !== null
            && !in_array($text, array_map('strval', array_keys($this->decl->choices)), true)) {
            throw new \InvalidArgumentException("illegal option '$text'");
        }
        return $text;
    }

    /** A stored value to JSON for the browser. */
    public function toJson(mixed $value): mixed
    {
        if ($value instanceof \DateTimeInterface) {
            return $value->format($this->type === 'DATE' ? 'Y-m-d' : 'Y-m-d\TH:i:s.v');
        }
        if ($this->type === 'BOOLEAN' && is_int($value)) {
            return (bool) $value;
        }
        return $value;
    }

    /** Accepts what python's strptime formats accept: `Y-m-d`, `Y-m-d H:i`, `Y-m-d H:i:s`, `Y-m-d H:i:s.u`, with `T` / `Z`. */
    public static function parseDate(mixed $value): \DateTimeImmutable
    {
        $text = is_scalar($value) ? rtrim(str_replace('T', ' ', (string) $value), 'Z') : '';
        if (preg_match('/^(\d{4})-(\d{1,2})-(\d{1,2})(?: (\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d{1,6}))?)?)?$/', $text, $m)
            && checkdate((int) $m[2], (int) $m[3], (int) $m[1])
            && (int) ($m[4] ?? 0) < 24 && (int) ($m[5] ?? 0) < 60 && (int) ($m[6] ?? 0) < 60) {
            return (new \DateTimeImmutable('@0'))
                ->setDate((int) $m[1], (int) $m[2], (int) $m[3])
                ->setTime((int) ($m[4] ?? 0), (int) ($m[5] ?? 0), (int) ($m[6] ?? 0), (int) str_pad($m[7] ?? '0', 6, '0'));
        }
        throw new \InvalidArgumentException("illegal date '" . self::show($value) . "'");
    }

    private static function show(mixed $value): string
    {
        return is_scalar($value) ? (string) $value : json_encode($value);
    }
}
