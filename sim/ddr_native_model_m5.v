`timescale 1ns / 1ps

// 支持字节掩码、命令/写数据独立反压的 M5 MIG Native 行为模型。
module ddr_native_model_m5 #(
    parameter integer ADDR_WIDTH = 28,
    parameter integer DATA_WIDTH = 128,
    parameter integer MEM_DEPTH = 256,
    parameter integer READ_LATENCY = 3
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire [ADDR_WIDTH-1:0] app_addr,
    input  wire [2:0]            app_cmd,
    input  wire                  app_en,
    output reg                   app_rdy,
    input  wire [DATA_WIDTH-1:0] app_wdf_data,
    input  wire [DATA_WIDTH/8-1:0] app_wdf_mask,
    input  wire                  app_wdf_end,
    input  wire                  app_wdf_wren,
    output reg                   app_wdf_rdy,
    output reg  [DATA_WIDTH-1:0] app_rd_data,
    output reg                   app_rd_data_valid
);

    reg [DATA_WIDTH-1:0] memory [0:MEM_DEPTH-1];
    reg [31:0] cycle_count;
    reg write_command_pending;
    reg write_data_pending;
    reg [ADDR_WIDTH-1:0] pending_write_address;
    reg [DATA_WIDTH-1:0] pending_write_data;
    reg [DATA_WIDTH/8-1:0] pending_write_mask;
    reg read_pending;
    reg [ADDR_WIDTH-1:0] pending_read_address;
    integer read_countdown;
    integer i;

    wire accept_write_command = app_en && app_rdy && (app_cmd == 3'b000);
    wire accept_read_command = app_en && app_rdy && (app_cmd == 3'b001);
    wire accept_write_data = app_wdf_wren && app_wdf_end && app_wdf_rdy;
    wire have_write_command = write_command_pending || accept_write_command;
    wire have_write_data = write_data_pending || accept_write_data;
    wire [ADDR_WIDTH-1:0] complete_write_address = accept_write_command
        ? app_addr : pending_write_address;
    wire [DATA_WIDTH-1:0] complete_write_data = accept_write_data
        ? app_wdf_data : pending_write_data;
    wire [DATA_WIDTH/8-1:0] complete_write_mask = accept_write_data
        ? app_wdf_mask : pending_write_mask;

    function integer memory_index;
        input [ADDR_WIDTH-1:0] address;
        begin
            memory_index = (address >> 3) % MEM_DEPTH;
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            cycle_count           <= 32'd0;
            app_rdy               <= 1'b0;
            app_wdf_rdy           <= 1'b0;
            app_rd_data           <= {DATA_WIDTH{1'b0}};
            app_rd_data_valid     <= 1'b0;
            write_command_pending <= 1'b0;
            write_data_pending    <= 1'b0;
            pending_write_address <= {ADDR_WIDTH{1'b0}};
            pending_write_data    <= {DATA_WIDTH{1'b0}};
            pending_write_mask    <= {(DATA_WIDTH/8){1'b1}};
            read_pending          <= 1'b0;
            pending_read_address  <= {ADDR_WIDTH{1'b0}};
            read_countdown        <= 0;
            for (i = 0; i < MEM_DEPTH; i = i + 1) begin
                memory[i] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            cycle_count       <= cycle_count + 1'b1;
            app_rdy           <= (cycle_count[1:0] != 2'b00) && !read_pending &&
                                 !write_command_pending;
            app_wdf_rdy       <= (cycle_count[2:0] != 3'b000) &&
                                 !write_data_pending;
            app_rd_data_valid <= 1'b0;

            if (accept_write_command) begin
                pending_write_address <= app_addr;
                write_command_pending <= 1'b1;
            end
            if (accept_write_data) begin
                pending_write_data <= app_wdf_data;
                pending_write_mask <= app_wdf_mask;
                write_data_pending <= 1'b1;
            end

            if (have_write_command && have_write_data) begin
                for (i = 0; i < DATA_WIDTH/8; i = i + 1) begin
                    if (!complete_write_mask[i]) begin
                        memory[memory_index(complete_write_address)][i*8 +: 8]
                            <= complete_write_data[i*8 +: 8];
                    end
                end
                write_command_pending <= 1'b0;
                write_data_pending    <= 1'b0;
            end

            if (accept_read_command) begin
                pending_read_address <= app_addr;
                read_pending         <= 1'b1;
                read_countdown       <= READ_LATENCY;
            end else if (read_pending) begin
                if (read_countdown == 0) begin
                    app_rd_data       <= memory[memory_index(pending_read_address)];
                    app_rd_data_valid <= 1'b1;
                    read_pending      <= 1'b0;
                end else begin
                    read_countdown <= read_countdown - 1;
                end
            end
        end
    end

endmodule

