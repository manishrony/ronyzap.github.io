# Return/dispute case: original Mitac motherboard — pending repair outcome

Host: zappa2. This case is **contingent and not yet active** — it only
applies if the originally-repaired Mitac board comes back from repair and
still shows the same fault signature documented in
`TROUBLESHOOTING-PCIE-SERR.md` and `CASE-CPU-RETURN-EPYC9B14.md`. This file
exists so the reasoning is written down ahead of that board's return,
rather than reconstructed from memory afterward.

Status: **repaired board not yet back in hand.** This is a pre-built case,
to be completed or discarded once the board returns and is tested.

---

## Why a motherboard case even though the CPU is the current leading suspect

The CPU case (`CASE-CPU-RETURN-EPYC9B14.md`) argues the CPU is the constant
across 3 boards and therefore the likely fault. That argument has one
structural weakness worth stating plainly: **it assumes the same physical
CPU was moved across all three boards without itself degrading further from
repeated reseating, and it assumes no board has an independent, coincidental
fault of its own.** Two used/repaired boards both having a latent defect is
unlikely but not impossible — this file tracks that alternative so a
motherboard return isn't left unargued if the evidence ends up pointing
back at the boards after all.

This board (the original Mitac, currently away for repair) is a **separate
unit** from boards #2 (TYAN S8056GME) and #3 referenced in the other case
files. If it returns and reproduces the fault with the CPU installed, that
is a point *against* the CPU and *for* a board-side or socket-side cause
common to multiple boards (e.g. a systemic seating/torque issue, or a
supplier batch issue across the boards used so far).

---

## The decisive test, once the board is back

| Outcome after reinstalling repaired Mitac board | Interpretation |
|---|---|
| Fault **recurs** with the same CPU installed | Strengthens the **CPU** case (now 4 boards, 1 CPU, same fault) — do **not** file a motherboard return; add this as evidence to `CASE-CPU-RETURN-EPYC9B14.md` instead |
| Fault **does not recur** | Weakens the CPU case. Re-open the question of whether boards #2/#3 specifically were the defective units, and whether the Mitac repair fixed something boards #2/#3 never had wrong with them in the first place |
| Fault recurs **but with a different signature** (different root port, different error class) | Treat as a new, independent issue — do not conflate with the existing SERR/hang case |

This test only produces a clean answer if **only the board changes** —
reuse the same CPU, same NVMe drive, same seating/torque procedure
documented in `TROUBLESHOOTING-PCIE-SERR.md`'s rebuild checklist. Changing
more than one variable at reinstall makes the result uninterpretable, same
caution as documented for the board #2→#3 swap.

---

## What would make a motherboard-return case credible

If filed, the case would need:

1. **Confirmation the repair ticket addressed something plausibly related**
   (PCIe root complex, socket, VRM) rather than an unrelated fault — get the
   repair facility's write-up of what was found/fixed before assuming
   relevance either way.
2. **The decisive-test outcome above**, run with CPU and drive held
   constant.
3. **Cross-reference against the CPU case** — if the fault recurs on *this*
   board too, that is actually evidence for the CPU case, not this one, and
   this file should be closed rather than filed.

## Evidence to attach, if filed

- Repair facility's diagnosis/work order for the Mitac board
- Post-reinstall `diagnostics` output and BMC SEL export, same format as
  used in `CASE-CPU-RETURN-EPYC9B14.md`
- `TROUBLESHOOTING-PCIE-SERR.md` for full background
- Explicit note of which CPU and drive were installed during the test (to
  preempt the "you changed multiple things" objection)

## Open items

- [ ] Get status/ETA on the Mitac repair
- [ ] When it arrives: reinstall with the **same CPU and NVMe**, run the
      rebuild checklist from `TROUBLESHOOTING-PCIE-SERR.md`
- [ ] Capture AER baseline immediately after first boot (same method as
      the 2026-09-21 board #2 baseline) for direct comparison
- [ ] Decide outcome per the decision table above; either complete this
      case for filing, or close it and fold the result into the CPU case
