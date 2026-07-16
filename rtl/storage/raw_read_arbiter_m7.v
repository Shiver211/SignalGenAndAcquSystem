`timescale 1ns / 1ps

// 冻结 RAW 帧读口仲裁：网络上传优先于后台 OTR 扫描，事务开始后保持 owner。
module raw_read_arbiter_m7 (
    input  wire        ui_clk,
    input  wire        ui_reset,

    input  wire        scan_request_valid,
    output wire        scan_request_ready,
    input  wire [31:0] scan_request_start,
    input  wire [31:0] scan_request_count,
    output wire [31:0] scan_sample_data,
    output wire        scan_sample_valid,
    input  wire        scan_sample_ready,
    output wire        scan_done,
    output wire        scan_error,

    input  wire        net_request_valid,
    output wire        net_request_ready,
    input  wire [31:0] net_request_start,
    input  wire [31:0] net_request_count,
    output wire [31:0] net_sample_data,
    output wire        net_sample_valid,
    input  wire        net_sample_ready,
    output wire        net_done,
    output wire        net_error,

    output wire        reader_request_valid,
    input  wire        reader_request_ready,
    output wire [31:0] reader_request_start,
    output wire [31:0] reader_request_count,
    input  wire [31:0] reader_sample_data,
    input  wire        reader_sample_valid,
    output wire        reader_sample_ready,
    input  wire        reader_done,
    input  wire        reader_error
);

    localparam [1:0] OWNER_IDLE = 2'd0;
    localparam [1:0] OWNER_SCAN = 2'd1;
    localparam [1:0] OWNER_NET  = 2'd2;

    reg [1:0] owner;
    wire select_net = (owner == OWNER_NET) ||
                      ((owner == OWNER_IDLE) && net_request_valid);
    wire select_scan = (owner == OWNER_SCAN) ||
                       ((owner == OWNER_IDLE) && !net_request_valid &&
                        scan_request_valid);

    assign reader_request_valid = (owner == OWNER_IDLE) &&
                                  (net_request_valid || scan_request_valid);
    assign reader_request_start = select_net ? net_request_start : scan_request_start;
    assign reader_request_count = select_net ? net_request_count : scan_request_count;

    assign net_request_ready  = (owner == OWNER_IDLE) && net_request_valid &&
                                reader_request_ready;
    assign scan_request_ready = (owner == OWNER_IDLE) && !net_request_valid &&
                                scan_request_valid && reader_request_ready;

    assign net_sample_data  = reader_sample_data;
    assign scan_sample_data = reader_sample_data;
    assign net_sample_valid = (owner == OWNER_NET) && reader_sample_valid;
    assign scan_sample_valid = (owner == OWNER_SCAN) && reader_sample_valid;
    assign reader_sample_ready = (owner == OWNER_NET) ? net_sample_ready :
                                 (owner == OWNER_SCAN) ? scan_sample_ready : 1'b0;
    assign net_done  = (owner == OWNER_NET) && reader_done;
    assign scan_done = (owner == OWNER_SCAN) && reader_done;
    assign net_error  = (owner == OWNER_NET) && reader_done && reader_error;
    assign scan_error = (owner == OWNER_SCAN) && reader_done && reader_error;

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            owner <= OWNER_IDLE;
        end else begin
            if ((owner == OWNER_IDLE) && reader_request_valid && reader_request_ready)
                owner <= net_request_valid ? OWNER_NET : OWNER_SCAN;
            else if ((owner != OWNER_IDLE) && reader_done)
                owner <= OWNER_IDLE;
        end
    end

endmodule

