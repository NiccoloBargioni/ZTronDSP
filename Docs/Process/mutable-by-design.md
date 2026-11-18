# Mutable by design (IMM-2)

No public stored property of a value type is `var`, and no reference type has a public setter,
except those entered here with a reason. `Scripts/lint-bans.sh --part 4` keeps this register
equal to the code: a public setter without a row fails, and a row without a setter fails.

`Symbol` is the property as the lint reports it (`Type.property`, or `Type.subscript`).
`File` is its path under the package root.

| Symbol | File | Reason |
|---|---|---|
