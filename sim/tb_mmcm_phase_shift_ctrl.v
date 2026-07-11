`timescale 1ns / 1ps

module tb_mmcm_phase_shift_ctrl;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg request_toggle = 1'b0;
    reg direction_inc = 1'b1;
    reg [9:0] step_count = 10'd1;
    reg psdone = 1'b0;
    wire psen;
    wire psincdec;
    wire busy;
    wire done_toggle;
    wire signed [15:0] phase_position;

    integer psen_count = 0;
    reg done_before;

    always #5 clk = ~clk;

    mmcm_phase_shift_ctrl #(
        .INITIAL_STEPS (10'd2)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .request_toggle (request_toggle),
        .direction_inc  (direction_inc),
        .step_count     (step_count),
        .psdone         (psdone),
        .psen           (psen),
        .psincdec       (psincdec),
        .busy           (busy),
        .done_toggle    (done_toggle),
        .phase_position (phase_position)
    );

    always @(posedge clk) begin
        if (psen) begin
            psen_count <= psen_count + 1;
        end
    end

    // 模拟 MMCM：收到 PSEN 三个周期后给出单周期 PSDONE。
    always @(posedge psen) begin
        repeat (3) @(posedge clk);
        psdone <= 1'b1;
        @(posedge clk);
        psdone <= 1'b0;
    end

    task issue_move;
        input move_inc;
        input [9:0] move_steps;
        input signed [15:0] expected_position;
        input integer expected_total_psen;
        begin
            @(negedge clk);
            direction_inc = move_inc;
            step_count = move_steps;
            done_before = done_toggle;
            request_toggle = ~request_toggle;

            wait (busy == 1'b1);
            wait (done_toggle != done_before);
            @(negedge clk);

            if (phase_position !== expected_position) begin
                $display("M2_PHASE_CTRL_FAIL position expected=%0d actual=%0d",
                         expected_position, phase_position);
                $fatal;
            end
            if (psen_count !== expected_total_psen) begin
                $display("M2_PHASE_CTRL_FAIL psen expected=%0d actual=%0d",
                         expected_total_psen, psen_count);
                $fatal;
            end
            if (busy !== 1'b0) begin
                $display("M2_PHASE_CTRL_FAIL busy did not clear");
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;

        wait (busy == 1'b1);
        wait (done_toggle == 1'b1);
        @(negedge clk);
        if ((phase_position !== 16'sd2) || (psen_count !== 2)) begin
            $display("M2_PHASE_CTRL_FAIL initial position=%0d psen=%0d",
                     phase_position, psen_count);
            $fatal;
        end

        issue_move(1'b1, 10'd3, 16'sd5, 5);
        issue_move(1'b0, 10'd2, 16'sd3, 7);
        issue_move(1'b1, 10'd0, 16'sd4, 8);

        $display("M2_PHASE_CTRL_SIM_PASS");
        $finish;
    end

endmodule
