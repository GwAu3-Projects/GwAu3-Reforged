#include-once
; ============================================================================
; GwNexusProtocol.au3
; Protocol definitions for GwNexus Named Pipe communication
; ============================================================================

; Request Types
Global Enum _
    $CYCRIPT_CYCRIPT = 0, _
    $REQUEST_SCAN_FIND = 1, _
    $REQUEST_SCAN_FIND_ASSERTION = 2, _
    $REQUEST_SCAN_FIND_IN_RANGE = 3, _
    $REQUEST_SCAN_TO_FUNCTION_START = 4, _
    $REQUEST_SCAN_FUNCTION_FROM_NEAR_CALL = 5, _
    $REQUEST_READ_MEMORY = 6, _
    $REQUEST_GET_SECTION_INFO = 7, _
    $REQUEST_READ_POINTER_CHAIN = 8, _
    $REQUEST_REGISTER_FUNCTION = 10, _
    $REQUEST_UNREGISTER_FUNCTION = 11, _
    $REQUEST_CALL_FUNCTION = 12, _
    $REQUEST_LIST_FUNCTIONS = 13, _
    $REQUEST_ALLOCATE_MEMORY = 20, _
    $REQUEST_FREE_MEMORY = 21, _
    $REQUEST_WRITE_MEMORY = 22, _
    $REQUEST_PROTECT_MEMORY = 23, _
    $REQUEST_INSTALL_HOOK = 30, _
    $REQUEST_REMOVE_HOOK = 31, _
    $REQUEST_ENABLE_HOOK = 32, _
    $REQUEST_DISABLE_HOOK = 33, _
    $REQUEST_GET_PENDING_EVENTS = 40, _
    $REQUEST_REGISTER_EVENT_BUFFER = 41, _
    $REQUEST_UNREGISTER_EVENT_BUFFER = 42, _
    $REQUEST_READ_MEMORY_ARRAY = 45, _
    $REQUEST_BATCH_REQUEST = 48, _
    $REQUEST_BATCH_READ_MEMORY = 49, _
    $REQUEST_SERVER_STATUS = 50, _
    $REQUEST_SERVER_STOP = 51, _
    $REQUEST_SERVER_START = 52, _
    $REQUEST_SERVER_RESTART = 53, _
    $REQUEST_DLL_DETACH = 60, _
    $REQUEST_DLL_STATUS = 61, _
    $REQUEST_HEARTBEAT = 100

; Parameter Types
Global Enum _
    $PARAM_INT8 = 1, _
    $PARAM_INT16 = 2, _
    $PARAM_INT32 = 3, _
    $PARAM_INT64 = 4, _
    $PARAM_FLOAT = 5, _
    $PARAM_DOUBLE = 6, _
    $PARAM_POINTER = 7, _
    $PARAM_STRING = 8, _
    $PARAM_WSTRING = 9

; Calling Conventions
Global Enum _
    $CONV_CDECL = 1, _
    $CONV_STDCALL = 2, _
    $CONV_FASTCALL = 3, _
    $CONV_THISCALL = 4

; Scanner Sections
Global Enum _
    $SECTION_TEXT = 0, _
    $SECTION_RDATA = 1, _
    $SECTION_DATA = 2

; Structure sizes (packed, 1-byte alignment)
Global Const $SIZE_FUNCTION_PARAM = 260        ; 1 + 3 padding + 256 union (string_val[256])
Global Const $SIZE_PIPE_REQUEST = 2644         ; Max size of request
Global Const $SIZE_PIPE_RESPONSE = 2576        ; Max size of response

; ============================================================================
; Structure Creation Functions
; ============================================================================

; Create a scan request structure
Func _GwNexus_CreateScanRequest($sPattern, $sMask, $iOffset = 0, $iSection = $SECTION_TEXT)
    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes - RequestType
        "byte pattern[256];" & _                ; 256 bytes
        "char mask[256];" & _                   ; 256 bytes
        "int offset;" & _                       ; 4 bytes
        "byte section;" & _                     ; 1 byte
        "byte pattern_length;" & _              ; 1 byte
        "byte padding[2]" _                     ; 2 bytes padding
    )

    DllStructSetData($tRequest, "type", $REQUEST_SCAN_FIND)
    DllStructSetData($tRequest, "offset", $iOffset)
    DllStructSetData($tRequest, "section", $iSection)

    ; Parse hex pattern string to bytes
    Local $aBytes = _GwNexus_HexStringToBytes($sPattern)
    If @error Then Return SetError(1, 0, 0)

    DllStructSetData($tRequest, "pattern_length", UBound($aBytes))

    For $i = 0 To UBound($aBytes) - 1
        DllStructSetData($tRequest, "pattern", $aBytes[$i], $i + 1)
    Next

    DllStructSetData($tRequest, "mask", $sMask)

    Return $tRequest
EndFunc

; Create an assertion scan request
Func _GwNexus_CreateAssertionRequest($sFile, $sMessage, $iLine = 0, $iOffset = 0)
    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes
        "char assertion_file[256];" & _         ; 256 bytes
        "char assertion_msg[256];" & _          ; 256 bytes
        "uint line_number;" & _                 ; 4 bytes
        "int offset" _                          ; 4 bytes
    )

    DllStructSetData($tRequest, "type", $REQUEST_SCAN_FIND_ASSERTION)
    DllStructSetData($tRequest, "assertion_file", $sFile)
    DllStructSetData($tRequest, "assertion_msg", $sMessage)
    DllStructSetData($tRequest, "line_number", $iLine)
    DllStructSetData($tRequest, "offset", $iOffset)

    Return $tRequest
EndFunc

; Create a pointer chain read request
; $iBaseAddress = Starting address (e.g., base_ptr address)
; $aOffsets = Array of offsets to follow (max 16)
; $iFinalSize = Size of final value to read (1, 2, 4, or 8 bytes)
Func _GwNexus_CreatePointerChainRequest($iBaseAddress, $aOffsets, $iFinalSize = 4)
    Local $iOffsetCount = UBound($aOffsets)
    If $iOffsetCount > 16 Then $iOffsetCount = 16

    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes - RequestType
        "ptr base_address;" & _                 ; 4 bytes - Base address
        "byte offset_count;" & _                ; 1 byte
        "byte final_size;" & _                  ; 1 byte
        "byte padding[2];" & _                  ; 2 bytes
        "int offsets[16]" _                     ; 64 bytes - Max 16 offsets
    )

    DllStructSetData($tRequest, "type", $REQUEST_READ_POINTER_CHAIN)
    DllStructSetData($tRequest, "base_address", $iBaseAddress)
    DllStructSetData($tRequest, "offset_count", $iOffsetCount)
    DllStructSetData($tRequest, "final_size", $iFinalSize)

    ; Fill offsets array
    For $i = 0 To $iOffsetCount - 1
        DllStructSetData($tRequest, "offsets", $aOffsets[$i], $i + 1)
    Next

    Return $tRequest
EndFunc

; Create a register function request
Func _GwNexus_CreateRegisterFunctionRequest($sName, $iAddress, $iParamCount, $iConvention = $CONV_STDCALL, $bHasReturn = True)
    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes
        "char name[64];" & _                    ; 64 bytes
        "ptr address;" & _                      ; 4/8 bytes (pointer)
        "byte param_count;" & _                 ; 1 byte
        "byte convention;" & _                  ; 1 byte
        "byte has_return;" & _                  ; 1 byte
        "byte padding[1]" _                     ; 1 byte
    )

    DllStructSetData($tRequest, "type", $REQUEST_REGISTER_FUNCTION)
    DllStructSetData($tRequest, "name", $sName)
    DllStructSetData($tRequest, "address", $iAddress)
    DllStructSetData($tRequest, "param_count", $iParamCount)
    DllStructSetData($tRequest, "convention", $iConvention)
    DllStructSetData($tRequest, "has_return", $bHasReturn ? 1 : 0)

    Return $tRequest
EndFunc

; Create a call function request
Func _GwNexus_CreateCallFunctionRequest($sName, $aParams = Null)
    ; Calculate structure size based on params
    Local $iParamCount = 0
    If IsArray($aParams) Then $iParamCount = UBound($aParams)

    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes
        "char name[64];" & _                    ; 64 bytes
        "byte param_count;" & _                 ; 1 byte
        "byte padding[3];" & _                  ; 3 bytes
        "byte params[" & ($iParamCount * $SIZE_FUNCTION_PARAM) & "]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_CALL_FUNCTION)
    DllStructSetData($tRequest, "name", $sName)
    DllStructSetData($tRequest, "param_count", $iParamCount)

    ; Fill parameters if provided
    If $iParamCount > 0 Then
        For $i = 0 To $iParamCount - 1
            _GwNexus_SetFunctionParam($tRequest, $i, $aParams[$i][0], $aParams[$i][1])
        Next
    EndIf

    Return $tRequest
EndFunc

; Set a function parameter in a call request
Func _GwNexus_SetFunctionParam(ByRef $tRequest, $iIndex, $iType, $vValue)
    Local $iOffset = 72 + ($iIndex * $SIZE_FUNCTION_PARAM) ; 4 + 64 + 1 + 3 = 72

    ; Create param structure at offset
    Local $tParam = DllStructCreate( _
        "byte type;" & _
        "byte padding[3];" & _
        "byte value[256]", _
        DllStructGetPtr($tRequest) + $iOffset)

    DllStructSetData($tParam, "type", $iType)

    Switch $iType
        Case $PARAM_INT8
            Local $tVal = DllStructCreate("byte", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_INT16
            Local $tVal = DllStructCreate("short", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_INT32
            Local $tVal = DllStructCreate("int", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_INT64
            Local $tVal = DllStructCreate("int64", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_FLOAT
            Local $tVal = DllStructCreate("float", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_DOUBLE
            Local $tVal = DllStructCreate("double", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_POINTER
            Local $tVal = DllStructCreate("ptr", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_STRING
            Local $tVal = DllStructCreate("char[256]", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)

        Case $PARAM_WSTRING
            Local $tVal = DllStructCreate("wchar[128]", DllStructGetPtr($tParam, "value"))
            DllStructSetData($tVal, 1, $vValue)
    EndSwitch
EndFunc

; Create a memory read request
Func _GwNexus_CreateReadMemoryRequest($iAddress, $iSize)
    Local $tRequest = DllStructCreate( _
        "int type;" & _                         ; 4 bytes
        "ptr address;" & _                      ; 4/8 bytes
        "uint size;" & _                        ; 4 bytes
        "uint protection;" & _                  ; 4 bytes
        "byte data[1024]" _                     ; 1024 bytes
    )

    DllStructSetData($tRequest, "type", $REQUEST_READ_MEMORY)
    DllStructSetData($tRequest, "address", $iAddress)
    DllStructSetData($tRequest, "size", $iSize)

    Return $tRequest
EndFunc

; Create a memory write request
Func _GwNexus_CreateWriteMemoryRequest($iAddress, $tData, $iSize)
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "uint size;" & _
        "uint protection;" & _
        "byte data[1024]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_WRITE_MEMORY)
    DllStructSetData($tRequest, "address", $iAddress)
    DllStructSetData($tRequest, "size", $iSize)

    ; Copy data bytes
    Local $pSrc = DllStructGetPtr($tData)
    Local $pDst = DllStructGetPtr($tRequest, "data")
    DllCall("kernel32.dll", "none", "RtlMoveMemory", "ptr", $pDst, "ptr", $pSrc, "ulong_ptr", $iSize)

    Return $tRequest
EndFunc

; Create an allocate memory request
Func _GwNexus_CreateAllocateMemoryRequest($iSize, $iProtection = 0x40) ; PAGE_EXECUTE_READWRITE
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "uint size;" & _
        "uint protection;" & _
        "byte data[1024]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_ALLOCATE_MEMORY)
    DllStructSetData($tRequest, "size", $iSize)
    DllStructSetData($tRequest, "protection", $iProtection)

    Return $tRequest
EndFunc

; Create a free memory request
Func _GwNexus_CreateFreeMemoryRequest($iAddress)
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "uint size;" & _
        "uint protection;" & _
        "byte data[1024]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_FREE_MEMORY)
    DllStructSetData($tRequest, "address", $iAddress)

    Return $tRequest
EndFunc

; Create function from near call request
Func _GwNexus_CreateFunctionFromNearCallRequest($iAddress)
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "ptr address;" & _
        "uint size;" & _
        "uint protection;" & _
        "byte data[1024]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_SCAN_FUNCTION_FROM_NEAR_CALL)
    DllStructSetData($tRequest, "address", $iAddress)

    Return $tRequest
EndFunc

; Create server status request
Func _GwNexus_CreateServerStatusRequest()
    Local $tRequest = DllStructCreate("int type")
    DllStructSetData($tRequest, "type", $REQUEST_SERVER_STATUS)
    Return $tRequest
EndFunc

; Create DLL status request
Func _GwNexus_CreateDLLStatusRequest()
    Local $tRequest = DllStructCreate("int type")
    DllStructSetData($tRequest, "type", $REQUEST_DLL_STATUS)
    Return $tRequest
EndFunc

; Create DLL detach request (eject DLL from target process)
Func _GwNexus_CreateDLLDetachRequest()
    Local $tRequest = DllStructCreate("int type")
    DllStructSetData($tRequest, "type", $REQUEST_DLL_DETACH)
    Return $tRequest
EndFunc

; Create list functions request
Func _GwNexus_CreateListFunctionsRequest()
    Local $tRequest = DllStructCreate("int type")
    DllStructSetData($tRequest, "type", $REQUEST_LIST_FUNCTIONS)
    Return $tRequest
EndFunc

; Create unregister function request
Func _GwNexus_CreateUnregisterFunctionRequest($sName)
    Local $tRequest = DllStructCreate( _
        "int type;" & _
        "char name[64]" _
    )

    DllStructSetData($tRequest, "type", $REQUEST_UNREGISTER_FUNCTION)
    DllStructSetData($tRequest, "name", $sName)

    Return $tRequest
EndFunc

; ============================================================================
; Response Parsing Functions
; ============================================================================

; Parse scan response
Func _GwNexus_ParseScanResponse($tResponse)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "ptr address" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Return DllStructGetData($tResult, "address")
EndFunc

; Parse call result response
Func _GwNexus_ParseCallResponse($tResponse)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte has_return;" & _
        "byte padding2[3];" & _
        "ptr return_value" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    If DllStructGetData($tResult, "has_return") = 0 Then
        Return SetError(0, 0, Null)
    EndIf

    Return DllStructGetData($tResult, "return_value")
EndFunc

; Parse memory response
Func _GwNexus_ParseMemoryResponse($tResponse)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "ptr address;" & _
        "uint size;" & _
        "byte data[1024]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $aResult[3]
    $aResult[0] = DllStructGetData($tResult, "address")
    $aResult[1] = DllStructGetData($tResult, "size")
    $aResult[2] = DllStructCreate("byte[" & $aResult[1] & "]", DllStructGetPtr($tResult, "data"))

    Return $aResult
EndFunc

; Parse function list response
Func _GwNexus_ParseFunctionListResponse($tResponse)
    Local $tResult = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "uint count;" & _
        "char names[1280]" _  ; 20 * 64
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tResult), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tResult))

    If DllStructGetData($tResult, "success") = 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iCount = DllStructGetData($tResult, "count")
    Local $aFunctions[$iCount]

    For $i = 0 To $iCount - 1
        Local $tName = DllStructCreate("char[64]", DllStructGetPtr($tResult, "names") + ($i * 64))
        $aFunctions[$i] = DllStructGetData($tName, 1)
    Next

    Return $aFunctions
EndFunc

; Get error message from response
Func _GwNexus_GetErrorMessage($tResponse)
    ; Error message is at offset after the union (approximately)
    Local $tError = DllStructCreate( _
        "byte success;" & _
        "byte padding[3];" & _
        "byte skip[1036];" & _  ; Skip union data
        "char error[256]" _
    )

    DllCall("kernel32.dll", "none", "RtlMoveMemory", _
        "ptr", DllStructGetPtr($tError), _
        "ptr", DllStructGetPtr($tResponse), _
        "ulong_ptr", DllStructGetSize($tError))

    Return DllStructGetData($tError, "error")
EndFunc

; ============================================================================
; Helper Functions
; ============================================================================

; Convert hex string to byte array
; Input: "55 8B EC" or "558BEC" or "55 8B EC ?? 83"
Func _GwNexus_HexStringToBytes($sHex)
    ; Remove spaces
    $sHex = StringReplace($sHex, " ", "")

    If Mod(StringLen($sHex), 2) <> 0 Then
        Return SetError(1, 0, 0)
    EndIf

    Local $iLen = StringLen($sHex) / 2
    Local $aBytes[$iLen]

    For $i = 0 To $iLen - 1
        Local $sByte = StringMid($sHex, ($i * 2) + 1, 2)
        If $sByte = "??" Then
            $aBytes[$i] = 0x00 ; Wildcard byte
        Else
            $aBytes[$i] = Dec($sByte)
        EndIf
    Next

    Return $aBytes
EndFunc

; Create mask from pattern (? = wildcard)
; Input: "55 8B EC ?? 83" -> "xxx?x"
Func _GwNexus_CreateMaskFromPattern($sPattern)
    Local $sMask = ""
    Local $aBytes = StringSplit(StringStripWS($sPattern, 7), " ", 2)

    For $i = 0 To UBound($aBytes) - 1
        If StringInStr($aBytes[$i], "?") Then
            $sMask &= "?"
        Else
            $sMask &= "x"
        EndIf
    Next

    Return $sMask
EndFunc
