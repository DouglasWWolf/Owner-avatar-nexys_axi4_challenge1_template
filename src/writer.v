module writer # (parameter DW=512, parameter AW=19)
(
    input   clk, resetn,

    input   start, clear,

    //==================  This is an AXI4-master interface  ===================

    // "Specify write address"              -- Master --    -- Slave --
    output reg [AW-1:0]                     M_AXI_AWADDR,
    output                                  M_AXI_AWVALID,
    output     [7:0]                        M_AXI_AWLEN,
    output     [2:0]                        M_AXI_AWSIZE,
    output     [3:0]                        M_AXI_AWID,
    output     [1:0]                        M_AXI_AWBURST,
    output                                  M_AXI_AWLOCK,
    output     [3:0]                        M_AXI_AWCACHE,
    output     [3:0]                        M_AXI_AWQOS,
    output     [2:0]                        M_AXI_AWPROT,
    input                                                   M_AXI_AWREADY,

    // "Write Data"                         -- Master --    -- Slave --
    output     [DW-1:0]                     M_AXI_WDATA,
    output     [(DW/8)-1:0]                 M_AXI_WSTRB,
    output                                  M_AXI_WVALID,
    output                                  M_AXI_WLAST,
    input                                                   M_AXI_WREADY,

    // "Send Write Response"                -- Master --    -- Slave --
    input[1:0]                                              M_AXI_BRESP,
    input                                                   M_AXI_BVALID,
    output                                  M_AXI_BREADY,

    // "Specify read address"               -- Master --    -- Slave --
    output     [AW-1:0]                     M_AXI_ARADDR,
    output                                  M_AXI_ARVALID,
    output     [2:0]                        M_AXI_ARPROT,
    output                                  M_AXI_ARLOCK,
    output     [3:0]                        M_AXI_ARID,
    output     [2:0]                        M_AXI_ARSIZE,
    output     [7:0]                        M_AXI_ARLEN,
    output     [1:0]                        M_AXI_ARBURST,
    output     [3:0]                        M_AXI_ARCACHE,
    output     [3:0]                        M_AXI_ARQOS,
    input                                                   M_AXI_ARREADY,

    // "Read data back to master"           -- Master --    -- Slave --
    input[DW-1:0]                                           M_AXI_RDATA,
    input                                                   M_AXI_RVALID,
    input[1:0]                                              M_AXI_RRESP,
    input                                                   M_AXI_RLAST,
    output                                  M_AXI_RREADY
    //==========================================================================

);

localparam BURST_SIZE      = 4096;
localparam BRAM_SIZE       = 512 * 1024;
localparam BRAM_ADDR       = 32'h0000_0000;
localparam BEATS_PER_BURST = BURST_SIZE / (DW/8);
localparam TOTAL_BURSTS    = BRAM_SIZE / BURST_SIZE;

//=============================================================================
//
// We're not using the read side of the AXI4-Master interface
//
//=============================================================================
assign M_AXI_ARADDR  = 0;
assign M_AXI_ARVALID = 0;
assign M_AXI_ARPROT  = 0;
assign M_AXI_ARLOCK  = 0;
assign M_AXI_ARID    = 0;
assign M_AXI_ARSIZE  = 0;
assign M_AXI_ARLEN   = 0;
assign M_AXI_ARBURST = 0;
assign M_AXI_ARCACHE = 0;
assign M_AXI_ARQOS   = 0;
assign M_AXI_RREADY  = 0;
//=============================================================================



//=============================================================================
//
// These parameters are fixed for every burst we write
//
//=============================================================================
assign M_AXI_AWSIZE  = $clog2(DW/8);        // Every write will be the full width of the bus
assign M_AXI_AWLEN   = BEATS_PER_BURST - 1; // Every burst will be the same size
assign M_AXI_AWID    = 0;                   // Not using transaction re-ordering
assign M_AXI_AWBURST = 1;                   // Burst type is "incremental"
assign M_AXI_AWLOCK  = 0;                   // AXI4 doesn't support locked transactions
assign M_AXI_AWCACHE = 0;                   // Transactions are non-bufferable
assign M_AXI_AWQOS   = 0;                   // No quality-of-service arbitration
assign M_AXI_AWPROT  = 2;                   // Non-secure, unprivileged access
//=============================================================================


// The state of the AW-channel state machine
reg awsm_state;

// The number of write-bursts requested on the AW-channel
reg[31:0] aw_burst;

// State of the W-channel state machine
reg[ 1:0] wsm_state;

// The number of the write-burst being performed on the W-channel
reg[31:0] w_burst;

// Beat within a burst.  0-based
reg[ 7:0] beat;

// This will be replicated across M_AXI_WDATA
reg[15:0] data;

// The number of write-bursts that have been acknowledged
reg[31:0] writes_ackd;

// State of the B-channel state machine
reg bsm_state;

// This will be true if we're supposed to zero-fill RAM
reg zero_fill;

//=============================================================================
// This state machine issues "write requests" on the AW channel
//=============================================================================

// Emit write-requests whenever the AW state machine is in state 1
assign M_AXI_AWVALID = (awsm_state == 1) & (resetn == 1);

always @(posedge clk) begin

    if (resetn == 0) begin
        awsm_state <= 0;
    end
    
    else case (awsm_state)

        // Here we're waiting around for someone to say "start"
        0:  if (start) begin
                aw_burst     <= 1;
                M_AXI_AWADDR <= BRAM_ADDR;
                awsm_state   <= 1;
            end

        // Every time the slave accepts a write-request, keep
        // track of the number of bursts we've requested, and 
        // keep track of the address of the next burst.
        1:  if (M_AXI_AWVALID & M_AXI_AWREADY) begin
                if (aw_burst < TOTAL_BURSTS) begin
                    aw_burst     <= aw_burst + 1;
                    M_AXI_AWADDR <= M_AXI_AWADDR + BURST_SIZE;
                end else
                    awsm_state <= 0;
            end

    endcase

end
//=============================================================================




//=============================================================================
// This state machine controls the W-channel
//=============================================================================

assign M_AXI_WDATA  = zero_fill ? 0 : {(DW/16){data}};
assign M_AXI_WSTRB  = -1;
assign M_AXI_WLAST  = (beat == BEATS_PER_BURST);
assign M_AXI_WVALID = (wsm_state == 1) & (resetn == 1);

always @(posedge clk) begin

    if (resetn == 0) begin
        wsm_state <= 0;
    end

    else case(wsm_state)

        0:  if (start) begin
                w_burst   <= 1;
                beat      <= 1;
                data      <= 1;
                zero_fill <= clear;
                wsm_state <= 1;
            end

        1:  if (M_AXI_WVALID & M_AXI_WREADY) begin
                data <= data + 1;
                beat <= beat + 1;
                if (M_AXI_WLAST) begin
                    if (w_burst < TOTAL_BURSTS) begin
                        beat    <= 1;
                        w_burst <= w_burst + 1;
                    end else
                        wsm_state <= 2;
                end
            end

        2:  if (writes_ackd == TOTAL_BURSTS)
                wsm_state <= 0;

    endcase

end
//=============================================================================



//=============================================================================
// This state machine counts write-acknowledgements from the slave
//=============================================================================
assign M_AXI_BREADY = (bsm_state == 1) & (resetn == 1);

always @(posedge clk) begin
    if (resetn == 0) begin
        bsm_state <= 0;
    end

    else case(bsm_state)

        0:  if (start) begin
                writes_ackd <= 0;
                bsm_state   <= 1;
            end

        1:  if (M_AXI_BVALID & M_AXI_BREADY) begin
                if (writes_ackd == TOTAL_BURSTS-1)
                    bsm_state <= 0;

                 writes_ackd <= writes_ackd + 1;
            end

    endcase
end
//=============================================================================
    


endmodule