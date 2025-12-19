#pragma once

#include <Windows.h>
#include <string>
#include <thread>
#include <atomic>
#include <functional>
#include <vector>
#include <mutex>

std::string GetPipeName();

namespace GW {

#pragma pack(push, 1)  // Force 1-byte alignment

    // ==================================
    // Protocol Definitions
    // ==================================

    // Request types
    enum RequestType {
        // Scanner operations
        SCAN_FIND = 1,
        SCAN_FIND_ASSERTION = 2,
        SCAN_FIND_IN_RANGE = 3,
        SCAN_TO_FUNCTION_START = 4,
        SCAN_FUNCTION_FROM_NEAR_CALL = 5,
        READ_MEMORY = 6,
        GET_SECTION_INFO = 7,
        READ_POINTER_CHAIN = 8,

        // Function Registry operations
        REGISTER_FUNCTION = 10,
        UNREGISTER_FUNCTION = 11,
        CALL_FUNCTION = 12,
        LIST_FUNCTIONS = 13,

        // Memory Manager operations
        ALLOCATE_MEMORY = 20,
        FREE_MEMORY = 21,
        WRITE_MEMORY = 22,
        PROTECT_MEMORY = 23,

        // Hook operations
        INSTALL_HOOK = 30,
        REMOVE_HOOK = 31,
        ENABLE_HOOK = 32,
        DISABLE_HOOK = 33,

        // Event operations
        GET_PENDING_EVENTS = 40,
        REGISTER_EVENT_BUFFER = 41,
        UNREGISTER_EVENT_BUFFER = 42,

        // Array operations
        READ_MEMORY_ARRAY = 45,   // Read an array of typed values from memory

        // Batch operations (for performance)
        BATCH_REQUEST = 48,       // Multiple requests in one call
        BATCH_READ_MEMORY = 49,   // Read multiple memory locations at once

        // Server control operations (NEW)
        SERVER_STATUS = 50,
        SERVER_STOP = 51,
        SERVER_START = 52,
        SERVER_RESTART = 53,

        // DLL control operations (NEW)
        DLL_DETACH = 60,
        DLL_STATUS = 61,

        // Heartbeat/Watchdog
        HEARTBEAT = 100
    };

    // Parameter types for function calls
    enum ParamType : uint8_t {
        PARAM_INT8 = 1,
        PARAM_INT16 = 2,
        PARAM_INT32 = 3,
        PARAM_INT64 = 4,
        PARAM_FLOAT = 5,
        PARAM_DOUBLE = 6,
        PARAM_POINTER = 7,
        PARAM_STRING = 8,     // ANSI string
        PARAM_WSTRING = 9     // Wide string
    };

    // Calling conventions
    enum CallConvention : uint8_t {
        CONV_CDECL = 1,
        CONV_STDCALL = 2,
        CONV_FASTCALL = 3,
        CONV_THISCALL = 4
    };

    // Function parameter structure
    struct FunctionParam {
        ParamType type;
        uint8_t padding[3];
        union {
            int8_t int8_val;
            int16_t int16_val;
            int32_t int32_val;
            int64_t int64_val;
            float float_val;
            double double_val;
            uintptr_t ptr_val;
            char string_val[256];
            wchar_t wstring_val[128];
        };
    };

    // Request structure for client->server communication
    struct PipeRequest {
        RequestType type;

        union {
            // Scanner operations
            struct {
                uint8_t pattern[256];
                char mask[256];
                int32_t offset;
                uint8_t section;
                uint8_t pattern_length;
                uint8_t padding1[2];
            } scan;

            struct {
                char assertion_file[256];
                char assertion_msg[256];
                uint32_t line_number;
                int32_t offset;
            } assertion;

            struct {
                uint32_t start_address;
                uint32_t end_address;
                uint8_t pattern[256];
                char mask[256];
                int32_t offset;
                uint8_t pattern_length;
                uint8_t padding[3];
            } range;

            // Function registry
            struct {
                char name[64];
                uintptr_t address;
                uint8_t param_count;
                CallConvention convention;
                uint8_t has_return;
                uint8_t padding[1];
            } register_func;

            struct {
                char name[64];
                uint8_t param_count;
                uint8_t padding[3];
                FunctionParam params[10];  // Max 10 params
            } call_func;

            // Memory operations
            struct {
                uintptr_t address;
                uint32_t size;
                uint32_t protection;
                uint8_t data[1024];
            } memory;

            // Hook operations
            struct {
                char name[64];
                uintptr_t target;
                uintptr_t detour;
                uint32_t length;
            } hook;

            // Event operations
            struct {
                char name[64];
                uintptr_t buffer_address;
                uint32_t buffer_size;
                uint32_t max_events;
            } event;

            // Server control operations (NEW)
            struct {
                char pipe_name[256];
                uint32_t wait_ms;
            } server_control;

            // DLL control operations (NEW)
            struct {
                uint8_t force;
                uint8_t padding[3];
            } dll_control;

            // Pointer chain read operation
            struct {
                uintptr_t base_address;
                uint8_t offset_count;
                uint8_t final_size;      // 1, 2, 4, or 8 bytes
                uint8_t padding[2];
                int32_t offsets[16];     // Max 16 offsets in the chain
            } pointer_chain;

            // Array read operation
            struct {
                uintptr_t address;        // Start address of array
                uint8_t element_type;     // ParamType of elements
                uint8_t padding[3];
                uint32_t element_count;   // Number of elements to read
            } array_read;

            // Batch memory read - read multiple addresses at once
            struct {
                uint8_t count;            // Number of addresses (max 32)
                uint8_t sizes[32];        // Size of each read (1, 2, 4, or 8)
                uint8_t padding[3];
                uintptr_t addresses[32];  // Addresses to read
            } batch_read;

            // Heartbeat
            struct {
                uint32_t client_timestamp;  // Client timestamp for latency calculation
            } heartbeat;
        };
    };

    // Response structure for server->client communication
    struct PipeResponse {
        uint8_t success;
        uint8_t padding[3];

        union {
            // Scanner result
            struct {
                uintptr_t address;
            } scan_result;

            // Function call result
            struct {
                uint8_t has_return;
                uint8_t padding[3];
                union {
                    int32_t int_val;
                    float float_val;
                    uintptr_t ptr_val;
                } return_value;
            } call_result;

            // Memory result
            struct {
                uintptr_t address;
                uint32_t size;
                uint8_t data[1024];
            } memory_result;

            // Function list
            struct {
                uint32_t count;
                char names[20][64];  // Max 20 function names
            } function_list;

            // Section info
            struct {
                uintptr_t start;
                uintptr_t end;
            } section_info;

            // Event data
            struct {
                uint32_t event_count;
                uint8_t events[1024];  // Raw event data
            } event_data;

            // Pointer chain result
            struct {
                uintptr_t final_address;  // Address where value was read from
                uint64_t value;           // The value read (up to 8 bytes)
            } pointer_chain_result;

            // Array result - for sending typed arrays to AutoIt
            struct {
                uint8_t element_type;     // ParamType of elements (PARAM_INT32, PARAM_FLOAT, etc.)
                uint8_t padding[3];
                uint32_t element_count;   // Number of elements
                uint32_t element_size;    // Size of each element in bytes
                uint32_t total_size;      // Total size of data in bytes
                uint8_t data[2048];       // Array data (max ~2KB)
            } array_result;

            // Batch read result - multiple values at once
            struct {
                uint8_t count;            // Number of values read
                uint8_t success_mask[4];  // Bitmask: bit i = 1 if read i succeeded
                uint8_t padding[3];
                uint64_t values[32];      // Values read (max 8 bytes each)
            } batch_result;

            // Heartbeat result
            struct {
                uint32_t client_timestamp;  // Echo back client timestamp
                uint32_t server_timestamp;  // Server timestamp (GetTickCount)
                uint32_t latency_ms;        // Calculated round-trip latency
            } heartbeat_result;
        };

        // Server status
        struct {
            int32_t status;
            uint32_t client_count;
            uint64_t uptime_ms;
            char pipe_name[256];
        } server_status;

        // DLL status
        struct {
            int32_t status;
            uint32_t version;
            char build_info[256];
        } dll_status;

        char error_message[256];
    };

    // Legacy structures for backward compatibility
    typedef PipeRequest ScanRequest;
    typedef PipeResponse ScanResponse;

#pragma pack(pop)  // Restore default alignment

    // ==================================
    // Named Pipe Server Class
    // ==================================

    class NamedPipeServer {
    private:
        static NamedPipeServer* instance;

        HANDLE hPipe;
        HANDLE hStopEvent;  // Event for signaling stop
        std::thread serverThread;
        std::atomic<bool> running;
        std::string pipeName;

        // Statistics
        std::atomic<uint32_t> clientCount;
        std::atomic<uint32_t> totalConnections;
        std::chrono::steady_clock::time_point startTime;

        // Multi-threaded client handling
        std::vector<std::thread> clientThreads;
        std::mutex clientThreadsMutex;

        // Internal methods
        void ServerLoop();
        void ProcessClient(HANDLE clientPipe);
        void ProcessClientThreaded(HANDLE clientPipe, uint32_t clientId);
        void HandleRequest(const PipeRequest& request, PipeResponse& response);
        void CleanupFinishedThreads();

        // Helper for hex pattern parsing
        bool ParseHexPattern(const char* hexStr, std::string& outPattern);

    public:
        NamedPipeServer();
        ~NamedPipeServer();

        // Singleton
        static NamedPipeServer& GetInstance();
        static void Destroy();

        // Server control
        bool Start(const std::string& pipeName = "");
        void Stop();
        bool IsRunning() const { return running.load(); }

        // Statistics
        uint32_t GetClientCount() const { return clientCount.load(); }
        uint32_t GetTotalConnections() const { return totalConnections.load(); }
        uint64_t GetUptimeMs() const;
        const std::string& GetPipeName() const { return pipeName; }

        // Optional callbacks for logging
        std::function<void(const std::string&)> OnLog;
        std::function<void(const std::string&)> OnError;
        std::function<void(const std::string&)> OnClientConnected;
        std::function<void(const std::string&)> OnClientDisconnected;
    };
}