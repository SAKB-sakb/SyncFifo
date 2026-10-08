// =============================================================================
// SyncFifoSva.sv
// -----------------------------------------------------------------------------
// Assertion checker for SyncFifo. It only looks at the FIFO ports, so it works
// for both read modes. Attach it with SyncFifoBind.sv.
//
// Every property carries its own clock and reset instead of relying on
// `default clocking` / `default disable iff`, so the checker runs on
// simulators with partial SVA support (e.g. Verilator --assert).
// =============================================================================

`timescale 1ns/1ps

module SyncFifoSva #(
  parameter  int unsigned SAKB_DATA_W    = 8,
  parameter  int unsigned SAKB_DEPTH     = 16,
  parameter  int unsigned SAKB_THRESHOLD = (SAKB_DEPTH * 3) / 4,
  localparam int unsigned SAKB_CNT_W     = $clog2(SAKB_DEPTH + 1)
) (
  input logic                   Clk,
  input logic                   RstN,
  input logic                   SValid,
  input logic                   SReady,
  input logic [SAKB_DATA_W-1:0] SData,
  input logic                   MValid,
  input logic                   MReady,
  input logic [SAKB_DATA_W-1:0] MData,
  input logic [SAKB_CNT_W-1:0]  Count,
  input logic                   Full,
  input logic                   Empty,
  input logic                   ThresholdMet
);

  // ---------------------------------------------------------------------------
  // Parameter checks
  // ---------------------------------------------------------------------------
  // Stop the simulation at time 0 if the FIFO was given a size it cannot
  // support. These checks live here so the RTL stays fully synthesizable.
  initial begin
    if (SAKB_DATA_W < 1)
      $fatal(1, "SyncFifo: SAKB_DATA_W must be >= 1 (got %0d)", SAKB_DATA_W);
    if (SAKB_DEPTH < 2)
      $fatal(1, "SyncFifo: SAKB_DEPTH must be >= 2 (got %0d)", SAKB_DEPTH);
    if (SAKB_THRESHOLD < 1 || SAKB_THRESHOLD > SAKB_DEPTH)
      $fatal(1, "SyncFifo: SAKB_THRESHOLD must be in 1..SAKB_DEPTH (got %0d)",
             SAKB_THRESHOLD);
  end

  // A write happens when the writer is valid and the FIFO is ready.
  // A read happens when the FIFO is valid and the reader is ready.
  logic Push, Pop;
  assign Push = SValid & SReady;
  assign Pop  = MValid & MReady;

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------
  // One cycle after reset is seen low, the FIFO must be completely empty.
  // This check is not switched off by reset, because it is about reset.
  AssertResetEmpty: assert property (@(posedge Clk)
    !RstN |=> (Count == '0) && Empty && !MValid && !Full)
    else $error("SVA: FIFO not empty after reset");

  // ---------------------------------------------------------------------------
  // Flags agree with the count
  // ---------------------------------------------------------------------------
  // The count can never go past the depth, and every flag must match the
  // count. Full and Empty can never be high together.
  AssertCountRange: assert property (@(posedge Clk) disable iff (!RstN)
    Count <= SAKB_CNT_W'(SAKB_DEPTH))
    else $error("SVA: Count %0d exceeds SAKB_DEPTH %0d", Count, SAKB_DEPTH);

  AssertFullFlag: assert property (@(posedge Clk) disable iff (!RstN)
    Full == (Count == SAKB_CNT_W'(SAKB_DEPTH)))
    else $error("SVA: Full does not match Count");

  AssertEmptyFlag: assert property (@(posedge Clk) disable iff (!RstN)
    Empty == (Count == '0))
    else $error("SVA: Empty does not match Count");

  AssertNotFullAndEmpty: assert property (@(posedge Clk) disable iff (!RstN)
    !(Full && Empty))
    else $error("SVA: Full and Empty both high");

  // The handshake outputs are just the flags turned around: the FIFO is ready
  // when it is not full and has valid data when it is not empty.
  AssertReadyIsNotFull: assert property (@(posedge Clk) disable iff (!RstN)
    SReady == !Full)
    else $error("SVA: SReady must be the inverse of Full");

  AssertValidIsNotEmpty: assert property (@(posedge Clk) disable iff (!RstN)
    MValid == !Empty)
    else $error("SVA: MValid must be the inverse of Empty");

  // ---------------------------------------------------------------------------
  // Threshold flag
  // ---------------------------------------------------------------------------
  // ThresholdMet must be high exactly when SAKB_THRESHOLD or more words are
  // stored, and must rise in the cycle the count steps up to that level.
  AssertThresholdFlag: assert property (@(posedge Clk) disable iff (!RstN)
    ThresholdMet == (Count >= SAKB_CNT_W'(SAKB_THRESHOLD)))
    else $error("SVA: ThresholdMet wrong (Count=%0d, SAKB_THRESHOLD=%0d)",
                Count, SAKB_THRESHOLD);

  AssertThresholdRise: assert property (@(posedge Clk) disable iff (!RstN)
    (Count == SAKB_CNT_W'(SAKB_THRESHOLD - 1)) && Push && !Pop |=> ThresholdMet)
    else $error("SVA: ThresholdMet did not rise at SAKB_THRESHOLD");

  // ---------------------------------------------------------------------------
  // Count bookkeeping
  // ---------------------------------------------------------------------------
  // Each cycle the count must change by exactly writes minus reads.
  // Skipped on the first cycle after reset, when $past() still sees reset.
  AssertCountUpdate: assert property (@(posedge Clk) disable iff (!RstN)
    $past(RstN) |->
      Count == $past(Count) + SAKB_CNT_W'($past(Push)) - SAKB_CNT_W'($past(Pop)))
    else $error("SVA: Count did not follow writes and reads");

  // Nothing can be written into a full FIFO, and nothing can be read out of
  // an empty one.
  AssertNoPushWhenFull: assert property (@(posedge Clk) disable iff (!RstN)
    Full |-> !Push);

  AssertNoPopWhenEmpty: assert property (@(posedge Clk) disable iff (!RstN)
    Empty |-> !Pop);

  // ---------------------------------------------------------------------------
  // Read-side handshake rule
  // ---------------------------------------------------------------------------
  // Once the FIFO offers a word, it must keep offering that same word until
  // the reader takes it.
  AssertMValidHold: assert property (@(posedge Clk) disable iff (!RstN)
    MValid && !MReady |=> MValid)
    else $error("SVA: MValid dropped before the word was read");

  AssertMDataHold: assert property (@(posedge Clk) disable iff (!RstN)
    MValid && !MReady |=> $stable(MData))
    else $error("SVA: MData changed before the word was read");

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  // These record that the tricky situations actually happened during the
  // test, so a pass is not just a pass on easy traffic.
  CoverFull: cover property (@(posedge Clk) disable iff (!RstN)
    Full);

  CoverThresholdRise: cover property (@(posedge Clk) disable iff (!RstN)
    ThresholdMet && !$past(ThresholdMet));

  CoverPushPopSame: cover property (@(posedge Clk) disable iff (!RstN)
    Push && Pop);

  CoverLeaveFull: cover property (@(posedge Clk) disable iff (!RstN)
    $past(Full) && !Full);

  CoverBackpressure: cover property (@(posedge Clk) disable iff (!RstN)
    MValid && !MReady);

endmodule
