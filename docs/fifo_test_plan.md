# 16x8 Synchronous FIFO: Verification Test Plan

**DUT:** 16-deep, 8-bit synchronous FIFO (counter-based full/empty, registered read data, reset > write > read priority).
**Environment:** class-based layered SystemVerilog testbench (transaction, generator, driver, monitor, scoreboard, environment), SVA in the interface.

## Features and scenarios

| ID | Feature / scenario | Stimulus (generator phase) | Checked by | Coverage item |
|----|--------------------|----------------------------|------------|---------------|
| T1 | Basic write then read, FIFO ordering | BALANCED | Scoreboard data compare | `cp_op`, `cp_wdata` |
| T2 | Fill to full | FILL, FILL_BURST | Scoreboard flag compare, SVA A4 | `cp_level.full`, `cp_trans.fifteen_to_full` |
| T3 | Write while full (overflow protection) | FILL | Scoreboard model, SVA A5 | `x_op_level` (wr_only x full) |
| T4 | Drain to empty | DRAIN, DRAIN_BURST | Scoreboard flag compare, SVA A3 | `cp_level.empty`, `cp_trans.one_to_empty` |
| T5 | Read while empty (underflow protection) | DRAIN | Scoreboard model, SVA A6 | `x_op_level` (rd_only x empty) |
| T6 | Simultaneous write + read | SIMULTANEOUS | Scoreboard model (DUT priority), `rd_ignored` counter | `cp_op.both`, `x_op_level` (both x all levels) |
| T7 | Pointer wrap-around | BALANCED, bursts | Scoreboard data compare | `cp_wptr`, `cp_rptr` (all 16 values) |
| T8 | Data corner values (0x00, 0xFF) | All phases (weighted) | Scoreboard data compare | `cp_wdata` |
| T9 | Reset at empty / partial / full | RESET_NEAR_FULL, RESET_RANDOM | SVA A2, scoreboard flags after reset | `cg_rst.cp_rst_level` |
| T10 | Flags stable and mutually exclusive | All phases | SVA A1, A7 | n/a |

## Assertions (SVA, in `fifo_if`)

| ID | Property |
|----|----------|
| A1 | full and empty never both high |
| A2 | after reset: empty and not full |
| A3 | accepted write, so FIFO not empty next cycle |
| A4 | accepted read (no write), so FIFO not full next cycle |
| A5 | write while full (no read), so stays full |
| A6 | read while empty (no write), so stays empty |
| A7 | no write/read, so flags stable |

## Exit criteria

- Scoreboard errors = 0 and no `[SVA]` errors in the log.
- Functional coverage 100% on `cg_ops` and `cg_rst`, or every uncovered bin documented as unreachable.

## Open question for design owner

When `wr` and `rd` are asserted in the same cycle and the FIFO is not full, the DUT performs the write and silently drops the read. The reference model mirrors this behavior. Confirm whether that matches the spec; if simultaneous operation is required, this is a design bug.
