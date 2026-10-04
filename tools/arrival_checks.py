"""Judge arrival evidence by aircraft identity; absent evidence never counts as a pass."""
import math

TOUCHDOWN_ZONE_M = 300.0
TOUCHDOWN_CROSS_M = 8.0
REARM_STOP_M = 6.0
MIN_AGL_M = 40.0
MAX_RADIAL_ERROR_M = 350.0
MAX_HOLD_DISTANCE_M = 12000.0
MAX_SAMPLE_GAP_S = 0.6
CLEANUP_LIMIT_S = 1.0
REQUIRED_COLUMNS = (
    "x", "y", "z", "phase", "ground", "alive", "hold_state", "radial_error",
    "search_key", "line", "assigned_alt", "stack_level", "clearance_approach",
    "clearance_runway", "terrain_clearance_agl", "hold_center_x", "hold_center_z", "hold_radius",
)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def get_column_map(trace):
    names = trace.get("columns", []) if isinstance(trace, dict) else []
    if not names or len(set(names)) != len(names):
        raise ValueError("missing or duplicate trace columns")
    col = {name: i for i, name in enumerate(names)}
    missing = set(REQUIRED_COLUMNS) - col.keys()
    if missing:
        raise ValueError("missing trace columns: " + ", ".join(sorted(missing)))
    rows = trace.get("samples", [])
    if not rows:
        raise ValueError("no trace samples")
    last_t = -1.0
    for t, samples in rows:
        if not finite(t) or t <= last_t or not samples:
            raise ValueError("invalid trace timestamps or empty roster")
        last_t = t
        keys = []
        for s in samples:
            if len(s) != len(names):
                raise ValueError("trace row does not match its schema")
            key = s[col["search_key"]]
            if not isinstance(key, int) or isinstance(key, bool) or key <= 0:
                raise ValueError("invalid aircraft identity")
            keys.append(key)
            for name in ("x", "y", "z", "terrain_clearance_agl"):
                if not finite(s[col[name]]):
                    raise ValueError("invalid " + name)
            for name in ("alive", "ground", "clearance_approach", "clearance_runway"):
                if not isinstance(s[col[name]], bool):
                    raise ValueError("invalid boolean " + name)
        if len(set(keys)) != len(keys):
            raise ValueError("duplicate aircraft identity in trace frame")
    return col


def get_samples_for_key(trace, key, col):
    return [(t, s) for t, rows in trace["samples"] for s in rows if s[col["search_key"]] == key]


def holding_metrics(trace, key, col, runway=None):
    samples = get_samples_for_key(trace, key, col)
    metrics = {"had_holding": False, "geometry_ok": True, "reason": "",
               "max_radial_error": None, "longest_orbit_s": 0.0,
               "min_agl": None, "max_distance": None}
    geometry = None
    last_orbit_t = orbit_start = None
    last_hold_t = None
    for t, s in samples:
        if s[col["phase"]] != "HOLDING" or not s[col["alive"]]:
            geometry = None
            last_orbit_t = orbit_start = last_hold_t = None
            continue
        metrics["had_holding"] = True
        numbers = [s[col[name]] for name in ("hold_center_x", "hold_center_z", "hold_radius",
                   "radial_error", "assigned_alt", "stack_level")]
        if not all(finite(n) for n in numbers) or numbers[2] <= 0 or not s[col["line"]]:
            raise ValueError("missing/invalid holding geometry or state")
        if last_hold_t is not None and t - last_hold_t > MAX_SAMPLE_GAP_S:
            raise ValueError("missing samples during holding")
        last_hold_t = t
        current = (s[col["line"]], *numbers[:3])
        if geometry is None:
            geometry = current
        elif current[0] != geometry[0] or any(abs(a-b) > 0.1 for a, b in zip(current[1:], geometry[1:])):
            metrics["geometry_ok"] = False
            metrics["reason"] = f"holding geometry shifted mid-episode at t={t:.2f}s"
        agl = s[col["terrain_clearance_agl"]]
        metrics["min_agl"] = agl if metrics["min_agl"] is None else min(metrics["min_agl"], agl)
        if runway:
            distance = math.hypot(s[col["x"]]-runway[0], s[col["z"]]-runway[1])
            metrics["max_distance"] = max(metrics["max_distance"] or 0.0, distance)
        state = s[col["hold_state"]]
        if state not in ("JOINING", "ORBITING", "REJOINING"):
            raise ValueError("invalid holding substate")
        if state == "ORBITING":
            error = abs(s[col["radial_error"]])
            metrics["max_radial_error"] = max(metrics["max_radial_error"] or 0.0, error)
            if last_orbit_t is None:
                orbit_start = t
            metrics["longest_orbit_s"] = max(metrics["longest_orbit_s"], t-orbit_start)
            last_orbit_t = t
        else:
            last_orbit_t = orbit_start = None
    return metrics


def check_holding_episodes_from_trace(trace, search_key, col):
    metrics = holding_metrics(trace, search_key, col)
    return metrics["geometry_ok"], metrics["reason"], metrics["had_holding"]


def judge(a, trace=None, col=None, runway=None):
    r = a.get("report", {})
    def number(name):
        return finite(r.get(name))
    checks = {
        "alive": a.get("alive") is True,
        "finished": a.get("phase") == "DONE" and not r.get("fail"),
        "touchdown zone": r.get("touched_down") is True and number("td_along") and number("td_cross")
            and 0.0 <= r["td_along"] <= TOUCHDOWN_ZONE_M and abs(r["td_cross"]) <= TOUCHDOWN_CROSS_M,
        "on pavement": number("off_pavement_s") and r["off_pavement_s"] == 0.0,
        "rearm stop": r.get("rearmed") is True and number("rearm_stop_error") and 0 <= r["rearm_stop_error"] <= REARM_STOP_M,
        "airborne": r.get("airborne") is True,
    }
    metrics = None
    try:
        col = get_column_map(trace)
        key = a["search_key"]
        if not get_samples_for_key(trace, key, col):
            raise ValueError("aircraft has no trace")
        metrics = holding_metrics(trace, key, col, runway)
        checks["trace evidence"] = True
    except (ValueError, TypeError, KeyError):
        checks["trace evidence"] = False
    had_holding = metrics and metrics["had_holding"]
    reported_hold = any(finite(r.get(n)) and r[n] > 0 for n in ("hold_orbit_duration", "hold_radial_err_max", "hold_max_dist"))
    if had_holding or reported_hold or a.get("phase") == "HOLDING":
        checks["gate fixed"] = bool(had_holding and metrics["geometry_ok"] and r.get("gate_changes") == 0)
        checks["terrain clearance"] = bool(had_holding and number("min_terrain_clearance")
            and r["min_terrain_clearance"] >= MIN_AGL_M and metrics["min_agl"] >= MIN_AGL_M)
        checks["hold max dist"] = bool(had_holding and number("hold_max_dist")
            and 0 < r["hold_max_dist"] <= MAX_HOLD_DISTANCE_M
            and (metrics["max_distance"] is None or metrics["max_distance"] <= MAX_HOLD_DISTANCE_M))
        if (metrics and metrics["max_radial_error"] is not None) or (finite(r.get("hold_orbit_duration")) and r["hold_orbit_duration"] > 0):
            checks["orbit radial error"] = bool(had_holding and number("hold_established_radial_err_max")
                and r["hold_established_radial_err_max"] <= MAX_RADIAL_ERROR_M
                and (metrics["max_radial_error"] is None or metrics["max_radial_error"] <= MAX_RADIAL_ERROR_M))
        else:
            checks["orbit radial error"] = "N/A"
    else:
        checks.update({name: "N/A" for name in ("gate fixed", "terrain clearance", "hold max dist", "orbit radial error")})
    return checks


def sustained_orbit_keys(res, trace, seconds, col):
    return [a["search_key"] for a in res["aircraft"] if a.get("alive") is True
            and (m := holding_metrics(trace, a["search_key"], col))["longest_orbit_s"] >= seconds
            and m["geometry_ok"] and m["max_radial_error"] is not None
            and m["max_radial_error"] <= MAX_RADIAL_ERROR_M and m["min_agl"] >= MIN_AGL_M]


def verify_roster(res, trace, col, expected_count):
    initial = {s[col["search_key"]] for s in trace["samples"][0][1]}
    final_keys = [a.get("search_key") for a in res.get("aircraft", [])]
    target = res.get("kill_event", {}).get("target_key")
    expected_survivors = initial - {target}
    return (not res.get("timed_out", True) and len(initial) == expected_count
            and len(set(final_keys)) == len(final_keys)
            and expected_survivors <= set(final_keys) <= initial
            and set(res.get("initial_keys", initial)) == initial)


def verify_kill_event(res, expected_hook, trace=None, col=None):
    reasons = []
    ke = res.get("kill_event", {})
    pre = ke.get("pre_kill_state", {})
    key = ke.get("target_key")
    requested, died, released = [ke.get(n) for n in ("kill_requested_at", "death_confirmed_at", "clearance_released_at")]
    if not isinstance(key, int) or key <= 0 or not all(finite(t) for t in (requested, died, released)):
        return False, ["invalid kill event metadata"]
    if expected_hook == "approach_holder" and pre.get("clearance_approach") is not True:
        reasons.append("target did not own APPROACH clearance")
    if expected_hook == "first_waiting" and (pre.get("phase") != "HOLDING" or pre.get("stack_level") != 0):
        reasons.append("target was not first waiting")
    if not 0 <= died-requested <= CLEANUP_LIMIT_S:
        reasons.append("target death not confirmed within 1.0s")
    if not 0 <= released-requested <= CLEANUP_LIMIT_S:
        reasons.append("clearance not released within 1.0s")
    try:
        col = get_column_map(trace)
        initial = {s[col["search_key"]] for s in trace["samples"][0][1]}
        samples = get_samples_for_key(trace, key, col)
        before = [(t, s) for t, s in samples if t <= requested and s[col["alive"]]]
        after = [(t, s) for t, s in samples if requested <= t <= requested+CLEANUP_LIMIT_S and not s[col["alive"]]]
        if key not in initial or not before or not after:
            reasons.append("intended target's live-to-dead transition is missing")
        if after and not any(not s[col["clearance_approach"]] and not s[col["clearance_runway"]] for t, s in after):
            reasons.append("clearance cleanup not observed while wreck remains")
        if expected_hook == "first_waiting":
            waiting = ke.get("waiting_keys", [])
            advanced = [other for other in waiting if any(
                requested-MAX_SAMPLE_GAP_S <= t < requested and s[col["alive"]]
                and s[col["phase"]] == "HOLDING" and s[col["stack_level"]] > 0
                for t, s in get_samples_for_key(trace, other, col)) and any(
                requested <= t <= requested+CLEANUP_LIMIT_S and s[col["alive"]]
                and s[col["phase"]] == "HOLDING" and s[col["stack_level"]] == 0
                for t, s in get_samples_for_key(trace, other, col))]
            if not waiting or not advanced:
                reasons.append("next waiting aircraft did not advance within 1.0s")
        survivor_keys = {a["search_key"] for a in res["aircraft"] if a["search_key"] != key}
        if survivor_keys != initial-{key}:
            reasons.append("missing or unexpected survivor")
        for a in res["aircraft"]:
            if a["search_key"] != key and (a.get("alive") is not True or a.get("phase") != "DONE"):
                reasons.append("survivor did not complete the cycle")
    except (ValueError, KeyError, TypeError):
        reasons.append("missing/invalid trace evidence for kill")
    return not reasons, reasons
