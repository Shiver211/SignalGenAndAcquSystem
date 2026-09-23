from __future__ import annotations

import unittest

from host.core.dac_calibration import full_scale_vpp_from_test, nominal_vpk_for_target


class DacCalibrationTest(unittest.TestCase):
    def test_test_measurement_scales_to_full_range(self) -> None:
        self.assertAlmostEqual(full_scale_vpp_from_test(0.125), 0.5)
        self.assertEqual(nominal_vpk_for_target(0, 0), 0)
        self.assertAlmostEqual(nominal_vpk_for_target(0.1, 0.5), 1.0)
        self.assertAlmostEqual(nominal_vpk_for_target(5.0, 6.0), 5.0 * 5.0 / 6.0)

    def test_uncalibrated_or_unreachable_amplitude_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "实测峰峰值"):
            full_scale_vpp_from_test(0)
        with self.assertRaisesRegex(ValueError, "尚未标定"):
            nominal_vpk_for_target(0.1, 0)
        with self.assertRaisesRegex(ValueError, "请切换档位"):
            nominal_vpk_for_target(1.0, 0.5)
