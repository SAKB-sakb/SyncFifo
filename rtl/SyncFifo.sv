// =============================================================================
// SyncFifo.sv
// -----------------------------------------------------------------------------
// Single-clock FIFO with a valid/ready handshake on both sides.
//
//   Write side : SValid / SReady / SData
//   Read side  : MValid / MReady / MData
//
// A word moves on a rising clock edge when valid and ready are both high.
//
// Read modes (SAKB_OUT_REG):
//   0 - First-word fall-through. MData comes straight out of the memory at the
//       read pointer.
//   1 - Registered output. MValid and MData come straight out of flip-flops,
//       which gives better timing. The output register is one of the
//       SAKB_DEPTH slots, so the capacity is the same in both modes. A word
//       written into an empty FIFO skips the memory and goes directly into the
//       output register, so it shows up one cycle after the write in both
//       modes.
//
// Status outputs (all built from registers, never from this cycle's inputs):
//   Count        - number of words stored (0 .. SAKB_DEPTH)
//   Full         - Count == SAKB_DEPTH       (same as !SReady)
//   Empty        - Count == 0                (same as !MValid)
//   ThresholdMet - Count >= SAKB_THRESHOLD
//
// Notes:
//   * SAKB_DEPTH can be any value >= 2, not only a power of two.
//   * Reset is synchronous and active low. The memory itself has no reset, so
//     it can map onto RAM.
//   * SReady does not look at MReady: a write is refused while the FIFO is
//     full, even if a read happens in the same cycle.
//   * Parameter ranges are checked in SyncFifoSva, so this file holds only
//     synthesizable code.
// =============================================================================

`timescale 1ns/1ps

module SyncFifo #(
  parameter  int unsigned SAKB_DATA_W    = 8,
  parameter  int unsigned SAKB_DEPTH     = 16,
  parameter  int unsigned SAKB_THRESHOLD = (SAKB_DEPTH * 3) / 4,
  parameter  bit          SAKB_OUT_REG   = 1'b0,
  // Derived - do not override.
  localparam int unsigned SAKB_CNT_W     = $clog2(SAKB_DEPTH + 1)
) (
  input  logic                   Clk,
  input  logic                   RstN,

  // Write side
  input  logic                   SValid,
  output logic                   SReady,
  input  logic [SAKB_DATA_W-1:0] SData,

  // Read side
  output logic                   MValid,
  input  logic                   MReady,
  output logic [SAKB_DATA_W-1:0] MData,

  // Status
  output logic [SAKB_CNT_W-1:0]  Count,
  output logic                   Full,
  output logic                   Empty,
  output logic                   ThresholdMet
);

  // In registered mode one word sits in the output register, so the memory
  // needs one slot less. Pointer and counter widths are worked out from that.
  localparam int unsigned SAKB_MEM_DEPTH = SAKB_OUT_REG ? SAKB_DEPTH - 1 : SAKB_DEPTH;
  localparam int unsigned SAKB_PTR_W     = (SAKB_MEM_DEPTH > 1) ? $clog2(SAKB_MEM_DEPTH) : 1;
  localparam int unsigned SAKB_MCNT_W    = $clog2(SAKB_MEM_DEPTH + 1);

  typedef logic [SAKB_PTR_W-1:0] PtrT;

  logic [SAKB_DATA_W-1:0] Mem [0:SAKB_MEM_DEPTH-1];

  PtrT                    WrPtr;
  PtrT                    RdPtr;
  logic [SAKB_MCNT_W-1:0] MemCount;

  logic                   MemFull;
  logic                   MemEmpty;
  logic                   MemPush;
  logic                   MemPop;
  logic [SAKB_DATA_W-1:0] MemRdData;
  logic                   Push;

  // Move a pointer to the next slot, and jump back to slot 0 after the last.
  // This is why the depth does not have to be a power of two.
  function automatic PtrT PtrInc(input PtrT Ptr);
    return (Ptr == PtrT'(SAKB_MEM_DEPTH - 1)) ? '0 : Ptr + PtrT'(1);
  endfunction

  // The memory is full when its counter reaches its size, empty at zero.
  // The word at the read pointer is always there for the read side to use.
  assign MemFull   = (MemCount == SAKB_MCNT_W'(SAKB_MEM_DEPTH));
  assign MemEmpty  = (MemCount == '0);
  assign MemRdData = Mem[RdPtr];

  // A new word is accepted whenever the memory has room.
  // Push is high only in a cycle where a word really goes in.
  assign SReady = ~MemFull;
  assign Push   = SValid & SReady;

  // Store the incoming word at the write pointer.
  // The memory has no reset, so synthesis can map it onto RAM.
  always_ff @(posedge Clk) begin
    if (MemPush)
      Mem[WrPtr] <= SData;
  end

  // Each pointer steps forward when a word goes in or comes out. The counter
  // goes up on a write, down on a read, and stays put when both happen.
  always_ff @(posedge Clk) begin
    if (!RstN) begin
      WrPtr    <= '0;
      RdPtr    <= '0;
      MemCount <= '0;
    end else begin
      if (MemPush) WrPtr <= PtrInc(WrPtr);
      if (MemPop)  RdPtr <= PtrInc(RdPtr);

      case ({MemPush, MemPop})
        2'b10:   MemCount <= MemCount + 1'b1;
        2'b01:   MemCount <= MemCount - 1'b1;
        default: MemCount <= MemCount;
      endcase
    end
  end

  generate
    if (SAKB_OUT_REG == 1'b0) begin : GenFwft

      // The word at the read pointer goes straight to the output.
      // A read happens when the output is valid and the reader is ready.
      assign MemPush = Push;
      assign MemPop  = MValid & MReady;
      assign MValid  = ~MemEmpty;
      assign MData   = MemRdData;
      assign Count   = SAKB_CNT_W'(MemCount);

    end else begin : GenOutReg

      logic                   OutValid;
      logic [SAKB_DATA_W-1:0] OutData;
      logic                   OutFree;
      logic                   Bypass;

      // The output register can take a new word when it is empty or its word
      // is being read. If the memory has data, it refills from the memory.
      assign OutFree = ~OutValid | MReady;
      assign MemPop  = OutFree & ~MemEmpty;

      // A word that arrives while the memory is empty and the output register
      // is free skips the memory, so it is readable on the very next cycle.
      assign Bypass  = Push & OutFree & MemEmpty;
      assign MemPush = Push & ~Bypass;

      // When the output register is free, it turns valid if there is a word to
      // load into it, either from the memory or straight from the input.
      always_ff @(posedge Clk) begin
        if (!RstN) begin
          OutValid <= 1'b0;
        end else if (OutFree) begin
          OutValid <= ~MemEmpty | Push;
        end
      end

      // Load the next word from the memory, or the incoming word if it skips
      // the memory. No reset needed: the data is only used while OutValid is 1.
      always_ff @(posedge Clk) begin
        if (MemPop)
          OutData <= MemRdData;
        else if (Bypass)
          OutData <= SData;
      end

      // The total count is the words in the memory plus the one held in the
      // output register.
      assign MValid = OutValid;
      assign MData  = OutData;
      assign Count  = SAKB_CNT_W'(MemCount) + SAKB_CNT_W'(OutValid);

    end
  endgenerate

  // Full, Empty and ThresholdMet are simple compares on the count.
  // ThresholdMet goes high once SAKB_THRESHOLD or more words are stored.
  assign Full         = (Count == SAKB_CNT_W'(SAKB_DEPTH));
  assign Empty        = (Count == '0);
  assign ThresholdMet = (Count >= SAKB_CNT_W'(SAKB_THRESHOLD));

endmodule
