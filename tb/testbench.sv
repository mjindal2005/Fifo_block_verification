// ============================================================
// testbench.sv : class-based layered testbench for the 16x8 FIFO
//
// Upgrades over the original:
//   1. Cycle-accurate monitor/driver (one transaction per clock)
//   2. Scoreboard checks DATA and the FULL/EMPTY FLAGS every cycle
//   3. Full-range randomized data (corner values weighted)
//   4. Phased, weighted stimulus (fill, drain, balanced, simultaneous,
//      reset) so FULL and EMPTY are actually reached
//   5. Functional coverage (covergroups) + coverage report
//   6. SVA assertions live in the interface (design.sv)
//   7. Fresh transaction object for every sample (no handle reuse)
//
// Needs a simulator with class + covergroup support
// (EDA Playground: Aldec Riviera Pro, Siemens Questa, or Synopsys VCS).
// Icarus Verilog will NOT work.
// ============================================================

typedef enum bit [1:0] {IDLE = 2'd0, WRITE = 2'd1, READ = 2'd2, BOTH = 2'd3} op_e;

///////////////////////////////////////////////////
// TRANSACTION
///////////////////////////////////////////////////
class transaction;

  // ---- stimulus (randomized) ----
  rand op_e       op;
  rand bit [7:0]  data;
  rand bit        rst_req;

  // ---- weight knobs set by the generator for each phase ----
  int unsigned w_wr = 25, w_rd = 25, w_both = 25, w_idle = 25, w_rst = 0;

  // ---- values sampled by the monitor ----
  bit        rst, wr, rd, full, empty;
  bit [7:0]  data_in, data_out;

  constraint c_op   { op dist {WRITE := w_wr, READ := w_rd, BOTH := w_both, IDLE := w_idle}; }
  constraint c_rst  { rst_req dist {1'b1 := w_rst, 1'b0 := (100 - w_rst)}; }
  constraint c_data { data dist {8'h00 := 5, 8'hFF := 5, [8'h01:8'hFE] :/ 90}; }

endclass

///////////////////////////////////////////////////
// GENERATOR : phased, weighted constrained-random stimulus
///////////////////////////////////////////////////
class generator;

  mailbox #(transaction) mbx;
  int total    = 0;
  bit finished = 0;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task phase(string name, int n, int wr, int rd, int both, int idle, int rstw = 0);
    transaction tr;
    $display("[GEN] Phase %-16s : %0d transactions (wr=%0d rd=%0d both=%0d idle=%0d rst=%0d%%)",
             name, n, wr, rd, both, idle, rstw);
    repeat (n) begin
      tr = new();
      tr.w_wr = wr; tr.w_rd = rd; tr.w_both = both; tr.w_idle = idle; tr.w_rst = rstw;
      if (!tr.randomize()) $error("[GEN] Randomization failed");
      mbx.put(tr);
      total++;
    end
  endtask

  task run();
    phase("FILL",            60, 70, 10,  5, 15);   // drive to FULL, keep writing (overflow)
    phase("DRAIN",           60, 10, 70,  5, 15);   // drive to EMPTY, keep reading (underflow)
    phase("BALANCED",       500, 25, 25, 25, 25);   // general mix, pointer wrap-around
    phase("SIMULTANEOUS",   200, 10, 10, 70, 10);   // wr + rd in the same cycle
    repeat (4) begin
      phase("FILL_BURST",    40, 80,  5,  5, 10);   // full <-> empty sweeps
      phase("DRAIN_BURST",   40,  5, 80,  5, 10);
    end
    phase("RESET_NEAR_FULL", 200, 70, 10,  5, 15, 2); // reset while full / nearly full
    phase("RESET_RANDOM",    300, 30, 30, 20, 20, 3); // reset at random occupancy
    finished = 1;
  endtask

endclass

///////////////////////////////////////////////////
// DRIVER : drives exactly one transaction per clock
///////////////////////////////////////////////////
class driver;

  virtual fifo_if fif;
  mailbox #(transaction) mbx;
  transaction tr;
  int sent = 0;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task reset();
    fif.rst     <= 1'b1;
    fif.rd      <= 1'b0;
    fif.wr      <= 1'b0;
    fif.data_in <= 8'h00;
    repeat (5) @(posedge fif.clock);
    fif.rst     <= 1'b0;
    $display("[DRV] DUT reset done");
    $display("------------------------------------------");
  endtask

  task run();
    forever begin
      @(posedge fif.clock);
      if (mbx.try_get(tr)) begin
        fif.rst     <= tr.rst_req;
        fif.wr      <= (tr.op == WRITE || tr.op == BOTH);
        fif.rd      <= (tr.op == READ  || tr.op == BOTH);
        fif.data_in <= tr.data;
        sent++;
      end
      else begin                       // nothing left: drive idle
        fif.rst <= 1'b0;
        fif.wr  <= 1'b0;
        fif.rd  <= 1'b0;
      end
    end
  endtask

endclass

///////////////////////////////////////////////////
// MONITOR : samples the DUT pins on every clock edge
// (values seen at the edge are the pre-edge values, i.e. exactly
//  what the DUT sees at that edge; data_out shows the result of
//  the PREVIOUS edge's read)
///////////////////////////////////////////////////
class monitor;

  virtual fifo_if fif;
  mailbox #(transaction) mbx;
  transaction tr;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task run();
    forever begin
      @(posedge fif.clock);
      tr = new();                       // new object every sample
      tr.rst      = fif.rst;
      tr.wr       = fif.wr;
      tr.rd       = fif.rd;
      tr.data_in  = fif.data_in;
      tr.full     = fif.full;
      tr.empty    = fif.empty;
      tr.data_out = fif.data_out;
      mbx.put(tr);
    end
  endtask

endclass

///////////////////////////////////////////////////
// SCOREBOARD : reference model + data/flag checks + functional coverage
///////////////////////////////////////////////////
class scoreboard;

  mailbox #(transaction) mbx;
  transaction tr;

  // ---- reference model ----
  bit [7:0] q[$];
  bit [3:0] m_wptr = 0, m_rptr = 0;
  bit       exp_valid = 0;
  bit [7:0] exp_data;
  bit       exp_full, exp_empty;
  int       lvl;

  // ---- statistics ----
  int err = 0;
  int cycles = 0, data_checks = 0, flag_checks = 0;
  int eff_wr = 0, eff_rd = 0, wr_blocked = 0, rd_blocked = 0, rd_ignored = 0, resets = 0;

  // ---- coverage sample variables ----
  bit [1:0] cov_op;
  int       cov_level;
  bit [3:0] cov_wptr, cov_rptr;
  bit [7:0] cov_wdata;
  bit       cov_wr_eff, cov_rd_eff;

  covergroup cg_ops;
    option.per_instance = 1;

    cp_op : coverpoint cov_op {
      bins idle    = {2'b00};
      bins wr_only = {2'b01};
      bins rd_only = {2'b10};
      bins both    = {2'b11};
    }
    cp_level : coverpoint cov_level {
      bins empty = {0};
      bins low   = {[1:4]};
      bins mid   = {[5:11]};
      bins high  = {[12:15]};
      bins full  = {16};
    }
    cp_trans : coverpoint cov_level {
      bins empty_to_one   = (0  => 1);
      bins one_to_empty   = (1  => 0);
      bins fifteen_to_full = (15 => 16);
      bins full_to_fifteen = (16 => 15);
    }
    cp_wptr : coverpoint cov_wptr iff (cov_wr_eff) { bins p[] = {[0:15]}; }
    cp_rptr : coverpoint cov_rptr iff (cov_rd_eff) { bins p[] = {[0:15]}; }
    cp_wdata : coverpoint cov_wdata iff (cov_wr_eff) {
      bins zero  = {8'h00};
      bins ones  = {8'hFF};
      bins other = {[8'h01:8'hFE]};
    }
    // wr-while-full, rd-while-empty, wr+rd at full/empty, etc.
    x_op_level : cross cp_op, cp_level;
  endgroup

  covergroup cg_rst;
    option.per_instance = 1;
    cp_rst_level : coverpoint cov_level {
      bins empty   = {0};
      bins partial = {[1:15]};
      bins full    = {16};
    }
  endgroup

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
    cg_ops = new();
    cg_rst = new();
  endfunction

  task run();
    forever begin
      mbx.get(tr);
      cycles++;
      lvl = q.size();

      // ---- 1. read data produced by the previous edge ----
      if (exp_valid) begin
        data_checks++;
        if (tr.data_out !== exp_data) begin
          err++;
          $error("[SCO] DATA MISMATCH exp=%0d got=%0d", exp_data, tr.data_out);
        end
      end
      exp_valid = 0;

      // ---- 2. flag check against the model (pre-edge state) ----
      exp_full  = (lvl == 16);
      exp_empty = (lvl == 0);
      flag_checks++;
      if (tr.full !== exp_full) begin
        err++;
        $error("[SCO] FULL FLAG MISMATCH exp=%0b got=%0b (model level=%0d)", exp_full, tr.full, lvl);
      end
      if (tr.empty !== exp_empty) begin
        err++;
        $error("[SCO] EMPTY FLAG MISMATCH exp=%0b got=%0b (model level=%0d)", exp_empty, tr.empty, lvl);
      end

      // ---- 3. functional coverage sample (pre-update state) ----
      cov_op     = {tr.rd, tr.wr};
      cov_level  = lvl;
      cov_wptr   = m_wptr;
      cov_rptr   = m_rptr;
      cov_wdata  = tr.data_in;
      cov_wr_eff = (!tr.rst && tr.wr && lvl < 16);
      cov_rd_eff = (!tr.rst && !cov_wr_eff && tr.rd && lvl > 0);
      if (tr.rst) cg_rst.sample();
      else        cg_ops.sample();

      // ---- 4. update reference model (mirrors DUT priority: rst > wr > rd) ----
      if (tr.rst) begin
        q.delete();
        m_wptr = 0;
        m_rptr = 0;
        resets++;
      end
      else begin
        if (tr.wr && lvl == 16) wr_blocked++;
        if (tr.rd && lvl == 0)  rd_blocked++;

        if (tr.wr && lvl < 16) begin
          q.push_back(tr.data_in);
          m_wptr++;
          eff_wr++;
          if (tr.rd) rd_ignored++;     // simultaneous wr+rd: DUT drops the read
        end
        else if (tr.rd && lvl > 0) begin
          exp_data  = q.pop_front();
          exp_valid = 1;
          m_rptr++;
          eff_rd++;
        end
      end
    end
  endtask

  function void report();
    $display("");
    $display("================ FIFO VERIFICATION SUMMARY ================");
    $display(" Cycles monitored                  : %0d", cycles);
    $display(" Accepted writes / reads           : %0d / %0d", eff_wr, eff_rd);
    $display(" Writes blocked (FIFO full)        : %0d", wr_blocked);
    $display(" Reads blocked (FIFO empty)        : %0d", rd_blocked);
    $display(" Resets applied                    : %0d", resets);
    $display(" Simultaneous wr+rd, read ignored  : %0d", rd_ignored);
    $display(" Data comparisons                  : %0d", data_checks);
    $display(" Flag comparisons (full+empty)     : %0d", flag_checks * 2);
    $display(" Scoreboard errors                 : %0d", err);
    $display(" Functional coverage (ops/level)   : %0.2f %%", cg_ops.get_inst_coverage());
    $display(" Functional coverage (reset)       : %0.2f %%", cg_rst.get_inst_coverage());
    if (err == 0) $display(" RESULT : TEST PASSED (scoreboard); check log for [SVA] errors");
    else          $display(" RESULT : TEST FAILED");
    $display("===========================================================");
  endfunction

endclass

///////////////////////////////////////////////////
// ENVIRONMENT
///////////////////////////////////////////////////
class environment;

  generator  gen;
  driver     drv;
  monitor    mon;
  scoreboard sco;
  mailbox #(transaction) gdmbx;   // generator -> driver
  mailbox #(transaction) msmbx;   // monitor   -> scoreboard
  virtual fifo_if fif;

  function new(virtual fifo_if fif);
    this.fif = fif;
    gdmbx = new();
    msmbx = new();
    gen = new(gdmbx);
    drv = new(gdmbx);
    mon = new(msmbx);
    sco = new(msmbx);
    drv.fif = fif;
    mon.fif = fif;
  endfunction

  task pre_test();
    drv.reset();
  endtask

  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_none
  endtask

  task post_test();
    wait (gen.finished);
    wait (drv.sent == gen.total);
    repeat (6) @(posedge fif.clock);   // let the last ops drain through monitor/scoreboard
    sco.report();
    $finish;
  endtask

  task run();
    pre_test();
    test();
    post_test();
  endtask

endclass

///////////////////////////////////////////////////
// TOP
///////////////////////////////////////////////////
module tb;

  fifo_if fif();

  FIFO dut (.clk(fif.clock), .rst(fif.rst), .wr(fif.wr), .rd(fif.rd),
            .din(fif.data_in), .dout(fif.data_out),
            .empty(fif.empty), .full(fif.full));

  initial fif.clock = 0;
  always #10 fif.clock = ~fif.clock;

  environment env;

  initial begin
    env = new(fif);
    env.run();
  end

  // watchdog
  initial begin
    #5_000_000;
    $error("[TB] Watchdog timeout");
    $finish;
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end

endmodule
