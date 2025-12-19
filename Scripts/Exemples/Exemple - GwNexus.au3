#include "../../API/_GwAu3.au3"

; ============================================================================
; GwNexusGUI.au3
; Complete GUI interface for GwNexus functions
; Supports single and multi-client modes
; ============================================================================

Opt("MustDeclareVars", 1)
Opt("GUIOnEventMode", 1)

; ============================================================================
; Global Variables
; ============================================================================

; Mode: 0 = Single, 1 = Multi
Global $g_iMode = 0

; Multi-client connections
Global $g_aConnections[0]       ; Array of connection objects
Global $g_aBasePtrs[0]          ; Base pointers for each connection
Global $g_aChangeGoldAddrs[0]   ; ChangeGold function addresses
Global $g_aMoveToAddrs[0]       ; MoveTo function addresses
Global $g_aDialogAddrs[0][2]    ; [Agent, Gadget] dialog addresses per connection
Global $g_iSelectedClient = -1  ; Currently selected client index

; Legacy single-client state (for backward compatibility)
Global $g_bConnected = False
Global $g_iPID = 0

; GUI Controls
Global $g_hMainGUI
Global $g_lblStatus, $g_lblGold, $g_lblConnection
Global $g_btnConnect, $g_btnDisconnect, $g_btnRefresh

; Mode and client selection controls
Global $g_cmbMode, $g_cmbClientList, $g_btnScan

; Tab controls
Global $g_tabMain

; Gold tab controls
Global $g_inpGoldAmount, $g_btnDeposit, $g_btnWithdraw, $g_btnDepositAll, $g_btnWithdrawAll

; MoveTo tab controls
Global $g_inpMoveX, $g_inpMoveY, $g_btnMoveTo, $g_btnMoveNorth, $g_btnMoveSouth, $g_btnMoveEast, $g_btnMoveWest

; Dialog tab controls
Global $g_inpDialogId, $g_btnSendAgentDialog, $g_btnSendGadgetDialog, $g_cmbDialogPresets

; Memory tab controls
Global $g_edtMemoryLog

; Summary tab controls (multi-client)
Global $g_lvSummary, $g_lblTotalAll, $g_btnRefreshAll

; Cached addresses and state (legacy single-client)
Global $g_iBasePtrAddr = 0
Global $g_iChangeGoldAddr = 0
Global $g_iMoveToAddr = 0
Global $g_iSendAgentDialogAddr = 0
Global $g_iSendGadgetDialogAddr = 0

; Patterns and offsets
Global Const $BASE_PTR_PATTERN = "50 6A 0F 6A 00 FF 35"
Global Const $BASE_PTR_OFFSET = 7
Global Const $CHANGE_GOLD_PATTERN = "68 21 03 00 00 89 45 FC"
Global Const $CHANGE_GOLD_OFFSET = 0x3C
Global Const $DIALOG_PATTERN = "89 4B 24 8B 4B 28 83 E9 00"
Global Const $SEND_AGENT_DIALOG_OFFSET = 0x15
Global Const $SEND_GADGET_DIALOG_OFFSET = 0x25

; Memory offsets
Global Const $GAMECONTEXT_ITEMS_OFFSET = 0x40
Global Const $ITEMCONTEXT_INVENTORY_OFFSET = 0xF8
Global Const $INVENTORY_GOLD_CHARACTER_OFFSET = 0x90
Global Const $INVENTORY_GOLD_STORAGE_OFFSET = 0x94

; ============================================================================
; Main
; ============================================================================

_CreateMainGUI()
_UpdateUI()

While True
    Sleep(100)
WEnd

; ============================================================================
; GUI Creation
; ============================================================================

Func _CreateMainGUI()
    ; Main window - increased height for summary tab
    $g_hMainGUI = GUICreate("GwNexus Control Panel", 550, 550)
    GUISetOnEvent($GUI_EVENT_CLOSE, "_OnExit")

    ; Mode and Client Selection panel (top)
    GUICtrlCreateGroup("Mode && Client", 10, 10, 530, 55)

    GUICtrlCreateLabel("Mode:", 20, 30, 35, 20)
    $g_cmbMode = GUICtrlCreateCombo("", 55, 27, 100, 25, $CBS_DROPDOWNLIST)
    GUICtrlSetData($g_cmbMode, "Single Client|Multi Client", "Single Client")
    GUICtrlSetOnEvent($g_cmbMode, "_OnModeChange")

    GUICtrlCreateLabel("Client:", 165, 30, 35, 20)
    $g_cmbClientList = GUICtrlCreateCombo("", 200, 27, 130, 25, $CBS_DROPDOWNLIST)
    GUICtrlSetOnEvent($g_cmbClientList, "_OnClientSelect")

    $g_btnScan = GUICtrlCreateButton("Scan", 340, 25, 50, 25)
    GUICtrlSetOnEvent($g_btnScan, "_OnScanProcesses")

    $g_btnConnect = GUICtrlCreateButton("Connect", 395, 25, 65, 25)
    GUICtrlSetOnEvent($g_btnConnect, "_OnConnect")

    $g_btnDisconnect = GUICtrlCreateButton("Disconnect", 465, 25, 70, 25)
    GUICtrlSetOnEvent($g_btnDisconnect, "_OnDisconnect")
    GUICtrlSetState($g_btnDisconnect, $GUI_DISABLE)

    GUICtrlCreateGroup("", -99, -99, 1, 1)

    ; Connection status panel
    GUICtrlCreateGroup("Status", 10, 70, 530, 50)
    $g_lblConnection = GUICtrlCreateLabel("Status: Disconnected", 20, 90, 250, 20)
    GUICtrlSetColor($g_lblConnection, 0xFF0000)
    $g_lblGold = GUICtrlCreateLabel("Gold: -- | Storage: -- | Total: --", 280, 90, 200, 20)
    $g_btnRefresh = GUICtrlCreateButton("Refresh", 485, 85, 50, 25)
    GUICtrlSetOnEvent($g_btnRefresh, "_OnRefreshGold")
    GUICtrlSetState($g_btnRefresh, $GUI_DISABLE)
    GUICtrlCreateGroup("", -99, -99, 1, 1)

    ; Tab control
    $g_tabMain = GUICtrlCreateTab(10, 125, 530, 380)

    ; === Gold Tab ===
    GUICtrlCreateTabItem("Gold")

    GUICtrlCreateLabel("Transfer gold between character and storage.", 20, 160, 300, 20)
    GUICtrlCreateLabel("Note: You must be at a Xunlai Chest!", 20, 180, 300, 20)
    GUICtrlSetColor(-1, 0xFF0000)

    GUICtrlCreateLabel("Amount:", 20, 215, 50, 20)
    $g_inpGoldAmount = GUICtrlCreateInput("100", 75, 212, 100, 22, $ES_NUMBER)
    GUICtrlSetState($g_inpGoldAmount, $GUI_DISABLE)

    $g_btnDeposit = GUICtrlCreateButton("Deposit", 190, 210, 80, 25)
    GUICtrlSetOnEvent($g_btnDeposit, "_OnDeposit")
    GUICtrlSetState($g_btnDeposit, $GUI_DISABLE)

    $g_btnWithdraw = GUICtrlCreateButton("Withdraw", 280, 210, 80, 25)
    GUICtrlSetOnEvent($g_btnWithdraw, "_OnWithdraw")
    GUICtrlSetState($g_btnWithdraw, $GUI_DISABLE)

    GUICtrlCreateGroup("Quick Actions", 20, 250, 500, 60)
    $g_btnDepositAll = GUICtrlCreateButton("Deposit ALL", 35, 270, 100, 30)
    GUICtrlSetOnEvent($g_btnDepositAll, "_OnDepositAll")
    GUICtrlSetState($g_btnDepositAll, $GUI_DISABLE)

    $g_btnWithdrawAll = GUICtrlCreateButton("Withdraw ALL", 150, 270, 100, 30)
    GUICtrlSetOnEvent($g_btnWithdrawAll, "_OnWithdrawAll")
    GUICtrlSetState($g_btnWithdrawAll, $GUI_DISABLE)
    GUICtrlCreateGroup("", -99, -99, 1, 1)

    ; === MoveTo Tab ===
    GUICtrlCreateTabItem("MoveTo")

    GUICtrlCreateLabel("Move your character to specific coordinates.", 20, 160, 300, 20)

    GUICtrlCreateLabel("X:", 20, 200, 20, 20)
    $g_inpMoveX = GUICtrlCreateInput("0", 40, 197, 80, 22)
    GUICtrlSetState($g_inpMoveX, $GUI_DISABLE)

    GUICtrlCreateLabel("Y:", 140, 200, 20, 20)
    $g_inpMoveY = GUICtrlCreateInput("0", 160, 197, 80, 22)
    GUICtrlSetState($g_inpMoveY, $GUI_DISABLE)

    $g_btnMoveTo = GUICtrlCreateButton("Move To", 260, 195, 80, 25)
    GUICtrlSetOnEvent($g_btnMoveTo, "_OnMoveTo")
    GUICtrlSetState($g_btnMoveTo, $GUI_DISABLE)

    GUICtrlCreateGroup("Quick Move (1000 units)", 20, 235, 500, 80)
    $g_btnMoveNorth = GUICtrlCreateButton("North (+Y)", 220, 255, 80, 25)
    GUICtrlSetOnEvent($g_btnMoveNorth, "_OnMoveNorth")
    GUICtrlSetState($g_btnMoveNorth, $GUI_DISABLE)

    $g_btnMoveSouth = GUICtrlCreateButton("South (-Y)", 220, 285, 80, 25)
    GUICtrlSetOnEvent($g_btnMoveSouth, "_OnMoveSouth")
    GUICtrlSetState($g_btnMoveSouth, $GUI_DISABLE)

    $g_btnMoveWest = GUICtrlCreateButton("West (-X)", 130, 270, 80, 25)
    GUICtrlSetOnEvent($g_btnMoveWest, "_OnMoveWest")
    GUICtrlSetState($g_btnMoveWest, $GUI_DISABLE)

    $g_btnMoveEast = GUICtrlCreateButton("East (+X)", 310, 270, 80, 25)
    GUICtrlSetOnEvent($g_btnMoveEast, "_OnMoveEast")
    GUICtrlSetState($g_btnMoveEast, $GUI_DISABLE)
    GUICtrlCreateGroup("", -99, -99, 1, 1)

    ; === Dialog Tab ===
    GUICtrlCreateTabItem("Dialog")

    GUICtrlCreateLabel("Send dialog responses to NPCs/Gadgets.", 20, 160, 300, 20)
    GUICtrlCreateLabel("Note: You must have an active dialog open!", 20, 180, 300, 20)
    GUICtrlSetColor(-1, 0xFF0000)

    GUICtrlCreateLabel("Preset:", 20, 215, 45, 20)
    $g_cmbDialogPresets = GUICtrlCreateCombo("", 70, 212, 200, 25, $CBS_DROPDOWNLIST)
    GUICtrlSetData($g_cmbDialogPresets, "Accept (0x0001)|Decline (0x0002)|Custom...", "Accept (0x0001)")
    GUICtrlSetOnEvent($g_cmbDialogPresets, "_OnDialogPresetChange")
    GUICtrlSetState($g_cmbDialogPresets, $GUI_DISABLE)

    GUICtrlCreateLabel("Dialog ID:", 20, 250, 55, 20)
    $g_inpDialogId = GUICtrlCreateInput("0x0001", 80, 247, 100, 22)
    GUICtrlSetState($g_inpDialogId, $GUI_DISABLE)

    $g_btnSendAgentDialog = GUICtrlCreateButton("Send Agent Dialog", 200, 245, 130, 25)
    GUICtrlSetOnEvent($g_btnSendAgentDialog, "_OnSendAgentDialog")
    GUICtrlSetState($g_btnSendAgentDialog, $GUI_DISABLE)

    $g_btnSendGadgetDialog = GUICtrlCreateButton("Send Gadget Dialog", 340, 245, 130, 25)
    GUICtrlSetOnEvent($g_btnSendGadgetDialog, "_OnSendGadgetDialog")
    GUICtrlSetState($g_btnSendGadgetDialog, $GUI_DISABLE)

    ; === Summary Tab (Multi-Client) ===
    GUICtrlCreateTabItem("Summary")

    GUICtrlCreateLabel("Multi-Client Gold Summary (only in Multi Client mode)", 20, 160, 350, 20)

    $g_lvSummary = GUICtrlCreateListView("PID|Character Gold|Storage Gold|Total", 20, 185, 500, 200, $LVS_REPORT)
    _GUICtrlListView_SetColumnWidth($g_lvSummary, 0, 80)
    _GUICtrlListView_SetColumnWidth($g_lvSummary, 1, 120)
    _GUICtrlListView_SetColumnWidth($g_lvSummary, 2, 120)
    _GUICtrlListView_SetColumnWidth($g_lvSummary, 3, 120)

    GUICtrlCreateLabel("Grand Total:", 20, 395, 80, 20)
    $g_lblTotalAll = GUICtrlCreateLabel("---", 100, 395, 150, 20)
    GUICtrlSetFont($g_lblTotalAll, 11, 700)
    GUICtrlSetColor($g_lblTotalAll, 0x000066)

    $g_btnRefreshAll = GUICtrlCreateButton("Refresh All", 420, 390, 100, 25)
    GUICtrlSetOnEvent($g_btnRefreshAll, "_OnRefreshAll")
    GUICtrlSetState($g_btnRefreshAll, $GUI_DISABLE)

    ; === Memory Tab ===
    GUICtrlCreateTabItem("Memory")

    GUICtrlCreateLabel("Memory reading log:", 20, 160, 200, 20)
    $g_edtMemoryLog = GUICtrlCreateEdit("", 20, 180, 500, 280, BitOR($ES_MULTILINE, $ES_AUTOVSCROLL, $ES_READONLY, $WS_VSCROLL))
    GUICtrlSetFont($g_edtMemoryLog, 9, 400, 0, "Consolas")

    ; End tabs
    GUICtrlCreateTabItem("")

    ; Status bar
    $g_lblStatus = GUICtrlCreateLabel("Ready - Click 'Scan' to find Guild Wars processes", 10, 515, 530, 20)

    GUISetState(@SW_SHOW)
EndFunc

; ============================================================================
; Mode and Client Selection Functions
; ============================================================================

Func _OnModeChange()
    Local $sMode = GUICtrlRead($g_cmbMode)
    $g_iMode = ($sMode = "Multi Client") ? 1 : 0
    _SetStatus("Mode: " & $sMode)
    _LogMemory("Mode changed to: " & $sMode)

    ; If already connected, reconnect in new mode
    If $g_bConnected Then
        _DisconnectAll()
    EndIf

    _UpdateUI()
EndFunc

Func _OnScanProcesses()
    _SetStatus("Scanning for Guild Wars processes...")

    Local $aProcesses = _GwNexus_FindGuildWarsProcesses()

    If UBound($aProcesses) = 0 Then
        GUICtrlSetData($g_cmbClientList, "")
        _SetStatus("No Guild Wars processes found!")
        Return
    EndIf

    ; Build combo data
    Local $sData = ""
    For $i = 0 To UBound($aProcesses) - 1
        If $sData <> "" Then $sData &= "|"
        $sData &= "PID: " & $aProcesses[$i]
    Next

    GUICtrlSetData($g_cmbClientList, "")
    GUICtrlSetData($g_cmbClientList, $sData)

    ; Select first
    Local $aItems = StringSplit($sData, "|")
    If $aItems[0] > 0 Then
        GUICtrlSetData($g_cmbClientList, $aItems[1])
    EndIf

    _SetStatus("Found " & UBound($aProcesses) & " Guild Wars process(es)")
    _LogMemory("Scan found " & UBound($aProcesses) & " GW process(es)")
EndFunc

Func _OnClientSelect()
    Local $sSelected = GUICtrlRead($g_cmbClientList)
    If $sSelected = "" Then Return

    Local $iPID = Int(StringRegExpReplace($sSelected, ".*PID:\s*(\d+).*", "$1"))
    If $iPID = 0 Then Return

    ; In Single mode: if connected to a different client, reconnect to the selected one
    If $g_iMode = 0 And $g_bConnected Then
        ; Check if we're already connected to this PID
        If UBound($g_aConnections) > 0 And _GwNexus_GetConnectionPID($g_aConnections[0]) <> $iPID Then
            ; Reconnect to the newly selected client
            _SetStatus("Switching to PID " & $iPID & "...")
            _ConnectSingle($iPID)
            _UpdateUI()
            Return
        EndIf
    EndIf

    ; Find this client in our connections (for Multi mode or already connected)
    For $i = 0 To UBound($g_aConnections) - 1
        If _GwNexus_GetConnectionPID($g_aConnections[$i]) = $iPID Then
            $g_iSelectedClient = $i
            _UpdateGoldDisplay()
            _SetStatus("Selected client: PID " & $iPID)
            Return
        EndIf
    Next
EndFunc

; ============================================================================
; Connection Functions
; ============================================================================

Func _OnConnect()
    Local $sSelected = GUICtrlRead($g_cmbClientList)

    If $sSelected = "" Then
        _SetStatus("Please scan and select a client first!")
        Return
    EndIf

    ; Extract PID from selection
    Local $iPID = Int(StringRegExpReplace($sSelected, ".*PID:\s*(\d+).*", "$1"))

    If $iPID = 0 Then
        _SetStatus("Invalid PID!")
        Return
    EndIf

    _SetStatus("Connecting...")

    If $g_iMode = 0 Then
        ; Single client mode
        _ConnectSingle($iPID)
    Else
        ; Multi client mode - connect to all
        _ConnectAll()
    EndIf

    _UpdateUI()
EndFunc

Func _ConnectSingle($iPID)
    _DisconnectAll()

    _SetStatus("Connecting to PID " & $iPID & "...")

    Local $aConn = _GwNexus_CreateConnection($iPID)
    If Not _GwNexus_IsConnectionValid($aConn) Then
        _SetStatus("Failed to connect to PID " & $iPID)
        MsgBox(16, "Connection Error", "Failed to connect to Guild Wars PID " & $iPID & "." & @CRLF & @CRLF & "Make sure GwNexus DLL is injected.")
        Return
    EndIf

    ; Store connection
    ReDim $g_aConnections[1]
    ReDim $g_aBasePtrs[1]
    ReDim $g_aChangeGoldAddrs[1]
    ReDim $g_aMoveToAddrs[1]
    ReDim $g_aDialogAddrs[1][2]

    $g_aConnections[0] = $aConn
    $g_aBasePtrs[0] = 0
    $g_aChangeGoldAddrs[0] = 0
    $g_aMoveToAddrs[0] = 0
    $g_aDialogAddrs[0][0] = 0
    $g_aDialogAddrs[0][1] = 0

    ; Initialize client
    If _InitializeClient(0) Then
        $g_iSelectedClient = 0
        $g_bConnected = True
        $g_iPID = $iPID

        ; Update legacy globals for backward compatibility
        $g_iBasePtrAddr = $g_aBasePtrs[0]
        $g_iChangeGoldAddr = $g_aChangeGoldAddrs[0]
        $g_iMoveToAddr = $g_aMoveToAddrs[0]
        $g_iSendAgentDialogAddr = $g_aDialogAddrs[0][0]
        $g_iSendGadgetDialogAddr = $g_aDialogAddrs[0][1]

        _SetStatus("Connected to PID " & $iPID)
        _LogMemory("Connected to PID " & $iPID)
        _UpdateGoldDisplay()
    Else
        _SetStatus("Connected but initialization failed for PID " & $iPID)
        _LogMemory("Initialization failed for PID " & $iPID)
    EndIf
EndFunc

Func _ConnectAll()
    _DisconnectAll()

    Local $aProcesses = _GwNexus_FindGuildWarsProcesses()

    If UBound($aProcesses) = 0 Then
        _SetStatus("No Guild Wars processes found!")
        Return
    EndIf

    ReDim $g_aConnections[UBound($aProcesses)]
    ReDim $g_aBasePtrs[UBound($aProcesses)]
    ReDim $g_aChangeGoldAddrs[UBound($aProcesses)]
    ReDim $g_aMoveToAddrs[UBound($aProcesses)]
    ReDim $g_aDialogAddrs[UBound($aProcesses)][2]

    Local $iConnected = 0

    For $i = 0 To UBound($aProcesses) - 1
        _SetStatus("Connecting to PID " & $aProcesses[$i] & "...")

        Local $aConn = _GwNexus_CreateConnection($aProcesses[$i])
        If _GwNexus_IsConnectionValid($aConn) Then
            $g_aConnections[$iConnected] = $aConn
            $g_aBasePtrs[$iConnected] = 0
            $g_aChangeGoldAddrs[$iConnected] = 0
            $g_aMoveToAddrs[$iConnected] = 0
            $g_aDialogAddrs[$iConnected][0] = 0
            $g_aDialogAddrs[$iConnected][1] = 0

            _InitializeClient($iConnected)
            _LogMemory("Connected to PID " & $aProcesses[$i])
            $iConnected += 1
        EndIf
    Next

    ; Resize arrays to actual count
    ReDim $g_aConnections[$iConnected]
    ReDim $g_aBasePtrs[$iConnected]
    ReDim $g_aChangeGoldAddrs[$iConnected]
    ReDim $g_aMoveToAddrs[$iConnected]
    ReDim $g_aDialogAddrs[$iConnected][2]

    If $iConnected > 0 Then
        $g_iSelectedClient = 0
        $g_bConnected = True
        $g_iPID = _GwNexus_GetConnectionPID($g_aConnections[0])

        ; Update legacy globals from first client
        $g_iBasePtrAddr = $g_aBasePtrs[0]
        $g_iChangeGoldAddr = $g_aChangeGoldAddrs[0]
        $g_iMoveToAddr = $g_aMoveToAddrs[0]
        $g_iSendAgentDialogAddr = $g_aDialogAddrs[0][0]
        $g_iSendGadgetDialogAddr = $g_aDialogAddrs[0][1]

        _SetStatus("Connected to " & $iConnected & " client(s)")
        _LogMemory("Connected to " & $iConnected & " client(s) in Multi mode")
        _RefreshAllClients()
    Else
        _SetStatus("Failed to connect to any client!")
    EndIf

    ; Update combo with connected clients
    _UpdateClientCombo()
EndFunc

Func _OnDisconnect()
    _DisconnectAll()
    _UpdateUI()
    _SetStatus("Disconnected")
    _LogMemory("Disconnected from all clients")
EndFunc

Func _DisconnectAll()
    For $i = 0 To UBound($g_aConnections) - 1
        If _GwNexus_IsConnectionValid($g_aConnections[$i]) Then
            ; Unregister functions
            If $g_aChangeGoldAddrs[$i] <> 0 Then
                _GwNexus_UnregisterFunctionEx($g_aConnections[$i], "ChangeGold")
            EndIf
            If $g_aMoveToAddrs[$i] <> 0 Then
                _GwNexus_UnregisterFunctionEx($g_aConnections[$i], "MoveTo")
            EndIf
            If $g_aDialogAddrs[$i][0] <> 0 Then
                _GwNexus_UnregisterFunctionEx($g_aConnections[$i], "SendAgentDialog")
            EndIf
            If $g_aDialogAddrs[$i][1] <> 0 Then
                _GwNexus_UnregisterFunctionEx($g_aConnections[$i], "SendGadgetDialog")
            EndIf
            _GwNexus_CloseConnection($g_aConnections[$i])
        EndIf
    Next

    ReDim $g_aConnections[0]
    ReDim $g_aBasePtrs[0]
    ReDim $g_aChangeGoldAddrs[0]
    ReDim $g_aMoveToAddrs[0]
    ReDim $g_aDialogAddrs[0][2]
    $g_iSelectedClient = -1
    $g_bConnected = False
    $g_iPID = 0

    ; Clear legacy globals
    $g_iBasePtrAddr = 0
    $g_iChangeGoldAddr = 0
    $g_iMoveToAddr = 0
    $g_iSendAgentDialogAddr = 0
    $g_iSendGadgetDialogAddr = 0

    ; Clear displays
    GUICtrlSetData($g_lblGold, "Gold: -- | Storage: -- | Total: --")
    GUICtrlSetData($g_lblTotalAll, "---")
    _GUICtrlListView_DeleteAllItems($g_lvSummary)
EndFunc

Func _UpdateClientCombo()
    Local $sData = ""
    For $i = 0 To UBound($g_aConnections) - 1
        If _GwNexus_IsConnectionValid($g_aConnections[$i]) Then
            If $sData <> "" Then $sData &= "|"
            $sData &= "PID: " & _GwNexus_GetConnectionPID($g_aConnections[$i])
        EndIf
    Next

    GUICtrlSetData($g_cmbClientList, "")
    If $sData <> "" Then
        GUICtrlSetData($g_cmbClientList, $sData)
        ; Select first
        Local $aItems = StringSplit($sData, "|")
        If $aItems[0] > 0 Then
            GUICtrlSetData($g_cmbClientList, $aItems[1])
        EndIf
    EndIf
EndFunc

Func _InitializeClient($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return False
    If Not _GwNexus_IsConnectionValid($g_aConnections[$iIndex]) Then Return False

    Local $aConn = $g_aConnections[$iIndex]
    Local $iPID = _GwNexus_GetConnectionPID($aConn)

    _SetStatus("Initializing PID " & $iPID & "...")

    ; Find base_ptr
    Local $iPatternAddr = _GwNexus_ScanFindEx($aConn, $BASE_PTR_PATTERN, $BASE_PTR_OFFSET)
    If @error Or $iPatternAddr = 0 Then
        _LogMemory("[" & $iPID & "] Base pointer pattern not found")
        Return False
    EndIf

    Local $iBasePtr = _GwNexus_ReadMemoryValueEx($aConn, $iPatternAddr, "ptr")
    If @error Or $iBasePtr = 0 Then
        _LogMemory("[" & $iPID & "] Failed to read base_ptr")
        Return False
    EndIf

    $g_aBasePtrs[$iIndex] = $iBasePtr
    _LogMemory("[" & $iPID & "] Base pointer: 0x" & Hex($iBasePtr))

    ; Initialize ChangeGold
    $iPatternAddr = _GwNexus_ScanFindEx($aConn, $CHANGE_GOLD_PATTERN)
    If Not @error And $iPatternAddr <> 0 Then
        Local $iNearCall = $iPatternAddr + $CHANGE_GOLD_OFFSET
        Local $iChangeGoldAddr = _GwNexus_ScanFunctionFromNearCallEx($aConn, $iNearCall)
        If Not @error And $iChangeGoldAddr <> 0 Then
            If _GwNexus_RegisterFunctionEx($aConn, "ChangeGold", $iChangeGoldAddr, 2, $CONV_CDECL, False) Then
                $g_aChangeGoldAddrs[$iIndex] = $iChangeGoldAddr
                _LogMemory("[" & $iPID & "] ChangeGold: 0x" & Hex($iChangeGoldAddr))
            EndIf
        EndIf
    EndIf

    ; Initialize MoveTo
    Local $iMoveToAddr = _InitMoveToForConnection($aConn)
    If $iMoveToAddr <> 0 Then
        $g_aMoveToAddrs[$iIndex] = $iMoveToAddr
        _LogMemory("[" & $iPID & "] MoveTo: 0x" & Hex($iMoveToAddr))
    EndIf

    ; Initialize Dialog functions
    $iPatternAddr = _GwNexus_ScanFindEx($aConn, $DIALOG_PATTERN)
    If Not @error And $iPatternAddr <> 0 Then
        ; SendAgentDialog
        Local $iAgentNearCall = $iPatternAddr + $SEND_AGENT_DIALOG_OFFSET
        Local $iAgentAddr = _GwNexus_ScanFunctionFromNearCallEx($aConn, $iAgentNearCall)
        If Not @error And $iAgentAddr <> 0 Then
            If _GwNexus_RegisterFunctionEx($aConn, "SendAgentDialog", $iAgentAddr, 1, $CONV_CDECL, False) Then
                $g_aDialogAddrs[$iIndex][0] = $iAgentAddr
                _LogMemory("[" & $iPID & "] SendAgentDialog: 0x" & Hex($iAgentAddr))
            EndIf
        EndIf

        ; SendGadgetDialog
        Local $iGadgetNearCall = $iPatternAddr + $SEND_GADGET_DIALOG_OFFSET
        Local $iGadgetAddr = _GwNexus_ScanFunctionFromNearCallEx($aConn, $iGadgetNearCall)
        If Not @error And $iGadgetAddr <> 0 Then
            If _GwNexus_RegisterFunctionEx($aConn, "SendGadgetDialog", $iGadgetAddr, 1, $CONV_CDECL, False) Then
                $g_aDialogAddrs[$iIndex][1] = $iGadgetAddr
                _LogMemory("[" & $iPID & "] SendGadgetDialog: 0x" & Hex($iGadgetAddr))
            EndIf
        EndIf
    EndIf

    Return True
EndFunc

; Initialize MoveTo for a specific connection
Func _InitMoveToForConnection($aConnection)
    ; Pattern from GwNexusFunctions.au3: 83 C4 0C 85 FF 74 0B 56 6A 03, offset -5
    Local $sPattern = "83 C4 0C 85 FF 74 0B 56 6A 03"
    Local $iPatternAddr = _GwNexus_ScanFindEx($aConnection, $sPattern, -5)
    If @error Or $iPatternAddr = 0 Then Return 0

    ; The pattern with offset -5 points to a CALL instruction
    Local $iMoveToAddr = _GwNexus_ScanFunctionFromNearCallEx($aConnection, $iPatternAddr)
    If @error Or $iMoveToAddr = 0 Then Return 0

    ; MoveTo takes 1 parameter: pointer to float[3] (x, y, zplane)
    If _GwNexus_RegisterFunctionEx($aConnection, "MoveTo", $iMoveToAddr, 1, $CONV_CDECL, False) Then
        Return $iMoveToAddr
    EndIf

    Return 0
EndFunc

; ============================================================================
; Gold Functions
; ============================================================================

Func _OnRefreshGold()
    _UpdateGoldDisplay()
EndFunc

Func _OnRefreshAll()
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    _RefreshAllClients()
EndFunc

Func _RefreshAllClients()
    _GUICtrlListView_DeleteAllItems($g_lvSummary)

    Local $iTotalAll = 0

    For $i = 0 To UBound($g_aConnections) - 1
        Local $iPID = _GwNexus_GetConnectionPID($g_aConnections[$i])
        Local $iCharGold = 0, $iStorageGold = 0

        If _GetClientGold($i, $iCharGold, $iStorageGold) Then
            Local $iTotal = $iCharGold + $iStorageGold
            $iTotalAll += $iTotal

            GUICtrlCreateListViewItem($iPID & "|" & _FormatGold($iCharGold) & "|" & _FormatGold($iStorageGold) & "|" & _FormatGold($iTotal), $g_lvSummary)
        Else
            GUICtrlCreateListViewItem($iPID & "|Error|Error|Error", $g_lvSummary)
        EndIf
    Next

    GUICtrlSetData($g_lblTotalAll, _FormatGold($iTotalAll))

    ; Also refresh selected client display
    _UpdateGoldDisplay()

    _SetStatus("Refreshed " & UBound($g_aConnections) & " client(s)")
EndFunc

Func _GetClientGold($iIndex, ByRef $iCharGold, ByRef $iStorageGold)
    $iCharGold = 0
    $iStorageGold = 0

    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return False
    If Not _GwNexus_IsConnectionValid($g_aConnections[$iIndex]) Then Return False
    If $g_aBasePtrs[$iIndex] = 0 Then Return False

    Local $aConn = $g_aConnections[$iIndex]
    Local $iBasePtr = $g_aBasePtrs[$iIndex]

    ; Read character gold
    Local $aOffsetsChar[5] = [0, 0x18, $GAMECONTEXT_ITEMS_OFFSET, $ITEMCONTEXT_INVENTORY_OFFSET, $INVENTORY_GOLD_CHARACTER_OFFSET]
    $iCharGold = _GwNexus_ReadPointerChainEx($aConn, $iBasePtr, $aOffsetsChar, 4)
    If @error Then $iCharGold = 0

    ; Read storage gold
    Local $aOffsetsStorage[5] = [0, 0x18, $GAMECONTEXT_ITEMS_OFFSET, $ITEMCONTEXT_INVENTORY_OFFSET, $INVENTORY_GOLD_STORAGE_OFFSET]
    $iStorageGold = _GwNexus_ReadPointerChainEx($aConn, $iBasePtr, $aOffsetsStorage, 4)
    If @error Then $iStorageGold = 0

    Return True
EndFunc

Func _FormatGold($iGold)
    If $iGold < 0 Then Return "---"

    ; Add thousand separators
    Local $sGold = String($iGold)
    Local $sFormatted = ""
    Local $iLen = StringLen($sGold)

    For $i = 1 To $iLen
        If $i > 1 And Mod($iLen - $i + 1, 3) = 0 Then
            $sFormatted &= ","
        EndIf
        $sFormatted &= StringMid($sGold, $i, 1)
    Next

    Return $sFormatted
EndFunc

Func _OnDeposit()
    Local $iAmount = Int(GUICtrlRead($g_inpGoldAmount))
    If $iAmount <= 0 Then
        MsgBox(16, "Error", "Please enter a valid amount")
        Return
    EndIf
    _DoDepositGold($iAmount)
EndFunc

Func _OnWithdraw()
    Local $iAmount = Int(GUICtrlRead($g_inpGoldAmount))
    If $iAmount <= 0 Then
        MsgBox(16, "Error", "Please enter a valid amount")
        Return
    EndIf
    _DoWithdrawGold($iAmount)
EndFunc

Func _OnDepositAll()
    _DoDepositGold(0)
EndFunc

Func _OnWithdrawAll()
    _DoWithdrawGold(0)
EndFunc

Func _DoDepositGold($iAmount)
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    ; In Multi mode, apply to ALL clients
    If $g_iMode = 1 Then
        _SetStatus("Depositing gold on all clients...")
        Local $iSuccessCount = 0

        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aChangeGoldAddrs[$i] = 0 Then ContinueLoop

            Local $iCharGold = 0, $iStorageGold = 0
            If Not _GetClientGold($i, $iCharGold, $iStorageGold) Then ContinueLoop

            Local $iWillMove = 0
            If $iAmount = 0 Then
                $iWillMove = _Min(1000000 - $iStorageGold, $iCharGold)
            Else
                If $iStorageGold + $iAmount > 1000000 Then ContinueLoop
                If $iAmount > $iCharGold Then ContinueLoop
                $iWillMove = $iAmount
            EndIf

            If $iWillMove > 0 Then
                _CallChangeGoldForClient($i, $iCharGold - $iWillMove, $iStorageGold + $iWillMove)
                _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$i]) & "] Deposited " & $iWillMove & " gold")
                $iSuccessCount += 1
            EndIf
        Next

        Sleep(100)
        _RefreshAllClients()
        _SetStatus("Deposited gold on " & $iSuccessCount & " client(s)")
    Else
        ; Single mode - apply to selected client only
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
            _SetStatus("No client selected!")
            Return
        EndIf

        If $g_aChangeGoldAddrs[$g_iSelectedClient] = 0 Then
            MsgBox(16, "Error", "ChangeGold function not initialized for this client")
            Return
        EndIf

        Local $iCharGold = 0, $iStorageGold = 0
        If Not _GetClientGold($g_iSelectedClient, $iCharGold, $iStorageGold) Then
            MsgBox(16, "Error", "Failed to read current gold")
            Return
        EndIf

        Local $iWillMove = 0
        If $iAmount = 0 Then
            $iWillMove = _Min(1000000 - $iStorageGold, $iCharGold)
        Else
            If $iStorageGold + $iAmount > 1000000 Then
                MsgBox(16, "Error", "Would exceed storage limit (1,000,000)")
                Return
            EndIf
            If $iAmount > $iCharGold Then
                MsgBox(16, "Error", "Not enough gold on character")
                Return
            EndIf
            $iWillMove = $iAmount
        EndIf

        If $iWillMove = 0 Then
            _SetStatus("Nothing to deposit")
            Return
        EndIf

        _SetStatus("Depositing " & $iWillMove & " gold...")
        _CallChangeGoldForClient($g_iSelectedClient, $iCharGold - $iWillMove, $iStorageGold + $iWillMove)
        Sleep(100)
        _UpdateGoldDisplay()
        _SetStatus("Deposited " & $iWillMove & " gold")
        _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient]) & "] Deposited " & $iWillMove & " gold")
    EndIf
EndFunc

Func _DoWithdrawGold($iAmount)
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    ; In Multi mode, apply to ALL clients
    If $g_iMode = 1 Then
        _SetStatus("Withdrawing gold on all clients...")
        Local $iSuccessCount = 0

        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aChangeGoldAddrs[$i] = 0 Then ContinueLoop

            Local $iCharGold = 0, $iStorageGold = 0
            If Not _GetClientGold($i, $iCharGold, $iStorageGold) Then ContinueLoop

            Local $iWillMove = 0
            If $iAmount = 0 Then
                $iWillMove = _Min($iStorageGold, 100000 - $iCharGold)
            Else
                If $iCharGold + $iAmount > 100000 Then ContinueLoop
                If $iAmount > $iStorageGold Then ContinueLoop
                $iWillMove = $iAmount
            EndIf

            If $iWillMove > 0 Then
                _CallChangeGoldForClient($i, $iCharGold + $iWillMove, $iStorageGold - $iWillMove)
                _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$i]) & "] Withdrew " & $iWillMove & " gold")
                $iSuccessCount += 1
            EndIf
        Next

        Sleep(100)
        _RefreshAllClients()
        _SetStatus("Withdrew gold on " & $iSuccessCount & " client(s)")
    Else
        ; Single mode - apply to selected client only
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
            _SetStatus("No client selected!")
            Return
        EndIf

        If $g_aChangeGoldAddrs[$g_iSelectedClient] = 0 Then
            MsgBox(16, "Error", "ChangeGold function not initialized for this client")
            Return
        EndIf

        Local $iCharGold = 0, $iStorageGold = 0
        If Not _GetClientGold($g_iSelectedClient, $iCharGold, $iStorageGold) Then
            MsgBox(16, "Error", "Failed to read current gold")
            Return
        EndIf

        Local $iWillMove = 0
        If $iAmount = 0 Then
            $iWillMove = _Min($iStorageGold, 100000 - $iCharGold)
        Else
            If $iCharGold + $iAmount > 100000 Then
                MsgBox(16, "Error", "Would exceed character limit (100,000)")
                Return
            EndIf
            If $iAmount > $iStorageGold Then
                MsgBox(16, "Error", "Not enough gold in storage")
                Return
            EndIf
            $iWillMove = $iAmount
        EndIf

        If $iWillMove = 0 Then
            _SetStatus("Nothing to withdraw")
            Return
        EndIf

        _SetStatus("Withdrawing " & $iWillMove & " gold...")
        _CallChangeGoldForClient($g_iSelectedClient, $iCharGold + $iWillMove, $iStorageGold - $iWillMove)
        Sleep(100)
        _UpdateGoldDisplay()
        _SetStatus("Withdrew " & $iWillMove & " gold")
        _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient]) & "] Withdrew " & $iWillMove & " gold")
    EndIf
EndFunc

Func _CallChangeGoldForClient($iIndex, $iCharGold, $iStorageGold)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aParams[2][2]
    $aParams[0][0] = $PARAM_INT32
    $aParams[0][1] = $iCharGold
    $aParams[1][0] = $PARAM_INT32
    $aParams[1][1] = $iStorageGold
    _GwNexus_CallFunctionEx($g_aConnections[$iIndex], "ChangeGold", $aParams)
EndFunc

; ============================================================================
; MoveTo Functions
; ============================================================================

Func _OnMoveTo()
    Local $fX = Number(GUICtrlRead($g_inpMoveX))
    Local $fY = Number(GUICtrlRead($g_inpMoveY))

    _DoMoveTo($fX, $fY)
EndFunc

Func _OnMoveNorth()
    _MoveRelative(0, 1000)
EndFunc

Func _OnMoveSouth()
    _MoveRelative(0, -1000)
EndFunc

Func _OnMoveEast()
    _MoveRelative(1000, 0)
EndFunc

Func _OnMoveWest()
    _MoveRelative(-1000, 0)
EndFunc

Func _MoveRelative($fDX, $fDY)
    Local $fX = Number(GUICtrlRead($g_inpMoveX)) + $fDX
    Local $fY = Number(GUICtrlRead($g_inpMoveY)) + $fDY

    GUICtrlSetData($g_inpMoveX, $fX)
    GUICtrlSetData($g_inpMoveY, $fY)

    _DoMoveTo($fX, $fY)
EndFunc

Func _DoMoveTo($fX, $fY)
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    ; In Multi mode, apply to ALL clients
    If $g_iMode = 1 Then
        _SetStatus("Moving all clients to X=" & $fX & ", Y=" & $fY)
        Local $iSuccessCount = 0

        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aMoveToAddrs[$i] <> 0 Then
                _MoveToForClient($i, $fX, $fY)
                _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$i]) & "] MoveTo: X=" & $fX & ", Y=" & $fY)
                $iSuccessCount += 1
            EndIf
        Next

        _SetStatus("Moved " & $iSuccessCount & " client(s) to X=" & $fX & ", Y=" & $fY)
    Else
        ; Single mode - apply to selected client only
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
            _SetStatus("No client selected!")
            Return
        EndIf

        If $g_aMoveToAddrs[$g_iSelectedClient] = 0 Then
            MsgBox(16, "Error", "MoveTo function not initialized for this client")
            Return
        EndIf

        _SetStatus("Moving to X=" & $fX & ", Y=" & $fY)
        _MoveToForClient($g_iSelectedClient, $fX, $fY)
        _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient]) & "] MoveTo: X=" & $fX & ", Y=" & $fY)
    EndIf
EndFunc

Func _MoveToForClient($iIndex, $fX, $fY, $iZPlane = 0)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aConn = $g_aConnections[$iIndex]

    ; Allocate memory for the float array (4 floats = 16 bytes)
    Local $iBuffer = _GwNexus_AllocateMemoryEx($aConn, 16)
    If @error Or $iBuffer = 0 Then
        _LogMemory("[" & _GwNexus_GetConnectionPID($aConn) & "] Failed to allocate memory for MoveTo")
        Return
    EndIf

    ; Create the float array: {x, y, zplane, 0}
    Local $tFloats = DllStructCreate("float[4]")
    DllStructSetData($tFloats, 1, $fX, 1)      ; X
    DllStructSetData($tFloats, 1, $fY, 2)      ; Y
    DllStructSetData($tFloats, 1, $iZPlane, 3) ; ZPlane
    DllStructSetData($tFloats, 1, 0.0, 4)      ; Unknown (always 0)

    ; Write the float array to allocated memory
    If Not _GwNexus_WriteMemoryEx($aConn, $iBuffer, $tFloats, 16) Then
        _LogMemory("[" & _GwNexus_GetConnectionPID($aConn) & "] Failed to write float array for MoveTo")
        _GwNexus_FreeMemoryEx($aConn, $iBuffer)
        Return
    EndIf

    ; Call MoveTo with the pointer to our float array
    Local $aParams[1][2]
    $aParams[0][0] = $PARAM_POINTER
    $aParams[0][1] = $iBuffer

    _GwNexus_CallFunctionEx($aConn, "MoveTo", $aParams)

    ; Free the allocated memory
    _GwNexus_FreeMemoryEx($aConn, $iBuffer)
EndFunc

; ============================================================================
; Dialog Functions
; ============================================================================

Func _OnDialogPresetChange()
    Local $sPreset = GUICtrlRead($g_cmbDialogPresets)
    Switch $sPreset
        Case "Accept (0x0001)"
            GUICtrlSetData($g_inpDialogId, "0x0001")
        Case "Decline (0x0002)"
            GUICtrlSetData($g_inpDialogId, "0x0002")
        Case "Custom..."
            GUICtrlSetData($g_inpDialogId, "")
    EndSwitch
EndFunc

Func _OnSendAgentDialog()
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    Local $iDialogId = _ParseHexOrDec(GUICtrlRead($g_inpDialogId))

    ; In Multi mode, apply to ALL clients
    If $g_iMode = 1 Then
        _SetStatus("Sending Agent Dialog to all clients: 0x" & Hex($iDialogId))
        Local $iSuccessCount = 0

        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aDialogAddrs[$i][0] <> 0 Then
                _SendAgentDialogForClient($i, $iDialogId)
                _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$i]) & "] SendAgentDialog: 0x" & Hex($iDialogId))
                $iSuccessCount += 1
            EndIf
        Next

        _SetStatus("Sent Agent Dialog to " & $iSuccessCount & " client(s)")
    Else
        ; Single mode - apply to selected client only
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
            _SetStatus("No client selected!")
            Return
        EndIf

        If $g_aDialogAddrs[$g_iSelectedClient][0] = 0 Then
            MsgBox(16, "Error", "SendAgentDialog function not initialized for this client")
            Return
        EndIf

        _SetStatus("Sending Agent Dialog: 0x" & Hex($iDialogId))
        _SendAgentDialogForClient($g_iSelectedClient, $iDialogId)
        _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient]) & "] SendAgentDialog: 0x" & Hex($iDialogId))
    EndIf
EndFunc

Func _SendAgentDialogForClient($iIndex, $iDialogId)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aParams[1][2]
    $aParams[0][0] = $PARAM_INT32
    $aParams[0][1] = $iDialogId
    _GwNexus_CallFunctionEx($g_aConnections[$iIndex], "SendAgentDialog", $aParams)
EndFunc

Func _OnSendGadgetDialog()
    If UBound($g_aConnections) = 0 Then
        _SetStatus("No clients connected!")
        Return
    EndIf

    Local $iDialogId = _ParseHexOrDec(GUICtrlRead($g_inpDialogId))

    ; In Multi mode, apply to ALL clients
    If $g_iMode = 1 Then
        _SetStatus("Sending Gadget Dialog to all clients: 0x" & Hex($iDialogId))
        Local $iSuccessCount = 0

        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aDialogAddrs[$i][1] <> 0 Then
                _SendGadgetDialogForClient($i, $iDialogId)
                _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$i]) & "] SendGadgetDialog: 0x" & Hex($iDialogId))
                $iSuccessCount += 1
            EndIf
        Next

        _SetStatus("Sent Gadget Dialog to " & $iSuccessCount & " client(s)")
    Else
        ; Single mode - apply to selected client only
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
            _SetStatus("No client selected!")
            Return
        EndIf

        If $g_aDialogAddrs[$g_iSelectedClient][1] = 0 Then
            MsgBox(16, "Error", "SendGadgetDialog function not initialized for this client")
            Return
        EndIf

        _SetStatus("Sending Gadget Dialog: 0x" & Hex($iDialogId))
        _SendGadgetDialogForClient($g_iSelectedClient, $iDialogId)
        _LogMemory("[" & _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient]) & "] SendGadgetDialog: 0x" & Hex($iDialogId))
    EndIf
EndFunc

Func _SendGadgetDialogForClient($iIndex, $iDialogId)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aParams[1][2]
    $aParams[0][0] = $PARAM_INT32
    $aParams[0][1] = $iDialogId
    _GwNexus_CallFunctionEx($g_aConnections[$iIndex], "SendGadgetDialog", $aParams)
EndFunc

; ============================================================================
; UI Update Functions
; ============================================================================

Func _UpdateUI()
    Local $bHasSelectedClient = ($g_iSelectedClient >= 0 And $g_iSelectedClient < UBound($g_aConnections))

    If $g_bConnected And $bHasSelectedClient Then
        Local $iPID = _GwNexus_GetConnectionPID($g_aConnections[$g_iSelectedClient])
        Local $sMode = ($g_iMode = 0) ? "Single" : "Multi"
        GUICtrlSetData($g_lblConnection, "Connected: PID " & $iPID & " (" & $sMode & ", " & UBound($g_aConnections) & " client(s))")
        GUICtrlSetColor($g_lblConnection, 0x008000)
        GUICtrlSetState($g_btnConnect, $GUI_DISABLE)
        GUICtrlSetState($g_btnDisconnect, $GUI_ENABLE)
        GUICtrlSetState($g_btnRefresh, $GUI_ENABLE)

        ; Enable Gold controls if initialized for selected client
        If $g_aChangeGoldAddrs[$g_iSelectedClient] <> 0 And $g_aBasePtrs[$g_iSelectedClient] <> 0 Then
            GUICtrlSetState($g_inpGoldAmount, $GUI_ENABLE)
            GUICtrlSetState($g_btnDeposit, $GUI_ENABLE)
            GUICtrlSetState($g_btnWithdraw, $GUI_ENABLE)
            GUICtrlSetState($g_btnDepositAll, $GUI_ENABLE)
            GUICtrlSetState($g_btnWithdrawAll, $GUI_ENABLE)
        Else
            GUICtrlSetState($g_inpGoldAmount, $GUI_DISABLE)
            GUICtrlSetState($g_btnDeposit, $GUI_DISABLE)
            GUICtrlSetState($g_btnWithdraw, $GUI_DISABLE)
            GUICtrlSetState($g_btnDepositAll, $GUI_DISABLE)
            GUICtrlSetState($g_btnWithdrawAll, $GUI_DISABLE)
        EndIf

        ; Enable MoveTo controls if initialized for selected client
        If $g_aMoveToAddrs[$g_iSelectedClient] <> 0 Then
            GUICtrlSetState($g_inpMoveX, $GUI_ENABLE)
            GUICtrlSetState($g_inpMoveY, $GUI_ENABLE)
            GUICtrlSetState($g_btnMoveTo, $GUI_ENABLE)
            GUICtrlSetState($g_btnMoveNorth, $GUI_ENABLE)
            GUICtrlSetState($g_btnMoveSouth, $GUI_ENABLE)
            GUICtrlSetState($g_btnMoveEast, $GUI_ENABLE)
            GUICtrlSetState($g_btnMoveWest, $GUI_ENABLE)
        Else
            GUICtrlSetState($g_inpMoveX, $GUI_DISABLE)
            GUICtrlSetState($g_inpMoveY, $GUI_DISABLE)
            GUICtrlSetState($g_btnMoveTo, $GUI_DISABLE)
            GUICtrlSetState($g_btnMoveNorth, $GUI_DISABLE)
            GUICtrlSetState($g_btnMoveSouth, $GUI_DISABLE)
            GUICtrlSetState($g_btnMoveEast, $GUI_DISABLE)
            GUICtrlSetState($g_btnMoveWest, $GUI_DISABLE)
        EndIf

        ; Enable Dialog controls if initialized for selected client
        If $g_aDialogAddrs[$g_iSelectedClient][0] <> 0 Or $g_aDialogAddrs[$g_iSelectedClient][1] <> 0 Then
            GUICtrlSetState($g_cmbDialogPresets, $GUI_ENABLE)
            GUICtrlSetState($g_inpDialogId, $GUI_ENABLE)
        Else
            GUICtrlSetState($g_cmbDialogPresets, $GUI_DISABLE)
            GUICtrlSetState($g_inpDialogId, $GUI_DISABLE)
        EndIf
        GUICtrlSetState($g_btnSendAgentDialog, ($g_aDialogAddrs[$g_iSelectedClient][0] <> 0) ? $GUI_ENABLE : $GUI_DISABLE)
        GUICtrlSetState($g_btnSendGadgetDialog, ($g_aDialogAddrs[$g_iSelectedClient][1] <> 0) ? $GUI_ENABLE : $GUI_DISABLE)

        ; Enable Summary tab controls in multi mode
        GUICtrlSetState($g_btnRefreshAll, ($g_iMode = 1) ? $GUI_ENABLE : $GUI_DISABLE)
    Else
        GUICtrlSetData($g_lblConnection, "Status: Disconnected")
        GUICtrlSetColor($g_lblConnection, 0xFF0000)
        GUICtrlSetData($g_lblGold, "Gold: -- | Storage: -- | Total: --")
        GUICtrlSetState($g_btnConnect, $GUI_ENABLE)
        GUICtrlSetState($g_btnDisconnect, $GUI_DISABLE)
        GUICtrlSetState($g_btnRefresh, $GUI_DISABLE)

        ; Disable all controls
        GUICtrlSetState($g_inpGoldAmount, $GUI_DISABLE)
        GUICtrlSetState($g_btnDeposit, $GUI_DISABLE)
        GUICtrlSetState($g_btnWithdraw, $GUI_DISABLE)
        GUICtrlSetState($g_btnDepositAll, $GUI_DISABLE)
        GUICtrlSetState($g_btnWithdrawAll, $GUI_DISABLE)
        GUICtrlSetState($g_inpMoveX, $GUI_DISABLE)
        GUICtrlSetState($g_inpMoveY, $GUI_DISABLE)
        GUICtrlSetState($g_btnMoveTo, $GUI_DISABLE)
        GUICtrlSetState($g_btnMoveNorth, $GUI_DISABLE)
        GUICtrlSetState($g_btnMoveSouth, $GUI_DISABLE)
        GUICtrlSetState($g_btnMoveEast, $GUI_DISABLE)
        GUICtrlSetState($g_btnMoveWest, $GUI_DISABLE)
        GUICtrlSetState($g_cmbDialogPresets, $GUI_DISABLE)
        GUICtrlSetState($g_inpDialogId, $GUI_DISABLE)
        GUICtrlSetState($g_btnSendAgentDialog, $GUI_DISABLE)
        GUICtrlSetState($g_btnSendGadgetDialog, $GUI_DISABLE)
        GUICtrlSetState($g_btnRefreshAll, $GUI_DISABLE)
    EndIf
EndFunc

Func _UpdateGoldDisplay()
    If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then
        GUICtrlSetData($g_lblGold, "Gold: -- | Storage: -- | Total: --")
        Return
    EndIf

    If $g_aBasePtrs[$g_iSelectedClient] = 0 Then
        GUICtrlSetData($g_lblGold, "Gold: -- | Storage: -- | Total: --")
        Return
    EndIf

    Local $iCharGold = 0, $iStorageGold = 0
    If _GetClientGold($g_iSelectedClient, $iCharGold, $iStorageGold) Then
        GUICtrlSetData($g_lblGold, "Gold: " & _FormatGold($iCharGold) & " | Storage: " & _FormatGold($iStorageGold) & " | Total: " & _FormatGold($iCharGold + $iStorageGold))
    Else
        GUICtrlSetData($g_lblGold, "Gold: Error | Storage: Error | Total: --")
    EndIf
EndFunc

Func _SetStatus($sMessage)
    GUICtrlSetData($g_lblStatus, $sMessage)
EndFunc

Func _LogMemory($sMessage)
    Local $sTime = "[" & @HOUR & ":" & @MIN & ":" & @SEC & "] "
    Local $sCurrentText = GUICtrlRead($g_edtMemoryLog)
    GUICtrlSetData($g_edtMemoryLog, $sCurrentText & $sTime & $sMessage & @CRLF)
    ; Auto-scroll to bottom
    _GUICtrlEdit_LineScroll($g_edtMemoryLog, 0, _GUICtrlEdit_GetLineCount($g_edtMemoryLog))
EndFunc

; ============================================================================
; Helpers
; ============================================================================

Func _ParseHexOrDec($sInput)
    $sInput = StringStripWS($sInput, 3)
    If StringLeft($sInput, 2) = "0x" Or StringLeft($sInput, 2) = "0X" Then
        Return Dec(StringMid($sInput, 3))
    Else
        Return Int($sInput)
    EndIf
EndFunc

Func _OnExit()
    If $g_bConnected Then
        _DisconnectAll()
    EndIf
    Exit
EndFunc
