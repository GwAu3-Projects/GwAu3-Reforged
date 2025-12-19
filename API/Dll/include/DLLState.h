#pragma once

#include <atomic>

namespace GW {

    // Version information
    constexpr uint32_t DLL_VERSION_MAJOR = 1;
    constexpr uint32_t DLL_VERSION_MINOR = 0;
    constexpr uint32_t DLL_VERSION_PATCH = 0;
    constexpr uint32_t DLL_VERSION = (DLL_VERSION_MAJOR << 16) | (DLL_VERSION_MINOR << 8) | DLL_VERSION_PATCH;

    // Build info (format: "v1.0.0 Debug/Release YYYY-MM-DD")
#ifdef _DEBUG
    constexpr const char* DLL_BUILD_TYPE = "Debug";
#else
    constexpr const char* DLL_BUILD_TYPE = "Release";
#endif

    // DLL State Management
    enum class DllState {
        Initializing,
        Running,
        ShuttingDown,
        Stopped
    };

    // Global state (defined in dllentry.cpp)
    extern std::atomic<DllState> g_dllState;

    // Helper functions
    inline bool IsDllRunning() {
        return g_dllState.load() == DllState::Running;
    }

    inline bool IsDllShuttingDown() {
        auto state = g_dllState.load();
        return state == DllState::ShuttingDown || state == DllState::Stopped;
    }

    inline void RequestShutdown() {
        DllState expected = DllState::Running;
        g_dllState.compare_exchange_strong(expected, DllState::ShuttingDown);
    }

} // namespace GW