#include "core/crashlog.h"

#include <csignal>
#include <cstdio>
#include <ctime>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <direct.h>
#include <windows.h>
#endif

using namespace godot;

namespace ysgd {

CrashStats g_crash_stats;

static FILE *g_session_log_fp = nullptr;
static wchar_t g_crashlog_dir[512] = L"crashlog";
static volatile const char *g_breadcrumb = "uninitialized";
static bool g_handlers_installed = false;

void set_breadcrumb(const char *where) {
    g_breadcrumb = where;
}

void log_line(const char *msg) {
    if (g_session_log_fp == nullptr) {
        return;
    }
    std::time_t now = std::time(nullptr);
    struct tm tbuf;
    localtime_s(&tbuf, &now);
    fprintf(g_session_log_fp, "[%02d:%02d:%02d] [Frame %llu | SimT %.2fs] %s\n",
            tbuf.tm_hour, tbuf.tm_min, tbuf.tm_sec,
            (unsigned long long)g_crash_stats.physics_frame, (double)g_crash_stats.sim_time, msg);
    fflush(g_session_log_fp);
}

void log_line(const String &msg) {
    log_line(msg.utf8().get_data());
}

#ifdef _WIN32
static const char *exception_code_to_string(DWORD code) {
    switch (code) {
        case EXCEPTION_ACCESS_VIOLATION: return "EXCEPTION_ACCESS_VIOLATION (0xC0000005)";
        case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
        case EXCEPTION_DATATYPE_MISALIGNMENT: return "EXCEPTION_DATATYPE_MISALIGNMENT";
        case EXCEPTION_FLT_DIVIDE_BY_ZERO: return "EXCEPTION_FLT_DIVIDE_BY_ZERO";
        case EXCEPTION_ILLEGAL_INSTRUCTION: return "EXCEPTION_ILLEGAL_INSTRUCTION";
        case EXCEPTION_IN_PAGE_ERROR: return "EXCEPTION_IN_PAGE_ERROR";
        case EXCEPTION_INT_DIVIDE_BY_ZERO: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
        case EXCEPTION_PRIV_INSTRUCTION: return "EXCEPTION_PRIV_INSTRUCTION";
        case EXCEPTION_STACK_OVERFLOW: return "EXCEPTION_STACK_OVERFLOW (0xC00000FD)";
        default: return "UNKNOWN_HARDWARE_EXCEPTION";
    }
}

static void write_crash_report(EXCEPTION_POINTERS *ep, const char *source_tag) {
    wchar_t crash_path[600];
    swprintf(crash_path, 600, L"%ls\\crash_report.txt", g_crashlog_dir);
    FILE *cfp = _wfopen(crash_path, L"a");
    FILE *targets[2] = { cfp, g_session_log_fp };

    std::time_t now = std::time(nullptr);
    struct tm tbuf;
    localtime_s(&tbuf, &now);

    for (FILE *fp : targets) {
        if (fp == nullptr) {
            continue;
        }
        fprintf(fp, "\n============================================================\n");
        fprintf(fp, "YSFLIGHT-GODOT CRASH REPORT (%04d-%02d-%02d %02d:%02d:%02d)\n",
                tbuf.tm_year + 1900, tbuf.tm_mon + 1, tbuf.tm_mday, tbuf.tm_hour, tbuf.tm_min, tbuf.tm_sec);
        fprintf(fp, "Handler Source   : %s\n", source_tag);
        fprintf(fp, "Last Breadcrumb  : %s\n", g_breadcrumb ? (const char *)g_breadcrumb : "none");
        fprintf(fp, "Physics Frame    : %llu\n", (unsigned long long)g_crash_stats.physics_frame);
        fprintf(fp, "Simulation Time  : %.3f sec\n", (double)g_crash_stats.sim_time);
        fprintf(fp, "Active Airplanes : %d\n", (int)g_crash_stats.airplanes);
        fprintf(fp, "Active Weapons   : %d\n", (int)g_crash_stats.weapons);

        if (ep != nullptr && ep->ExceptionRecord != nullptr) {
            const DWORD code = ep->ExceptionRecord->ExceptionCode;
            void *addr = ep->ExceptionRecord->ExceptionAddress;
            fprintf(fp, "Exception Code   : 0x%08lX (%s)\n", (unsigned long)code, exception_code_to_string(code));
            fprintf(fp, "Fault Address    : 0x%p\n", addr);
            if (code == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
                const ULONG_PTR op = ep->ExceptionRecord->ExceptionInformation[0];
                const ULONG_PTR target_addr = ep->ExceptionRecord->ExceptionInformation[1];
                fprintf(fp, "Access Type      : %s at address 0x%p\n",
                        (op == 0) ? "READ" : (op == 1) ? "WRITE" : "EXECUTE", (void *)target_addr);
            }
            HMODULE mod = nullptr;
            if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   (LPCSTR)addr, &mod) && mod != nullptr) {
                char mod_name[MAX_PATH] = {0};
                GetModuleFileNameA(mod, mod_name, MAX_PATH);
                const uintptr_t offset = (uintptr_t)addr - (uintptr_t)mod;
                fprintf(fp, "Faulting Module  : %s + 0x%llX\n", mod_name, (unsigned long long)offset);
            }
        }
        fprintf(fp, "============================================================\n");
        fflush(fp);
    }
    if (cfp != nullptr) {
        fclose(cfp);
    }
}

static LONG WINAPI vectored_exception_handler(EXCEPTION_POINTERS *ep) {
    if (ep != nullptr && ep->ExceptionRecord != nullptr) {
        const DWORD c = ep->ExceptionRecord->ExceptionCode;
        if (c == EXCEPTION_ACCESS_VIOLATION || c == EXCEPTION_STACK_OVERFLOW || c == EXCEPTION_INT_DIVIDE_BY_ZERO ||
            c == EXCEPTION_ILLEGAL_INSTRUCTION || c == EXCEPTION_ARRAY_BOUNDS_EXCEEDED) {
            write_crash_report(ep, "VectoredExceptionHandler");
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static LONG WINAPI unhandled_exception_filter(EXCEPTION_POINTERS *ep) {
    write_crash_report(ep, "UnhandledExceptionFilter");
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

static void signal_handler(int sig) {
    const char *sig_name = (sig == SIGSEGV) ? "SIGSEGV" : (sig == SIGABRT) ? "SIGABRT" : "SIGNAL";
#ifdef _WIN32
    write_crash_report(nullptr, sig_name);
#else
    log_line(sig_name);
#endif
}

void crashlog_init(const String &res_global_path) {
    const String base_dir = res_global_path.trim_suffix("/").trim_suffix("\\");
    const int slash = (int)base_dir.rfind("/");
    const int bslash = (int)base_dir.rfind("\\");
    const int cut = slash > bslash ? slash : bslash;
    const String dir = (cut > 0) ? (base_dir.substr(0, cut) + "/crashlog") : (base_dir + "/crashlog");

    const Char16String wdir = dir.utf16();
    wcsncpy_s(g_crashlog_dir, 512, (const wchar_t *)wdir.get_data(), _TRUNCATE);
    _wmkdir(g_crashlog_dir);

    if (g_session_log_fp == nullptr) {
        wchar_t latest_path[600];
        swprintf(latest_path, 600, L"%ls\\latest_run.txt", g_crashlog_dir);
        g_session_log_fp = _wfopen(latest_path, L"w");
        log_line("=== YSFlight-Godot Session Log Initialized ===");
    }
    if (!g_handlers_installed) {
#ifdef _WIN32
        AddVectoredExceptionHandler(0, vectored_exception_handler);
        SetUnhandledExceptionFilter(unhandled_exception_filter);
#endif
        std::signal(SIGSEGV, signal_handler);
        std::signal(SIGABRT, signal_handler);
        g_handlers_installed = true;
        log_line("Installed Windows SEH Vectored + Unhandled Exception + Signal crash handlers.");
    }
}

} // namespace ysgd
