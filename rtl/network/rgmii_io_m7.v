`timescale 1ns / 1ps

// 7-series RGMII I/O。YT8531C 绑带已启用 RX/TX 内部延迟，因此 FPGA 端
// 发送时钟与数据同相，接收端直接使用 PHY 提供的延迟后 RXC 采样。
module rgmii_io_m7 (
    input  wire       reset_tx,
    input  wire       clk_tx_125m,
    input  wire       clk_ref_200m,
    input  wire [7:0] gmii_txd,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,

    input  wire       eth_rxc_1,
    input  wire [3:0] eth_rxd_1,
    input  wire       eth_rx_ctl_1,
    output wire       eth_txc_1,
    output wire [3:0] eth_txd_1,
    output wire       eth_tx_ctl_1,

    output wire       rx_clk,
    output wire [7:0] gmii_rxd,
    output wire       gmii_rx_dv,
    output wire       gmii_rx_er
);

    wire eth_rxc_ibuf;
    wire [3:0] eth_rxd_ibuf;
    wire [3:0] eth_rxd_delayed;
    wire eth_rx_ctl_ibuf;
    wire eth_rx_ctl_delayed;
    wire [3:0] rx_rise;
    wire [3:0] rx_fall;
    wire rx_ctl_rise;
    wire rx_ctl_fall;
    wire tx_ctl_fall = gmii_tx_en ^ gmii_tx_er;
    wire txc_oddr;
    wire [3:0] txd_oddr;
    wire tx_ctl_oddr;
    wire idelayctrl_ready;

    (* IODELAY_GROUP = "rgmii_io_m7" *) IDELAYCTRL u_rgmii_idelayctrl (
        .RDY(idelayctrl_ready), .REFCLK(clk_ref_200m), .RST(reset_tx)
    );

    IBUF u_rxc_ibuf (.I(eth_rxc_1), .O(eth_rxc_ibuf));
    BUFG u_rxc_bufg (.I(eth_rxc_ibuf), .O(rx_clk));

    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_rgmii_data
            IBUF u_rxd_ibuf (.I(eth_rxd_1[bit_index]), .O(eth_rxd_ibuf[bit_index]));
            // RGMII-ID 外部延迟基础上再补 24 taps，平衡布线后的接收 setup/hold 裕量。
            (* IODELAY_GROUP = "rgmii_io_m7" *) IDELAYE2 #(
                .CINVCTRL_SEL("FALSE"), .DELAY_SRC("IDATAIN"),
                .HIGH_PERFORMANCE_MODE("TRUE"), .IDELAY_TYPE("FIXED"),
                .IDELAY_VALUE(24), .PIPE_SEL("FALSE"),
                .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
            ) u_rxd_idelay (
                .C(1'b0), .CE(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(5'd0),
                .DATAIN(1'b0), .DATAOUT(eth_rxd_delayed[bit_index]),
                .IDATAIN(eth_rxd_ibuf[bit_index]), .INC(1'b0), .LD(1'b0),
                .LDPIPEEN(1'b0), .REGRST(1'b0)
            );
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")
            ) u_rxd_iddr (
                .Q1(rx_rise[bit_index]), .Q2(rx_fall[bit_index]),
                .C(rx_clk), .CE(1'b1), .D(eth_rxd_delayed[bit_index]),
                .R(1'b0), .S(1'b0)
            );
            ODDR #(
                .DDR_CLK_EDGE("SAME_EDGE"),
                .INIT(1'b0), .SRTYPE("SYNC")
            ) u_txd_oddr (
                .Q(txd_oddr[bit_index]), .C(clk_tx_125m), .CE(1'b1),
                .D1(gmii_txd[bit_index]), .D2(gmii_txd[bit_index + 4]),
                .R(reset_tx), .S(1'b0)
            );
            OBUF u_txd_obuf (.I(txd_oddr[bit_index]), .O(eth_txd_1[bit_index]));
        end
    endgenerate

    IBUF u_rx_ctl_ibuf (.I(eth_rx_ctl_1), .O(eth_rx_ctl_ibuf));
    (* IODELAY_GROUP = "rgmii_io_m7" *) IDELAYE2 #(
        .CINVCTRL_SEL("FALSE"), .DELAY_SRC("IDATAIN"),
        .HIGH_PERFORMANCE_MODE("TRUE"), .IDELAY_TYPE("FIXED"),
        .IDELAY_VALUE(24), .PIPE_SEL("FALSE"),
        .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
    ) u_rx_ctl_idelay (
        .C(1'b0), .CE(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(5'd0),
        .DATAIN(1'b0), .DATAOUT(eth_rx_ctl_delayed),
        .IDATAIN(eth_rx_ctl_ibuf), .INC(1'b0), .LD(1'b0),
        .LDPIPEEN(1'b0), .REGRST(1'b0)
    );
    IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")
    ) u_rx_ctl_iddr (
        .Q1(rx_ctl_rise), .Q2(rx_ctl_fall), .C(rx_clk), .CE(1'b1),
        .D(eth_rx_ctl_delayed), .R(1'b0), .S(1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0), .SRTYPE("SYNC")
    ) u_tx_ctl_oddr (
        .Q(tx_ctl_oddr), .C(clk_tx_125m), .CE(1'b1),
        .D1(gmii_tx_en), .D2(tx_ctl_fall), .R(reset_tx), .S(1'b0)
    );
    OBUF u_tx_ctl_obuf (.I(tx_ctl_oddr), .O(eth_tx_ctl_1));

    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0), .SRTYPE("SYNC")
    ) u_txc_oddr (
        .Q(txc_oddr), .C(clk_tx_125m), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(reset_tx), .S(1'b0)
    );
    OBUF u_txc_obuf (.I(txc_oddr), .O(eth_txc_1));

    assign gmii_rxd   = {rx_fall, rx_rise};
    assign gmii_rx_dv = rx_ctl_rise;
    assign gmii_rx_er = rx_ctl_rise ^ rx_ctl_fall;

endmodule
