<?php

namespace Erupt\Attribute;

/**
 * Declares a public static method of a model as a row operation; the method receives an
 * Erupt\OperationContext and may return a string, which runs as JavaScript in the browser, so return
 * only code you wrote.
 *
 * `code` defaults to the method name. `mode`: SINGLE (row button), MULTI (row and toolbar), MULTI_ONLY
 * (toolbar), BUTTON (toolbar, no rows). `form`: an #[Erupt] class whose fields are asked for before
 * running. `confirm`: false skips the confirm dialog, a string replaces its text. `show`: name of a
 * public static method of the model taking the user (?array) and returning bool; it hides the operation
 * and refuses to run it. `ifExpr`: browser-side JS over `item` that disables (or hides) the row button.
 * `raw`: raw `@RowOperation` attributes.
 */
#[\Attribute(\Attribute::TARGET_METHOD)]
final class Operation
{
    public function __construct(
        public string $title,
        public ?string $code = null,
        public string $mode = 'MULTI',
        public ?string $icon = null,
        public string $tip = '',
        public bool|string $confirm = true,
        public ?string $form = null,
        public ?string $show = null,
        public string $ifExpr = '',
        public array $raw = [],
    ) {
    }
}
