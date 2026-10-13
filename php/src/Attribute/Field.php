<?php

namespace Erupt\Attribute;

/**
 * One column. `title` labels both the table column and the form input. The edit type follows the
 * property type (string INPUT, int / float NUMBER, bool BOOLEAN, DateTimeInterface DATE_TIME) unless
 * `type` is given; `choices` makes a CHOICE. A property typed with another #[Erupt] class (or `ref`)
 * references one of its records: the repository stores the referenced primary key, the UI shows
 * `label`; `tree` names the referenced model's parent field and turns the picker into a tree. `table` /
 * `form` hide the field from the table / the form. `view` / `edit` are raw `@View` / `@Edit` attributes.
 */
#[\Attribute(\Attribute::TARGET_PROPERTY)]
final class Field
{
    public function __construct(
        public string $title = '',
        public ?string $type = null,
        public bool $pk = false,
        public bool $search = false,
        public bool $notNull = false,
        public bool $sortable = false,
        public bool $table = true,
        public bool $form = true,
        public ?array $choices = null,
        public ?string $ref = null,
        public string $label = 'name',
        public ?string $tree = null,
        public array $view = [],
        public array $edit = [],
    ) {
    }
}
