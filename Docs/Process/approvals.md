# Approvals register (APR-2)

`AnyView` and Combine are not used (APR-1). An exception needs a change request approved by the
owner before the code exists; its number is entered here. `Scripts/lint-bans.sh --part 3`
accepts a use only when a row names it, the change request file exists, and that file reads
`Approved` with a name and a date. A row without such a change request fails the lint, and so
does a row that no code uses.

`API` is the name as the lint reports it (`AnyView`, `import Combine`, `ObservableObject`, …).
`Scope` is a path under the package root; `*` matches within one path component.

| Change request | API | Scope | Reason |
|---|---|---|---|
