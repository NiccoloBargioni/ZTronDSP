# Process records

What §11 of the specification asks to be kept, and the script that reads each file.

| File | Holds | Rule | Read by |
|---|---|---|---|
| `ledger.md` | One row per work package | §11.9, §11.8 item 6 | `Scripts/ledger.sh` |
| `reports/WP-nnn-A.md`, `reports/WP-nnn-B.md` | The two verifier reports of a package | VER-4 | `Scripts/ledger.sh --check` |
| `changes/CR-nnn.md` | Change requests | §11.9, FIX-3, FIX-4, §11.7 | `Scripts/lint-bans.sh` (approval status) |
| `approvals.md` | Approved uses of `AnyView` and Combine | APR-2 | `Scripts/lint-bans.sh --part 3` |
| `mutable-by-design.md` | Every public setter, with its reason | IMM-2, VIS-1 | `Scripts/lint-bans.sh --part 4` |
| `open-declarations.md` | Every `open` declaration, with its reason | VIS-1 | `Scripts/lint-bans.sh --part 4` |
| `unchecked-sendable.md` | Every `@unchecked Sendable` type, with its threading contract | §9.2 | `Scripts/lint-bans.sh --part 4` |
| `shader-coverage.md` | Every shader function and the test that covers it | COV-4 (a) | `Scripts/lint-bans.sh --part 4` |
| `templates/` | Brief, ledger row, verifier report, change request, stability note | §11, NUMS-2 | people and agents |

The registers start empty. A register row is data: the scripts match it against the code in both
directions, so a use without a row fails and a row without a use fails.

Stability notes live in `Docs/Numerics/<row>.md` (NUMS-2); their template is here.
