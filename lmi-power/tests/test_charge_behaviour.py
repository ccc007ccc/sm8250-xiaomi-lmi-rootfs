import unittest

from lmi_power.sysfs import active_charge_behaviour


class ChargeBehaviourTest(unittest.TestCase):
    def test_active_bracket_value(self):
        self.assertEqual(active_charge_behaviour("auto [inhibit-charge]"), "inhibit-charge")
        self.assertEqual(active_charge_behaviour("[auto] inhibit-charge"), "auto")

    def test_plain_value(self):
        self.assertEqual(active_charge_behaviour("auto"), "auto")
        self.assertEqual(active_charge_behaviour("inhibit-charge"), "inhibit-charge")


if __name__ == "__main__":
    unittest.main()
