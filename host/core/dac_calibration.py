"""将高阻负载下的 DAC 实测峰峰值换算为数字幅度。"""

TEST_FRACTION = 0.25


def full_scale_vpp_from_test(measured_vpp: float) -> float:
    if measured_vpp <= 0:
        raise ValueError("实测峰峰值必须大于 0")
    return measured_vpp / TEST_FRACTION


def nominal_vpk_for_target(target_vpp: float, full_scale_vpp: float) -> float:
    if not 0 <= target_vpp <= 5:
        raise ValueError("目标峰峰值必须在 0..5 Vpp")
    if target_vpp == 0:
        return 0.0
    if full_scale_vpp <= 0:
        raise ValueError("该档尚未标定")
    if target_vpp > full_scale_vpp:
        raise ValueError(f"该档最多输出 {full_scale_vpp:.3f} Vpp，请切换档位")
    return 5.0 * target_vpp / full_scale_vpp
