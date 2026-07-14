`timescale 1ns / 1ps

// MIG Native 接口 DDR3 压力测试引擎。
// 每个 app 命令对应 DDR3 BL8，在 x16/4:1 配置下传输 128bit（16 bytes）。
module ddr_test_engine #(
    parameter integer REGION_BURSTS = 1024,
    parameter [27:0] MID_BASE_ADDR = 28'h4000000,
    parameter [27:0] MEMORY_LAST_ADDR = 28'h7FFFFF8,
    parameter integer UI_CLK_HZ = 100_000_000
) (
    input  wire         ui_clk,
    input  wire         ui_reset,
    input  wire         init_calib_complete,
    input  wire         enable,
    input  wire         clear_errors,

    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    input  wire         app_rdy,
    output reg  [127:0] app_wdf_data,
    output reg          app_wdf_end,
    output reg  [15:0]  app_wdf_mask,
    output reg          app_wdf_wren,
    input  wire         app_wdf_rdy,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid,

    output wire         test_active,
    output wire         test_pass,
    output wire [3:0]   state_debug,
    output wire [2:0]   pattern_index,
    output wire [1:0]   region_index,
    output wire [27:0]  current_address,
    output reg  [31:0]  calibration_cycles,
    output reg  [31:0]  completed_pattern_passes,
    output reg  [31:0]  completed_sweeps,
    output reg  [31:0]  error_count,
    output reg  [27:0]  first_error_address,
    output reg  [127:0] first_expected_data,
    output reg  [127:0] first_actual_data,
    output reg  [63:0]  write_bytes,
    output reg  [63:0]  read_bytes,
    output reg  [31:0]  write_throughput_mb_s,
    output reg  [31:0]  read_throughput_mb_s,
    output reg  [31:0]  peak_write_throughput_mb_s,
    output reg  [31:0]  peak_read_throughput_mb_s
);

    localparam [3:0] S_WAIT_CAL    = 4'd0;
    localparam [3:0] S_WRITE_SETUP = 4'd1;
    localparam [3:0] S_WRITE       = 4'd2;
    localparam [3:0] S_READ_SETUP  = 4'd3;
    localparam [3:0] S_READ_CMD    = 4'd4;
    localparam [3:0] S_READ_WAIT   = 4'd5;
    localparam [3:0] S_NEXT_REGION = 4'd6;

    localparam [27:0] REGION_SPAN = (REGION_BURSTS - 1) << 3;
    localparam [27:0] END_BASE_ADDR = MEMORY_LAST_ADDR - REGION_SPAN;
    // 统计窗口固定为 1us；1us 内传输的字节数在数值上等于十进制 MB/s。
    localparam integer THROUGHPUT_WINDOW_CYCLES = UI_CLK_HZ / 1_000_000;

    reg [3:0]  state;
    reg [2:0]  pattern_reg;
    reg [1:0]  region_reg;
    reg [27:0] address_reg;
    reg [27:0] read_pending_address;
    reg        write_cmd_sent;
    reg        write_data_sent;

    reg [31:0] throughput_cycle_count;
    reg [31:0] window_write_bytes;
    reg [31:0] window_read_bytes;

    function [31:0] lfsr_advance8;
        input [31:0] seed;
        integer i;
        reg [31:0] value;
        begin
            value = (seed == 32'd0) ? 32'h0000_0001 : seed;
            for (i = 0; i < 8; i = i + 1) begin
                value = {value[30:0], value[31] ^ value[21] ^ value[1] ^ value[0]};
            end
            lfsr_advance8 = value;
        end
    endfunction

    function [127:0] make_pattern;
        input [2:0]  selected_pattern;
        input [27:0] address;
        reg [31:0] l0;
        reg [31:0] l1;
        reg [31:0] l2;
        reg [31:0] l3;
        begin
            case (selected_pattern)
                3'd0: make_pattern = {
                    4'hD, address,
                    4'hA, address,
                    4'h5, address,
                    4'h0, address
                };
                3'd1: make_pattern = 128'd0;
                3'd2: make_pattern = {128{1'b1}};
                3'd3: make_pattern = address[3]
                    ? 128'h55AA55AA55AA55AA55AA55AA55AA55AA
                    : 128'hAA55AA55AA55AA55AA55AA55AA55AA55;
                default: begin
                    l0 = lfsr_advance8({4'h0, address} ^ 32'h1ACE_B00C);
                    l1 = lfsr_advance8(l0);
                    l2 = lfsr_advance8(l1);
                    l3 = lfsr_advance8(l2);
                    make_pattern = {l3, l2, l1, l0};
                end
            endcase
        end
    endfunction

    function [27:0] scope_base_address;
        input [1:0] scope;
        begin
            case (scope)
                2'd0: scope_base_address = 28'd0;
                2'd1: scope_base_address = MID_BASE_ADDR;
                2'd2: scope_base_address = END_BASE_ADDR;
                default: scope_base_address = 28'd0;
            endcase
        end
    endfunction

    function [27:0] scope_last_address;
        input [1:0] scope;
        begin
            case (scope)
                2'd0: scope_last_address = REGION_SPAN;
                2'd1: scope_last_address = MID_BASE_ADDR + REGION_SPAN;
                2'd2: scope_last_address = MEMORY_LAST_ADDR;
                default: scope_last_address = MEMORY_LAST_ADDR;
            endcase
        end
    endfunction

    wire write_cmd_accept = enable && (state == S_WRITE) &&
                            !write_cmd_sent && app_rdy;
    wire write_data_accept = enable && (state == S_WRITE) &&
                             !write_data_sent && app_wdf_rdy;
    wire write_transaction_done = (state == S_WRITE) &&
                                  (write_cmd_sent || write_cmd_accept) &&
                                  (write_data_sent || write_data_accept);
    wire read_cmd_accept = enable && (state == S_READ_CMD) && app_rdy;
    wire read_data_accept = enable && (state == S_READ_WAIT) && app_rd_data_valid;

    wire [127:0] expected_read_data = make_pattern(pattern_reg, read_pending_address);
    wire [31:0] next_window_write_bytes = window_write_bytes +
                                          (write_transaction_done ? 32'd16 : 32'd0);
    wire [31:0] next_window_read_bytes = window_read_bytes +
                                         (read_data_accept ? 32'd16 : 32'd0);
    wire [31:0] next_write_throughput = next_window_write_bytes;
    wire [31:0] next_read_throughput = next_window_read_bytes;

    assign test_active = enable && init_calib_complete && (state != S_WAIT_CAL);
    assign test_pass = (error_count == 32'd0);
    assign state_debug = state;
    assign pattern_index = pattern_reg;
    assign region_index = region_reg;
    assign current_address = address_reg;

    always @(*) begin
        app_addr     = address_reg;
        app_cmd      = 3'b000;
        app_en       = 1'b0;
        app_wdf_data = make_pattern(pattern_reg, address_reg);
        app_wdf_end  = 1'b0;
        app_wdf_mask = 16'd0;
        app_wdf_wren = 1'b0;

        if (enable) begin
            case (state)
                S_WRITE: begin
                    app_cmd      = 3'b000;
                    app_en       = !write_cmd_sent;
                    app_wdf_end  = !write_data_sent;
                    app_wdf_wren = !write_data_sent;
                end
                S_READ_CMD: begin
                    app_cmd = 3'b001;
                    app_en  = 1'b1;
                end
                default: begin
                    app_cmd = 3'b000;
                end
            endcase
        end
    end

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            state                       <= S_WAIT_CAL;
            pattern_reg                 <= 3'd0;
            region_reg                  <= 2'd0;
            address_reg                 <= 28'd0;
            read_pending_address        <= 28'd0;
            write_cmd_sent              <= 1'b0;
            write_data_sent             <= 1'b0;
            calibration_cycles          <= 32'd0;
            completed_pattern_passes    <= 32'd0;
            completed_sweeps            <= 32'd0;
            error_count                 <= 32'd0;
            first_error_address         <= 28'd0;
            first_expected_data         <= 128'd0;
            first_actual_data           <= 128'd0;
            write_bytes                 <= 64'd0;
            read_bytes                  <= 64'd0;
            throughput_cycle_count      <= 32'd0;
            window_write_bytes          <= 32'd0;
            window_read_bytes           <= 32'd0;
            write_throughput_mb_s       <= 32'd0;
            read_throughput_mb_s        <= 32'd0;
            peak_write_throughput_mb_s  <= 32'd0;
            peak_read_throughput_mb_s   <= 32'd0;
        end else begin
            if (!init_calib_complete && calibration_cycles != 32'hFFFF_FFFF) begin
                calibration_cycles <= calibration_cycles + 1'b1;
            end

            if (clear_errors) begin
                error_count         <= 32'd0;
                first_error_address <= 28'd0;
                first_expected_data <= 128'd0;
                first_actual_data   <= 128'd0;
            end

            if (throughput_cycle_count == THROUGHPUT_WINDOW_CYCLES - 1) begin
                throughput_cycle_count <= 32'd0;
                window_write_bytes     <= 32'd0;
                window_read_bytes      <= 32'd0;
                write_throughput_mb_s  <= next_write_throughput;
                read_throughput_mb_s   <= next_read_throughput;
                if (next_write_throughput > peak_write_throughput_mb_s) begin
                    peak_write_throughput_mb_s <= next_write_throughput;
                end
                if (next_read_throughput > peak_read_throughput_mb_s) begin
                    peak_read_throughput_mb_s <= next_read_throughput;
                end
            end else begin
                throughput_cycle_count <= throughput_cycle_count + 1'b1;
                if (write_transaction_done) begin
                    window_write_bytes <= window_write_bytes + 5'd16;
                end
                if (read_data_accept) begin
                    window_read_bytes <= window_read_bytes + 5'd16;
                end
            end

            case (state)
                S_WAIT_CAL: begin
                    if (enable && init_calib_complete) begin
                        state <= S_WRITE_SETUP;
                    end
                end

                S_WRITE_SETUP: begin
                    address_reg     <= scope_base_address(region_reg);
                    write_cmd_sent  <= 1'b0;
                    write_data_sent <= 1'b0;
                    state           <= S_WRITE;
                end

                S_WRITE: begin
                    if (write_transaction_done) begin
                        write_bytes     <= write_bytes + 5'd16;
                        write_cmd_sent  <= 1'b0;
                        write_data_sent <= 1'b0;
                        if (address_reg == scope_last_address(region_reg)) begin
                            state <= S_READ_SETUP;
                        end else begin
                            address_reg <= address_reg + 4'd8;
                        end
                    end else begin
                        if (write_cmd_accept) begin
                            write_cmd_sent <= 1'b1;
                        end
                        if (write_data_accept) begin
                            write_data_sent <= 1'b1;
                        end
                    end
                end

                S_READ_SETUP: begin
                    address_reg <= scope_base_address(region_reg);
                    state       <= S_READ_CMD;
                end

                S_READ_CMD: begin
                    if (read_cmd_accept) begin
                        read_pending_address <= address_reg;
                        state                <= S_READ_WAIT;
                    end
                end

                S_READ_WAIT: begin
                    if (read_data_accept) begin
                        read_bytes <= read_bytes + 5'd16;
                        if (!clear_errors && app_rd_data != expected_read_data) begin
                            error_count <= error_count + 1'b1;
                            if (error_count == 32'd0) begin
                                first_error_address <= read_pending_address;
                                first_expected_data <= expected_read_data;
                                first_actual_data   <= app_rd_data;
                            end
                        end

                        if (address_reg == scope_last_address(region_reg)) begin
                            state <= S_NEXT_REGION;
                        end else begin
                            address_reg <= address_reg + 4'd8;
                            state       <= S_READ_CMD;
                        end
                    end
                end

                S_NEXT_REGION: begin
                    if (region_reg == 2'd3) begin
                        region_reg               <= 2'd0;
                        completed_pattern_passes <= completed_pattern_passes + 1'b1;
                        if (pattern_reg == 3'd4) begin
                            pattern_reg      <= 3'd0;
                            completed_sweeps <= completed_sweeps + 1'b1;
                        end else begin
                            pattern_reg <= pattern_reg + 1'b1;
                        end
                    end else begin
                        region_reg <= region_reg + 1'b1;
                    end
                    state <= S_WRITE_SETUP;
                end

                default: begin
                    state <= S_WAIT_CAL;
                end
            endcase
        end
    end

endmodule
