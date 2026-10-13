<?php

namespace Erupt\Attribute;

/**
 * Declares a class as an erupt model.
 *
 * `name` defaults to the class's short name and is what the server addresses (`node.Name`); `power`
 * switches features off (`['delete' => false]`); `orderBy` is the default table order, applied by the
 * node (`'views desc, id'`); `raw` holds raw `@Erupt` attributes merged onto the defaults
 * (`['layout' => ['pageSize' => 30]]`, see Erupt\Types\Annotations).
 */
#[\Attribute(\Attribute::TARGET_CLASS)]
final class Erupt
{
    public function __construct(
        public string $title = '',
        public ?string $name = null,
        public array $power = [],
        public ?string $orderBy = null,
        public array $raw = [],
    ) {
    }
}
