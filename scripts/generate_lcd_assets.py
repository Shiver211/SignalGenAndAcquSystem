"""生成 LCD 演示的 8x8 ASCII 字模、正弦表及 32x32 静态图；无需第三方库。"""
from pathlib import Path
import math

ROOT = Path(__file__).resolve().parents[1]

# 每行 5 位，字符置于 8x8 单元中；屏上放大两倍。
FONT = {
    ' ': [0, 0, 0, 0, 0, 0, 0],
    '0': [14, 17, 19, 21, 25, 17, 14],
    '1': [4, 12, 4, 4, 4, 4, 14],
    '2': [14, 17, 1, 2, 4, 8, 31],
    '3': [30, 1, 1, 14, 1, 1, 30],
    '4': [2, 6, 10, 18, 31, 2, 2],
    '5': [31, 16, 16, 30, 1, 1, 30],
    '6': [14, 16, 16, 30, 17, 17, 14],
    '7': [31, 1, 2, 4, 8, 8, 8],
    '8': [14, 17, 17, 14, 17, 17, 14],
    '9': [14, 17, 17, 15, 1, 1, 14],
    'A': [14, 17, 17, 31, 17, 17, 17],
    'B': [30, 17, 17, 30, 17, 17, 30],
    'C': [14, 17, 16, 16, 16, 17, 14],
    'D': [30, 17, 17, 17, 17, 17, 30],
    'E': [31, 16, 16, 30, 16, 16, 31],
    'F': [31, 16, 16, 30, 16, 16, 16],
    'G': [14, 17, 16, 23, 17, 17, 15],
    'H': [17, 17, 17, 31, 17, 17, 17],
    'I': [14, 4, 4, 4, 4, 4, 14],
    'J': [7, 2, 2, 2, 2, 18, 12],
    'K': [17, 18, 20, 24, 20, 18, 17],
    'L': [16, 16, 16, 16, 16, 16, 31],
    'M': [17, 27, 21, 21, 17, 17, 17],
    'N': [17, 25, 21, 19, 17, 17, 17],
    'O': [14, 17, 17, 17, 17, 17, 14],
    'P': [30, 17, 17, 30, 16, 16, 16],
    'Q': [14, 17, 17, 17, 21, 18, 13],
    'R': [30, 17, 17, 30, 20, 18, 17],
    'S': [15, 16, 16, 14, 1, 1, 30],
    'T': [31, 4, 4, 4, 4, 4, 4],
    'U': [17, 17, 17, 17, 17, 17, 14],
    'V': [17, 17, 17, 17, 17, 10, 4],
    'W': [17, 17, 17, 21, 21, 21, 10],
    'X': [17, 17, 10, 4, 10, 17, 17],
    'Y': [17, 17, 10, 4, 4, 4, 4],
    'Z': [31, 1, 2, 4, 8, 16, 31],
    '/': [1, 2, 2, 4, 8, 8, 16],
    '-': [0, 0, 0, 31, 0, 0, 0],
    '+': [0, 4, 4, 31, 4, 4, 0],
    '.': [0, 0, 0, 0, 0, 12, 12],
}


def sprite_pixel(x, y):
    if (x - 23) ** 2 + (y - 8) ** 2 <= 16:
        return 1  # 太阳
    if y >= 27:
        return 3  # 草地
    if y >= 10 + abs(x - 10) or y >= 15 + abs(x - 25):
        return 2  # 山峰
    return 0  # 天空


def generate():
    lines = [
        '`timescale 1ns / 1ps',
        '// 由 scripts/generate_lcd_assets.py 生成。修改资源后重新运行脚本。',
        'module lcd_demo_assets (',
        '    input wire [7:0] character, input wire [2:0] font_row,',
        '    input wire [7:0] sine_phase,',
        '    input wire [4:0] image_x, image_y,',
        '    output wire [7:0] font_bits,',
        '    output reg [8:0] sine_y, output reg [23:0] image_rgb',
        ');',
        '    reg [63:0] glyph, image_row;',
        '    wire [1:0] image_index = image_row >> ((31 - image_x) * 2);',
        '    assign font_bits = glyph >> ((7 - font_row) * 8);',
        '    always @* begin',
        '        case (character)',
    ]
    for ch, rows in sorted(FONT.items()):
        glyph = int.from_bytes(bytes([r << 2 for r in rows] + [0]), 'big')
        lines.append(f"            8'h{ord(ch):02x}: glyph = 64'h{glyph:016x}; // {ch}")
    lines += ["            default: glyph = 64'h0;", '        endcase',
              '        case (sine_phase)']
    for phase in range(256):
        y = round(336 - 44 * math.sin(phase * math.tau / 256))
        lines.append(f"            8'd{phase}: sine_y = 9'd{y};")
    lines += ["            default: sine_y = 9'd336;", '        endcase',
              '        case (image_y)']
    for y in range(32):
        bits = 0
        for x in range(32):
            bits = (bits << 2) | sprite_pixel(x, y)
        lines.append(f"            5'd{y}: image_row = 64'h{bits:016x};")
    lines += ["            default: image_row = 64'h0;", '        endcase',
              '        case (image_index)',
              "            0: image_rgb = 24'h468dcc;",
              "            1: image_rgb = 24'hffe17a;",
              "            2: image_rgb = 24'h35566a;",
              "            3: image_rgb = 24'h42c69a;",
              '        endcase', '    end', 'endmodule', '']
    dest = ROOT / 'rtl' / 'display' / 'lcd_demo_assets.v'
    dest.write_text('\n'.join(lines), encoding='utf-8')
    print(f'LCD 资源已生成：{dest}')


if __name__ == '__main__':
    generate()
