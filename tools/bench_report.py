import sys
import os
import json
import math

def percentile(data, p):
    if not data:
        return 0.0
    s = sorted(data)
    idx = int(round(p / 100.0 * len(s) + 0.5)) - 1
    return s[max(0, min(len(s) - 1, idx))]

def main():
    save_baseline = "--save-baseline" in sys.argv
    run_dir = None
    for arg in sys.argv[1:]:
        if not arg.startswith("--"):
            run_dir = arg
            break

    bench_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "crashlog", "bench"))
    if not run_dir:
        if not os.path.exists(bench_dir):
            print("No run directory found (bench folder does not exist).")
            sys.exit(1)
        # Find newest subdir with frames.csv
        subdirs = [os.path.join(bench_dir, d) for d in os.listdir(bench_dir) if os.path.isdir(os.path.join(bench_dir, d))]
        valid_dirs = [d for d in subdirs if os.path.exists(os.path.join(d, "frames.csv"))]
        if not valid_dirs:
            print("No valid run directory found containing frames.csv.")
            sys.exit(1)
        run_dir = max(valid_dirs, key=os.path.getmtime)
    
    csv_path = os.path.join(run_dir, "frames.csv")
    if not os.path.exists(csv_path):
        print(f"frames.csv not found in {run_dir}")
        sys.exit(1)

    meta = {}
    meta_path = os.path.join(run_dir, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, "r") as f:
            meta = json.load(f)

    with open(csv_path, "r") as f:
        lines = f.readlines()

    if not lines:
        sys.exit(1)

    headers = lines[0].strip().split(",")
    col_idx = {h: i for i, h in enumerate(headers)}

    rows = []
    for line in lines[1:]:
        if not line.strip(): continue
        parts = line.strip().split(",")
        rows.append([float(p) for p in parts])

    # Filter rows
    valid_rows = []
    skip_next = False
    for i, row in enumerate(rows):
        flag = int(row[col_idx["flag"]])
        if flag == 2:
            continue
        if flag == 1:
            skip_next = True
            continue
        if skip_next:
            skip_next = False
            continue
        valid_rows.append(row)

    if not valid_rows:
        print("No valid frames left after filtering.")
        sys.exit(1)

    frames = len(valid_rows)
    sim_time_min = valid_rows[0][col_idx["sim_time"]]
    sim_time_max = valid_rows[-1][col_idx["sim_time"]]
    sim_seconds_covered = sim_time_max - sim_time_min

    wall_ms = [r[col_idx["wall_ms"]] for r in valid_rows]
    sum_wall_ms = sum(wall_ms)
    avg_fps = frames / (sum_wall_ms / 1000.0) if sum_wall_ms > 0 else 0
    p99_wall_ms = percentile(wall_ms, 99)
    p999_wall_ms = percentile(wall_ms, 99.9)
    
    fps_1_low = 1000.0 / p99_wall_ms if p99_wall_ms > 0 else 0
    fps_01_low = 1000.0 / p999_wall_ms if p999_wall_ms > 0 else 0

    miss_60 = sum(1 for w in wall_ms if w > 16.667)
    miss_30 = sum(1 for w in wall_ms if w > 33.333)
    # Hitches: frames over 20 ms, i.e. a visible stutter even for a player capped at 60 FPS
    hitches = sum(1 for w in wall_ms if w > 20.0)
    total_s = sum(wall_ms) / 1000.0

    summary = {
        "frames": frames,
        "sim_seconds_covered": sim_seconds_covered,
        "meta": meta,
        "avg_fps": avg_fps,
        "1_low": fps_1_low,
        "0.1_low": fps_01_low,
        "miss_60_pct": (miss_60 / frames) * 100 if frames > 0 else 0,
        "miss_30_pct": (miss_30 / frames) * 100 if frames > 0 else 0,
        "hitches_per_min": (hitches / total_s) * 60.0 if total_s > 0 else 0,
        "sections": {},
        "ticks_hist": {0:0, 1:0, 2:0, 3:0},
        "spikes": [],
        "cam_modes": {},
        "weapons_buckets": {},
        "leak_check": {}
    }

    # Sections
    has_audio = "audio_ms" in col_idx
    sections = ["wall_ms", "cpu_total", "sim_ms", "sync_ms", "camera_ms", "fetch_ms", "vfx_ms", "hud_ms"]
    if has_audio:
        sections.append("audio_ms")
    sections.extend(["gpu_ms", "render_cpu_ms"])

    section_cols = ["sim_ms", "sync_ms", "camera_ms", "fetch_ms", "vfx_ms", "hud_ms"]
    if has_audio:
        section_cols.append("audio_ms")
    # C++ trails + tracers (2026-09-29): before that, this work was GDScript and counted in vfx_ms
    if "fx_cpp_ms" in col_idx:
        sections.insert(sections.index("gpu_ms"), "fx_cpp_ms")
        section_cols.append("fx_cpp_ms")

    section_data = {s: [] for s in sections}
    for r in valid_rows:
        for s in sections:
            if s == "cpu_total":
                val = sum(r[col_idx[c]] for c in section_cols)
            else:
                val = r[col_idx[s]]
            section_data[s].append(val)
            
    for s in sections:
        d = section_data[s]
        summary["sections"][s] = {
            "p50": percentile(d, 50),
            "p95": percentile(d, 95),
            "p99": percentile(d, 99),
            "max": max(d) if d else 0
        }

    # Ticks
    for r in valid_rows:
        t = int(r[col_idx["ticks"]])
        if t >= 3:
            summary["ticks_hist"][3] += 1
        else:
            summary["ticks_hist"][t] += 1

    # Spikes
    spikes = [r for r in valid_rows if r[col_idx["wall_ms"]] > 25.0]
    spikes.sort(key=lambda x: x[col_idx["wall_ms"]], reverse=True)
    spikes = spikes[:15]
    
    sub_cols = ["sim_ms", "sync_ms", "camera_ms", "fetch_ms", "vfx_ms", "hud_ms"]
    if has_audio:
        sub_cols.append("audio_ms")
    sub_cols.append("gpu_ms")
    for r in spikes:
        max_sub = max(sub_cols, key=lambda c: r[col_idx[c]])
        max_val = r[col_idx[max_sub]]
        summary["spikes"].append({
            "frame": int(r[col_idx["frame"]]),
            "sim_time": r[col_idx["sim_time"]],
            "wall_ms": r[col_idx["wall_ms"]],
            "cam_mode": int(r[col_idx["cam_mode"]]),
            "largest_section": max_sub,
            "largest_val": max_val,
            "alive_air": r[col_idx["alive_air"]],
            "weapons": r[col_idx["weapons"]],
            "explosions": r[col_idx["explosions"]]
        })

    # Cam modes
    cam_names = {1: "COCKPIT", 2: "HORIZON_CHASE", 3: "LOCKED_TAIL", 4: "FLY_BY", 5: "PADLOCK_THREAT", 6: "SPECTATOR_AI", 7: "TOWER", 8: "ACTION_MOUNT"}
    cam_data = {}
    for r in valid_rows:
        cm = int(r[col_idx["cam_mode"]])
        if cm not in cam_data:
            cam_data[cm] = []
        cam_data[cm].append(r[col_idx["wall_ms"]])

    for cm, d in cam_data.items():
        summary["cam_modes"][cam_names.get(cm, str(cm))] = {
            "frames": len(d),
            "avg_fps": len(d) / (sum(d)/1000.0) if sum(d) > 0 else 0,
            "p99_wall_ms": percentile(d, 99)
        }

    # Weapon buckets
    wb = {"0-99": [], "100-199": [], "200-399": [], "400+": []}
    for r in valid_rows:
        w = r[col_idx["weapons"]]
        if w < 100:
            wb["0-99"].append(r[col_idx["wall_ms"]])
        elif w < 200:
            wb["100-199"].append(r[col_idx["wall_ms"]])
        elif w < 400:
            wb["200-399"].append(r[col_idx["wall_ms"]])
        else:
            wb["400+"].append(r[col_idx["wall_ms"]])
            
    for k, d in wb.items():
        if d:
            summary["weapons_buckets"][k] = {
                "avg_wall_ms": sum(d) / len(d),
                "p99_wall_ms": percentile(d, 99)
            }

    # Motion smoothness (player jet): |displayed step - speed*dt| / (speed*dt); 0 = perfectly smooth
    if "motion_err" in col_idx:
        me = [r[col_idx["motion_err"]] for r in valid_rows if r[col_idx["motion_err"]] >= 0.0]
        if me:
            summary["motion_err_mean_pct"] = 100.0 * sum(me) / len(me)
            summary["motion_err_p95_pct"] = 100.0 * percentile(me, 95)
            summary["motion_err_p99_pct"] = 100.0 * percentile(me, 99)

    # Leak check
    nodes_all = [r[col_idx["nodes"]] for r in valid_rows]
    ve_all = [r[col_idx["visual_entities"]] for r in valid_rows]
    summary["leak_check"] = {
        "nodes": {"first": nodes_all[0], "last": nodes_all[-1], "max": max(nodes_all)},
        "visual_entities": {"first": ve_all[0], "last": ve_all[-1], "max": max(ve_all)}
    }

    with open(os.path.join(run_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
        
    baseline_path = os.path.join(bench_dir, "baseline.json")
    if save_baseline:
        with open(baseline_path, "w") as f:
            json.dump(summary, f, indent=2)
            
    # Print report
    print(f"--- Benchmark Report ---")
    print(f"Run Dir: {run_dir}")
    print(f"Frames Analysed: {frames} ({sim_seconds_covered:.1f} sim seconds)")
    if meta:
        print(f"Label: {meta.get('label')} | CPU: {meta.get('cpu')} | GPU: {meta.get('gpu')}")
    
    print(f"\nAvg FPS: {avg_fps:.1f}")
    print(f"1% Low:  {fps_1_low:.1f}")
    print(f"0.1% Low: {fps_01_low:.1f}")
    print(f"Missed 60fps (>16.67ms): {summary['miss_60_pct']:.2f}%")
    if "motion_err_mean_pct" in summary:
        print(f"Motion error (player jet, 0% = smooth): mean {summary['motion_err_mean_pct']:.1f}% | p95 {summary['motion_err_p95_pct']:.1f}% | p99 {summary['motion_err_p99_pct']:.1f}%")
    print(f"Missed 30fps (>33.33ms): {summary['miss_30_pct']:.2f}%")
    print(f"Hitches >20ms: {summary.get('hitches_per_min', 0):.1f} per minute")
    
    print("\n--- Sections (ms) ---")
    print(f"{'Section':<15} | {'p50':>6} | {'p95':>6} | {'p99':>6} | {'max':>6}")
    print("-" * 45)
    for s in sections:
        d = summary["sections"][s]
        print(f"{s:<15} | {d['p50']:6.2f} | {d['p95']:6.2f} | {d['p99']:6.2f} | {d['max']:6.2f}")
        
    print(f"\n--- Ticks Histogram ---")
    print(f"0 ticks: {summary['ticks_hist'][0]}")
    print(f"1 ticks: {summary['ticks_hist'][1]}")
    print(f"2 ticks: {summary['ticks_hist'][2]}")
    print(f"3+ ticks: {summary['ticks_hist'][3]}")
    
    print(f"\n--- Top 15 Spikes (>25ms) ---")
    print(f"{'Frame':>6} | {'SimTime':>7} | {'WallMs':>6} | {'Cam':>3} | {'Largest':<12} | {'Val':>6} | {'Air':>3} | {'Wpn':>3} | {'Exp':>3}")
    for sp in summary["spikes"]:
        print(f"{sp['frame']:6d} | {sp['sim_time']:7.1f} | {sp['wall_ms']:6.1f} | {sp['cam_mode']:3d} | {sp['largest_section']:<12} | {sp['largest_val']:6.1f} | {int(sp['alive_air']):3d} | {int(sp['weapons']):3d} | {int(sp['explosions']):3d}")
        
    print(f"\n--- By Cam Mode ---")
    print(f"{'Mode':<15} | {'Frames':>6} | {'AvgFPS':>6} | {'p99 Ms':>6}")
    for cm, d in summary["cam_modes"].items():
        print(f"{cm:<15} | {d['frames']:6d} | {d['avg_fps']:6.1f} | {d['p99_wall_ms']:6.1f}")
        
    print(f"\n--- By Weapons Count ---")
    print(f"{'Bucket':<8} | {'AvgMs':>6} | {'p99Ms':>6}")
    for k, d in summary["weapons_buckets"].items():
        print(f"{k:<8} | {d['avg_wall_ms']:6.2f} | {d['p99_wall_ms']:6.2f}")
        
    print(f"\n--- Leak Check ---")
    lc = summary["leak_check"]
    print(f"Nodes: First {int(lc['nodes']['first'])}, Last {int(lc['nodes']['last'])}, Max {int(lc['nodes']['max'])}")
    print(f"VisEnts: First {int(lc['visual_entities']['first'])}, Last {int(lc['visual_entities']['last'])}, Max {int(lc['visual_entities']['max'])}")

    if not save_baseline and os.path.exists(baseline_path):
        try:
            with open(baseline_path, "r") as f:
                base = json.load(f)
            if base.get("meta", {}).get("started") != meta.get("started"):
                print("\n--- Baseline Comparison ---")
                print(f"{'Metric':<15} | {'Base':>8} | {'Now':>8} | {'Delta':>8}")
                print("-" * 45)
                
                def p_cmp(name, b_val, n_val, higher_better=False):
                    d = n_val - b_val
                    sign = "+" if d > 0 else ""
                    print(f"{name:<15} | {b_val:8.2f} | {n_val:8.2f} | {sign}{d:8.2f}")
                    
                p_cmp("Avg FPS", base["avg_fps"], summary["avg_fps"], True)
                p_cmp("1% Low", base["1_low"], summary["1_low"], True)
                p_cmp("0.1% Low", base["0.1_low"], summary["0.1_low"], True)
                p_cmp("Miss 60 (%)", base["miss_60_pct"], summary["miss_60_pct"])
                if "hitches_per_min" in base:
                    p_cmp("Hitch/min", base["hitches_per_min"], summary["hitches_per_min"])
                print("")
                
                for s in sections:
                    if s in base.get("sections", {}) and s in summary.get("sections", {}):
                        p_cmp(s + " p50", base["sections"][s]["p50"], summary["sections"][s]["p50"])
                        p_cmp(s + " p99", base["sections"][s]["p99"], summary["sections"][s]["p99"])
        except Exception as e:
            print(f"Could not load or compare baseline: {e}")

if __name__ == "__main__":
    main()
