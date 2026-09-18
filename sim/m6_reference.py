"""生成 M6 共用测试向量，校验当前包络与测量通路的 HDL 输出。"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parent
VECTOR_DIR = ROOT / "vectors"
SAMPLE_RATE = 1024
SAMPLE_COUNT = 1024
BUCKET_SIZE = 32
WINDOW_SAMPLES = 512


def build_vectors() -> list[tuple[int, int, int, int]]:
    vectors: list[tuple[int, int, int, int]] = []
    for index in range(SAMPLE_COUNT):
        # A：32Hz 主信号 + 240Hz 带外分量；B：64Hz 方波。
        code_a = round(
            2048
            + 800 * math.sin(2 * math.pi * index / 32)
            + 100 * math.sin(2 * math.pi * 240 * index / SAMPLE_RATE)
        )
        code_b = 2850 if (index % 16) < 8 else 1250

        # 第一个包络桶内放入单点峰值，简单抽点不会看到该峰值。
        if index == 7:
            code_a = 4095

        code_a = min(4095, max(0, code_a))
        code_b = min(4095, max(0, code_b))
        otr_a = int(index in {11, 511, 777})
        otr_b = int(index in {21, 700})
        vectors.append((code_a, code_b, otr_a, otr_b))
    return vectors


def envelope_reference(
    vectors: list[tuple[int, int, int, int]],
) -> list[int]:
    result: list[int] = []
    for start in range(0, len(vectors), BUCKET_SIZE):
        bucket = vectors[start : start + BUCKET_SIZE]
        a = [sample[0] for sample in bucket]
        b = [sample[1] for sample in bucket]
        packed = min(a) | (max(a) << 16) | (min(b) << 32) | (max(b) << 48)
        result.append(packed)
    return result


def period_reference(
    codes: list[int], low: int, high_threshold: int,
) -> tuple[int, int, bool]:
    crossings: list[int] = []
    high = False
    for index, code in enumerate(codes):
        if not high and code >= high_threshold:
            crossings.append(index)
            high = True
        elif high and code <= low:
            high = False
    periods = np.diff(np.asarray(crossings, dtype=np.int64))
    if len(periods) < 8:
        return 0, 0, False
    period_sum = int(periods.sum())
    period_count = int(len(periods))
    return (
        period_sum // period_count,
        (SAMPLE_RATE * period_count + period_sum // 2) // period_sum,
        True,
    )


def adaptive_thresholds(codes: list[int]) -> tuple[int, int]:
    minimum, maximum = min(codes), max(codes)
    center = (minimum + maximum) // 2
    hysteresis = max(16, (maximum - minimum) // 4)
    return max(0, center - hysteresis), min(4095, center + hysteresis)


def measurement_reference(
    vectors: list[tuple[int, int, int, int]],
) -> list[int]:
    result: list[int] = []
    thresholds_a: tuple[int, int] | None = None
    thresholds_b: tuple[int, int] | None = None
    for start in range(0, len(vectors), WINDOW_SAMPLES):
        window = vectors[start : start + WINDOW_SAMPLES]
        a = [sample[0] for sample in window]
        b = [sample[1] for sample in window]
        min_a, max_a = min(a), max(a)
        min_b, max_b = min(b), max(b)
        mean_a = sum(a) // len(a)
        mean_b = sum(b) // len(b)
        otr_a = sum(sample[2] for sample in window)
        otr_b = sum(sample[3] for sample in window)
        if thresholds_a is None:
            period_a, frequency_a, valid_a = 0, 0, False
            period_b, frequency_b, valid_b = 0, 0, False
        else:
            period_a, frequency_a, valid_a = period_reference(
                a, thresholds_a[0], thresholds_a[1],
            )
            period_b, frequency_b, valid_b = period_reference(
                b, thresholds_b[0], thresholds_b[1],
            )
        thresholds_a = adaptive_thresholds(a)
        thresholds_b = adaptive_thresholds(b)

        packed = 0
        packed |= min_a
        packed |= max_a << 16
        packed |= min_b << 32
        packed |= max_b << 48
        packed |= mean_a << 64
        packed |= mean_b << 96
        packed |= (max_a - min_a) << 128
        packed |= (max_b - min_b) << 144
        packed |= otr_a << 160
        packed |= otr_b << 192
        packed |= period_a << 224
        packed |= period_b << 256
        packed |= frequency_a << 288
        packed |= frequency_b << 320
        packed |= (int(valid_a) | (int(valid_b) << 1)) << 352
        result.append(packed)
    return result


def write_mem(path: Path, values: list[int], hex_digits: int) -> None:
    path.write_text(
        "".join(f"{value:0{hex_digits}X}\n" for value in values),
        encoding="ascii",
    )


def generate() -> None:
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    vectors = build_vectors()
    packed_input = [
        code_a | (code_b << 12) | (otr_a << 24) | (otr_b << 25)
        for code_a, code_b, otr_a, otr_b in vectors
    ]
    write_mem(VECTOR_DIR / "m6_input.mem", packed_input, 7)
    write_mem(VECTOR_DIR / "m6_envelope_expected.mem", envelope_reference(vectors), 16)
    write_mem(
        VECTOR_DIR / "m6_measurement_expected.mem",
        measurement_reference(vectors),
        92,
    )
    print(
        "M6_PYTHON_REFERENCE_GENERATED "
        f"samples={len(vectors)} envelope={len(vectors) // BUCKET_SIZE} "
        f"measurement={len(vectors) // WINDOW_SAMPLES}"
    )


def verify(result_path: Path) -> None:
    vectors = build_vectors()
    expected = {
        "E": envelope_reference(vectors),
        # 与处理链测试的刷新节拍一致：计算完成后才重开测量窗口，
        # 1024 个输入样本只覆盖第一个完整的 512-sample 测量窗口。
        "M": measurement_reference(vectors)[:1],
    }
    observed: dict[str, list[int]] = {"E": [], "M": []}
    for line in result_path.read_text(encoding="ascii").splitlines():
        fields = line.split(",")
        if fields[0] in observed:
            observed[fields[0]].append(int(fields[2], 16))

    for kind, values in expected.items():
        if observed[kind] != values:
            raise SystemExit(f"M6 Python 校验失败：HDL {kind} 结果与 Python 不一致")
    print(
        "M6_PYTHON_REFERENCE_PASS "
        f"envelope={len(observed['E'])} measurement={len(observed['M'])}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("generate", "verify"))
    parser.add_argument("result", nargs="?", type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        generate()
    elif args.result is None:
        parser.error("verify 需要 HDL 结果文件")
    else:
        verify(args.result)


if __name__ == "__main__":
    main()
