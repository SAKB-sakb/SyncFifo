// =============================================================================
// TbSyncFifo.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for SyncFifo.
//
// A SystemVerilog queue acts as the reference model. Every cycle the bench
//   1. checks Count / Full / Empty / ThresholdMet / SReady / MValid against
//      the model,
//   2. drives new inputs,
//   3. notes which writes and reads will happen on the next rising edge and
//      compares every word read out of the FIFO with the model.
//
// Inputs are driven on the falling edge so they never race the DUT.
// The write side follows the valid/ready rule: once SValid goes high it stays
// high, with the same data, until the word is accepted.
// =============================================================================

`timescale 1ns/1ps

module TbSyncFifo;

  // ---------------------------------------------------------------------------
  // Parameters (override from the Makefile)
  // ---------------------------------------------------------------------------
  parameter  int unsigned SAKB_DATA_W        = 8;
  parameter  int unsigned SAKB_DEPTH         = 16;
  parameter  int unsigned SAKB_THRESHOLD     = 12;
  parameter  bit          SAKB_OUT_REG       = 1'b0;
  parameter  int unsigned SAKB_RANDOM_CYCLES = 4000;

  localparam int unsigned SAKB_CNT_W = $clog2(SAKB_DEPTH + 1);

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic                   Clk = 1'b0;
  logic                   RstN;
  logic                   SValid;
  logic                   SReady;
  logic [SAKB_DATA_W-1:0] SData;
  logic                   MValid;
  logic                   MReady;
  logic [SAKB_DATA_W-1:0] MData;
  logic [SAKB_CNT_W-1:0]  Count;
  logic                   Full;
  logic                   Empty;
  logic                   ThresholdMet;

  SyncFifo #(
    .SAKB_DATA_W    (SAKB_DATA_W),
    .SAKB_DEPTH     (SAKB_DEPTH),
    .SAKB_THRESHOLD (SAKB_THRESHOLD),
    .SAKB_OUT_REG   (SAKB_OUT_REG)
  ) Dut (.*);

  // 10 ns clock period.
  always #5 Clk = ~Clk;

  // ---------------------------------------------------------------------------
  // Reference model and statistics
  // ---------------------------------------------------------------------------
  logic [SAKB_DATA_W-1:0] Model [$];
  bit                     WrPending;     // SValid is high but not accepted yet

  int unsigned ErrorCount     = 0;
  int unsigned NumWrites      = 0;
  int unsigned NumReads       = 0;
  int unsigned NumFullCycles  = 0;
  int unsigned NumThreshRises = 0;
  int unsigned NumSameCycle   = 0;
  bit          PrevThresh     = 1'b0;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic Fail(input string Msg);
    ErrorCount++;
    $display("[%0t] ERROR: %s", $time, Msg);
  endtask

  // Compare every status output with what the model says it should be.
  // Also count how often Full and a rising ThresholdMet were seen.
  task automatic CheckStatus();
    int unsigned Size;
    Size = Model.size();

    if (Count !== SAKB_CNT_W'(Size))
      Fail($sformatf("Count = %0d, expected %0d", Count, Size));
    if (Full !== (Size == SAKB_DEPTH))
      Fail($sformatf("Full = %b with %0d words", Full, Size));
    if (Empty !== (Size == 0))
      Fail($sformatf("Empty = %b with %0d words", Empty, Size));
    if (ThresholdMet !== (Size >= SAKB_THRESHOLD))
      Fail($sformatf("ThresholdMet = %b with %0d words (SAKB_THRESHOLD=%0d)",
                     ThresholdMet, Size, SAKB_THRESHOLD));
    if (SReady !== (Size != SAKB_DEPTH))
      Fail($sformatf("SReady = %b with %0d words", SReady, Size));
    if (MValid !== (Size != 0))
      Fail($sformatf("MValid = %b with %0d words", MValid, Size));

    if (Full)                         NumFullCycles++;
    if (ThresholdMet && !PrevThresh)  NumThreshRises++;
    PrevThresh = ThresholdMet;
  endtask

  // Run one clock cycle: check, drive new inputs, then update the model with
  // whatever is about to be written or read. Starts and ends on a falling edge.
  task automatic Step(input bit WantWrite, input bit WantRead);
    logic [SAKB_DATA_W-1:0] Expected;
    bit                     DidPush;
    bit                     DidPop;

    CheckStatus();

    // Only change the write inputs if no earlier word is still waiting.
    if (!WrPending) begin
      SValid = WantWrite;
      SData  = SAKB_DATA_W'($urandom);
    end
    MReady = WantRead;

    #1;  // let the outputs settle

    DidPop  = MValid && MReady;
    DidPush = SValid && SReady;

    if (DidPop) begin
      Expected = Model.pop_front();
      if (MData !== Expected)
        Fail($sformatf("read 0x%0h, expected 0x%0h", MData, Expected));
      NumReads++;
    end

    if (DidPush) begin
      Model.push_back(SData);
      NumWrites++;
    end

    if (DidPush && DidPop) NumSameCycle++;
    WrPending = SValid && !SReady;

    @(negedge Clk);
  endtask

  // Hold reset low for a few cycles and clear the model to match.
  // All inputs go idle so nothing is written while reset is active.
  task automatic ApplyReset(input int unsigned Cycles);
    RstN      = 1'b0;
    SValid    = 1'b0;
    MReady    = 1'b0;
    SData     = '0;
    WrPending = 1'b0;
    Model.delete();
    repeat (Cycles) @(negedge Clk);
    RstN = 1'b1;
  endtask

  // Keep reading until the FIFO is empty and no write is still waiting.
  task automatic Drain();
    while (Model.size() != 0 || WrPending)
      Step(1'b0, 1'b1);
  endtask

  // Random traffic: each side is active with the given chance (in percent).
  task automatic RandomTraffic(input int unsigned Cycles,
                               input int unsigned WrPct,
                               input int unsigned RdPct);
    repeat (Cycles)
      Step(($urandom % 100) < WrPct, ($urandom % 100) < RdPct);
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
`ifdef DUMP
    $dumpfile("SyncFifo.vcd");
    $dumpvars(0, TbSyncFifo);
`endif

    $display("------------------------------------------------------------");
    $display(" SyncFifo test: DATA_W=%0d DEPTH=%0d THRESHOLD=%0d OUT_REG=%0d",
             SAKB_DATA_W, SAKB_DEPTH, SAKB_THRESHOLD, SAKB_OUT_REG);
    $display("------------------------------------------------------------");

    @(negedge Clk);
    ApplyReset(3);

    // 1. Write until full, then try one more write that must be refused.
    //    The flags are checked on every cycle along the way.
    $display("[1] fill to full");
    repeat (SAKB_DEPTH + 1) Step(1'b1, 1'b0);
    if (!Full) Fail("FIFO not full after SAKB_DEPTH writes");

    // 2. Read everything back out. The refused word from step 1 gets in as
    //    soon as there is room, so it is drained too.
    $display("[2] drain to empty");
    Drain();
    Step(1'b0, 1'b0);
    if (!Empty) Fail("FIFO not empty after drain");

    // 3. Half fill the FIFO, then write and read every cycle.
    //    The fill level should stay put while data keeps flowing through.
    $display("[3] simultaneous read/write");
    repeat (SAKB_DEPTH / 2) Step(1'b1, 1'b0);
    repeat (100)            Step(1'b1, 1'b1);
    Drain();

    // 4. Random traffic with different mixes of writes and reads, so the FIFO
    //    spends time near full, near empty, and streaming at full speed.
    $display("[4] random traffic");
    RandomTraffic(SAKB_RANDOM_CYCLES / 4, 50, 50);
    RandomTraffic(SAKB_RANDOM_CYCLES / 4, 90, 30);
    RandomTraffic(SAKB_RANDOM_CYCLES / 4, 30, 90);
    RandomTraffic(SAKB_RANDOM_CYCLES / 4, 100, 100);
    Drain();

    // 5. Reset while the FIFO still holds data, check it comes back empty,
    //    then make sure it works normally afterwards.
    $display("[5] reset with data inside");
    repeat (SAKB_DEPTH - 1) Step(1'b1, 1'b0);
    ApplyReset(2);
    Step(1'b0, 1'b0);
    if (!Empty) Fail("FIFO not empty after mid-test reset");
    RandomTraffic(200, 60, 60);
    Drain();
    Step(1'b0, 1'b0);

    // Fail the test if the interesting cases never happened, because then
    // a pass would not prove much.
    if (NumFullCycles  == 0) Fail("Full was never reached");
    if (NumThreshRises == 0) Fail("ThresholdMet never rose");
    if (NumSameCycle   == 0) Fail("no cycle with a read and a write together");

    $display("------------------------------------------------------------");
    $display(" writes=%0d reads=%0d full-cycles=%0d threshold-rises=%0d same-cycle=%0d",
             NumWrites, NumReads, NumFullCycles, NumThreshRises, NumSameCycle);
    if (ErrorCount == 0) begin
      $display(" TEST PASSED");
      $display("------------------------------------------------------------");
      $finish;
    end else begin
      $display(" TEST FAILED with %0d error(s)", ErrorCount);
      $display("------------------------------------------------------------");
      $fatal(1, "SyncFifo test failed");
    end
  end

  // Stop the simulation if it runs far longer than the test ever should.
  // This catches a hang instead of letting it run forever.
  initial begin
    #(10 * (SAKB_RANDOM_CYCLES + 100 * SAKB_DEPTH + 2000) * 10);
    $fatal(1, "Timeout");
  end

endmodule
