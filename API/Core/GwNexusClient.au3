#include-once
#include "GwNexusProtocol.au3"

; ============================================================================
; GwNexusClient.au3
; AutoIt client for GwNexus Named Pipe communication
; Supports multiple simultaneous connections to different GW instances
; ============================================================================

; ============================================================================
; Connection Object Structure
; ============================================================================
; A connection is represented as a 1D array:
;   [0] = Pipe handle
;   [1] = Process ID
;   [2] = Pipe name
;   [3] = Connection ID (unique identifier)
Global Const $CONN_HANDLE = 0
Global Const $CONN_PID = 1
Global Const $CONN_PIPENAME = 2
Global Const $CONN_ID = 3
Global Const $CONN_SIZE = 4

; Global connection counter for unique IDs
Global $g_iGwNexusConnectionCounter = 0

; Legacy global pipe handle (for backward compatibility)
Global $g_hGwNexusPipe = -1
Global $g_iGwNexusPID = 0
Global $g_sGwNexusPipeName = ""

; Current active connection (for legacy single-connection API)
Global $g_aGwNexusActiveConnection = 0

; Response buffer size
Global Const $GWNEXUS_RESPONSE_SIZE = 2860

; ============================================================================
; Client-Side Cache (Performance Optimization)
; ============================================================================
; Cache for pattern scan results - these don't change during game session
Global $g_dicScanCache = ObjCreate("Scripting.Dictionary")

; Enable/disable caching (enabled by default)
Global $g_bCacheEnabled = True

; Clear the scan cache (call when reconnecting or if game restarts)
Func _GwNexus_ClearCache()
    $g_dicScanCache.RemoveAll()
EndFunc

; Enable or disable caching
Func _GwNexus_SetCacheEnabled($bEnabled)
    $g_bCacheEnabled = $bEnabled
EndFunc

; Get cache statistics
Func _GwNexus_GetCacheStats()
    Local $aStats[2]
    $aStats[0] = $g_dicScanCache.Count ; Number of cached entries
    $aStats[1] = $g_bCacheEnabled      ; Is caching enabled
    Return $aStats
EndFunc

; ============================================================================
; Multi-Connection API (NEW)
; ============================================================================

; Create a new connection to a GW instance
; Returns: Connection array on success, 0 on failure
; Usage: $hConn = _GwNexus_CreateConnection($iPID)
Func _GwNexus_CreateConnection($iPID)
    Local $sPipeName = "\\.\pipe\GwNexus_" & $iPID

    ; Wait for pipe to be available
    Local $aWait = DllCall("kernel32.dll", "bool", "WaitNamedPipeW", _
        "wstr", $sPipeName, _
        "dword", 5000) ; 5 second timeout

    If @error Or $aWait[0] = 0 Then
        ConsoleWrite("[DEBUG] WaitNamedPipe failed for PID " & $iPID & ", error: " & _WinAPI_GetLastError() & @CRLF)
    EndIf

    ; Try to connect to the pipe
    Local $aResult = DllCall("kernel32.dll", "handle", "CreateFileW", _
        "wstr", $sPipeName, _
        "dword", BitOR(0x80000000, 0x40000000), _ ; GENERIC_READ | GENERIC_WRITE
        "dword", 0, _                              ; No sharing
        "ptr", 0, _                                ; Default security
        "dword", 3, _                              ; OPEN_EXISTING
        "dword", 0, _                              ; Normal attributes
        "ptr", 0)                                  ; No template

    If @error Then
        ConsoleWrite("[DEBUG] CreateFileW DllCall failed for PID " & $iPID & ", @error: " & @error & @CRLF)
        Return SetError(1, @error, 0)
    EndIf

    Local $hPipe = $aResult[0]

    ; Check for INVALID_HANDLE_VALUE
    If $hPipe = Ptr(-1) Or $hPipe = 0 Then
        Local $iLastError = _WinAPI_GetLastError()
        ConsoleWrite("[DEBUG] CreateFileW failed for PID " & $iPID & ", GetLastError: " & $iLastError & @CRLF)
        Return SetError(1, $iLastError, 0)
    EndIf

    ; Set pipe to message mode
    Local $dwMode = 0x02 ; PIPE_READMODE_MESSAGE
    Local $aSetMode = DllCall("kernel32.dll", "bool", "SetNamedPipeHandleState", _
        "handle", $hPipe, _
        "dword*", $dwMode, _
        "ptr", 0, _
        "ptr", 0)

    If @error Or $aSetMode[0] = 0 Then
        ConsoleWrite("[DEBUG] SetNamedPipeHandleState failed for PID " & $iPID & ", error: " & _WinAPI_GetLastError() & @CRLF)
        _WinAPI_CloseHandle($hPipe)
        Return SetError(2, @error, 0)
    EndIf

    ; Create connection object
    $g_iGwNexusConnectionCounter += 1
    Local $aConnection[$CONN_SIZE]
    $aConnection[$CONN_HANDLE] = $hPipe
    $aConnection[$CONN_PID] = $iPID
    $aConnection[$CONN_PIPENAME] = $sPipeName
    $aConnection[$CONN_ID] = $g_iGwNexusConnectionCounter

    Return $aConnection
EndFunc

; Close a connection
; $aConnection = Connection array returned by _GwNexus_CreateConnection
Func _GwNexus_CloseConnection(ByRef $aConnection)
    If Not IsArray($aConnection) Or UBound($aConnection) < $CONN_SIZE Then
        Return SetError(1, 0, False)
    EndIf

    If $aConnection[$CONN_HANDLE] <> -1 And $aConnection[$CONN_HANDLE] <> 0 Then
        _WinAPI_CloseHandle($aConnection[$CONN_HANDLE])
    EndIf

    $aConnection[$CONN_HANDLE] = -1
    $aConnection[$CONN_PID] = 0
    $aConnection[$CONN_PIPENAME] = ""

    Return True
EndFunc

; Check if a connection is valid
Func _GwNexus_IsConnectionValid($aConnection)
    If Not IsArray($aConnection) Or UBound($aConnection) < $CONN_SIZE Then
        Return False
    EndIf
    Return $aConnection[$CONN_HANDLE] <> -1 And $aConnection[$CONN_HANDLE] <> 0
EndFunc

; Get connection info
Func _GwNexus_GetConnectionPID($aConnection)
    If Not IsArray($aConnection) Or UBound($aConnection) < $CONN_SIZE Then Return 0
    Return $aConnection[$CONN_PID]
EndFunc

Func _GwNexus_GetConnectionPipeName($aConnection)
    If Not IsArray($aConnection) Or UBound($aConnection) < $CONN_SIZE Then Return ""
    Return $aConnection[$CONN_PIPENAME]
EndFunc

Func _GwNexus_GetConnectionID($aConnection)
    If Not IsArray($aConnection) Or UBound($aConnection) < $CONN_SIZE Then Return 0
    Return $aConnection[$CONN_ID]
EndFunc

; Default timeout for pipe operations (in milliseconds)
Global Const $GWNEXUS_PIPE_TIMEOUT = 10000 ; 10 seconds

; Send request on a specific connection with timeout
; Returns: DllStruct of response or 0 on error
; Error codes: 1=invalid connection, 2=write failed, 3=read timeout, 4=read failed
Func _GwNexus_SendRequestEx($aConnection, $tRequest, $iTimeout = $GWNEXUS_PIPE_TIMEOUT)
    If Not _GwNexus_IsConnectionValid($aConnection) Then
        Return SetError(1, 0, 0) ; Invalid connection
    EndIf

    Local $hPipe = $aConnection[$CONN_HANDLE]
    Local $iRequestSize = DllStructGetSize($tRequest)
    Local $iBytesWritten = 0

    ; Create event for overlapped I/O
    Local $aEventResult = DllCall("kernel32.dll", "handle", "CreateEventW", _
        "ptr", 0, _      ; default security
        "bool", True, _  ; manual reset
        "bool", False, _ ; initial state = non-signaled
        "ptr", 0)        ; no name

    If @error Or $aEventResult[0] = 0 Then
        Return SetError(2, @error, 0)
    EndIf

    Local $hEvent = $aEventResult[0]

    ; Create OVERLAPPED structure
    Local $tOverlapped = DllStructCreate("ptr Internal;ptr InternalHigh;dword Offset;dword OffsetHigh;handle hEvent")
    DllStructSetData($tOverlapped, "hEvent", $hEvent)

    ; Write request to pipe (overlapped)
    Local $aResult = DllCall("kernel32.dll", "bool", "WriteFile", _
        "handle", $hPipe, _
        "struct*", $tRequest, _
        "dword", $iRequestSize, _
        "dword*", $iBytesWritten, _
        "struct*", $tOverlapped)

    If @error Then
        _WinAPI_CloseHandle($hEvent)
        Return SetError(2, @error, 0)
    EndIf

    ; If WriteFile returned FALSE, check if it's pending
    If $aResult[0] = 0 Then
        Local $iLastError = _WinAPI_GetLastError()
        If $iLastError <> 997 Then ; ERROR_IO_PENDING = 997
            _WinAPI_CloseHandle($hEvent)
            Return SetError(2, $iLastError, 0)
        EndIf

        ; Wait for write to complete with timeout
        Local $aWaitResult = DllCall("kernel32.dll", "dword", "WaitForSingleObject", _
            "handle", $hEvent, _
            "dword", $iTimeout)

        If @error Or $aWaitResult[0] <> 0 Then ; WAIT_OBJECT_0 = 0
            DllCall("kernel32.dll", "bool", "CancelIo", "handle", $hPipe)
            _WinAPI_CloseHandle($hEvent)
            Return SetError(2, $aWaitResult[0], 0) ; Write timeout or error
        EndIf
    EndIf

    ; Reset event for read operation
    DllCall("kernel32.dll", "bool", "ResetEvent", "handle", $hEvent)

    ; Read response (overlapped)
    Local $tResponse = DllStructCreate("byte data[" & $GWNEXUS_RESPONSE_SIZE & "]")
    Local $iBytesRead = 0

    $aResult = DllCall("kernel32.dll", "bool", "ReadFile", _
        "handle", $hPipe, _
        "struct*", $tResponse, _
        "dword", $GWNEXUS_RESPONSE_SIZE, _
        "dword*", $iBytesRead, _
        "struct*", $tOverlapped)

    If @error Then
        _WinAPI_CloseHandle($hEvent)
        Return SetError(4, @error, 0)
    EndIf

    ; If ReadFile returned FALSE, check if it's pending
    If $aResult[0] = 0 Then
        Local $iLastError = _WinAPI_GetLastError()
        If $iLastError <> 997 Then ; ERROR_IO_PENDING = 997
            _WinAPI_CloseHandle($hEvent)
            Return SetError(4, $iLastError, 0)
        EndIf

        ; Wait for read to complete with timeout
        Local $aWaitResult = DllCall("kernel32.dll", "dword", "WaitForSingleObject", _
            "handle", $hEvent, _
            "dword", $iTimeout)

        If @error Or $aWaitResult[0] <> 0 Then ; WAIT_OBJECT_0 = 0
            DllCall("kernel32.dll", "bool", "CancelIo", "handle", $hPipe)
            _WinAPI_CloseHandle($hEvent)
            If $aWaitResult[0] = 258 Then ; WAIT_TIMEOUT = 258
                ConsoleWrite("[ERROR] Pipe read timeout after " & $iTimeout & "ms" & @CRLF)
                Return SetError(3, 258, 0) ; Read timeout
            EndIf
            Return SetError(4, $aWaitResult[0], 0) ; Read error
        EndIf

        ; Get the result of the overlapped operation
        Local $aOverlappedResult = DllCall("kernel32.dll", "bool", "GetOverlappedResult", _
            "handle", $hPipe, _
            "struct*", $tOverlapped, _
            "dword*", $iBytesRead, _
            "bool", False)

        If @error Or $aOverlappedResult[0] = 0 Then
            _WinAPI_CloseHandle($hEvent)
            Return SetError(4, _WinAPI_GetLastError(), 0)
        EndIf
    EndIf

    _WinAPI_CloseHandle($hEvent)
    Return $tResponse
EndFunc

; Create connections to all available GW instances
; Returns: Array of connection objects
Func _GwNexus_CreateAllConnections()
    Local $aProcesses = _GwNexus_FindGuildWarsProcesses()
    Local $aConnections[UBound($aProcesses)]
    Local $iCount = 0

    For $i = 0 To UBound($aProcesses) - 1
        Local $aConn = _GwNexus_CreateConnection($aProcesses[$i])
        If _GwNexus_IsConnectionValid($aConn) Then
            $aConnections[$iCount] = $aConn
            $iCount += 1
        EndIf
    Next

    ReDim $aConnections[$iCount]
    Return $aConnections
EndFunc

; Close all connections in an array
Func _GwNexus_CloseAllConnections(ByRef $aConnections)
    If Not IsArray($aConnections) Then Return
    For $i = 0 To UBound($aConnections) - 1
        If IsArray($aConnections[$i]) Then
            _GwNexus_CloseConnection($aConnections[$i])
        EndIf
    Next
EndFunc

; ============================================================================
; Legacy Single-Connection API (Backward Compatible)
; ============================================================================

; Connect to GwNexus pipe by process ID
; Returns: True on success, False on failure
Func _GwNexus_Connect($iPID)
    If $g_hGwNexusPipe <> -1 Then
        _GwNexus_Disconnect()
    EndIf

    ; Use the new multi-connection API internally
    $g_aGwNexusActiveConnection = _GwNexus_CreateConnection($iPID)

    If Not _GwNexus_IsConnectionValid($g_aGwNexusActiveConnection) Then
        $g_aGwNexusActiveConnection = 0
        Return SetError(@error, @extended, False)
    EndIf

    ; Update legacy globals for compatibility
    $g_hGwNexusPipe = $g_aGwNexusActiveConnection[$CONN_HANDLE]
    $g_iGwNexusPID = $g_aGwNexusActiveConnection[$CONN_PID]
    $g_sGwNexusPipeName = $g_aGwNexusActiveConnection[$CONN_PIPENAME]

    Return True
EndFunc

; Disconnect from pipe
Func _GwNexus_Disconnect()
    If IsArray($g_aGwNexusActiveConnection) Then
        _GwNexus_CloseConnection($g_aGwNexusActiveConnection)
        $g_aGwNexusActiveConnection = 0
    ElseIf $g_hGwNexusPipe <> -1 Then
        _WinAPI_CloseHandle($g_hGwNexusPipe)
    EndIf

    $g_hGwNexusPipe = -1
    $g_iGwNexusPID = 0
    $g_sGwNexusPipeName = ""
EndFunc

; Check if connected
Func _GwNexus_IsConnected()
    Return $g_hGwNexusPipe <> -1
EndFunc

; Get current pipe name
Func _GwNexus_GetPipeName()
    Return $g_sGwNexusPipeName
EndFunc

; Get current PID
Func _GwNexus_GetPID()
    Return $g_iGwNexusPID
EndFunc

; Get active connection object (for advanced use)
Func _GwNexus_GetActiveConnection()
    Return $g_aGwNexusActiveConnection
EndFunc

; ============================================================================
; Low-Level Communication
; ============================================================================

; Send request and receive response
; $tRequest = DllStruct of request
; Returns: DllStruct of response or 0 on error
Func _GwNexus_SendRequest($tRequest)
    If $g_hGwNexusPipe = -1 Then
        Return SetError(1, 0, 0) ; Not connected
    EndIf

    Local $iRequestSize = DllStructGetSize($tRequest)
    Local $iBytesWritten = 0

    ; Write request to pipe
    Local $aResult = DllCall("kernel32.dll", "bool", "WriteFile", _
        "handle", $g_hGwNexusPipe, _
        "struct*", $tRequest, _
        "dword", $iRequestSize, _
        "dword*", $iBytesWritten, _
        "ptr", 0)

    If @error Or $aResult[0] = 0 Then
        Return SetError(2, @error, 0) ; Write failed
    EndIf

    ; Read response
    Local $tResponse = DllStructCreate("byte data[" & $GWNEXUS_RESPONSE_SIZE & "]")
    Local $iBytesRead = 0

    $aResult = DllCall("kernel32.dll", "bool", "ReadFile", _
        "handle", $g_hGwNexusPipe, _
        "struct*", $tResponse, _
        "dword", $GWNEXUS_RESPONSE_SIZE, _
        "dword*", $iBytesRead, _
        "ptr", 0)

    If @error Or $aResult[0] = 0 Then
        Return SetError(3, @error, 0) ; Read failed
    EndIf

    Return $tResponse
EndFunc

; ============================================================================
; Scanner Functions
; ============================================================================

; Find pattern in memory
; $sPattern = Hex pattern with spaces, e.g., "55 8B EC ?? 83"
; $iOffset = Offset to add to result
; $iSection = Section to scan (SECTION_TEXT, SECTION_RDATA, SECTION_DATA)
; Returns: Address or 0 on failure
Func _GwNexus_ScanFind($sPattern, $iOffset = 0, $iSection = $SECTION_TEXT)
    ; Check cache first
    If $g_bCacheEnabled Then
        Local $sCacheKey = "SF:" & $sPattern & ":" & $iOffset & ":" & $iSection
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $sMask = _GwNexus_CreateMaskFromPattern($sPattern)
    Local $tRequest = _GwNexus_CreateScanRequest($sPattern, $sMask, $iOffset, $iSection)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 Then
        Local $sCacheKey = "SF:" & $sPattern & ":" & $iOffset & ":" & $iSection
        $g_dicScanCache.Add($sCacheKey, $iResult)
    EndIf

    Return $iResult
EndFunc

; Find pattern using assertion message
; Returns: Address or 0 on failure
Func _GwNexus_ScanFindAssertion($sFile, $sMessage, $iLine = 0, $iOffset = 0)
    ; Check cache first
    If $g_bCacheEnabled Then
        Local $sCacheKey = "SA:" & $sFile & ":" & $sMessage & ":" & $iLine & ":" & $iOffset
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $tRequest = _GwNexus_CreateAssertionRequest($sFile, $sMessage, $iLine, $iOffset)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 Then
        Local $sCacheKey = "SA:" & $sFile & ":" & $sMessage & ":" & $iLine & ":" & $iOffset
        $g_dicScanCache.Add($sCacheKey, $iResult)
    EndIf

    Return $iResult
EndFunc

; Get function address from a near call instruction
; $iAddress = Address of the CALL instruction (E8 xx xx xx xx)
; Returns: Target function address or 0 on failure
Func _GwNexus_ScanFunctionFromNearCall($iAddress)
    ; Check cache first
    If $g_bCacheEnabled Then
        Local $sCacheKey = "NC:" & Hex($iAddress)
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $tRequest = _GwNexus_CreateFunctionFromNearCallRequest($iAddress)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 Then
        Local $sCacheKey = "NC:" & Hex($iAddress)
        $g_dicScanCache.Add($sCacheKey, $iResult)
    EndIf

    Return $iResult
EndFunc

; ============================================================================
; Function Registry
; ============================================================================

; Register a function for calling
; Returns: True on success, False on failure
Func _GwNexus_RegisterFunction($sName, $iAddress, $iParamCount, $iConvention = $CONV_STDCALL, $bHasReturn = True)
    Local $tRequest = _GwNexus_CreateRegisterFunctionRequest($sName, $iAddress, $iParamCount, $iConvention, $bHasReturn)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

; Unregister a function
Func _GwNexus_UnregisterFunction($sName)
    Local $tRequest = _GwNexus_CreateUnregisterFunctionRequest($sName)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

; Call a registered function
; $aParams = 2D array [[type, value], [type, value], ...]
; Returns: Return value or 0
Func _GwNexus_CallFunction($sName, $aParams = Null)
    Local $tRequest = _GwNexus_CreateCallFunctionRequest($sName, $aParams)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseCallResponse($tResponse)
EndFunc

; List registered functions
; Returns: Array of function names
Func _GwNexus_ListFunctions()
    Local $tRequest = _GwNexus_CreateListFunctionsRequest()

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseFunctionListResponse($tResponse)
EndFunc

; ============================================================================
; Memory Operations
; ============================================================================

; Read memory from target process
; Returns: Array [address, size, data struct] or 0 on failure
Func _GwNexus_ReadMemory($iAddress, $iSize)
    If $iSize > 1024 Then $iSize = 1024 ; Max size

    Local $tRequest = _GwNexus_CreateReadMemoryRequest($iAddress, $iSize)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseMemoryResponse($tResponse)
EndFunc

; Read a single value from memory
Func _GwNexus_ReadMemoryValue($iAddress, $sType = "dword")
    Local $iSize
    Switch $sType
        Case "byte"
            $iSize = 1
        Case "word", "short"
            $iSize = 2
        Case "dword", "int", "float"
            $iSize = 4
        Case "int64", "double", "ptr"
            $iSize = 8
        Case Else
            $iSize = 4
    EndSwitch

    Local $aResult = _GwNexus_ReadMemory($iAddress, $iSize)
    If @error Then Return SetError(@error, 0, 0)

    Local $tValue = DllStructCreate($sType, DllStructGetPtr($aResult[2]))
    Return DllStructGetData($tValue, 1)
EndFunc

; Write memory to target process
; Returns: True on success
Func _GwNexus_WriteMemory($iAddress, $tData, $iSize)
    If $iSize > 1024 Then Return SetError(1, 0, False) ; Too large

    Local $tRequest = _GwNexus_CreateWriteMemoryRequest($iAddress, $tData, $iSize)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

; Write a single value to memory
Func _GwNexus_WriteMemoryValue($iAddress, $vValue, $sType = "dword")
    Local $tData = DllStructCreate($sType)
    DllStructSetData($tData, 1, $vValue)

    Return _GwNexus_WriteMemory($iAddress, $tData, DllStructGetSize($tData))
EndFunc

; Read value following a pointer chain
; $iBaseAddress = Starting address (e.g., base_ptr address)
; $aOffsets = Array of offsets to follow (max 16)
; $iFinalSize = Size of final value to read (1, 2, 4, or 8 bytes)
; Returns: Value read at the end of the chain, or 0 on error
Func _GwNexus_ReadPointerChain($iBaseAddress, $aOffsets, $iFinalSize = 4)
    Local $tRequest = _GwNexus_CreatePointerChainRequest($iBaseAddress, $aOffsets, $iFinalSize)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; Parse response
    ; PipeResponse: success (1) + padding (3) + union (pointer_chain_result at same offset as others)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "ptr final_address;" & _
        "uint64 value", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    ; Return value based on final_size
    Local $iValue = DllStructGetData($tResult, "value")

    Switch $iFinalSize
        Case 1
            Return BitAND($iValue, 0xFF)
        Case 2
            Return BitAND($iValue, 0xFFFF)
        Case 4
            Return BitAND($iValue, 0xFFFFFFFF)
        Case 8
            Return $iValue
        Case Else
            Return BitAND($iValue, 0xFFFFFFFF)
    EndSwitch
EndFunc

; Allocate memory in target process
; Returns: Allocated address or 0
Func _GwNexus_AllocateMemory($iSize, $iProtection = 0x40)
    Local $tRequest = _GwNexus_CreateAllocateMemoryRequest($iSize, $iProtection)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $aResult = _GwNexus_ParseMemoryResponse($tResponse)
    If @error Then Return SetError(@error, 0, 0)

    Return $aResult[0]
EndFunc

; Free memory in target process
Func _GwNexus_FreeMemory($iAddress)
    Local $tRequest = _GwNexus_CreateFreeMemoryRequest($iAddress)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

; ============================================================================
; Array Read Functions
; ============================================================================

; Read an array of typed values from memory
; $iAddress = Memory address of the array
; $iElementType = Type of elements ($PARAM_INT8, $PARAM_INT32, $PARAM_FLOAT, etc.)
; $iElementCount = Number of elements to read
; Returns: AutoIt array of values, or 0 on error
Func _GwNexus_ReadMemoryArray($iAddress, $iElementType, $iElementCount)
    ; Create request
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "byte element_type;" & _
        "byte padding[3];" & _
        "uint element_count" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_READ_MEMORY_ARRAY)
    DllStructSetData($tRequest, "address", $iAddress)
    DllStructSetData($tRequest, "element_type", $iElementType)
    DllStructSetData($tRequest, "element_count", $iElementCount)

    ; Send request
    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; Parse response header
    Local $tHeader = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte element_type;" & _
        "byte padding2[3];" & _
        "uint element_count;" & _
        "uint element_size;" & _
        "uint total_size", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tHeader, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iCount = DllStructGetData($tHeader, "element_count")
    Local $iElemSize = DllStructGetData($tHeader, "element_size")
    Local $iType = DllStructGetData($tHeader, "element_type")

    ; Create result array
    Local $aResult[$iCount]

    ; Get pointer to data (after header: 1 + 3 + 1 + 3 + 4 + 4 + 4 = 20 bytes)
    Local $pData = DllStructGetPtr($tResponse) + 20

    ; Parse elements based on type
    Local $sStructType = ""
    Switch $iType
        Case $PARAM_INT8
            $sStructType = "byte"
        Case $PARAM_INT16
            $sStructType = "short"
        Case $PARAM_INT32
            $sStructType = "int"
        Case $PARAM_INT64
            $sStructType = "int64"
        Case $PARAM_FLOAT
            $sStructType = "float"
        Case $PARAM_DOUBLE
            $sStructType = "double"
        Case $PARAM_POINTER
            $sStructType = "ptr"
        Case Else
            Return SetError(2, 0, 0) ; Unknown type
    EndSwitch

    ; Read each element
    For $i = 0 To $iCount - 1
        Local $tElement = DllStructCreate($sStructType, $pData + ($i * $iElemSize))
        $aResult[$i] = DllStructGetData($tElement, 1)
    Next

    Return $aResult
EndFunc

; Read an array of typed values from memory (Extended - specific connection)
Func _GwNexus_ReadMemoryArrayEx($aConnection, $iAddress, $iElementType, $iElementCount)
    If Not _GwNexus_IsConnectionValid($aConnection) Then
        Return SetError(1, 0, 0)
    EndIf

    ; Create request
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "byte element_type;" & _
        "byte padding[3];" & _
        "uint element_count" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_READ_MEMORY_ARRAY)
    DllStructSetData($tRequest, "address", $iAddress)
    DllStructSetData($tRequest, "element_type", $iElementType)
    DllStructSetData($tRequest, "element_count", $iElementCount)

    ; Send request
    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; Parse response header
    Local $tHeader = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte element_type;" & _
        "byte padding2[3];" & _
        "uint element_count;" & _
        "uint element_size;" & _
        "uint total_size", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tHeader, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iCount = DllStructGetData($tHeader, "element_count")
    Local $iElemSize = DllStructGetData($tHeader, "element_size")
    Local $iType = DllStructGetData($tHeader, "element_type")

    ; Create result array
    Local $aResult[$iCount]

    ; Get pointer to data (after header: 1 + 3 + 1 + 3 + 4 + 4 + 4 = 20 bytes)
    Local $pData = DllStructGetPtr($tResponse) + 20

    ; Parse elements based on type
    Local $sStructType = ""
    Switch $iType
        Case $PARAM_INT8
            $sStructType = "byte"
        Case $PARAM_INT16
            $sStructType = "short"
        Case $PARAM_INT32
            $sStructType = "int"
        Case $PARAM_INT64
            $sStructType = "int64"
        Case $PARAM_FLOAT
            $sStructType = "float"
        Case $PARAM_DOUBLE
            $sStructType = "double"
        Case $PARAM_POINTER
            $sStructType = "ptr"
        Case Else
            Return SetError(2, 0, 0) ; Unknown type
    EndSwitch

    ; Read each element
    For $i = 0 To $iCount - 1
        Local $tElement = DllStructCreate($sStructType, $pData + ($i * $iElemSize))
        $aResult[$i] = DllStructGetData($tElement, 1)
    Next

    Return $aResult
EndFunc

; Convenience function: Read array of INT32
Func _GwNexus_ReadInt32Array($iAddress, $iCount)
    Return _GwNexus_ReadMemoryArray($iAddress, $PARAM_INT32, $iCount)
EndFunc

; Convenience function: Read array of FLOAT
Func _GwNexus_ReadFloatArray($iAddress, $iCount)
    Return _GwNexus_ReadMemoryArray($iAddress, $PARAM_FLOAT, $iCount)
EndFunc

; Convenience function: Read array of POINTER
Func _GwNexus_ReadPointerArray($iAddress, $iCount)
    Return _GwNexus_ReadMemoryArray($iAddress, $PARAM_POINTER, $iCount)
EndFunc

; Extended versions for multi-connection
Func _GwNexus_ReadInt32ArrayEx($aConnection, $iAddress, $iCount)
    Return _GwNexus_ReadMemoryArrayEx($aConnection, $iAddress, $PARAM_INT32, $iCount)
EndFunc

Func _GwNexus_ReadFloatArrayEx($aConnection, $iAddress, $iCount)
    Return _GwNexus_ReadMemoryArrayEx($aConnection, $iAddress, $PARAM_FLOAT, $iCount)
EndFunc

Func _GwNexus_ReadPointerArrayEx($aConnection, $iAddress, $iCount)
    Return _GwNexus_ReadMemoryArrayEx($aConnection, $iAddress, $PARAM_POINTER, $iCount)
EndFunc

; ============================================================================
; Batch Read Functions (Performance Optimization)
; ============================================================================

; Read multiple memory addresses in a single request
; $aAddresses = Array of addresses to read
; $aSizes = Array of sizes (1, 2, 4, or 8 bytes each) - or single value for all
; Returns: Array of values (0 if read failed for that index)
; Use _GwNexus_BatchReadSuccess() to check which reads succeeded
Global $g_aLastBatchSuccessMask[4] ; Store success mask from last batch read

Func _GwNexus_BatchReadMemory($aAddresses, $vSizes = 4)
    Local $iCount = UBound($aAddresses)
    If $iCount = 0 Or $iCount > 32 Then
        Return SetError(1, 0, 0) ; Invalid count
    EndIf

    ; Create request structure
    ; type (4) + count (1) + sizes[32] (32) + padding (3) + addresses[32] (128 for 32-bit)
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "byte count;" & _
        "byte sizes[32];" & _
        "byte padding[3];" & _
        "ptr addresses[32]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_BATCH_READ_MEMORY)
    DllStructSetData($tRequest, "count", $iCount)

    ; Set sizes
    If IsArray($vSizes) Then
        For $i = 0 To $iCount - 1
            DllStructSetData($tRequest, "sizes", $vSizes[$i], $i + 1)
        Next
    Else
        For $i = 0 To $iCount - 1
            DllStructSetData($tRequest, "sizes", $vSizes, $i + 1)
        Next
    EndIf

    ; Set addresses
    For $i = 0 To $iCount - 1
        DllStructSetData($tRequest, "addresses", $aAddresses[$i], $i + 1)
    Next

    ; Send request
    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; Parse response
    ; success (1) + padding (3) + count (1) + success_mask[4] (4) + padding (3) + values[32] (256)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte count;" & _
        "byte success_mask[4];" & _
        "byte padding2[3];" & _
        "uint64 values[32]", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    ; Store success mask for later checking
    For $i = 0 To 3
        $g_aLastBatchSuccessMask[$i] = DllStructGetData($tResult, "success_mask", $i + 1)
    Next

    ; Extract values
    Local $aResult[$iCount]
    For $i = 0 To $iCount - 1
        Local $iValue = DllStructGetData($tResult, "values", $i + 1)

        ; Mask based on size
        If IsArray($vSizes) Then
            Local $iSize = $vSizes[$i]
        Else
            Local $iSize = $vSizes
        EndIf

        Switch $iSize
            Case 1
                $aResult[$i] = BitAND($iValue, 0xFF)
            Case 2
                $aResult[$i] = BitAND($iValue, 0xFFFF)
            Case 4
                $aResult[$i] = BitAND($iValue, 0xFFFFFFFF)
            Case 8
                $aResult[$i] = $iValue
            Case Else
                $aResult[$i] = BitAND($iValue, 0xFFFFFFFF)
        EndSwitch
    Next

    Return $aResult
EndFunc

; Check if a specific index in the last batch read succeeded
Func _GwNexus_BatchReadSuccess($iIndex)
    If $iIndex < 0 Or $iIndex > 31 Then Return False
    Local $iByte = Int($iIndex / 8)
    Local $iBit = Mod($iIndex, 8)
    Return BitAND($g_aLastBatchSuccessMask[$iByte], BitShift(1, -$iBit)) <> 0
EndFunc

; Extended version for specific connection
Func _GwNexus_BatchReadMemoryEx($aConnection, $aAddresses, $vSizes = 4)
    If Not _GwNexus_IsConnectionValid($aConnection) Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iCount = UBound($aAddresses)
    If $iCount = 0 Or $iCount > 32 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "byte count;" & _
        "byte sizes[32];" & _
        "byte padding[3];" & _
        "ptr addresses[32]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_BATCH_READ_MEMORY)
    DllStructSetData($tRequest, "count", $iCount)

    If IsArray($vSizes) Then
        For $i = 0 To $iCount - 1
            DllStructSetData($tRequest, "sizes", $vSizes[$i], $i + 1)
        Next
    Else
        For $i = 0 To $iCount - 1
            DllStructSetData($tRequest, "sizes", $vSizes, $i + 1)
        Next
    EndIf

    For $i = 0 To $iCount - 1
        DllStructSetData($tRequest, "addresses", $aAddresses[$i], $i + 1)
    Next

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte count;" & _
        "byte success_mask[4];" & _
        "byte padding2[3];" & _
        "uint64 values[32]", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    For $i = 0 To 3
        $g_aLastBatchSuccessMask[$i] = DllStructGetData($tResult, "success_mask", $i + 1)
    Next

    Local $aResult[$iCount]
    For $i = 0 To $iCount - 1
        Local $iValue = DllStructGetData($tResult, "values", $i + 1)

        If IsArray($vSizes) Then
            Local $iSize = $vSizes[$i]
        Else
            Local $iSize = $vSizes
        EndIf

        Switch $iSize
            Case 1
                $aResult[$i] = BitAND($iValue, 0xFF)
            Case 2
                $aResult[$i] = BitAND($iValue, 0xFFFF)
            Case 4
                $aResult[$i] = BitAND($iValue, 0xFFFFFFFF)
            Case 8
                $aResult[$i] = $iValue
        EndSwitch
    Next

    Return $aResult
EndFunc

; ============================================================================
; Server/DLL Control
; ============================================================================

; Get server status
; Returns: Array [status, client_count, uptime_ms, pipe_name] or 0 on failure
Func _GwNexus_GetServerStatus()
    Local $tRequest = _GwNexus_CreateServerStatusRequest()

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; PipeResponse layout:
    ; - success (1) + padding (3) = 4 bytes
    ; - union (largest = function_list: 4 + 20*64 = 1284 bytes)
    ; - server_status starts at offset 1288
    ; Total union size = 1284 bytes

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte union_data[1284];" & _  ; Skip union (function_list is largest: 4 + 1280)
        "int status;" & _
        "uint client_count;" & _
        "uint64 uptime_ms;" & _
        "char pipe_name[256]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aStatus[4]
    $aStatus[0] = DllStructGetData($tResult, "status")
    $aStatus[1] = DllStructGetData($tResult, "client_count")
    $aStatus[2] = DllStructGetData($tResult, "uptime_ms")
    $aStatus[3] = DllStructGetData($tResult, "pipe_name")

    Return $aStatus
EndFunc

; Get DLL status
; Returns: Array [status, version, build_info] or 0 on failure
Func _GwNexus_GetDLLStatus()
    Local $tRequest = _GwNexus_CreateDLLStatusRequest()

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; PipeResponse layout:
    ; - success (1) + padding (3) = 4 bytes
    ; - union = 1284 bytes
    ; - server_status (4 + 4 + 8 + 256) = 272 bytes
    ; - dll_status starts at offset 1560

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte union_data[1284];" & _     ; Skip union
        "byte server_status[272];" & _   ; Skip server_status (4+4+8+256)
        "int status;" & _
        "uint version;" & _
        "char build_info[256]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aStatus[3]
    $aStatus[0] = DllStructGetData($tResult, "status")
    $aStatus[1] = DllStructGetData($tResult, "version")
    $aStatus[2] = DllStructGetData($tResult, "build_info")

    Return $aStatus
EndFunc

; ============================================================================
; Heartbeat/Watchdog Functions
; ============================================================================

; Send heartbeat to check if connection is alive and measure latency
; Returns: Array [client_timestamp, server_timestamp, latency_ms] or 0 on failure
Func _GwNexus_Heartbeat()
    Local $iClientTimestamp = DllCall("kernel32.dll", "dword", "GetTickCount")[0]

    Local $tRequest = DllStructCreate("int type; uint client_timestamp")
    DllStructSetData($tRequest, "type", $REQUEST_HEARTBEAT)
    DllStructSetData($tRequest, "client_timestamp", $iClientTimestamp)

    Local $tResponse = _GwNexus_SendRequest($tRequest)
    If @error Then Return SetError(@error, 0, 0)

    ; Parse response - heartbeat_result is in the union
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "uint client_timestamp;" & _
        "uint server_timestamp;" & _
        "uint latency_ms", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aResult[3]
    $aResult[0] = DllStructGetData($tResult, "client_timestamp")
    $aResult[1] = DllStructGetData($tResult, "server_timestamp")
    $aResult[2] = DllStructGetData($tResult, "latency_ms")

    Return $aResult
EndFunc

; Extended version for specific connection
Func _GwNexus_HeartbeatEx($aConnection)
    If Not _GwNexus_IsConnectionValid($aConnection) Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iClientTimestamp = DllCall("kernel32.dll", "dword", "GetTickCount")[0]

    Local $tRequest = DllStructCreate("int type; uint client_timestamp")
    DllStructSetData($tRequest, "type", $REQUEST_HEARTBEAT)
    DllStructSetData($tRequest, "client_timestamp", $iClientTimestamp)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "uint client_timestamp;" & _
        "uint server_timestamp;" & _
        "uint latency_ms", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aResult[3]
    $aResult[0] = DllStructGetData($tResult, "client_timestamp")
    $aResult[1] = DllStructGetData($tResult, "server_timestamp")
    $aResult[2] = DllStructGetData($tResult, "latency_ms")

    Return $aResult
EndFunc

; Check if connection is alive (returns True/False)
Func _GwNexus_IsAlive()
    Local $aResult = _GwNexus_Heartbeat()
    Return Not @error
EndFunc

; Check if specific connection is alive
Func _GwNexus_IsAliveEx($aConnection)
    Local $aResult = _GwNexus_HeartbeatEx($aConnection)
    Return Not @error
EndFunc

; ============================================================================
; Utility Functions
; ============================================================================

; Find Guild Wars process
; Returns: Array of PIDs or empty array
Func _GwNexus_FindGuildWarsProcesses()
    Local $aProcesses[0]
    Local $aList = ProcessList("Gw.exe")

    If $aList[0][0] > 0 Then
        ReDim $aProcesses[$aList[0][0]]
        For $i = 1 To $aList[0][0]
            $aProcesses[$i - 1] = $aList[$i][1]
        Next
    EndIf

    Return $aProcesses
EndFunc

; Connect to first available Guild Wars process
Func _GwNexus_ConnectToFirstGW()
    Local $aProcesses = _GwNexus_FindGuildWarsProcesses()

    If UBound($aProcesses) = 0 Then
        Return SetError(1, 0, False) ; No GW process found
    EndIf

    For $i = 0 To UBound($aProcesses) - 1
        If _GwNexus_Connect($aProcesses[$i]) Then
            Return True
        EndIf
    Next

    Return SetError(2, 0, False) ; Could not connect to any
EndFunc

; Wait for pipe to be available (useful after injection)
Func _GwNexus_WaitForPipe($iPID, $iTimeoutMs = 5000)
    Local $sName = "\\.\pipe\GwNexus_" & $iPID
    Local $hTimer = TimerInit()

    While TimerDiff($hTimer) < $iTimeoutMs
        ; Try to check if pipe exists
        Local $aResult = DllCall("kernel32.dll", "dword", "WaitNamedPipeW", _
            "wstr", $sName, _
            "dword", 100)

        If Not @error And $aResult[0] <> 0 Then
            Return True
        EndIf

        Sleep(50)
    WEnd

    Return False
EndFunc

; Enumerate all GwNexus pipes by scanning GW processes and reading character names
; Returns: 2D array [n][2] where [i][0] = character name, [i][1] = pipe name
Func _GwNexus_EnumeratePipes()
    Local $aPipes[0][2]

    ; Get all GW windows
    Local $aWinList = WinList("[CLASS:ArenaNet_Dx_Window_Class]")
    If $aWinList[0][0] = 0 Then Return $aPipes

    Local $hKernel = DllOpen("kernel32.dll")
    If $hKernel = -1 Then Return $aPipes

    ; Pattern to find character name
    Local $sCharNameCode = BinaryToString("0x8BF86A03680F0000C08BCFE8")
    Local $iCharNameRva = 0  ; Will be found once and reused

    For $i = 1 To $aWinList[0][0]
        Local $iPID = WinGetProcess($aWinList[$i][1])
        If $iPID = 0 Then ContinueLoop

        ; Open process
        Local $aOpen = DllCall($hKernel, "handle", "OpenProcess", "dword", 0x1F0FFF, "bool", False, "dword", $iPID)
        If @error Or $aOpen[0] = 0 Then ContinueLoop
        Local $hProc = $aOpen[0]

        ; Get module info
        Local $iModuleBase = 0, $iModuleSize = 0
        If Not __GwNexus_GetModuleInfo($hKernel, $hProc, $iPID, $iModuleBase, $iModuleSize) Then
            DllCall($hKernel, "bool", "CloseHandle", "handle", $hProc)
            ContinueLoop
        EndIf

        ; Find character name RVA if not already found
        If $iCharNameRva = 0 Then
            $iCharNameRva = __GwNexus_ScanForCharname($hKernel, $hProc, $iModuleBase, $iModuleSize, $sCharNameCode)
        EndIf

        If $iCharNameRva <> 0 Then
            ; Read character name
            Local $tName = DllStructCreate("wchar[30]")
            Local $aRead = DllCall($hKernel, "bool", "ReadProcessMemory", _
                "handle", $hProc, _
                "ptr", $iModuleBase + $iCharNameRva, _
                "struct*", $tName, _
                "ulong_ptr", DllStructGetSize($tName), _
                "ulong_ptr*", 0)

            If Not @error And $aRead[0] Then
                Local $sCharName = DllStructGetData($tName, 1)
                If $sCharName <> "" Then
                    ; Build pipe name (replace spaces with underscores)
                    Local $sPipeName = "\\.\pipe\GwNexus_" & StringReplace($sCharName, " ", "_")

                    ; Check if pipe exists by trying to wait for it briefly
                    Local $aWait = DllCall($hKernel, "bool", "WaitNamedPipeW", "wstr", $sPipeName, "dword", 100)
                    If Not @error And $aWait[0] <> 0 Then
                        ; Pipe exists, add to list
                        Local $iSize = UBound($aPipes)
                        ReDim $aPipes[$iSize + 1][2]
                        $aPipes[$iSize][0] = $sCharName
                        $aPipes[$iSize][1] = $sPipeName
                    EndIf
                EndIf
            EndIf
        EndIf

        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProc)
    Next

    DllClose($hKernel)
    Return $aPipes
EndFunc

; Internal: Get module base and size for a process
Func __GwNexus_GetModuleInfo($hKernel, $hProc, $iPID, ByRef $iModuleBase, ByRef $iModuleSize)
    Local $aModules = _WinAPI_EnumProcessModules($iPID)
    If @error Or Not IsArray($aModules) Then Return False

    Local $sProcName = _WinAPI_GetProcessName($iPID)
    Local $iProcNameLen = StringLen($sProcName)

    For $i = 1 To $aModules[0][0]
        Local $sModName = StringRight($aModules[$i][1], $iProcNameLen)
        If StringCompare($sModName, $sProcName, 0) = 0 Then
            Local $tModInfo = _WinAPI_GetModuleInformation($hProc, $aModules[$i][0])
            If @error Then Return False
            $iModuleBase = DllStructGetData($tModInfo, "BaseOfDll")
            $iModuleSize = DllStructGetData($tModInfo, "SizeOfImage")
            Return True
        EndIf
    Next
    Return False
EndFunc

; Internal: Scan for character name address
Func __GwNexus_ScanForCharname($hKernel, $hProc, $iModuleBase, $iModuleSize, $sCharNameCode)
    Local $iCurrentAddr = $iModuleBase
    Local $tMBI = DllStructCreate("ptr;ptr;dword;ulong_ptr;dword;dword;dword")

    While $iCurrentAddr < $iModuleBase + $iModuleSize
        DllCall($hKernel, "ulong_ptr", "VirtualQueryEx", _
            "handle", $hProc, _
            "ptr", $iCurrentAddr, _
            "struct*", $tMBI, _
            "ulong_ptr", DllStructGetSize($tMBI))

        Local $iRegionSize = DllStructGetData($tMBI, 4)
        Local $iState = DllStructGetData($tMBI, 5)

        If $iState = 0x1000 Then  ; MEM_COMMIT
            Local $tBuffer = DllStructCreate("byte[" & $iRegionSize & "]")
            Local $aRead = DllCall($hKernel, "bool", "ReadProcessMemory", _
                "handle", $hProc, _
                "ptr", $iCurrentAddr, _
                "struct*", $tBuffer, _
                "ulong_ptr", $iRegionSize, _
                "ulong_ptr*", 0)

            If Not @error And $aRead[0] Then
                Local $sMemData = BinaryToString(DllStructGetData($tBuffer, 1))
                Local $iSearch = StringInStr($sMemData, $sCharNameCode, 2)

                If $iSearch > 0 Then
                    Local $iTmpAddr = $iCurrentAddr + $iSearch - 1
                    Local $tPtr = DllStructCreate("ptr")
                    DllCall($hKernel, "bool", "ReadProcessMemory", _
                        "handle", $hProc, _
                        "ptr", $iTmpAddr - 0x42, _
                        "struct*", $tPtr, _
                        "ulong_ptr", DllStructGetSize($tPtr), _
                        "ulong_ptr*", 0)
                    Return DllStructGetData($tPtr, 1) - $iModuleBase
                EndIf
            EndIf
        EndIf

        $iCurrentAddr += $iRegionSize
        If $iRegionSize = 0 Then ExitLoop
    WEnd

    Return 0
EndFunc

; Scan all GW clients and return character names with injection status
; Returns: 2D array [n][3] where [i][0] = char name, [i][1] = PID, [i][2] = injected (bool)
Func _GwNexus_ScanAllClients()
    Local $aClients[0][3]

    ; Get all GW windows
    Local $aWinList = WinList("[CLASS:ArenaNet_Dx_Window_Class]")
    If $aWinList[0][0] = 0 Then Return $aClients

    Local $hKernel = DllOpen("kernel32.dll")
    If $hKernel = -1 Then Return $aClients

    Local $iCharNameRva = 0  ; Will be found once and reused

    For $i = 1 To $aWinList[0][0]
        Local $iPID = WinGetProcess($aWinList[$i][1])
        If $iPID = 0 Then ContinueLoop

        ; Open process
        Local $aOpen = DllCall($hKernel, "handle", "OpenProcess", "dword", 0x1F0FFF, "bool", False, "dword", $iPID)
        If @error Or $aOpen[0] = 0 Then ContinueLoop
        Local $hProc = $aOpen[0]

        ; Get module info
        Local $iModuleBase = 0, $iModuleSize = 0
        If Not __GwNexus_GetModuleInfo($hKernel, $hProc, $iPID, $iModuleBase, $iModuleSize) Then
            DllCall($hKernel, "bool", "CloseHandle", "handle", $hProc)
            ContinueLoop
        EndIf

        ; Find character name RVA (scan only once, reuse for all)
        If $iCharNameRva = 0 Then
            $iCharNameRva = __GwNexus_ScanForCharname($hKernel, $hProc, $iModuleBase, $iModuleSize, BinaryToString("0x8BF86A03680F0000C08BCFE8"))
        EndIf

        If $iCharNameRva <> 0 Then
            ; Read character name
            Local $tName = DllStructCreate("wchar[30]")
            Local $aRead = DllCall($hKernel, "bool", "ReadProcessMemory", _
                "handle", $hProc, _
                "ptr", $iModuleBase + $iCharNameRva, _
                "struct*", $tName, _
                "ulong_ptr", DllStructGetSize($tName), _
                "ulong_ptr*", 0)

            If Not @error And $aRead[0] Then
                Local $sCharName = DllStructGetData($tName, 1)
                If $sCharName <> "" Then
                    ; Check if pipe exists (DLL injected)
                    Local $sPipeName = "\\.\pipe\GwNexus_" & StringReplace($sCharName, " ", "_")
                    Local $aWait = DllCall($hKernel, "bool", "WaitNamedPipeW", "wstr", $sPipeName, "dword", 100)
                    Local $bInjected = (Not @error And $aWait[0] <> 0)

                    ; Add to list
                    Local $iSize = UBound($aClients)
                    ReDim $aClients[$iSize + 1][3]
                    $aClients[$iSize][0] = $sCharName
                    $aClients[$iSize][1] = $iPID
                    $aClients[$iSize][2] = $bInjected
                EndIf
            EndIf
        EndIf

        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProc)
    Next

    DllClose($hKernel)
    Return $aClients
EndFunc

; Create connection by character name
; Returns: Connection array on success, 0 on failure
Func _GwNexus_CreateConnectionByName($sCharName, $iPID = 0)
    ; Replace spaces with underscores for pipe name
    Local $sPipeNameChar = "\\.\pipe\GwNexus_" & StringReplace($sCharName, " ", "_")
    Local $sPipeNamePID = "\\.\pipe\GwNexus_" & $iPID
    Local $sPipeName = ""

    ; Try character name pipe first
    Local $aWait = DllCall("kernel32.dll", "bool", "WaitNamedPipeW", _
        "wstr", $sPipeNameChar, _
        "dword", 2000) ; 2 second timeout

    If Not @error And $aWait[0] <> 0 Then
        $sPipeName = $sPipeNameChar
    Else
        ; Try PID-based pipe as fallback (release mode DLL uses this if character name not found)
        If $iPID > 0 Then
            $aWait = DllCall("kernel32.dll", "bool", "WaitNamedPipeW", _
                "wstr", $sPipeNamePID, _
                "dword", 3000) ; 3 second timeout

            If Not @error And $aWait[0] <> 0 Then
                $sPipeName = $sPipeNamePID
            EndIf
        EndIf
    EndIf

    If $sPipeName = "" Then
        Return SetError(1, 0, 0) ; Pipe not available
    EndIf

    ; Try to connect to the pipe
    Local $aResult = DllCall("kernel32.dll", "handle", "CreateFileW", _
        "wstr", $sPipeName, _
        "dword", 0xC0000000, _ ; GENERIC_READ | GENERIC_WRITE
        "dword", 0, _          ; No sharing
        "ptr", 0, _            ; Default security
        "dword", 3, _          ; OPEN_EXISTING
        "dword", 0x40000000, _ ; FILE_FLAG_OVERLAPPED
        "ptr", 0)              ; No template

    If @error Or $aResult[0] = -1 Or $aResult[0] = 0 Then
        Return SetError(2, _WinAPI_GetLastError(), 0) ; Failed to open pipe
    EndIf

    Local $hPipe = $aResult[0]

    ; Set pipe to message mode
    Local $iMode = 2 ; PIPE_READMODE_MESSAGE
    Local $aSetMode = DllCall("kernel32.dll", "bool", "SetNamedPipeHandleState", _
        "handle", $hPipe, _
        "dword*", $iMode, _
        "ptr", 0, _
        "ptr", 0)

    If @error Or $aSetMode[0] = 0 Then
        _WinAPI_CloseHandle($hPipe)
        Return SetError(3, 0, 0) ; Failed to set mode
    EndIf

    $g_iGwNexusConnectionCounter += 1

    ; Create connection object
    Local $aConnection[4]
    $aConnection[$CONN_HANDLE] = $hPipe
    $aConnection[$CONN_PID] = $iPID  ; PID passed as parameter (required for proper cache keying)
    $aConnection[$CONN_PIPENAME] = $sPipeName
    $aConnection[$CONN_ID] = $g_iGwNexusConnectionCounter

    Return $aConnection
EndFunc

; ============================================================================
; Multi-Connection Extended Functions (Ex versions)
; These functions work with specific connection objects
; ============================================================================

; Scanner functions with connection parameter (with caching per PID)
Func _GwNexus_ScanFindEx($aConnection, $sPattern, $iOffset = 0, $iSection = $SECTION_TEXT)
    ; Cache key includes PID since different processes may have different addresses
    If $g_bCacheEnabled And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "SFX:" & $iPID & ":" & $sPattern & ":" & $iOffset & ":" & $iSection
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $sMask = _GwNexus_CreateMaskFromPattern($sPattern)
    Local $tRequest = _GwNexus_CreateScanRequest($sPattern, $sMask, $iOffset, $iSection)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "SFX:" & $iPID & ":" & $sPattern & ":" & $iOffset & ":" & $iSection
        If Not $g_dicScanCache.Exists($sCacheKey) Then
            $g_dicScanCache.Add($sCacheKey, $iResult)
        EndIf
    EndIf

    Return $iResult
EndFunc

Func _GwNexus_ScanFindAssertionEx($aConnection, $sFile, $sMessage, $iLine = 0, $iOffset = 0)
    ; Cache key includes PID
    If $g_bCacheEnabled And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "SAX:" & $iPID & ":" & $sFile & ":" & $sMessage & ":" & $iLine & ":" & $iOffset
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $tRequest = _GwNexus_CreateAssertionRequest($sFile, $sMessage, $iLine, $iOffset)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "SAX:" & $iPID & ":" & $sFile & ":" & $sMessage & ":" & $iLine & ":" & $iOffset
        If Not $g_dicScanCache.Exists($sCacheKey) Then
            $g_dicScanCache.Add($sCacheKey, $iResult)
        EndIf
    EndIf

    Return $iResult
EndFunc

Func _GwNexus_ScanFunctionFromNearCallEx($aConnection, $iAddress)
    ; Cache key includes PID
    If $g_bCacheEnabled And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "NCX:" & $iPID & ":" & Hex($iAddress)
        If $g_dicScanCache.Exists($sCacheKey) Then
            Return $g_dicScanCache.Item($sCacheKey)
        EndIf
    EndIf

    Local $tRequest = _GwNexus_CreateFunctionFromNearCallRequest($iAddress)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $iResult = _GwNexus_ParseScanResponse($tResponse)

    ; Cache the result
    If $g_bCacheEnabled And $iResult <> 0 And _GwNexus_IsConnectionValid($aConnection) Then
        Local $iPID = _GwNexus_GetConnectionPID($aConnection)
        Local $sCacheKey = "NCX:" & $iPID & ":" & Hex($iAddress)
        If Not $g_dicScanCache.Exists($sCacheKey) Then
            $g_dicScanCache.Add($sCacheKey, $iResult)
        EndIf
    EndIf

    Return $iResult
EndFunc

; Function registry with connection parameter
Func _GwNexus_RegisterFunctionEx($aConnection, $sName, $iAddress, $iParamCount, $iConvention = $CONV_STDCALL, $bHasReturn = True)
    Local $tRequest = _GwNexus_CreateRegisterFunctionRequest($sName, $iAddress, $iParamCount, $iConvention, $bHasReturn)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

Func _GwNexus_UnregisterFunctionEx($aConnection, $sName)
    Local $tRequest = _GwNexus_CreateUnregisterFunctionRequest($sName)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

Func _GwNexus_CallFunctionEx($aConnection, $sName, $aParams = Null)
    Local $tRequest = _GwNexus_CreateCallFunctionRequest($sName, $aParams)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseCallResponse($tResponse)
EndFunc

Func _GwNexus_ListFunctionsEx($aConnection)
    Local $tRequest = _GwNexus_CreateListFunctionsRequest()

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseFunctionListResponse($tResponse)
EndFunc

; Memory operations with connection parameter
Func _GwNexus_ReadMemoryEx($aConnection, $iAddress, $iSize)
    If $iSize > 1024 Then $iSize = 1024

    Local $tRequest = _GwNexus_CreateReadMemoryRequest($iAddress, $iSize)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Return _GwNexus_ParseMemoryResponse($tResponse)
EndFunc

Func _GwNexus_ReadMemoryValueEx($aConnection, $iAddress, $sType = "dword")
    Local $iSize
    Switch $sType
        Case "byte"
            $iSize = 1
        Case "word", "short"
            $iSize = 2
        Case "dword", "int", "float"
            $iSize = 4
        Case "int64", "double", "ptr"
            $iSize = 8
        Case Else
            $iSize = 4
    EndSwitch

    Local $aResult = _GwNexus_ReadMemoryEx($aConnection, $iAddress, $iSize)
    If @error Then Return SetError(@error, 0, 0)

    Local $tValue = DllStructCreate($sType, DllStructGetPtr($aResult[2]))
    Return DllStructGetData($tValue, 1)
EndFunc

Func _GwNexus_WriteMemoryEx($aConnection, $iAddress, $tData, $iSize)
    If $iSize > 1024 Then Return SetError(1, 0, False)

    Local $tRequest = _GwNexus_CreateWriteMemoryRequest($iAddress, $tData, $iSize)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

Func _GwNexus_WriteMemoryValueEx($aConnection, $iAddress, $vValue, $sType = "dword")
    Local $tData = DllStructCreate($sType)
    DllStructSetData($tData, 1, $vValue)

    Return _GwNexus_WriteMemoryEx($aConnection, $iAddress, $tData, DllStructGetSize($tData))
EndFunc

; Pointer chain with connection parameter
Func _GwNexus_ReadPointerChainEx($aConnection, $iBaseAddress, $aOffsets, $iFinalSize = 4)
    Local $tRequest = _GwNexus_CreatePointerChainRequest($iBaseAddress, $aOffsets, $iFinalSize)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "ptr final_address;" & _
        "uint64 value", _
        DllStructGetPtr($tResponse))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iValue = DllStructGetData($tResult, "value")

    Switch $iFinalSize
        Case 1
            Return BitAND($iValue, 0xFF)
        Case 2
            Return BitAND($iValue, 0xFFFF)
        Case 4
            Return BitAND($iValue, 0xFFFFFFFF)
        Case 8
            Return $iValue
        Case Else
            Return BitAND($iValue, 0xFFFFFFFF)
    EndSwitch
EndFunc

; Memory allocation with connection parameter
Func _GwNexus_AllocateMemoryEx($aConnection, $iSize, $iProtection = 0x40)
    Local $tRequest = _GwNexus_CreateAllocateMemoryRequest($iSize, $iProtection)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $aResult = _GwNexus_ParseMemoryResponse($tResponse)
    If @error Then Return SetError(@error, 0, 0)

    Return $aResult[0]
EndFunc

Func _GwNexus_FreeMemoryEx($aConnection, $iAddress)
    Local $tRequest = _GwNexus_CreateFreeMemoryRequest($iAddress)

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, False)

    Local $tResult = DllStructCreate("byte success", DllStructGetPtr($tResponse))
    Return DllStructGetData($tResult, "success") = 1
EndFunc

; Server/DLL control with connection parameter
Func _GwNexus_GetServerStatusEx($aConnection)
    Local $tRequest = _GwNexus_CreateServerStatusRequest()

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte union_data[1284];" & _
        "int status;" & _
        "uint client_count;" & _
        "uint64 uptime_ms;" & _
        "char pipe_name[256]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aStatus[4]
    $aStatus[0] = DllStructGetData($tResult, "status")
    $aStatus[1] = DllStructGetData($tResult, "client_count")
    $aStatus[2] = DllStructGetData($tResult, "uptime_ms")
    $aStatus[3] = DllStructGetData($tResult, "pipe_name")

    Return $aStatus
EndFunc

Func _GwNexus_GetDLLStatusEx($aConnection)
    Local $tRequest = _GwNexus_CreateDLLStatusRequest()

    Local $tResponse = _GwNexus_SendRequestEx($aConnection, $tRequest)
    If @error Then Return SetError(@error, 0, 0)

    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte union_data[1284];" & _
        "byte server_status[272];" & _
        "int status;" & _
        "uint version;" & _
        "char build_info[256]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aStatus[3]
    $aStatus[0] = DllStructGetData($tResult, "status")
    $aStatus[1] = DllStructGetData($tResult, "version")
    $aStatus[2] = DllStructGetData($tResult, "build_info")

    Return $aStatus
EndFunc
