#ifndef YSGD_CRASHLOG_H
#define YSGD_CRASHLOG_H

// Session log (<game folder>/crashlog/latest_run.txt) and crash reports (crash_report.txt), written by
// Windows SEH / signal handlers. Everything here is safe to call before crashlog_init (it then does nothing).

#include <cstdint>

#include <godot_cpp/variant/string.hpp>

namespace ysgd {

// Values printed in every log line and crash report. Updated by the simulation node.
struct CrashStats {
    volatile uint64_t physics_frame = 0;
    volatile double sim_time = 0.0;
    volatile int airplanes = 0;
    volatile int weapons = 0;
};
extern CrashStats g_crash_stats;

// res_global_path = globalized "res://"; the log folder is its parent + "/crashlog".
void crashlog_init(const godot::String &res_global_path);
void log_line(const char *msg);
void log_line(const godot::String &msg);

// Last known activity, printed in crash reports. Pass string literals only (the pointer is stored).
void set_breadcrumb(const char *where);

} // namespace ysgd

#endif // YSGD_CRASHLOG_H
