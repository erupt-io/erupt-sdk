<?php

namespace Erupt;

use Erupt\Attribute\Operation;
use Erupt\Types\RowOperationMode;

/** A compiled #[Operation]. */
final class OperationSpec
{
    public readonly string $code;

    /** @param callable(OperationContext): (string|null|void) $fn */
    public function __construct(public readonly Operation $decl, private readonly mixed $fn, string $method, private readonly ?\Closure $show)
    {
        $this->code = $decl->code ?? $method;
        if (RowOperationMode::tryFrom($decl->mode) === null) {
            throw new \InvalidArgumentException("operation $this->code: mode '$decl->mode' is not a RowOperationMode, expected one of "
                . implode(', ', array_column(RowOperationMode::cases(), 'value')));
        }
        if ($decl->form !== null) {
            Model::of($decl->form);
        }
    }

    public function formModel(): ?Model
    {
        return $this->decl->form === null ? null : Model::of($this->decl->form);
    }

    public function visible(?array $user): bool
    {
        return $this->show === null || ($this->show)($user);
    }

    public function run(OperationContext $context): mixed
    {
        return ($this->fn)($context);
    }

    public function build(): array
    {
        $d = $this->decl;
        $tpl = ['code' => $this->code, 'title' => $d->title, 'mode' => $d->mode, 'tip' => $d->tip, 'ifExpr' => $d->ifExpr,
            'eruptClass' => $d->form === null ? 'void' : $this->formModel()->name];
        if ($d->icon !== null) {
            $tpl['icon'] = $d->icon;
        }
        if ($d->confirm === false) {
            $tpl['callHint'] = ''; // the browser runs it without asking
        } elseif (is_string($d->confirm)) {
            $tpl['callHint'] = $d->confirm;
        }
        return Model::merge($tpl, $d->raw);
    }
}
