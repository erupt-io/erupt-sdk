<?php

namespace Erupt;

use Erupt\Attribute\Field;

/** A compiled #[Field]: builds its erupt field JSON and converts values to the types the repository stores. */
final class FieldSpec
{
    public const REFERENCES = ['REFERENCE_TABLE', 'REFERENCE_TREE'];
    /** many records of another model, stored as the JSON list of their keys */
    public const COLLECTIONS = ['CHECKBOX', 'TAB_TREE', 'TRANSFER'];
    /** the edit attribute that names a fetchHandler, by the type that fetches options */
    public const FETCHED = ['CHOICE' => 'choiceType', 'MULTI_CHOICE' => 'multiChoiceType', 'TAGS' => 'tagsType'];
    /** invoke kind -> the #[Field] attribute naming its code */
    public const INVOKED = ['options' => 'fetch', 'onchange' => 'onchange', 'autocomplete' => 'complete', 'button' => 'click'];

    /** edit type -> python-equivalent value kind */
    private const KINDS = [
        'INPUT' => 'string', 'TEXTAREA' => 'string', 'CHOICE' => 'string', 'NUMBER' => 'number',
        'BOOLEAN' => 'bool', 'DATE' => 'date', 'DATE_TIME' => 'datetime',
        'TAGS' => 'string', 'AUTO_COMPLETE' => 'string', 'ATTACHMENT' => 'string', 'HTML_EDITOR' => 'string',
        'MARKDOWN' => 'string', 'CODE_EDITOR' => 'string',
        'COLOR' => 'string', 'ICON' => 'string', 'SIGNATURE' => 'string', 'MAP' => 'string', 'HIDDEN' => 'string',
        'RATE' => 'number', 'SLIDER' => 'number',
    ];

    /** the edit types a field may take: the simple ones above, references, collections, MULTI_CHOICE and BUTTON */
    public const SUPPORTED = ['INPUT', 'TEXTAREA', 'CHOICE', 'NUMBER', 'BOOLEAN', 'DATE', 'DATE_TIME', 'TAGS', 'AUTO_COMPLETE',
        'ATTACHMENT', 'HTML_EDITOR', 'MARKDOWN', 'CODE_EDITOR', 'COLOR', 'ICON', 'SIGNATURE', 'MAP', 'HIDDEN', 'RATE', 'SLIDER',
        ...self::REFERENCES, ...self::COLLECTIONS, 'MULTI_CHOICE', 'BUTTON'];

    /** fieldReturnName by edit type (PROTOCOL.md §7.1); a reference names its target, the rest are "String" */
    private const RETURN_NAMES = ['NUMBER' => 'number', 'RATE' => 'number', 'SLIDER' => 'number', 'BOOLEAN' => 'Boolean',
        'DATE' => 'Date', 'DATE_TIME' => 'Date'];

    /** what a JSON field holds: an `array` property a list, an `object` property an object */
    public const JSON_ARRAY = 'array';
    public const JSON_OBJECT = 'object';

    public readonly ?string $type;

    /** @param array<string, \Closure> $code invoke kind -> the field's own code */
    public function __construct(public readonly string $name, public readonly Field $decl, ?string $type,
                                public readonly ?string $json = null, public readonly array $code = [])
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

    public function isCollection(): bool
    {
        return in_array($this->type, self::COLLECTIONS, true);
    }

    /** The referenced model, for a reference or collection field. */
    public function target(): Model
    {
        return Model::of($this->decl->ref);
    }

    /** The field as declared (PROTOCOL.md §12.3): the server completes the rest from Java's defaults. */
    public function build(): array
    {
        $d = $this->decl;
        if ($d->pk) {
            return ['fieldName' => $this->name, 'fieldReturnName' => 'number', 'componentValue' => null,
                'eruptFieldJson' => ['edit' => ['title' => '', 'type' => 'NUMBER']]];
        }
        // a DATE_TIME is a DATE whose dateType says so; a DATE says it too, as AUTO is the node's to resolve
        $edit = ['title' => $d->title, 'type' => $this->type === 'DATE_TIME' ? 'DATE' : $this->type];
        if ($this->type === 'DATE' || $this->type === 'DATE_TIME') {
            $edit['dateType'] = ['type' => $this->type];
        }
        if ($d->notNull) {
            $edit['notNull'] = true;
        }
        if (!$d->form) {
            $edit['show'] = false;
        }
        if ($d->search) {
            $edit['search'] = ['value' => true];
        }
        $view = ['title' => $d->title];
        if ($d->sortable) {
            $view['sortable'] = true;
        }
        $returnName = self::RETURN_NAMES[$this->type] ?? 'String';
        if ($this->type === 'REFERENCE_TABLE') {
            $edit['referenceTableType'] = ['id' => $this->target()->pk, 'label' => $d->label];
        } elseif ($this->type === 'REFERENCE_TREE') {
            $edit['referenceTreeType'] = ['id' => $this->target()->pk, 'label' => $d->label, 'pid' => $d->tree];
        }
        if ($this->isReference() || $this->isCollection()) {
            // the server lists a CHECKBOX by the view column, a TAB_TREE by the target's own tree
            $returnName = $this->target()->name;
            $view['column'] = $d->label;
        }
        if (isset($this->code['options'], self::FETCHED[$this->type])) {
            $edit[self::FETCHED[$this->type]] = ['fetchHandler' => ['invoke']];
        }
        if (isset($this->code['onchange'])) {
            $edit['onchange'] = 'invoke';
        }
        $options = null;
        if ($d->choices !== null) { // CHOICE, or MULTI_CHOICE over an array
            $options = [];
            foreach ($d->choices as $value => $label) {
                $options[] = ['value' => (string) $value, 'label' => $label, 'desc' => null, 'color' => null, 'disable' => false];
            }
        }
        // a BUTTON is a form element only: no table column
        $views = $d->table && $this->type !== 'BUTTON' ? [Model::merge($view, $d->view)] : [];
        return ['fieldName' => $this->name, 'fieldReturnName' => $returnName, 'componentValue' => $options,
            'eruptFieldJson' => ['edit' => Model::merge($edit, $d->edit), 'views' => $views]];
    }

    /**
     * A JSON value as the server sends it (PROTOCOL.md §12.4), or a column as a driver reads it, to the value the
     * repository stores; throws \InvalidArgumentException when it cannot be. Dates are stored as wall-clock strings:
     * DATE `2026-01-05`, DATE_TIME `2026-01-05T10:30:00.000`. The server has checked the value; a key in a path
     * segment, a delete body or an operation's ids arrives as the browser sent it, so it may fail here.
     */
    public function coerce(mixed $value): mixed
    {
        if ($this->isReference()) {
            $target = $this->target();
            return $target->fields[$target->pk]->coerce($value);
        }
        if ($this->isCollection()) {
            // a list of keys; a SQL repository reads it back as its JSON text
            $items = is_string($value) && $value !== '' ? json_decode($value, true, 512, JSON_THROW_ON_ERROR) : ($value ?: []);
            $pk = $this->target()->fields[$this->target()->pk];
            return array_map([$pk, 'coerce'], array_values((array) $items));
        }
        if ($value === null || $value === '') {
            return null;
        }
        if ($this->json !== null) {
            return $this->json($value);
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
        return is_bool($value) ? ($value ? 'True' : 'False') : (string) $value;
    }

    /** A JSON value: a list as an array, an object as a stdClass (so an empty one stays `{}`). */
    private function json(mixed $value): mixed
    {
        if (is_string($value)) {
            $value = json_decode($value, $this->json === self::JSON_ARRAY, 512, JSON_THROW_ON_ERROR);
        }
        return $this->json === self::JSON_OBJECT && is_array($value) ? (object) $value : $value;
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
