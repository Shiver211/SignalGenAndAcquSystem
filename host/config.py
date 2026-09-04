"""上位机与 FPGA 共享的固定部署参数。"""

PC_IP = "192.168.1.100"
FPGA_IP = "192.168.1.10"
UDP_PORT = 5001
UART_BAUD = 921_600

# 当前双通道 AD9226 为 65Msps；后续单通道交织为 130Msps。
# 千兆网不能持续上传满速 RAW，短时基按 1:1 触发窗口上传，长时基用 Min/Max。
ADC_SAMPLE_RATE_HZ = 65_000_000
INTERLEAVE_SAMPLE_RATE_HZ = 130_000_000
# 与 FPGA 包络 FIFO 深度一致，保证 1:1 突发可被吸收后再经千兆网送出。
MAX_ENVELOPE_POINTS = 2048
# 应用层按约 80MB/s 估算有效载荷，给 MAC/IP/UDP 头和测量包留余量。
GBE_ENVELOPE_BYTES_PER_SEC = 80_000_000
