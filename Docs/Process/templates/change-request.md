# CR-nnn — title

File as `Docs/Process/changes/CR-nnn.md`. Any deviation from the specification is a change
request, approved by the owner before code that relies on it merges (§11.9).

| Field | Value |
|---|---|
| Status | Proposed |
| Kind | Deviation · Split (§11.7) · Escalation (FIX-3) · Approval-gated API (APR-2) · Tolerance (STG-2) · Algorithm (§7.3) · Specification defect (FIX-4) |
| Raised by | Role and package: implementer, verifier A or B, integrator; WP-nnn |
| Raised on | YYYY-MM-DD |
| Packages paused | WP-nnn, … (FIX-4) |
| Approved by | |
| Approved on | |

`Status` is `Proposed`, `Approved`, `Rejected` or `Withdrawn`. Only the owner sets `Approved`,
with a name and a date; the lint accepts an entry of `Docs/Process/approvals.md` only when its
change request reads `Approved` here (APR-2).

## What

## Why

## Evidence

Measurements, probes, compiler output. For a tolerance: the measured error (STG-2). For an
algorithm: the superseding method and where it was published (§7.3).

## Sections affected

## For a split (§11.7)

The parts, each with two lenses, and the partition of the original acceptance: every check of
the original row appears in exactly one part, unchanged.

| Part | Acceptance checks it takes | Lenses |
|---|---|---|

## Open blocking findings carried (FIX-3)

Neither a split nor a change request closes a finding. Each open blocking finding, and the part
or change in which it will be verified:

| Finding | Carried into |
|---|---|

## Owner's decision

Approved, rejected or returned, with conditions if any.
