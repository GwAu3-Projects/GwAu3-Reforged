#include-once
#include "GwNexusClient.au3"

; ============================================================================
; GwNexusFunctions.au3
; Guild Wars game functions wrapper for AutoIt
; ============================================================================

; ============================================================================
; MoveTo Function
; ============================================================================

; Pattern to find MoveTo function
; Original: "\x83\xc4\x0c\x85\xff\x74\x0b\x56\x6a\x03" with offset -5, then FunctionFromNearCall
Global Const $MOVETO_PATTERN = "83 C4 0C 85 FF 74 0B 56 6A 03"
Global Const $MOVETO_OFFSET = -5

; Cached MoveTo address
Global $g_iMoveToAddr = 0

; Initialize MoveTo function
; Returns: Address of MoveTo function or 0 on failure
Func _GwNexus_InitMoveTo()
    If $g_iMoveToAddr <> 0 Then
        Return $g_iMoveToAddr ; Already initialized
    EndIf

    ; Step 1: Find the pattern
    ; Pattern: 83 C4 0C 85 FF 74 0B 56 6A 03
    ; Offset: -5 (points to the CALL instruction before the pattern)
    Local $iPatternAddr = _GwNexus_ScanFind($MOVETO_PATTERN, $MOVETO_OFFSET)
    If @error Or $iPatternAddr = 0 Then
        ConsoleWrite("[ERROR] MoveTo pattern not found" & @CRLF)
        Return SetError(1, 0, 0)
    EndIf

    ConsoleWrite("[DEBUG] MoveTo near call at: 0x" & Hex($iPatternAddr) & @CRLF)

    ; Step 2: Use the DLL's FunctionFromNearCall to resolve the target
    $g_iMoveToAddr = _GwNexus_ScanFunctionFromNearCall($iPatternAddr)
    If @error Or $g_iMoveToAddr = 0 Then
        ConsoleWrite("[ERROR] Failed to resolve MoveTo function from near call" & @CRLF)
        Return SetError(2, 0, 0)
    EndIf

    ConsoleWrite("[DEBUG] MoveTo function at: 0x" & Hex($g_iMoveToAddr) & @CRLF)

    ; Step 3: Register the function with RPC Bridge
    ; MoveTo signature: void MoveTo(float* pos) - CDECL, 1 param (pointer), no return
    If Not _GwNexus_RegisterFunction("MoveTo", $g_iMoveToAddr, 1, $CONV_CDECL, False) Then
        ConsoleWrite("[ERROR] Failed to register MoveTo function" & @CRLF)
        Return SetError(3, 0, 0)
    EndIf

    ConsoleWrite("[OK] MoveTo function registered at: 0x" & Hex($g_iMoveToAddr) & @CRLF)
    Return $g_iMoveToAddr
EndFunc

; Move to a position
; $fX, $fY = coordinates
; $iZPlane = z-plane (default 0)
; Returns: True on success
Func _GwNexus_MoveTo($fX, $fY, $iZPlane = 0)
    ; Initialize if needed
    If $g_iMoveToAddr = 0 Then
        If _GwNexus_InitMoveTo() = 0 Then
            Return SetError(1, 0, False)
        EndIf
    EndIf

    ; Allocate memory for the float array (4 floats = 16 bytes)
    Local $iBuffer = _GwNexus_AllocateMemory(16)
    If @error Or $iBuffer = 0 Then
        ConsoleWrite("[ERROR] Failed to allocate memory for MoveTo" & @CRLF)
        Return SetError(2, 0, False)
    EndIf

    ; Create the float array: {x, y, zplane, 0}
    Local $tFloats = DllStructCreate("float[4]")
    DllStructSetData($tFloats, 1, $fX, 1)      ; X
    DllStructSetData($tFloats, 1, $fY, 2)      ; Y
    DllStructSetData($tFloats, 1, $iZPlane, 3) ; ZPlane
    DllStructSetData($tFloats, 1, 0.0, 4)      ; Unknown (always 0)

    ; Write the float array to allocated memory
    If Not _GwNexus_WriteMemory($iBuffer, $tFloats, 16) Then
        ConsoleWrite("[ERROR] Failed to write float array" & @CRLF)
        _GwNexus_FreeMemory($iBuffer)
        Return SetError(3, 0, False)
    EndIf

    ; Call MoveTo with the pointer to our float array
    Local $aParams[1][2]
    $aParams[0][0] = $PARAM_POINTER
    $aParams[0][1] = $iBuffer

    _GwNexus_CallFunction("MoveTo", $aParams)
    Local $iError = @error

    ; Free the allocated memory
    _GwNexus_FreeMemory($iBuffer)

    If $iError Then
        ConsoleWrite("[ERROR] MoveTo call failed" & @CRLF)
        Return SetError(4, 0, False)
    EndIf

    Return True
EndFunc

; ============================================================================
; Helper: Get current player position (if needed later)
; ============================================================================

; TODO: Add GetPlayerPos function when needed
; Pattern and implementation similar to MoveTo

; ============================================================================
; Cleanup
; ============================================================================

Func _GwNexus_CleanupFunctions()
    If $g_iMoveToAddr <> 0 Then
        _GwNexus_UnregisterFunction("MoveTo")
        $g_iMoveToAddr = 0
    EndIf
EndFunc
