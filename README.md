# Coverage-Driven Block Verification of a 16×8 Synchronous FIFO

Class-based, layered SystemVerilog testbench with constrained-random stimulus, a cycle-accurate
scoreboard, functional coverage and SVA assertions for a 16-deep, 8-bit synchronous FIFO.

> The testbench follows the layered, UVM-style architecture (transaction / generator / driver /
> monitor / scoreboard / environment), built with plain SystemVerilog classes, mailboxes and
> events. It does **not** use the UVM library.

## Results (single regression run)

| Metric | Value |
|---|---|
| Randomized transactions | 1,640 (1,645 monitored cycles incl. trailing idle) |
| Accepted writes / reads | 581 / 479 |
| Writes blocked (full) / reads blocked (empty) | 334 / 86 |
| Resets applied | 14 |
| Data comparisons | 479 |
| Flag comparisons (full + empty) | 3,290 |
| Scoreboard mismatches | 0 |
| SVA assertion failures | 0 (7 assertions) |
| Functional coverage | 100% (operation × occupancy covergroup), 100% (reset covergroup) |

## Architecture

- **transaction** : randomized operation (idle / write / read / simultaneous), data, reset request;
  weights are set per stimulus phase.
- **generator** : phased stimulus (fill, drain, balanced, simultaneous, fill/drain bursts,
  reset near full, reset at random occupancy).
- **driver** : one transaction per clock through a virtual interface.
- **monitor** : samples DUT pins on every clock edge, new object per sample.
- **scoreboard** : queue-based reference model; checks read data and the full/empty flags on
  every cycle; hosts the covergroups.
- **interface** : 7 SVA assertions (flag exclusivity, reset, overflow/underflow protection,
  flag stability).

## Functional coverage

`cg_ops`: operation, occupancy level, full/empty transitions, every write and read pointer
value (wrap-around), data corner values, and the cross of operation × occupancy
(write-while-full, read-while-empty, simultaneous at full/empty). `cg_reset`: reset at
empty / partial / full.

## Repository layout

```
rtl/design.sv                DUT + interface with SVA
tb/testbench.sv              class-based testbench
docs/fifo_test_plan.md       scenarios, checks, coverage mapping
```

## How to run

Needs a simulator with SystemVerilog class, covergroup and assertion support
(developed and run on Siemens Questa). Typical flow:

```
vlog -sv rtl/design.sv tb/testbench.sv
vsim -c work.tb -do "run -all; quit -f"
```

The summary block is printed at the end of the run. Search the log for `[SVA]` to see assertion
failures.

## Observation

When `wr` and `rd` are asserted in the same cycle and the FIFO is not full, the DUT performs
the write and drops the read (write has priority). The reference model mirrors this behavior;
see the open question in the test plan.

## License

MIT
