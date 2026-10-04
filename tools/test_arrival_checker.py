"""Reject incomplete arrival evidence without launching Godot."""
import copy
import unittest
import arrival_checks as checks


class TestArrivalChecker(unittest.TestCase):
    def setUp(self):
        self.columns = list(checks.REQUIRED_COLUMNS)
        self.col = {n: i for i, n in enumerate(self.columns)}
        self.trace = {"columns": self.columns, "samples": [[t, [self.row(101)]] for t in (n*0.25 for n in range(85))]}
        self.jet = {"search_key": 101, "alive": True, "phase": "DONE", "report": {
            "fail": "", "touched_down": True, "td_along": 100.0, "td_cross": 0.0,
            "off_pavement_s": 0.0, "rearmed": True, "rearm_stop_error": 2.0, "airborne": True,
            "gate_changes": 0, "min_terrain_clearance": 600.0, "hold_max_dist": 2000.0,
            "hold_orbit_duration": 21.0, "hold_established_radial_err_max": 50.0}}

    def row(self, key, **changes):
        values = dict(x=2000.0, y=600.0, z=0.0, phase="HOLDING", ground=False, alive=True,
            hold_state="ORBITING", radial_error=50.0, search_key=key, line="FINAL",
            assigned_alt=600.0, stack_level=0, clearance_approach=False, clearance_runway=False,
            terrain_clearance_agl=600.0, hold_center_x=0.0, hold_center_z=0.0, hold_radius=2000.0)
        values.update(changes)
        return [values[n] for n in self.columns]

    def verdict(self, jet=None, trace=None):
        return checks.judge(jet or self.jet, trace or self.trace, runway=(0, 0, 0, 1000))

    def test_valid_evidence_passes(self):
        self.assertNotIn(False, self.verdict().values())
        self.assertEqual(checks.sustained_orbit_keys({"aircraft": [self.jet]}, self.trace, 20, self.col), [101])

    def test_missing_report_field_fails(self):
        del self.jet["report"]["min_terrain_clearance"]
        self.assertIs(self.verdict()["terrain clearance"], False)

    def test_missing_trace_fails(self):
        self.assertIs(checks.judge(self.jet)["trace evidence"], False)

    def test_missing_geometry_column_fails(self):
        self.trace["columns"].remove("hold_center_x")
        self.assertIs(self.verdict()["trace evidence"], False)

    def test_missing_survivor_fails(self):
        self.trace["samples"][0][1].append(self.row(202))
        self.assertFalse(checks.verify_roster({"aircraft": [self.jet], "timed_out": False}, self.trace, self.col, 2))

    def test_duplicate_identity_fails(self):
        self.trace["samples"][0][1].append(self.row(101))
        self.assertIs(self.verdict()["trace evidence"], False)

    def test_identity_shift_does_not_mix_histories(self):
        trace = {"columns": self.columns, "samples": [
            [0, [self.row(101, line="RIGHT"), self.row(202, line="LEFT")]],
            [0.25, [self.row(202, line="LEFT")]]]}
        self.assertTrue(checks.check_holding_episodes_from_trace(trace, 202, self.col)[0])
        trace["samples"][1][1][0][self.col["line"]] = "RIGHT"
        self.assertFalse(checks.check_holding_episodes_from_trace(trace, 202, self.col)[0])

    def test_geometry_change_fails(self):
        self.trace["samples"][1][1][0][self.col["hold_center_x"]] = 10.0
        # Sparse samples are rejected too; use normal sampler spacing for this assertion.
        self.trace["samples"] = [[0, [self.row(101)]], [0.25, [self.row(101, hold_center_x=10.0)]]]
        self.assertIs(self.verdict()["gate fixed"], False)

    def test_short_orbit_error_fails(self):
        self.jet["report"]["hold_orbit_duration"] = 19.0
        self.jet["report"]["hold_established_radial_err_max"] = 1000000.0
        self.assertIs(self.verdict()["orbit radial error"], False)

    def test_trace_error_cannot_hide_in_report(self):
        self.trace["samples"] = [[0, [self.row(101)]], [0.25, [self.row(101, radial_error=400.0)]]]
        self.assertIs(self.verdict()["orbit radial error"], False)

    def test_sustained_requires_trace_duration(self):
        self.trace["samples"] = [[0, [self.row(101)]], [0.25, [self.row(101)]]]
        self.assertEqual(checks.sustained_orbit_keys({"aircraft": [self.jet]}, self.trace, 20, self.col), [])

    def test_separate_orbits_not_added(self):
        self.trace["samples"] = [[t*0.25, [self.row(101, hold_state=("REJOINING" if t == 40 else "ORBITING"))]] for t in range(81)]
        self.assertEqual(checks.sustained_orbit_keys({"aircraft": [self.jet]}, self.trace, 20, self.col), [])

    def test_nan_evidence_fails(self):
        self.jet["report"]["min_terrain_clearance"] = float("nan")
        self.assertIs(self.verdict()["terrain clearance"], False)

    def kill_fixture(self):
        survivor = copy.deepcopy(self.jet)
        survivor["search_key"] = 202
        result = {"aircraft": [survivor], "kill_event": {"target_key": 101,
            "kill_requested_at": 0.1, "death_confirmed_at": 0.25, "clearance_released_at": 0.25,
            "pre_kill_state": {"phase": "HOLDING", "stack_level": 0, "clearance_approach": True}}}
        trace = {"columns": self.columns, "samples": [
            [0, [self.row(101, clearance_approach=True), self.row(202, stack_level=1)]],
            [0.25, [self.row(101, alive=False), self.row(202)]] ]}
        return result, trace

    def test_valid_kill_passes(self):
        r, tr = self.kill_fixture()
        self.assertTrue(checks.verify_kill_event(r, "approach_holder", tr, self.col)[0])

    def test_delayed_release_fails(self):
        r, tr = self.kill_fixture()
        r["kill_event"]["clearance_released_at"] = 2.0
        self.assertFalse(checks.verify_kill_event(r, "approach_holder", tr, self.col)[0])

    def test_wrong_waiting_target_fails(self):
        r, tr = self.kill_fixture()
        r["kill_event"]["pre_kill_state"]["stack_level"] = 1
        self.assertFalse(checks.verify_kill_event(r, "first_waiting", tr, self.col)[0])

    def test_missing_kill_survivor_fails(self):
        r, tr = self.kill_fixture()
        r["aircraft"] = []
        self.assertFalse(checks.verify_kill_event(r, "approach_holder", tr, self.col)[0])

    def test_kill_must_be_observed(self):
        r, tr = self.kill_fixture()
        tr["samples"][1][1][0][self.col["alive"]] = True
        self.assertFalse(checks.verify_kill_event(r, "approach_holder", tr, self.col)[0])

    def test_first_waiting_advances_before_wreck_removal(self):
        r, tr = self.kill_fixture()
        r["kill_event"]["waiting_keys"] = [202]
        self.assertTrue(checks.verify_kill_event(r, "first_waiting", tr, self.col)[0])
        tr["samples"][1][1][1][self.col["stack_level"]] = 1
        self.assertFalse(checks.verify_kill_event(r, "first_waiting", tr, self.col)[0])

    def test_wrong_kill_identity_fails(self):
        r, tr = self.kill_fixture()
        r["kill_event"]["target_key"] = 999
        self.assertFalse(checks.verify_kill_event(r, "approach_holder", tr, self.col)[0])

    def test_already_front_waiter_does_not_prove_step_down(self):
        r, tr = self.kill_fixture()
        r["kill_event"]["waiting_keys"] = [202]
        tr["samples"][0][1][1][self.col["stack_level"]] = 0
        self.assertFalse(checks.verify_kill_event(r, "first_waiting", tr, self.col)[0])

    def test_finished_required(self):
        self.jet["phase"] = "CLIMB"
        self.assertIs(self.verdict()["finished"], False)


if __name__ == "__main__":
    unittest.main()
