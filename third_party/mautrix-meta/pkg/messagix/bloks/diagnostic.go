package bloks

import (
	"fmt"
	"slices"
)

// UnsupportedFunctionError exposes code identifiers only, never script literals,
// variable names, argument values or response bodies.
type UnsupportedFunctionError struct {
	Function  BloksFunctionID
	Arity     int
	Functions []BloksFunctionID
}

func (e *UnsupportedFunctionError) Error() string {
	return fmt.Sprintf("unimplemented function %s (%d args)", e.Function, e.Arity)
}

func (i *Interpreter) unsupportedFunction(call *BloksScriptFuncall) error {
	functions := make([]BloksFunctionID, 0, len(i.functions))
	for name := range i.functions {
		functions = append(functions, name)
	}
	slices.Sort(functions)
	return &UnsupportedFunctionError{Function: call.Function, Arity: len(call.Args), Functions: functions}
}

func (i *Interpreter) collectScriptFunctions(node *BloksScriptNode) {
	if node == nil {
		return
	}
	call, ok := node.Content.(*BloksScriptFuncall)
	if !ok {
		return
	} // Literals must never enter the diagnostic inventory.
	if len(i.functions) < 512 {
		i.functions[call.Function] = struct{}{}
	}
	for j := range call.Args {
		i.collectScriptFunctions(&call.Args[j])
	}
}

func (i *Interpreter) collectTreeFunctions(node BloksTreeNodeContent) {
	switch value := node.(type) {
	case *BloksTreeComponent:
		for _, child := range value.Attributes {
			if child != nil {
				i.collectTreeFunctions(child.BloksTreeNodeContent)
			}
		}
	case *BloksTreeComponentList:
		for _, child := range *value {
			i.collectTreeFunctions(child)
		}
	case *BloksTreeScript:
		i.collectScriptFunctions(&value.AST)
	case *BloksTreeScriptSet:
		for _, script := range value.Scripts {
			i.collectScriptFunctions(&script.AST)
		}
	}
}

func (i *Interpreter) collectBundleFunctions(bundle *BloksBundle) {
	payload := &bundle.Layout.Payload
	for _, script := range payload.Scripts {
		i.collectScriptFunctions(&script.AST)
	}
	for _, variable := range payload.Variables {
		if variable.Info.InitialScript != nil {
			i.collectScriptFunctions(&variable.Info.InitialScript.AST)
		}
	}
	for _, embedded := range payload.Embedded {
		i.collectBundleFunctions(&embedded.Contents)
	}
	for _, template := range payload.Templates {
		i.collectTreeFunctions(template.BloksTreeNodeContent)
	}
	if payload.Tree != nil {
		i.collectTreeFunctions(payload.Tree.BloksTreeNodeContent)
	}
	if payload.Action != nil {
		i.collectScriptFunctions(&payload.Action.AST)
	}
}
