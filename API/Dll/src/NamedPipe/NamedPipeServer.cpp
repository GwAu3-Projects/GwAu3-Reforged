#include "NamedPipe/NamedPipeServer.h"
#include "NamedPipe/RPCBridge.h"
#include "Utilities/Scanner.h"
#include "Utilities/Debug.h"
#include "DllState.h"
#include <sstream>
#include <iomanip>

// Get character name from game memory (with retry)
std::wstring GetCharacterName() {
    // Pattern to find character name: 8B F8 6A 03 68 0F 00 00 C0 8B CF E8
    static const char pattern[] = "\x8B\xF8\x6A\x03\x68\x0F\x00\x00\xC0\x8B\xCF\xE8";
    static const char* mask = "xxxxxxxxxxxx";
    static uintptr_t cachedPatternAddr = 0;

    // Find pattern once and cache it
    if (cachedPatternAddr == 0) {
        cachedPatternAddr = GW::Scanner::Find(pattern, mask, 0);
        if (cachedPatternAddr == 0) {
            LOG_WARN("Character name pattern not found");
            return L"";
        }
    }

    // The pointer to character name is at patternAddr - 0x42
    uintptr_t namePtr = *(uintptr_t*)(cachedPatternAddr - 0x42);
    if (namePtr == 0) {
        return L"";  // Character not loaded yet, don't log warning
    }

    // Read the wide character name (max 30 chars)
    wchar_t* nameAddr = (wchar_t*)namePtr;

    // Check if it's a valid pointer
    if (IsBadReadPtr(nameAddr, sizeof(wchar_t))) {
        return L"";
    }

    std::wstring name(nameAddr, wcsnlen(nameAddr, 30));

    // Return empty if name is empty or just whitespace
    if (name.empty() || name[0] == L'\0') {
        return L"";
    }

    return name;
}

// Wait for character name to be available (with timeout)
std::wstring WaitForCharacterName(int maxRetries = 50, int delayMs = 100) {
    for (int i = 0; i < maxRetries; i++) {
        std::wstring name = GetCharacterName();
        if (!name.empty()) {
            LOG_INFO("Character name found after %d ms: %S", i * delayMs, name.c_str());
            return name;
        }
        Sleep(delayMs);
    }
    LOG_WARN("Character name not found after %d retries (%d ms)", maxRetries, maxRetries * delayMs);
    return L"";
}

// Convert wide string to UTF-8
std::string WideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return "";

    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return "";

    std::string utf8(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, &utf8[0], size, nullptr, nullptr);
    return utf8;
}

std::string GetPipeName() {
    static std::string pipeName;
    if (pipeName.empty()) {
        // Try to get character name first
        std::wstring charName = GetCharacterName();
        std::stringstream ss;

        if (!charName.empty()) {
            // Replace spaces with underscores in character name
            for (auto& c : charName) {
                if (c == L' ') c = L'_';
            }
            ss << "\\\\.\\pipe\\GwNexus_" << WideToUtf8(charName);
            LOG_INFO("Pipe name set to character: %s", WideToUtf8(charName).c_str());
        } else {
            // Fallback to PID if character name not found
            ss << "\\\\.\\pipe\\GwNexus_" << GetCurrentProcessId();
            LOG_WARN("Using PID for pipe name (character not found)");
        }
        pipeName = ss.str();
    }
    return pipeName;
}

namespace GW {

    // Helper function to get request type name
    static const char* GetRequestTypeName(RequestType type) {
        switch (type) {
        case SCAN_FIND: return "SCAN_FIND";
        case SCAN_FIND_ASSERTION: return "SCAN_FIND_ASSERTION";
        case SCAN_FIND_IN_RANGE: return "SCAN_FIND_IN_RANGE";
        case SCAN_TO_FUNCTION_START: return "SCAN_TO_FUNCTION_START";
        case SCAN_FUNCTION_FROM_NEAR_CALL: return "SCAN_FUNCTION_FROM_NEAR_CALL";
        case READ_MEMORY: return "READ_MEMORY";
        case GET_SECTION_INFO: return "GET_SECTION_INFO";
        case READ_POINTER_CHAIN: return "READ_POINTER_CHAIN";
        case REGISTER_FUNCTION: return "REGISTER_FUNCTION";
        case UNREGISTER_FUNCTION: return "UNREGISTER_FUNCTION";
        case CALL_FUNCTION: return "CALL_FUNCTION";
        case LIST_FUNCTIONS: return "LIST_FUNCTIONS";
        case ALLOCATE_MEMORY: return "ALLOCATE_MEMORY";
        case FREE_MEMORY: return "FREE_MEMORY";
        case WRITE_MEMORY: return "WRITE_MEMORY";
        case PROTECT_MEMORY: return "PROTECT_MEMORY";
        case INSTALL_HOOK: return "INSTALL_HOOK";
        case REMOVE_HOOK: return "REMOVE_HOOK";
        case ENABLE_HOOK: return "ENABLE_HOOK";
        case DISABLE_HOOK: return "DISABLE_HOOK";
        case GET_PENDING_EVENTS: return "GET_PENDING_EVENTS";
        case REGISTER_EVENT_BUFFER: return "REGISTER_EVENT_BUFFER";
        case UNREGISTER_EVENT_BUFFER: return "UNREGISTER_EVENT_BUFFER";
        default: return "UNKNOWN";
        }
    }

    // Helper function to format bytes as hex string
    static std::string BytesToHex(const char* data, size_t len, size_t maxLen = 32) {
        std::stringstream ss;
        size_t displayLen = (len > maxLen) ? maxLen : len;

        for (size_t i = 0; i < displayLen; i++) {
            ss << "\\x" << std::hex << std::setw(2) << std::setfill('0')
                << (unsigned int)(unsigned char)data[i];
        }

        if (len > maxLen) {
            ss << "... (" << std::dec << len << " bytes total)";
        }

        return ss.str();
    }

    // Helper function to format a pattern for logging
    static std::string FormatPattern(const uint8_t* pattern, size_t maxLen = 256) {
        std::stringstream ss;
        size_t len = 0;

        // Find actual length
        for (size_t i = 0; i < maxLen; i++) {
            if (pattern[i] != 0) {
                len = i + 1;
            }
        }

        size_t displayLen = (len > 32) ? 32 : len;

        for (size_t i = 0; i < displayLen; i++) {
            unsigned char c = pattern[i];
            if (c >= 32 && c <= 126) {
                ss << (char)c;
            }
            else {
                ss << "\\x" << std::hex << std::setw(2) << std::setfill('0') << (unsigned int)c;
            }
        }

        if (len > 32) {
            ss << "... (" << std::dec << len << " bytes)";
        }

        return ss.str();
    }

    NamedPipeServer* NamedPipeServer::instance = nullptr;

    NamedPipeServer::NamedPipeServer()
        : hPipe(INVALID_HANDLE_VALUE)
        , hStopEvent(NULL)
        , running(false)
        , clientCount(0)
        , totalConnections(0)
        , startTime() {
        LOG_DEBUG("NamedPipeServer constructor called");

        // Create the stop event
        hStopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        if (!hStopEvent) {
            LOG_ERROR("Failed to create stop event");
        }
    }

    NamedPipeServer::~NamedPipeServer() {
        LOG_DEBUG("NamedPipeServer destructor called");
        Stop();

        if (hStopEvent) {
            CloseHandle(hStopEvent);
            hStopEvent = NULL;
        }
    }

    NamedPipeServer& NamedPipeServer::GetInstance() {
        if (!instance) {
            LOG_DEBUG("Creating NamedPipeServer singleton instance");
            instance = new NamedPipeServer();
        }
        return *instance;
    }

    void NamedPipeServer::Destroy() {
        LOG_DEBUG("Destroying NamedPipeServer singleton instance");
        if (instance) {
            delete instance;
            instance = nullptr;
        }
    }

    bool NamedPipeServer::Start(const std::string& pipeNameParam) {
        // Generate pipe name directly here to avoid any static variable issues
        std::string actualPipeName;
        if (pipeNameParam.empty()) {
            // Try to get character name first
            std::wstring charName = GetCharacterName();
            std::stringstream ss;

            if (!charName.empty()) {
                // Replace spaces with underscores in character name
                for (auto& c : charName) {
                    if (c == L' ') c = L'_';
                }
                ss << "\\\\.\\pipe\\GwNexus_" << WideToUtf8(charName);
                LOG_INFO("Pipe name set to character: %s", WideToUtf8(charName).c_str());
            } else {
                // Fallback to PID if character name not found
                ss << "\\\\.\\pipe\\GwNexus_" << GetCurrentProcessId();
                LOG_WARN("Using PID for pipe name (character not found)");
            }
            actualPipeName = ss.str();
        } else {
            actualPipeName = pipeNameParam;
        }

        LOG_DEBUG("NamedPipeServer::Start called with pipeName: %s", actualPipeName.c_str());

        if (running) {
            LOG_WARN("Server already running, cannot start again");
            if (OnError) OnError("Server already running");
            return false;
        }

        this->pipeName = actualPipeName;

        // Reset stop event
        ResetEvent(hStopEvent);

        // Reset statistics
        clientCount = 0;
        totalConnections = 0;
        startTime = std::chrono::steady_clock::now();

        running = true;

        LOG_INFO("Starting Named Pipe server on: %s", actualPipeName.c_str());

        // Start server thread - detach to not block
        try {
            serverThread = std::thread(&NamedPipeServer::ServerLoop, this);
            if (serverThread.joinable()) {
                LOG_INFO("Server thread created successfully, detaching...");
                serverThread.detach();
            } else {
                LOG_ERROR("Server thread is not joinable after creation!");
                running = false;
                return false;
            }
        }
        catch (const std::exception& e) {
            LOG_ERROR("Failed to create server thread: %s", e.what());
            running = false;
            return false;
        }
        catch (...) {
            LOG_ERROR("Failed to create server thread: unknown exception");
            running = false;
            return false;
        }

        if (OnLog) OnLog("Named pipe server started on: " + actualPipeName);
        LOG_SUCCESS("Named pipe server started: %s", actualPipeName.c_str());

        // Give the thread a moment to start and log its status
        Sleep(100);

        return true;
    }

    void NamedPipeServer::Stop() {
        LOG_DEBUG("NamedPipeServer::Stop called");

        if (!running) {
            LOG_DEBUG("Server not running, nothing to stop");
            return;
        }

        LOG_INFO("Stopping Named Pipe server...");

        // Signal shutdown
        running = false;

        // Set the stop event to wake up any waiting operations
        if (hStopEvent) {
            SetEvent(hStopEvent);
        }

        // Close any active pipe to unblock operations
        if (hPipe != INVALID_HANDLE_VALUE) {
            // Cancel pending I/O
            CancelIo(hPipe);

            // Disconnect clients
            DisconnectNamedPipe(hPipe);

            // Close handle
            CloseHandle(hPipe);
            hPipe = INVALID_HANDLE_VALUE;
        }

        // Create a dummy connection to unblock ConnectNamedPipe if needed
        HANDLE hDummy = CreateFileA(
            pipeName.c_str(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            NULL,
            OPEN_EXISTING,
            FILE_FLAG_WRITE_THROUGH,
            NULL
        );

        if (hDummy != INVALID_HANDLE_VALUE) {
            CloseHandle(hDummy);
        }

        // Wait for all client threads to finish
        LOG_INFO("Waiting for %zu client threads to finish...", clientThreads.size());
        {
            std::lock_guard<std::mutex> lock(clientThreadsMutex);
            for (auto& thread : clientThreads) {
                if (thread.joinable()) {
                    thread.join();
                }
            }
            clientThreads.clear();
        }

        // Wait a short time for thread to exit
        Sleep(100);

        // Clear callbacks
        OnLog = nullptr;
        OnError = nullptr;
        OnClientConnected = nullptr;
        OnClientDisconnected = nullptr;

        LOG_INFO("Named pipe server stopped");
    }

    void NamedPipeServer::CleanupFinishedThreads() {
        // This is called periodically to remove finished threads from the vector
        // Note: We can't easily check if threads are done, so we just keep them
        // until Stop() is called. For a more sophisticated approach, we'd need
        // a thread-safe way to track finished threads.
    }

    void NamedPipeServer::ProcessClientThreaded(HANDLE clientPipe, uint32_t clientId) {
        LOG_DEBUG("Client thread #%u started, ThreadID: %lu", clientId, GetCurrentThreadId());

        // Increment client count
        clientCount++;

        // Process client requests
        try {
            ProcessClient(clientPipe);
        }
        catch (const std::exception& e) {
            LOG_ERROR("Exception in client thread #%u: %s", clientId, e.what());
        }
        catch (...) {
            LOG_ERROR("Unknown exception in client thread #%u", clientId);
        }

        // Cleanup pipe
        if (clientPipe != INVALID_HANDLE_VALUE) {
            DisconnectNamedPipe(clientPipe);
            CloseHandle(clientPipe);
        }

        // Decrement client count
        clientCount--;

        if (OnClientDisconnected) OnClientDisconnected("Client disconnected");
        LOG_INFO("Client #%u disconnected, thread exiting", clientId);
    }

    void NamedPipeServer::ServerLoop() {
        LOG_INFO("ServerLoop thread STARTED, ThreadID: %lu, PipeName: %s",
            GetCurrentThreadId(), pipeName.c_str());

        // Validate pipe name before proceeding
        if (pipeName.empty()) {
            LOG_ERROR("ServerLoop: pipeName is EMPTY! Cannot create pipe.");
            running = false;
            return;
        }

        // Set thread priority
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);

        // Security descriptor
        SECURITY_DESCRIPTOR sd;
        if (!InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION)) {
            LOG_ERROR("Failed to initialize security descriptor: %lu", GetLastError());
            running = false;
            return;
        }
        if (!SetSecurityDescriptorDacl(&sd, TRUE, NULL, FALSE)) {
            LOG_ERROR("Failed to set security descriptor DACL: %lu", GetLastError());
            running = false;
            return;
        }

        SECURITY_ATTRIBUTES sa;
        sa.nLength = sizeof(SECURITY_ATTRIBUTES);
        sa.lpSecurityDescriptor = &sd;
        sa.bInheritHandle = FALSE;

        int connectionCount = 0;

        while (running) {
            // Check DLL state
            if (GW::IsDllShuttingDown()) {
                LOG_INFO("DLL shutting down, stopping Named Pipe server");
                running = false;
                break;
            }

            LOG_INFO("Creating named pipe instance #%d on: %s", ++connectionCount, pipeName.c_str());

            // Create named pipe with overlapped I/O
            HANDLE newPipe = CreateNamedPipeA(
                pipeName.c_str(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                sizeof(PipeResponse),
                sizeof(PipeRequest),
                0,
                &sa
            );

            if (newPipe == INVALID_HANDLE_VALUE) {
                DWORD error = GetLastError();
                LOG_ERROR("FAILED to create named pipe '%s': error=%lu", pipeName.c_str(), error);

                if (running && !GW::IsDllShuttingDown()) {
                    if (OnError) OnError("Failed to create named pipe: " + std::to_string(error));
                }
                running = false;
                return;
            }

            hPipe = newPipe;

            LOG_SUCCESS("Named pipe CREATED successfully: %s (handle=0x%p)", pipeName.c_str(), newPipe);
            LOG_INFO("Waiting for client connection...");

            // Use overlapped structure for async operations
            OVERLAPPED overlapped = {};
            overlapped.hEvent = CreateEvent(NULL, TRUE, TRUE, NULL);

            // Start async connect
            BOOL connected = ConnectNamedPipe(hPipe, &overlapped);
            DWORD error = GetLastError();

            if (!connected && error == ERROR_IO_PENDING) {
                // Wait for either connection or stop signal
                HANDLE events[2] = { overlapped.hEvent, hStopEvent };
                DWORD waitResult = WaitForMultipleObjects(2, events, FALSE, INFINITE);

                if (waitResult == WAIT_OBJECT_0) {
                    // Connection event
                    DWORD bytesTransferred;
                    connected = GetOverlappedResult(hPipe, &overlapped, &bytesTransferred, FALSE);
                }
                else if (waitResult == WAIT_OBJECT_0 + 1) {
                    // Stop event
                    LOG_INFO("Stop event signaled, exiting server loop");
                    CloseHandle(overlapped.hEvent);
                    CloseHandle(hPipe);
                    hPipe = INVALID_HANDLE_VALUE;
                    break;
                }
            }
            else if (error == ERROR_PIPE_CONNECTED) {
                connected = TRUE;
            }

            CloseHandle(overlapped.hEvent);

            if (connected && running && !GW::IsDllShuttingDown()) {
                LOG_SUCCESS("Client #%d connected", connectionCount);

                // Update statistics
                totalConnections++;

                if (OnClientConnected) OnClientConnected("Client connected");

                // Transfer pipe handle to client thread
                HANDLE clientPipe = hPipe;
                hPipe = INVALID_HANDLE_VALUE;  // Clear so we don't close it
                uint32_t clientId = connectionCount;

                // Create a new thread for this client
                {
                    std::lock_guard<std::mutex> lock(clientThreadsMutex);
                    clientThreads.emplace_back(&NamedPipeServer::ProcessClientThreaded, this, clientPipe, clientId);
                }

                LOG_DEBUG("Client #%d handler thread started", connectionCount);
            }
            else {
                // Close pipe if connection failed
                if (hPipe != INVALID_HANDLE_VALUE) {
                    LOG_DEBUG("Closing pipe instance #%d (connection failed)", connectionCount);
                    DisconnectNamedPipe(hPipe);
                    CloseHandle(hPipe);
                    hPipe = INVALID_HANDLE_VALUE;
                }
            }

            // Check if we should stop
            if (WaitForSingleObject(hStopEvent, 0) == WAIT_OBJECT_0) {
                LOG_INFO("Stop event signaled, exiting server loop");
                break;
            }
        }

        LOG_INFO("Named Pipe server thread exiting");
    }

    // Timeout for pipe read operations (in milliseconds)
    static const DWORD PIPE_READ_TIMEOUT_MS = 30000; // 30 seconds
    static const DWORD PIPE_WRITE_TIMEOUT_MS = 10000; // 10 seconds

    void NamedPipeServer::ProcessClient(HANDLE clientPipe) {
        LOG_DEBUG("ProcessClient started for pipe handle: 0x%p", clientPipe);

        PipeRequest request;
        PipeResponse response;
        DWORD bytesRead, bytesWritten;
        int requestCount = 0;

        // Create event for overlapped I/O
        HANDLE hReadEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        HANDLE hWriteEvent = CreateEvent(NULL, TRUE, FALSE, NULL);

        if (!hReadEvent || !hWriteEvent) {
            LOG_ERROR("Failed to create overlapped events");
            if (hReadEvent) CloseHandle(hReadEvent);
            if (hWriteEvent) CloseHandle(hWriteEvent);
            return;
        }

        OVERLAPPED readOverlapped = {};
        OVERLAPPED writeOverlapped = {};
        readOverlapped.hEvent = hReadEvent;
        writeOverlapped.hEvent = hWriteEvent;

        while (running && !GW::IsDllShuttingDown()) {
            // Check if pipe is still valid
            DWORD flags = 0;
            if (!GetNamedPipeInfo(clientPipe, &flags, NULL, NULL, NULL)) {
                LOG_DEBUG("GetNamedPipeInfo failed, pipe disconnected");
                break;
            }

            LOG_TRACE("Waiting for request #%d from client...", ++requestCount);

            // Reset event
            ResetEvent(hReadEvent);

            // Read request from client with overlapped I/O
            BOOL success = ReadFile(
                clientPipe,
                &request,
                sizeof(request),
                &bytesRead,
                &readOverlapped
            );

            DWORD error = GetLastError();

            // If operation is pending, wait with timeout
            if (!success && error == ERROR_IO_PENDING) {
                // Wait for read or stop event with timeout
                HANDLE waitHandles[2] = { hReadEvent, hStopEvent };
                DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, PIPE_READ_TIMEOUT_MS);

                if (waitResult == WAIT_OBJECT_0) {
                    // Read completed - get the result
                    if (!GetOverlappedResult(clientPipe, &readOverlapped, &bytesRead, FALSE)) {
                        error = GetLastError();
                        if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) {
                            LOG_DEBUG("Pipe disconnected during read (error: %lu)", error);
                        } else {
                            LOG_ERROR("GetOverlappedResult failed: %lu", error);
                        }
                        break;
                    }
                    success = TRUE;
                } else if (waitResult == WAIT_OBJECT_0 + 1) {
                    // Stop event signaled
                    LOG_INFO("Stop event signaled during read, cancelling...");
                    CancelIo(clientPipe);
                    break;
                } else if (waitResult == WAIT_TIMEOUT) {
                    // Timeout - check if client is still connected
                    LOG_DEBUG("Read timeout (%lu ms), checking connection...", PIPE_READ_TIMEOUT_MS);

                    // Check if pipe is still valid
                    DWORD pipeFlags = 0;
                    if (!GetNamedPipeInfo(clientPipe, &pipeFlags, NULL, NULL, NULL)) {
                        LOG_DEBUG("Pipe no longer valid after timeout");
                        CancelIo(clientPipe);
                        break;
                    }

                    // Continue waiting (client might just be idle)
                    continue;
                } else {
                    // Wait failed
                    LOG_ERROR("WaitForMultipleObjects failed: %lu", GetLastError());
                    CancelIo(clientPipe);
                    break;
                }
            } else if (!success) {
                // Immediate error
                if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) {
                    LOG_DEBUG("Pipe disconnected (error: %lu)", error);
                } else if (error != ERROR_SUCCESS) {
                    LOG_ERROR("Named pipe read error: %lu", error);
                    if (running && OnError) OnError("Read error: " + std::to_string(error));
                }
                break;
            }

            if (bytesRead == 0) {
                LOG_DEBUG("Zero bytes read, pipe likely closed");
                break;
            }

            // Log request
            LOG_INFO("==================================================================");
            LOG_INFO("| REQUEST #%d RECEIVED", requestCount);
            LOG_INFO("| Type: %s (%d)", GetRequestTypeName(request.type), request.type);
            LOG_INFO("| Bytes read: %lu", bytesRead);

            // Log request details based on type
            switch (request.type) {
            case SCAN_FIND:
                LOG_INFO("| Pattern: %s", FormatPattern(request.scan.pattern,
                    request.scan.pattern_length > 0 ? request.scan.pattern_length : 256).c_str());
                LOG_INFO("| Mask: %s", request.scan.mask);
                LOG_INFO("| Offset: %d", request.scan.offset);
                LOG_INFO("| Section: %d", request.scan.section);
                break;

            case SCAN_FIND_ASSERTION:
                LOG_INFO("| File: %s", request.assertion.assertion_file);
                LOG_INFO("| Message: %s", request.assertion.assertion_msg);
                LOG_INFO("| Line: %u", request.assertion.line_number);
                LOG_INFO("| Offset: %d", request.assertion.offset);
                break;

            case READ_MEMORY:
                LOG_INFO("| Address: 0x%08X", request.memory.address);
                LOG_INFO("| Size: %u", request.memory.size);
                break;

            case READ_POINTER_CHAIN:
                LOG_INFO("| Base Address: 0x%08X", request.pointer_chain.base_address);
                LOG_INFO("| Offset Count: %d", request.pointer_chain.offset_count);
                LOG_INFO("| Final Size: %d bytes", request.pointer_chain.final_size);
                break;

            case CALL_FUNCTION:
                LOG_INFO("| Function: %s", request.call_func.name);
                LOG_INFO("| Param count: %d", request.call_func.param_count);
                break;

            case REGISTER_FUNCTION:
                LOG_INFO("| Name: %s", request.register_func.name);
                LOG_INFO("| Address: 0x%08X", request.register_func.address);
                LOG_INFO("| Params: %d", request.register_func.param_count);
                LOG_INFO("| Convention: %d", request.register_func.convention);
                break;
            }

            // Check for shutdown
            if (!running || GW::IsDllShuttingDown()) {
                LOG_DEBUG("Shutdown requested, stopping client processing");
                break;
            }

            // Process request
            memset(&response, 0, sizeof(response));

            auto startTime = std::chrono::high_resolution_clock::now();

            try {
                HandleRequest(request, response);
            }
            catch (const std::exception& e) {
                LOG_ERROR("Exception during request handling: %s", e.what());
                response.success = 0;
                strcpy_s(response.error_message, "Exception during request handling");
            }
            catch (...) {
                LOG_ERROR("Unknown exception during request handling");
                response.success = 0;
                strcpy_s(response.error_message, "Unknown exception");
            }

            auto endTime = std::chrono::high_resolution_clock::now();
            auto duration = std::chrono::duration_cast<std::chrono::microseconds>(endTime - startTime);

            // Log response
            LOG_INFO("| RESPONSE #%d", requestCount);
            LOG_INFO("| Success: %s", response.success ? "YES" : "NO");
            LOG_INFO("| Processing time: %lld µs", duration.count());

            if (!response.success) {
                LOG_INFO("| Error: %s", response.error_message);
            }
            else {
                switch (request.type) {
                case SCAN_FIND:
                case SCAN_FIND_ASSERTION:
                case SCAN_FIND_IN_RANGE:
                case SCAN_TO_FUNCTION_START:
                case SCAN_FUNCTION_FROM_NEAR_CALL:
                    LOG_INFO("| Result Address: 0x%08X", response.scan_result.address);
                    break;

                case READ_MEMORY:
                    LOG_INFO("| Read Address: 0x%08X", response.memory_result.address);
                    LOG_INFO("| Read Size: %u bytes", response.memory_result.size);
                    break;

                case GET_SECTION_INFO:
                    LOG_INFO("| Section Start: 0x%08X", response.section_info.start);
                    LOG_INFO("| Section End: 0x%08X", response.section_info.end);
                    break;
                }
            }
            LOG_INFO("==================================================================");

            // Send response with overlapped I/O and timeout
            ResetEvent(hWriteEvent);

            success = WriteFile(
                clientPipe,
                &response,
                sizeof(response),
                &bytesWritten,
                &writeOverlapped
            );

            error = GetLastError();

            if (!success && error == ERROR_IO_PENDING) {
                // Wait for write to complete with timeout
                HANDLE waitHandles[2] = { hWriteEvent, hStopEvent };
                DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, PIPE_WRITE_TIMEOUT_MS);

                if (waitResult == WAIT_OBJECT_0) {
                    // Write completed - get the result
                    if (!GetOverlappedResult(clientPipe, &writeOverlapped, &bytesWritten, FALSE)) {
                        error = GetLastError();
                        LOG_ERROR("Write GetOverlappedResult failed: %lu", error);
                        break;
                    }
                } else if (waitResult == WAIT_OBJECT_0 + 1) {
                    // Stop event signaled
                    LOG_INFO("Stop event signaled during write, cancelling...");
                    CancelIo(clientPipe);
                    break;
                } else if (waitResult == WAIT_TIMEOUT) {
                    LOG_ERROR("Write timeout (%lu ms), client may be blocked", PIPE_WRITE_TIMEOUT_MS);
                    CancelIo(clientPipe);
                    break;
                } else {
                    LOG_ERROR("Write WaitForMultipleObjects failed: %lu", GetLastError());
                    CancelIo(clientPipe);
                    break;
                }
            } else if (!success) {
                LOG_ERROR("Named pipe write error: %lu", error);
                if (running && OnError) OnError("Write error: " + std::to_string(error));
                break;
            }

            LOG_DEBUG("Response sent: %lu bytes", bytesWritten);

            // Flush to ensure data is sent
            FlushFileBuffers(clientPipe);
        }

        // Cleanup overlapped events
        if (hReadEvent) CloseHandle(hReadEvent);
        if (hWriteEvent) CloseHandle(hWriteEvent);

        LOG_DEBUG("ProcessClient ended after %d requests", requestCount);
    }

    void NamedPipeServer::HandleRequest(const PipeRequest& request, PipeResponse& response) {
        LOG_TRACE("HandleRequest called for type: %s", GetRequestTypeName(request.type));

        // Check if still running
        if (!running || GW::IsDllShuttingDown()) {
            LOG_WARN("Server is shutting down, rejecting request");
            response.success = 0;
            strcpy_s(response.error_message, "Server is shutting down");
            return;
        }

        // Use RPCBridge for new RPC requests (type >= 10)
        if (request.type >= REGISTER_FUNCTION) {
            LOG_DEBUG("Forwarding request to RPCBridge");

            RPCBridge& bridge = RPCBridge::GetInstance();

            if (bridge.HandleRequest(request, response)) {
                LOG_DEBUG("RPCBridge handled request successfully");
                return;
            }
            else {
                LOG_ERROR("RPCBridge failed to handle request");
                response.success = 0;
                if (strlen(response.error_message) == 0) {
                    strcpy_s(response.error_message, "RPC Bridge failed");
                }
                return;
            }
        }

        // Handle legacy scanner requests
        LOG_DEBUG("Handling legacy scanner request");

        try {
            switch (request.type) {
            case SCAN_FIND: {
                // Use pattern_length to determine actual length
                size_t patternLength = request.scan.pattern_length;
                if (patternLength == 0 || patternLength > 256) {
                    patternLength = strlen(request.scan.mask);
                    LOG_WARN("Invalid pattern_length (%u), using mask length: %zu",
                        request.scan.pattern_length, patternLength);
                }

                LOG_INFO("| Pattern length: %zu bytes", patternLength);

                // Create binary pattern with exact length
                std::string pattern(reinterpret_cast<const char*>(request.scan.pattern), patternLength);

                LOG_DEBUG("Calling Scanner::Find...");
                response.scan_result.address = Scanner::Find(
                    pattern.c_str(),
                    strlen(request.scan.mask) > 0 ? request.scan.mask : nullptr,
                    request.scan.offset,
                    (ScannerSection)request.scan.section
                );

                response.success = (response.scan_result.address != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Pattern found at: 0x%08X", response.scan_result.address);
                }
                else {
                    LOG_WARN("Pattern not found");
                    strcpy_s(response.error_message, "Pattern not found");
                }
                break;
            }

            case SCAN_FIND_ASSERTION: {
                if (OnLog) {
                    OnLog("SCAN_FIND_ASSERTION request - File: " +
                        std::string(request.assertion.assertion_file) +
                        ", Msg: " + std::string(request.assertion.assertion_msg) +
                        ", Line: " + std::to_string(request.assertion.line_number));
                }

                LOG_DEBUG("Calling Scanner::FindAssertion...");
                response.scan_result.address = Scanner::FindAssertion(
                    request.assertion.assertion_file,
                    request.assertion.assertion_msg,
                    request.assertion.line_number,
                    request.assertion.offset
                );

                response.success = (response.scan_result.address != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Assertion found at: 0x%08X", response.scan_result.address);
                }
                else {
                    LOG_WARN("Assertion not found");
                    strcpy_s(response.error_message, "Assertion not found");
                }
                break;
            }

            case SCAN_FIND_IN_RANGE: {
                // Use pattern_length for range pattern too
                size_t patternLength = request.range.pattern_length;
                if (patternLength == 0 || patternLength > 256) {
                    patternLength = strlen(request.range.mask);
                    LOG_WARN("Invalid pattern_length (%u), using mask length: %zu",
                        request.range.pattern_length, patternLength);
                }

                LOG_INFO("| Pattern length: %zu bytes", patternLength);

                // Create binary pattern
                std::string pattern(reinterpret_cast<const char*>(request.range.pattern), patternLength);

                LOG_DEBUG("Calling Scanner::FindInRange (0x%08X - 0x%08X)...",
                    request.range.start_address, request.range.end_address);

                response.scan_result.address = Scanner::FindInRange(
                    pattern.c_str(),
                    strlen(request.range.mask) > 0 ? request.range.mask : nullptr,
                    request.range.offset,
                    request.range.start_address,
                    request.range.end_address
                );

                response.success = (response.scan_result.address != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Pattern found in range at: 0x%08X", response.scan_result.address);
                }
                else {
                    LOG_WARN("Pattern not found in range");
                    strcpy_s(response.error_message, "Pattern not found in range");
                }
                break;
            }

            case SCAN_TO_FUNCTION_START: {
                LOG_DEBUG("Calling Scanner::ToFunctionStart from 0x%08X...", request.memory.address);

                response.scan_result.address = Scanner::ToFunctionStart(
                    request.memory.address,
                    request.memory.size > 0 ? request.memory.size : 0xff
                );

                response.success = (response.scan_result.address != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Function start found at: 0x%08X", response.scan_result.address);
                }
                else {
                    LOG_WARN("Function start not found");
                    strcpy_s(response.error_message, "Function start not found");
                }
                break;
            }

            case SCAN_FUNCTION_FROM_NEAR_CALL: {
                LOG_DEBUG("Calling Scanner::FunctionFromNearCall at 0x%08X...", request.memory.address);

                response.scan_result.address = Scanner::FunctionFromNearCall(
                    request.memory.address,
                    true
                );

                response.success = (response.scan_result.address != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Function address found: 0x%08X", response.scan_result.address);
                }
                else {
                    LOG_WARN("Function address not found");
                    strcpy_s(response.error_message, "Function address not found");
                }
                break;
            }

            case READ_MEMORY: {
                LOG_DEBUG("Reading memory at 0x%08X, size: %u", request.memory.address, request.memory.size);

                if (request.memory.address && request.memory.size > 0
                    && request.memory.size <= sizeof(response.memory_result.data)) {

                    if (!IsBadReadPtr((void*)request.memory.address, request.memory.size)) {
                        memcpy(response.memory_result.data,
                            (void*)request.memory.address, request.memory.size);
                        response.memory_result.address = request.memory.address;
                        response.memory_result.size = request.memory.size;
                        response.success = 1;

                        LOG_SUCCESS("Memory read successful: %u bytes", request.memory.size);
                        LOG_TRACE("Data: %s",
                            BytesToHex((char*)response.memory_result.data, request.memory.size).c_str());
                    }
                    else {
                        response.success = 0;
                        strcpy_s(response.error_message, "Invalid memory address");
                        LOG_ERROR("Invalid memory address: 0x%08X", request.memory.address);
                    }
                }
                else {
                    response.success = 0;
                    strcpy_s(response.error_message, "Invalid read parameters");
                    LOG_ERROR("Invalid read parameters: addr=0x%08X, size=%u",
                        request.memory.address, request.memory.size);
                }
                break;
            }

            case GET_SECTION_INFO: {
                LOG_DEBUG("Getting section info for section: %d", request.scan.section);

                Scanner::GetSectionAddressRange(
                    (ScannerSection)request.scan.section,
                    &response.section_info.start,
                    &response.section_info.end
                );

                response.success = (response.section_info.start != 0
                    && response.section_info.end != 0) ? 1 : 0;

                if (response.success) {
                    LOG_SUCCESS("Section info: 0x%08X - 0x%08X (size: 0x%X)",
                        response.section_info.start,
                        response.section_info.end,
                        response.section_info.end - response.section_info.start);
                }
                else {
                    strcpy_s(response.error_message, "Section not found");
                    LOG_WARN("Section not found");
                }
                break;
            }

            case READ_POINTER_CHAIN: {
                LOG_DEBUG("Reading pointer chain from 0x%08X with %d offsets",
                    request.pointer_chain.base_address, request.pointer_chain.offset_count);

                // Validate parameters
                if (request.pointer_chain.offset_count > 16) {
                    response.success = 0;
                    strcpy_s(response.error_message, "Too many offsets (max 16)");
                    LOG_ERROR("Too many offsets: %d", request.pointer_chain.offset_count);
                    break;
                }

                if (request.pointer_chain.final_size != 1 && request.pointer_chain.final_size != 2 &&
                    request.pointer_chain.final_size != 4 && request.pointer_chain.final_size != 8) {
                    response.success = 0;
                    strcpy_s(response.error_message, "Invalid final_size (must be 1, 2, 4, or 8)");
                    LOG_ERROR("Invalid final_size: %d", request.pointer_chain.final_size);
                    break;
                }

                // Follow the pointer chain
                uintptr_t currentAddress = request.pointer_chain.base_address;

                for (uint8_t i = 0; i < request.pointer_chain.offset_count; i++) {
                    // Read pointer at current address
                    if (IsBadReadPtr((void*)currentAddress, sizeof(uintptr_t))) {
                        response.success = 0;
                        sprintf_s(response.error_message, "Invalid pointer at step %d (0x%08X)",
                            i, currentAddress);
                        LOG_ERROR("Invalid pointer at step %d: 0x%08X", i, currentAddress);
                        break;
                    }

                    // Dereference the pointer
                    uintptr_t nextAddress = *(uintptr_t*)currentAddress;
                    LOG_TRACE("Step %d: [0x%08X] -> 0x%08X", i, currentAddress, nextAddress);

                    // Apply offset
                    currentAddress = nextAddress + request.pointer_chain.offsets[i];
                    LOG_TRACE("Step %d: + offset 0x%X = 0x%08X", i, request.pointer_chain.offsets[i], currentAddress);
                }

                // Check if we had an error during chain traversal
                if (!response.success && strlen(response.error_message) > 0) {
                    break;
                }

                // Read final value
                if (IsBadReadPtr((void*)currentAddress, request.pointer_chain.final_size)) {
                    response.success = 0;
                    sprintf_s(response.error_message, "Invalid final address: 0x%08X", currentAddress);
                    LOG_ERROR("Invalid final address: 0x%08X", currentAddress);
                    break;
                }

                response.pointer_chain_result.final_address = currentAddress;
                response.pointer_chain_result.value = 0;

                // Read value based on size
                switch (request.pointer_chain.final_size) {
                case 1:
                    response.pointer_chain_result.value = *(uint8_t*)currentAddress;
                    break;
                case 2:
                    response.pointer_chain_result.value = *(uint16_t*)currentAddress;
                    break;
                case 4:
                    response.pointer_chain_result.value = *(uint32_t*)currentAddress;
                    break;
                case 8:
                    response.pointer_chain_result.value = *(uint64_t*)currentAddress;
                    break;
                }

                response.success = 1;
                LOG_SUCCESS("Pointer chain resolved: final=0x%08X, value=0x%llX",
                    currentAddress, response.pointer_chain_result.value);
                break;
            }

            default:
                response.success = 0;
                strcpy_s(response.error_message, "Unknown request type");
                LOG_ERROR("Unknown request type: %d", request.type);
                if (OnError) OnError("Unknown request type: " + std::to_string(request.type));
                break;
            }
        }
        catch (const std::exception& e) {
            response.success = 0;
            strcpy_s(response.error_message, e.what());
            LOG_ERROR("Exception in HandleRequest: %s", e.what());
            if (OnError) OnError("Exception handling request: " + std::string(e.what()));
        }
        catch (...) {
            response.success = 0;
            strcpy_s(response.error_message, "Unknown exception");
            LOG_ERROR("Unknown exception in HandleRequest");
            if (OnError) OnError("Unknown exception handling request");
        }
    }

    bool NamedPipeServer::ParseHexPattern(const char* hexStr, std::string& outPattern) {
        LOG_TRACE("ParseHexPattern called with: %s", hexStr);

        // Check if it's a hex pattern (format: "8B 0C 90 85 C9 74 19")
        std::string input(hexStr);
        std::stringstream ss(input);
        std::string byteStr;

        outPattern.clear();

        // Try to parse as hex
        while (ss >> byteStr) {
            // If not a valid hex byte, it's not a hex pattern
            if (byteStr.length() > 2) {
                LOG_TRACE("Not a hex pattern - byte string too long: %s", byteStr.c_str());
                return false;
            }

            try {
                unsigned int byte = std::stoul(byteStr, nullptr, 16);
                if (byte > 255) {
                    LOG_TRACE("Not a hex pattern - byte value > 255: %u", byte);
                    return false;
                }
                outPattern.push_back((char)byte);
            }
            catch (...) {
                LOG_TRACE("Not a hex pattern - failed to parse byte: %s", byteStr.c_str());
                return false;
            }
        }

        // Log parsed pattern
        if (!outPattern.empty()) {
            LOG_DEBUG("Successfully parsed hex pattern: %s", BytesToHex(outPattern.c_str(), outPattern.length()).c_str());

            if (OnLog) {
                std::stringstream logMsg;
                logMsg << "Parsed hex pattern: ";
                for (unsigned char c : outPattern) {
                    logMsg << "\\x" << std::hex << std::setw(2) << std::setfill('0') << (int)c;
                }
                OnLog(logMsg.str());
            }
        }
        else {
            LOG_TRACE("ParseHexPattern resulted in empty pattern");
        }

        return !outPattern.empty();
    }

    uint64_t NamedPipeServer::GetUptimeMs() const {
        if (!running) {
            return 0;
        }
        auto now = std::chrono::steady_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime);
        return static_cast<uint64_t>(duration.count());
    }
}