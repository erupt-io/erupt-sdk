package erupt

import (
	"context"
	"errors"
	"fmt"
)

// Operation is a row operation. Handler receives the selected rows and the form values; a returned
// script is run as JavaScript in the browser, so only return code you wrote.
type Operation struct {
	Code  string           // required, unique within the model
	Title string           // button label
	Mode  RowOperationMode // SINGLE, MULTI (default), MULTI_ONLY or BUTTON (toolbar, no rows)
	Icon  string           // e.g. "fa fa-paper-plane"
	Tip   string
	// IfExpr is browser-side JS over `item` that disables (or hides) the row button.
	IfExpr string
	// Confirm replaces the confirm dialog text; NoConfirm runs without asking.
	Confirm   string
	NoConfirm bool
	// Form is a model whose fields are asked for before running (it needs no pk and is not registered).
	Form *Model
	// Show hides the operation from a user and refuses to run it for them.
	Show func(*User) bool
	// Raw passes raw @RowOperation attributes (an M or a RowOperation).
	Raw     any
	Handler func(*OpContext) (string, error)

	raw map[string]any
}

// OpContext is what an operation handler receives.
type OpContext struct {
	Context context.Context
	Rows    []Record // the selected records as the repository returned them; empty for BUTTON mode
	Param   Record   // coerced form values, nil without a form
	Repo    Repository
	Model   *Model
	User    *User
}

func newOperation(model string, op Operation) (*Operation, error) {
	if op.Code == "" || op.Handler == nil {
		return nil, fmt.Errorf("%s: an operation needs a Code and a Handler", model)
	}
	path := "operation " + model + "." + op.Code
	if op.Mode == "" {
		op.Mode = RowOperationModeMulti
	}
	if err := checkEnum(RowOperationModeValues, string(op.Mode), "RowOperationMode", path+".mode"); err != nil {
		return nil, err
	}
	raw, err := rawObject(op.Raw, "RowOperation", path)
	if err != nil {
		return nil, err
	}
	op.raw = raw
	return &op, nil
}

func (op *Operation) visible(user *User) bool { return op.Show == nil || op.Show(user) }

func (op *Operation) build() map[string]any {
	tpl := deepCopy(defaults.RowOperation).(map[string]any)
	eruptClass := "void"
	if op.Form != nil {
		eruptClass = op.Form.name
	}
	merge(tpl, M{"code": op.Code, "title": op.Title, "mode": string(op.Mode), "tip": op.Tip, "ifExpr": op.IfExpr,
		"type": "ERUPT", "eruptClass": eruptClass})
	if op.Icon != "" {
		tpl["icon"] = op.Icon
	}
	if op.NoConfirm {
		tpl["callHint"] = "" // the browser runs it without asking
	} else if op.Confirm != "" {
		tpl["callHint"] = op.Confirm
	}
	return merge(tpl, op.raw)
}

// FailError is a business error: the browser shows its message instead of a server error.
type FailError struct{ Message string }

func (e *FailError) Error() string { return e.Message }

// Fail returns a FailError, for operation handlers and repositories.
func Fail(format string, args ...any) error { return &FailError{fmt.Sprintf(format, args...)} }

func isFail(err error) (*FailError, bool) {
	var f *FailError
	ok := errors.As(err, &f)
	return f, ok
}
