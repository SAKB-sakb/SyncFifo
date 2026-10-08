// =============================================================================
// SyncFifoBind.sv
// -----------------------------------------------------------------------------
// Attaches SyncFifoSva to every SyncFifo instance without touching the RTL.
// =============================================================================

bind SyncFifo SyncFifoSva #(
  .SAKB_DATA_W    (SAKB_DATA_W),
  .SAKB_DEPTH     (SAKB_DEPTH),
  .SAKB_THRESHOLD (SAKB_THRESHOLD)
) SvaChecker (
  .Clk          (Clk),
  .RstN         (RstN),
  .SValid       (SValid),
  .SReady       (SReady),
  .SData        (SData),
  .MValid       (MValid),
  .MReady       (MReady),
  .MData        (MData),
  .Count        (Count),
  .Full         (Full),
  .Empty        (Empty),
  .ThresholdMet (ThresholdMet)
);
