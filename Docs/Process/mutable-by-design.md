# Mutable by design (IMM-1, IMM-2)

No public stored property of a value type is `var`, and no reference type has a public setter,
except those entered here with a reason (IMM-2). Nor does a public struct keep a stored `var` that
its module can set, internal or package, except those entered here (IMM-1, as WP-909 reads it): a
private or file-private setter is the type's own business, and a `@usableFromInline` one is how
VIS-1 writes the internals of a toolkit primitive or a frame accessor, which its `@inlinable` code
sets. `Scripts/lint-bans.sh --part 4` keeps this register equal to the code: a setter or a stored
`var` of these kinds without a row fails, and a row that matches nothing fails.

`Symbol` is the property as the lint reports it (`Type.property`, or `Type.subscript`).
`File` is its path under the package root.

| Symbol | File | Reason |
|---|---|---|
