<?php

namespace Erupt;

use Erupt\Attribute\Erupt;
use Erupt\Attribute\Field;
use Erupt\Attribute\Operation;
use Erupt\Types\EditType;

/**
 * An #[Erupt] class compiled into erupt build JSON. Nothing re-implements annotation semantics: every
 * field and operation starts from the template the Java proxies emit (resources/erupt-node-defaults.json)
 * and a declaration only overrides values on top of it.
 */
final class Model
{
    private const IDENTIFIER = '/^[A-Za-z_][A-Za-z0-9_]*$/';

    /** @var array<class-string, Model> */
    private static array $compiled = [];
    /** @var array<class-string, true> */
    private static array $compiling = [];

    public readonly string $name;
    public readonly string $title;
    /** Primary key field, or null for a model that only serves as an operation form. */
    public readonly ?string $pk;
    public readonly array $power;
    /** @var list<array{0: string, 1: bool}> default sort, [field, descending] */
    public readonly array $orderBy;
    /** @var array<string, FieldSpec> stored and served, in declaration order */
    public readonly array $fields;
    /** @var list<FieldSpec> every field in order, virtual ones included, for the build */
    public readonly array $declared;
    /** @var array<string, OperationSpec> */
    public readonly array $operations;
    private readonly array $raw;

    /** The compiled model of an #[Erupt] class; cached, so declarations are checked once. */
    public static function of(string $class): self
    {
        if (isset(self::$compiled[$class])) {
            return self::$compiled[$class];
        }
        if (isset(self::$compiling[$class])) {
            throw new \InvalidArgumentException("$class references itself (directly or through another model)");
        }
        self::$compiling[$class] = true;
        try {
            return self::$compiled[$class] = new self(new \ReflectionClass($class));
        } finally {
            unset(self::$compiling[$class]);
        }
    }

    private function __construct(\ReflectionClass $class)
    {
        $attribute = $class->getAttributes(Erupt::class)[0] ?? null;
        if ($attribute === null) {
            throw new \InvalidArgumentException("{$class->getName()} has no #[Erupt] attribute");
        }
        $decl = $attribute->newInstance();
        $this->name = $decl->name ?? $class->getShortName();
        if (!preg_match(self::IDENTIFIER, $this->name)) {
            throw new \InvalidArgumentException("erupt name '$this->name' must be an identifier");
        }
        $this->title = $decl->title;
        Schema::check('Erupt', $decl->raw, "#[Erupt] $this->name");
        $this->raw = $decl->raw;
        $defaults = Schema::defaults()['power'];
        if ($unknown = array_diff_key($decl->power, $defaults)) {
            throw new \InvalidArgumentException("$this->name: unknown power " . implode(', ', array_keys($unknown)));
        }
        $this->power = array_merge($defaults, $decl->power);

        $fields = $declared = [];
        foreach ($class->getProperties() as $property) {
            $field = $property->getAttributes(Field::class)[0] ?? null;
            if ($field !== null) {
                $declared[] = $spec = $this->field($property, $field->newInstance());
                if (!$spec->decl->virtual) {
                    $fields[$property->getName()] = $spec;
                }
            }
        }
        $this->fields = $fields;
        $this->declared = $declared;
        $pks = array_keys(array_filter($fields, fn(FieldSpec $f) => $f->isPk()));
        if (count($pks) > 1) {
            throw new \InvalidArgumentException("$this->name: at most one #[Field(pk: true)]");
        }
        $this->pk = $pks[0] ?? null;
        $this->orderBy = $this->parseOrder($decl->orderBy);

        $operations = [];
        foreach ($class->getMethods() as $method) {
            $op = $method->getAttributes(Operation::class)[0] ?? null;
            if ($op === null) {
                continue;
            }
            if (!$method->isStatic() || !$method->isPublic()) {
                throw new \InvalidArgumentException("$this->name::{$method->getName()}: an operation must be a public static method");
            }
            $op = $op->newInstance();
            $show = null;
            if ($op->show !== null) {
                if (!$class->hasMethod($op->show) || !$class->getMethod($op->show)->isStatic()) {
                    throw new \InvalidArgumentException("$this->name::{$method->getName()}: show must name a static method of $this->name");
                }
                $show = \Closure::fromCallable([$class->getName(), $op->show]);
            }
            $spec = new OperationSpec($op, [$class->getName(), $method->getName()], $method->getName(), $show);
            if (isset($operations[$spec->code])) {
                throw new \InvalidArgumentException("$this->name: operation code '$spec->code' declared twice");
            }
            $operations[$spec->code] = $spec;
        }
        $this->operations = $operations;
    }

    private function field(\ReflectionProperty $property, Field $decl): FieldSpec
    {
        $name = $property->getName();
        $path = "$this->name.$name";
        if ($decl->type !== null && EditType::tryFrom($decl->type) === null) {
            throw new \InvalidArgumentException("$path.type: '$decl->type' is not a EditType, expected one of "
                . implode(', ', array_column(EditType::cases(), 'value')));
        }
        Schema::check('View', $decl->view, "$path.view");
        Schema::check('Edit', $decl->edit, "$path.edit");
        if ($decl->pk) {
            return new FieldSpec($name, $decl, null);
        }
        $hint = $property->getType() instanceof \ReflectionNamedType ? $property->getType()->getName() : null;
        if ($decl->ref === null && $hint !== null && class_exists($hint) && (new \ReflectionClass($hint))->getAttributes(Erupt::class)) {
            $decl->ref = $hint;
        }
        $type = match (true) {
            $decl->ref !== null => $decl->tree !== null ? 'REFERENCE_TREE' : 'REFERENCE_TABLE',
            $decl->type !== null => $decl->type,
            $decl->choices !== null && $hint !== 'array' => 'CHOICE',
            $hint === 'bool' => 'BOOLEAN',
            $hint === 'int', $hint === 'float' => 'NUMBER',
            $hint !== null && is_a($hint, \DateTimeInterface::class, true) => 'DATE_TIME',
            default => 'INPUT',
        };
        if (!isset(Schema::defaults()['fields'][$type])) {
            throw new \InvalidArgumentException("$path: edit type $type is not supported yet");
        }
        $json = $decl->ref === null ? match ($hint) {
            'array' => FieldSpec::JSON_ARRAY,
            'object', \stdClass::class => FieldSpec::JSON_OBJECT,
            default => null,
        } : null;
        $spec = new FieldSpec($name, $decl, $type, $json);
        if ($spec->isReference()) {
            $target = Model::of($decl->ref);
            if ($target->pk === null) {
                throw new \InvalidArgumentException("$path: $target->name has no primary key");
            }
            foreach (array_filter([$decl->label, $decl->tree]) as $key) {
                if (!isset($target->fields[$key])) {
                    throw new \InvalidArgumentException("$path: $target->name has no field '$key'");
                }
            }
        }
        return $spec;
    }

    /** `'views desc, id'` -> `[['views', true], ['id', false]]`, fields checked against the model. */
    private function parseOrder(?string $orderBy): array
    {
        $sort = [];
        foreach (array_filter(array_map('trim', explode(',', $orderBy ?? ''))) as $part) {
            $words = preg_split('/\s+/', $part);
            if (count($words) > 2 || !isset($this->fields[$words[0]])
                || (count($words) === 2 && !in_array(strtolower($words[1]), ['asc', 'desc'], true))) {
                throw new \InvalidArgumentException("$this->name: illegal orderBy '$part'");
            }
            $sort[] = [$words[0], count($words) === 2 && strtolower($words[1]) === 'desc'];
        }
        return $sort;
    }

    /** @param list<OperationSpec> $operations */
    public function buildErupt(array $operations = []): array
    {
        $erupt = self::merge(Schema::defaults()['erupt'], ['primaryKeyCol' => $this->pk ?? 'id']);
        $erupt['rowOperation'] = array_map(fn(OperationSpec $op) => $op->build(), $operations);
        return [
            'eruptName' => $this->name,
            'eruptJson' => self::merge($erupt, $this->raw),
            'eruptFieldModels' => array_map(fn(FieldSpec $f) => $f->build(), $this->declared),
            'searchCondition' => new \stdClass(),
            'extraRow' => false,
            'tags' => new \stdClass(),
        ];
    }

    public function buildModel(array $power, ?array $user): array
    {
        $operations = array_values(array_filter($this->operations, fn(OperationSpec $op) => $op->visible($user)));
        $forms = [];
        foreach ($operations as $op) {
            if ($op->decl->form !== null) {
                $forms[$op->code] = $op->formModel()->buildErupt();
            }
        }
        return [
            'eruptModel' => $this->buildErupt($operations),
            'power' => $power,
            'tabErupts' => null,
            'combineErupts' => null,
            'operationErupts' => $forms ?: null,
        ];
    }

    /** Deep merge of JSON objects; lists and scalars are replaced. */
    public static function merge(array $target, array $override): array
    {
        foreach ($override as $key => $value) {
            if (is_array($value) && !array_is_list($value) && isset($target[$key]) && is_array($target[$key]) && !array_is_list($target[$key])) {
                $target[$key] = self::merge($target[$key], $value);
            } else {
                $target[$key] = $value;
            }
        }
        return $target;
    }
}
