// ============================================================
// design.sv : 16x8 synchronous FIFO (your original DUT, unchanged)
//             + interface with SVA assertions (new)
// ============================================================

module FIFO(input clk, rst, wr, rd,
            input [7:0] din, output reg [7:0] dout,
            output empty, full);

  // Pointers for write and read operations
  reg [3:0] wptr = 0, rptr = 0;

  // Counter for tracking the number of elements in the FIFO
  reg [4:0] cnt = 0;

  // Memory array to store data
  reg [7:0] mem [15:0];

  always @(posedge clk)
  begin
    if (rst == 1'b1)
      begin
        wptr <= 0;
        rptr <= 0;
        cnt  <= 0;
      end
    else if (wr && !full)
      begin
        mem[wptr] <= din;
        wptr      <= wptr + 1;
        cnt       <= cnt + 1;
      end
    else if (rd && !empty)
      begin
        dout <= mem[rptr];
        rptr <= rptr + 1;
        cnt  <= cnt - 1;
      end
  end

  assign empty = (cnt == 0) ? 1'b1 : 1'b0;
  assign full  = (cnt == 16) ? 1'b1 : 1'b0;

endmodule

//////////////////////////////////////

interface fifo_if;

  logic clock, rd, wr;
  logic full, empty;
  logic [7:0] data_in;
  logic [7:0] data_out;
  logic rst;

  // ----------------------------------------------------------
  // SVA assertions (7). All sample on posedge clock.
  // NOTE: rst is tested as a SAMPLED value in each antecedent. Do not use
  // 'disable iff (rst)' here: rst is driven with a non-blocking assignment at
  // the clock edge, so disable iff would see the next cycle's value.
  // ----------------------------------------------------------

  // A1: FIFO can never report full and empty together
  a_not_full_and_empty : assert property (@(posedge clock)
    !(full && empty))
    else $error("[SVA] A1: full and empty asserted together");

  // A2: reset leaves the FIFO empty and not full on the next cycle
  a_reset_clears : assert property (@(posedge clock)
    rst |=> (empty && !full))
    else $error("[SVA] A2: reset did not clear the FIFO");

  // A3: an accepted write means the FIFO is not empty afterwards
  a_write_sets_nonempty : assert property (@(posedge clock)
    (!rst && wr && !full) |=> !empty)
    else $error("[SVA] A3: FIFO empty after an accepted write");

  // A4: an accepted read (no write) means the FIFO is not full afterwards
  a_read_clears_full : assert property (@(posedge clock)
    (!rst && rd && !empty && !wr) |=> !full)
    else $error("[SVA] A4: FIFO still full after an accepted read");

  // A5: write into a full FIFO (no read) must not change the full flag
  a_full_holds : assert property (@(posedge clock)
    (!rst && wr && full && !rd) |=> full)
    else $error("[SVA] A5: overflow changed FIFO state");

  // A6: read from an empty FIFO (no write) must not change the empty flag
  a_empty_holds : assert property (@(posedge clock)
    (!rst && rd && empty && !wr) |=> empty)
    else $error("[SVA] A6: underflow changed FIFO state");

  // A7: flags are stable on idle cycles
  a_idle_flags_stable : assert property (@(posedge clock)
    (!rst && !wr && !rd) |=> ($stable(full) && $stable(empty)))
    else $error("[SVA] A7: flags changed on an idle cycle");

endinterface
