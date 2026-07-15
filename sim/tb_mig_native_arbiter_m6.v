`timescale 1ns / 1ps

module tb_mig_native_arbiter_m6;
    reg ui_clk = 1'b0;
    reg ui_reset = 1'b1;
    reg [27:0] raw_addr = 28'd0;
    reg [2:0] raw_cmd = 3'b000;
    reg raw_en = 1'b0;
    wire raw_rdy;
    reg [127:0] raw_wdf_data = 128'd0;
    reg raw_wdf_end = 1'b1;
    reg [15:0] raw_wdf_mask = 16'd0;
    reg raw_wdf_wren = 1'b0;
    wire raw_wdf_rdy;
    reg [27:0] dec_addr = 28'd0;
    reg [2:0] dec_cmd = 3'b000;
    reg dec_en = 1'b0;
    wire dec_rdy;
    reg [127:0] dec_wdf_data = 128'd0;
    reg dec_wdf_end = 1'b1;
    reg [15:0] dec_wdf_mask = 16'd0;
    reg dec_wdf_wren = 1'b0;
    wire dec_wdf_rdy;
    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    wire app_rdy;
    wire [127:0] app_wdf_data;
    wire app_wdf_end;
    wire [15:0] app_wdf_mask;
    wire app_wdf_wren;
    wire app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire app_rd_data_valid;
    wire raw_rd_data_valid;
    wire dec_rd_data_valid;
    integer raw_accept_cycle = -1;
    integer dec_accept_cycle = -1;
    integer cycle = 0;
    integer timeout;

    always #5 ui_clk = ~ui_clk;
    always @(posedge ui_clk) cycle <= cycle + 1;

    mig_native_arbiter_m6 dut (
        .ui_clk(ui_clk), .ui_reset(ui_reset),
        .raw_addr(raw_addr), .raw_cmd(raw_cmd), .raw_en(raw_en), .raw_rdy(raw_rdy),
        .raw_wdf_data(raw_wdf_data), .raw_wdf_end(raw_wdf_end),
        .raw_wdf_mask(raw_wdf_mask), .raw_wdf_wren(raw_wdf_wren),
        .raw_wdf_rdy(raw_wdf_rdy),
        .dec_addr(dec_addr), .dec_cmd(dec_cmd), .dec_en(dec_en), .dec_rdy(dec_rdy),
        .dec_wdf_data(dec_wdf_data), .dec_wdf_end(dec_wdf_end),
        .dec_wdf_mask(dec_wdf_mask), .dec_wdf_wren(dec_wdf_wren),
        .dec_wdf_rdy(dec_wdf_rdy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_wdf_rdy(app_wdf_rdy), .app_rd_data_valid(app_rd_data_valid),
        .raw_rd_data_valid(raw_rd_data_valid), .dec_rd_data_valid(dec_rd_data_valid)
    );

    ddr_native_model_m5 #(.MEM_DEPTH(16), .READ_LATENCY(4)) memory_model (
        .clk(ui_clk), .reset(ui_reset), .app_addr(app_addr), .app_cmd(app_cmd),
        .app_en(app_en), .app_rdy(app_rdy), .app_wdf_data(app_wdf_data),
        .app_wdf_mask(app_wdf_mask), .app_wdf_end(app_wdf_end),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
    );

    always @(posedge ui_clk) begin
        if (raw_en && raw_rdy && raw_accept_cycle < 0) raw_accept_cycle <= cycle;
        if (dec_en && dec_rdy && dec_accept_cycle < 0) dec_accept_cycle <= cycle;
        if (raw_en && raw_rdy) raw_en <= 1'b0;
        if (raw_wdf_wren && raw_wdf_rdy) raw_wdf_wren <= 1'b0;
        if (dec_en && dec_rdy) dec_en <= 1'b0;
        if (dec_wdf_wren && dec_wdf_rdy) dec_wdf_wren <= 1'b0;
    end

    initial begin
        repeat (5) @(posedge ui_clk);
        ui_reset <= 1'b0;
        repeat (3) @(posedge ui_clk);

        // 两路同时请求时 RAW 必须先完成。
        @(negedge ui_clk);
        raw_addr = 28'd0;
        raw_wdf_data = 128'h1111_1111_1111_1111_1111_1111_1111_1111;
        raw_en = 1'b1;
        raw_wdf_wren = 1'b1;
        dec_addr = 28'd8;
        dec_wdf_data = 128'h2222_2222_2222_2222_2222_2222_2222_2222;
        dec_en = 1'b1;
        dec_wdf_wren = 1'b1;

        timeout = 0;
        while ((raw_en || raw_wdf_wren || dec_en || dec_wdf_wren) && timeout < 100) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        repeat (5) @(posedge ui_clk);
        if (raw_accept_cycle < 0 || dec_accept_cycle <= raw_accept_cycle)
            $fatal(1, "M6 arbiter priority invalid raw/dec cycles=%0d/%0d",
                   raw_accept_cycle, dec_accept_cycle);
        if (memory_model.memory[0] !== raw_wdf_data ||
            memory_model.memory[1] !== dec_wdf_data)
            $fatal(1, "M6 arbiter write data mismatch");

        // RAW 读等待返回期间，DEC 写请求不能穿过当前事务。
        @(negedge ui_clk);
        raw_addr = 28'd0;
        raw_cmd = 3'b001;
        raw_en = 1'b1;
        dec_addr = 28'd16;
        dec_cmd = 3'b000;
        dec_wdf_data = 128'h3333_3333_3333_3333_3333_3333_3333_3333;
        dec_en = 1'b1;
        dec_wdf_wren = 1'b1;

        wait (raw_rd_data_valid);
        if (app_rd_data !== 128'h1111_1111_1111_1111_1111_1111_1111_1111)
            $fatal(1, "M6 arbiter raw read data mismatch");
        if (dec_rd_data_valid)
            $fatal(1, "M6 arbiter routed RAW read to DEC client");

        timeout = 0;
        while ((dec_en || dec_wdf_wren) && timeout < 100) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        repeat (5) @(posedge ui_clk);
        if (memory_model.memory[2] !== dec_wdf_data)
            $fatal(1, "M6 arbiter delayed DEC write mismatch");

        $display("M6_MIG_ARBITER_SIM_PASS raw_first=%0d dec_second=%0d",
                 raw_accept_cycle, dec_accept_cycle);
        $finish;
    end

endmodule

