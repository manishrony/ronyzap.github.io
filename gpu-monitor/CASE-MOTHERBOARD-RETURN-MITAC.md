# Mitac motherboard — decision record (not a dispute case)

Host: zappa2. **Decided 2026-10-01: this board will not be reinstalled or
used as the decisive test.** Board #3 stays in production, and the CPU
swap test (see `CASE-CPU-RETURN-EPYC9B14.md`) is being run there instead.
When the repaired Mitac board returns from RMA, it is being kept as a
**cold spare**, not redeployed or disputed further. No motherboard
return/dispute is being filed against it.

This file is kept, unfiled, for two reasons: (1) the reasoning below for
why a board-side cause couldn't be fully ruled out is still valid
background if the CPU swap test comes back inconclusive, and (2) it
documents *why* no action is being taken on this board, so that isn't lost
later. If the CPU swap test clears the CPU (fault persists on board #3
with the new CPU), this board becomes a candidate to re-open as an actual
test unit — see "If this needs to be revisited" at the bottom.

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

## If this needs to be revisited

The CPU swap test on board #3 (`CASE-CPU-RETURN-EPYC9B14.md`) is the
decisive test now — not this board. But if that test's outcome is
**"fault persists on the new CPU,"** the CPU is cleared and the Mitac
board (sitting as a cold spare) becomes the next useful experiment: install
the *new, known-good* CPU and the same NVMe into the Mitac board and see if
the fault follows the rig (PSU/cabling/rack) or stays with board #3.

| If CPU swap test shows... | What to do with the Mitac spare |
|---|---|
| Fault clears on board #3 with new CPU | **CPU confirmed.** Mitac board stays a cold spare, untouched — no need to test it. |
| Fault persists on board #3 with new CPU | CPU cleared. Install the new CPU into the Mitac board as the next isolation step — see the original decision table preserved below. |

This test only produces a clean answer if **only the board changes** —
reuse the same (by then confirmed-good) CPU, same NVMe drive, same
seating/torque procedure documented in `TROUBLESHOOTING-PCIE-SERR.md`'s
rebuild checklist. Changing more than one variable at reinstall makes the
result uninterpretable, same caution as documented for the board #2→#3
swap.

**Original decision table (preserved for reference, not currently in use):**

| Outcome after reinstalling repaired Mitac board | Interpretation |
|---|---|
| Fault **recurs** with the same CPU installed | Strengthens the **CPU** case (now 4 boards, 1 CPU, same fault) — do **not** file a motherboard return; add this as evidence to `CASE-CPU-RETURN-EPYC9B14.md` instead |
| Fault **does not recur** | Weakens the CPU case. Re-open the question of whether boards #2/#3 specifically were the defective units, and whether the Mitac repair fixed something boards #2/#3 never had wrong with them in the first place |
| Fault recurs **but with a different signature** (different root port, different error class) | Treat as a new, independent issue — do not conflate with the existing SERR/hang case |

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

- [x] ~~Get status/ETA on the Mitac repair~~ — decided 2026-10-01: when it
      returns, it goes into inventory as a cold spare, not back into
      zappa2
- [ ] When it arrives: inspect/confirm repair facility's work order for the
      record, then shelve it — **no reinstall unless** the CPU swap test
      comes back "fault persists" (see table above)
- [ ] If the CPU swap test does come back inconclusive/negative, revisit
      this file and run the Mitac-board isolation test with the
      confirmed-good CPU
