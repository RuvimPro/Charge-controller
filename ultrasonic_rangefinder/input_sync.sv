module input_sync(

    input logic clk,

    // Asynchronous inputs
    input logic sw_async,
    input logic rst_async,
    input logic echo_async,

    // Synchronized outputs
    output logic sw_sync,
    output logic rst_sync,
    output logic echo_sync
);

// Synchronizer registers
logic [1:0] sw_chain   = 2'b00;
logic [1:0] rst_chain  = 2'b11; // начальный сброс
logic [1:0] echo_chain = 2'b00;

// Two-stage synchronizers
always_ff @(posedge clk) begin : p_sync_regs
    sw_chain   <= {sw_chain[0],   sw_async};
    rst_chain  <= {rst_chain[0],  rst_async};
    echo_chain <= {echo_chain[0], echo_async};
end

// Synchronized outputs
assign sw_sync   = sw_chain[1];
assign rst_sync  = rst_chain[1];
assign echo_sync = echo_chain[1];

endmodule
