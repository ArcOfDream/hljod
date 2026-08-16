# odkdl

A quick 'n dirty KDL parser, easy to borrow into other codebases. Not quite fully compliant to spec, but for my use cases it's been more than enough.

It's event based, so you're meant to provide a callback that receives Start_Node, End_Node, Argument, Property, Start_Children and End_Children events.

## usage

```odin
import kdl "kdl"

cb :: proc(ctx: rawptr, e: kdl.Event) -> bool {
    #partial switch e.type {
    case .Start_Node: fmt.println("node:", e.name)
    case .Argument:   fmt.println("  arg:", e.value.raw_text)
    case .Property:   fmt.println("  prop", e.name, "=", e.value.raw_text)
    }
    return true
}

ok, err := kdl.parse(source, cb, nil)
```

## api

- `kdl.parse(source, callback, ctx)` - parse a KDL document
- `kdl.Event` / `kdl.Event_Type` - parser events
- `kdl.Value` - parsed value with raw_text and type tag

## currently unhandled

- string escapes (`\n`, `\t`)
- multi-line strings (`"""..."""`), type annotations (`(type)value`),
  and AST building