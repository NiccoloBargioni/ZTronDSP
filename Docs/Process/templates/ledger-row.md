# Ledger row

One row of `Docs/Process/ledger.md`. The first five columns come from §12 and are re-derived by
`Scripts/ledger.sh --update`; the integrator fills in the rest.

| Column | Content | Rule |
|---|---|---|
| ID | `WP-nnn`, or `WP-nnnx` for a part | §12, §11.7 |
| Package | The "Package" cell of §12 | §12 |
| Deps | The "Dep" cell of §12 | WP-R4 |
| Lenses | The two lenses the package is verified through | VER-1 |
| Tag | `ALG`, `OPT` or empty | WP-R5 |
| Status | `Ready`, `Blocked-on-deps`, `Awaiting-trigger` (computed); `Implementing`, `Verifying`, `Fixing`, `Done`, `Paused`, `Escalated`, `Retired` | §11.3 |
| Implementer | Who built the package | §11.1 |
| Verifier A | Who verified it through the first lens | §11.1, VER-1 |
| Verifier B | Who verified it through the second lens; not the same actor as any other role on this package | §11.1, VER-2 |
| Time (min) | Implementation time, against the 30-minute box | WP-R1 |
| Revision | The revision on which both lenses reported zero blocking findings | FIX-2 |
| Report A | `reports/WP-nnn-A.md` | VER-4 |
| Report B | `reports/WP-nnn-B.md` | VER-4 |
| Fix cycles | 0 to 3; there is no fourth | FIX-3 |
| Currency check | `ALG`: the date and outcome of the check of §7.3; otherwise `n/a` | WP-R5, §7.3 |
| Stability note | `ALG`: `Docs/Numerics/<row>.md`; otherwise `n/a` | NUMS-2 |
| Backlog | Non-blocking findings with their owner, or `none` | §11.6 |

## Definition of done (§11.8)

A package is `Done` when all six hold, and the integrator has checked items 1 to 4 and 6:

1. The acceptance checks of §12 pass on the simulator matrix, or in the device lab for a package that §12 marks as a device run.
2. Every CI gate of §10.3 that the package can affect passes.
3. COV-3 holds: the files the package adds or changes are at 97.5 % or above.
4. Public symbols have documentation comments with their threading contract (VIS-2); a package that adds a stage has met STG-1.
5. Zero blocking findings from both lenses on the same revision.
6. This row is complete.

## Side states

| State | Entered when | What is recorded |
|---|---|---|
| `Paused` | A verifier files a change request against the specification (FIX-4) | The change request, in Backlog |
| `Escalated` | Three fix cycles did not converge (FIX-3) | The owner's decision: a split or a change request, with every open blocking finding carried into it |
| `Retired` | The package was replaced by its parts (§11.7) | The change request of the split; the parts follow as rows of their own |
