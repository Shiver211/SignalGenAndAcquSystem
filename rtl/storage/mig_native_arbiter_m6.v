`timescale 1ns / 1ps

// RAW 采集/读出与 DECIMATED 写入共享 MIG Native 端口的事务级仲裁器。
module mig_native_arbiter_m6 (
    input  wire         ui_clk,
    input  wire         ui_reset,

    input  wire [27:0]  raw_addr,
    input  wire [2:0]   raw_cmd,
    input  wire         raw_en,
    output wire         raw_rdy,
    input  wire [127:0] raw_wdf_data,
    input  wire         raw_wdf_end,
    input  wire [15:0]  raw_wdf_mask,
    input  wire         raw_wdf_wren,
    output wire         raw_wdf_rdy,

    input  wire [27:0]  dec_addr,
    input  wire [2:0]   dec_cmd,
    input  wire         dec_en,
    output wire         dec_rdy,
    input  wire [127:0] dec_wdf_data,
    input  wire         dec_wdf_end,
    input  wire [15:0]  dec_wdf_mask,
    input  wire         dec_wdf_wren,
    output wire         dec_wdf_rdy,

    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    input  wire         app_rdy,
    output reg  [127:0] app_wdf_data,
    output reg          app_wdf_end,
    output reg  [15:0]  app_wdf_mask,
    output reg          app_wdf_wren,
    input  wire         app_wdf_rdy,
    input  wire         app_rd_data_valid,
    output wire         raw_rd_data_valid,
    output wire         dec_rd_data_valid
);

    localparam [1:0] OWNER_IDLE = 2'd0;
    localparam [1:0] OWNER_RAW  = 2'd1;
    localparam [1:0] OWNER_DEC  = 2'd2;

    reg [1:0] owner;
    reg command_done;
    reg write_data_done;
    reg command_is_read;

    assign raw_rd_data_valid = app_rd_data_valid && (owner == OWNER_RAW) &&
                               command_is_read;
    assign dec_rd_data_valid = app_rd_data_valid && (owner == OWNER_DEC) &&
                               command_is_read;

    assign raw_rdy     = (owner == OWNER_RAW) ? app_rdy : 1'b0;
    assign raw_wdf_rdy = (owner == OWNER_RAW) ? app_wdf_rdy : 1'b0;
    assign dec_rdy     = (owner == OWNER_DEC) ? app_rdy : 1'b0;
    assign dec_wdf_rdy = (owner == OWNER_DEC) ? app_wdf_rdy : 1'b0;

    wire selected_en = (owner == OWNER_RAW) ? raw_en : dec_en;
    wire [2:0] selected_cmd = (owner == OWNER_RAW) ? raw_cmd : dec_cmd;
    wire selected_wdf_wren = (owner == OWNER_RAW) ? raw_wdf_wren : dec_wdf_wren;
    wire command_accept = (owner != OWNER_IDLE) && selected_en && app_rdy;
    wire data_accept = (owner != OWNER_IDLE) && selected_wdf_wren && app_wdf_rdy;
    wire write_complete =
        (command_done || command_accept) &&
        (write_data_done || data_accept);

    always @(*) begin
        app_addr     = 28'd0;
        app_cmd      = 3'b000;
        app_en       = 1'b0;
        app_wdf_data = 128'd0;
        app_wdf_end  = 1'b0;
        app_wdf_mask = 16'hFFFF;
        app_wdf_wren = 1'b0;

        if (owner == OWNER_RAW) begin
            app_addr     = raw_addr;
            app_cmd      = raw_cmd;
            app_en       = raw_en;
            app_wdf_data = raw_wdf_data;
            app_wdf_end  = raw_wdf_end;
            app_wdf_mask = raw_wdf_mask;
            app_wdf_wren = raw_wdf_wren;
        end else if (owner == OWNER_DEC) begin
            app_addr     = dec_addr;
            app_cmd      = dec_cmd;
            app_en       = dec_en;
            app_wdf_data = dec_wdf_data;
            app_wdf_end  = dec_wdf_end;
            app_wdf_mask = dec_wdf_mask;
            app_wdf_wren = dec_wdf_wren;
        end
    end

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            owner            <= OWNER_IDLE;
            command_done     <= 1'b0;
            write_data_done  <= 1'b0;
            command_is_read  <= 1'b0;
        end else begin
            case (owner)
                OWNER_IDLE: begin
                    command_done    <= 1'b0;
                    write_data_done <= 1'b0;
                    command_is_read <= 1'b0;
                    if (raw_en || raw_wdf_wren)
                        owner <= OWNER_RAW;
                    else if (dec_en || dec_wdf_wren)
                        owner <= OWNER_DEC;
                end

                OWNER_RAW, OWNER_DEC: begin
                    if (command_accept) begin
                        command_done    <= 1'b1;
                        command_is_read <= (selected_cmd != 3'b000);
                    end
                    if (data_accept) write_data_done <= 1'b1;

                    if ((command_done && command_is_read && app_rd_data_valid) ||
                        (command_accept && (selected_cmd != 3'b000) &&
                         app_rd_data_valid) || write_complete) begin
                        owner <= OWNER_IDLE;
                        command_done    <= 1'b0;
                        write_data_done <= 1'b0;
                        command_is_read <= 1'b0;
                    end
                end
                default: owner <= OWNER_IDLE;
            endcase
        end
    end

endmodule
