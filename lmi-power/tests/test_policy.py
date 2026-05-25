import unittest

from lmi_power.config import PolicyConfig
from lmi_power.policy import AUTO, INHIBIT, PolicyInputs, PolicyState, decide


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.config = PolicyConfig()

    def decision(self, capacity, temp=300, behaviour=AUTO, state=PolicyState(), target=700000, effective=700000):
        return decide(
            self.config,
            state,
            PolicyInputs(
                capacity=capacity,
                temp_decic=temp,
                charge_behaviour=behaviour,
                input_current_limit_target_ua=target,
                input_current_limit_effective_ua=effective,
            ),
        )

    def test_stops_at_stop_percent(self):
        state, decision = self.decision(70)
        self.assertTrue(state.soc_block)
        self.assertEqual(decision.target_behaviour, INHIBIT)
        self.assertEqual(decision.reason, "soc_high")
        self.assertEqual(decision.target_input_current_ua, self.config.hold_input_current_ua)

    def test_resumes_at_resume_percent(self):
        state, decision = self.decision(65, behaviour=INHIBIT, state=PolicyState(soc_block=True))
        self.assertFalse(state.soc_block)
        self.assertEqual(decision.target_behaviour, AUTO)
        self.assertEqual(decision.reason, "soc_low")
        self.assertEqual(decision.target_input_current_ua, self.config.charge_input_current_ua)

    def test_window_seeds_from_current_behaviour(self):
        _, hold = self.decision(68, behaviour=INHIBIT)
        _, charge = self.decision(68, behaviour=AUTO)
        self.assertEqual(hold.reason, "soc_hold")
        self.assertEqual(charge.reason, "soc_window")

    def test_hot_hysteresis(self):
        state, hot = self.decision(65, temp=550)
        self.assertEqual(state.temp_block, "hot")
        self.assertEqual(hot.target_behaviour, INHIBIT)
        state, still_hot = self.decision(65, temp=510, state=state)
        self.assertEqual(state.temp_block, "hot")
        self.assertEqual(still_hot.reason, "hot")
        state, cool = self.decision(65, temp=500, state=state)
        self.assertIsNone(state.temp_block)
        self.assertEqual(cool.target_behaviour, AUTO)

    def test_reports_current_limit_mismatch(self):
        _, decision = self.decision(65, target=1000000, effective=550000)
        self.assertTrue(decision.input_limit_mismatch)


if __name__ == "__main__":
    unittest.main()
