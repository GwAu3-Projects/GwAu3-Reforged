#RequireAdmin
#include "../../API/_GwAu3.au3"
#include "../../Utilities/ImGui/ImGui.au3"
#include "../../Utilities/ImGui/ImGui_Utils.au3"

; ============================================================================
; GwNexus ImGui GUI
; Modern ImGui interface for GwNexus functions
; Supports single and multi-client modes
; ============================================================================

Opt("GUIOnEventMode", False)
Opt("GUICloseOnESC", False)
Opt("ExpandVarStrings", 1)

; ============================================================================
; Global Variables
; ============================================================================

Global $s_GUI_Script_Name = "GwNexus Control Panel"
Global $s_GUI_Status = "Ready"

; Mode: 0 = Single, 1 = Multi
Global $g_iMode = 0

; Options
Global $g_bShowLogConsole = True
Global $g_bAlwaysOnTop = False

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
Global $g_sCharName = ""

; Scanned clients data: [n][3] = [CharName, PID, Injected]
Global $g_aScannedClients[0][3]
; Multi-client selection checkboxes (one per scanned client)
Global $g_aClientSelected[0]

; DLL path for injection
Global $g_sDllPath = ""
Global $g_aDllList[0]       ; Array of available DLL paths
Global $g_aDllNames[0]      ; Array of DLL names (for display)
Global $g_iSelectedDll = 0  ; Currently selected DLL index

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

; Event flags
Global $g_b_Event_Exit = False
Global $g_b_Event_Scan = False
Global $g_b_Event_Connect = False
Global $g_b_Event_Disconnect = False
Global $g_i_Event_DisconnectIndex = -1  ; Index of client to disconnect (-1 = all)
Global $g_b_Event_EjectDLL = False
Global $g_i_Event_EjectIndex = -1  ; Index of client to eject DLL (-1 = all connected)

; Input fields
Global $g_sInput_GoldAmount = "100"
Global $g_sInput_MoveX = "0"
Global $g_sInput_MoveY = "0"
Global $g_sInput_DialogId = "0x0001"
Global $g_iInput_DialogPreset = 0

; Gold values cache
Global $g_iCharGold = 0
Global $g_iStorageGold = 0

; Log messages array [time][message][color]
Global $g_aLogMessages[0][3]

Log_SetCallback(_LogCallback)

; ============================================================================
; Main
; ============================================================================

_ImGui_EnableViewports()
_ImGui_GUICreate($s_GUI_Script_Name, 100, 100)
_ImGui_StyleColorsDark()
_ImGui_SetWindowTitleAlign(0.5, 0.5)
_ImGui_EnableDocking()

TraySetToolTip($s_GUI_Script_Name)

; Scan for available DLLs
_ScanAvailableDlls()

AdlibRegister("_GUI_Handle", 30)
AdlibRegister("ProcessEvents", 30)

_LogMessage("GwNexus Control Panel Started", 0xFF00FF00)
_LogMessage("Click 'Scan' to find Guild Wars processes", 0xFFAAAAAA)

While 1
    Sleep(10)
    If $g_b_Event_Exit Then _GUI_ExitApp()
WEnd

_GUI_ExitApp()

; ============================================================================
; Event Processing
; ============================================================================

Func ProcessEvents()
    If $g_b_Event_Exit Then _GUI_ExitApp()

    If $g_b_Event_Scan Then
        $g_b_Event_Scan = False
        _ScanProcesses()
    EndIf

    If $g_b_Event_Connect Then
        $g_b_Event_Connect = False
        _DoConnect()
    EndIf

    If $g_b_Event_Disconnect Then
        $g_b_Event_Disconnect = False
        If $g_i_Event_DisconnectIndex >= 0 Then
            ; Disconnect single client
            _DisconnectClient($g_i_Event_DisconnectIndex)
        Else
            ; Disconnect all
            _DisconnectAll()
            _RefreshClientComboFromScan()
            _LogMessage("Disconnected from all clients", 0xFFFF0000)
        EndIf
        $g_i_Event_DisconnectIndex = -1
    EndIf

    If $g_b_Event_EjectDLL Then
        $g_b_Event_EjectDLL = False
        If $g_i_Event_EjectIndex >= 0 Then
            ; Eject DLL from single client
            _EjectDLL($g_i_Event_EjectIndex)
        Else
            ; Eject DLL from all connected clients
            _EjectAllDLLs()
        EndIf
        $g_i_Event_EjectIndex = -1
    EndIf
EndFunc

; ============================================================================
; GUI Rendering
; ============================================================================

Func _GUI_Handle()
    If Not _ImGui_PeekMsg() Then
        $g_b_Event_Exit = True
        Return
    EndIf

    _ImGui_BeginFrame()

    _ImGui_SetNextWindowSize(650, 550, $ImGuiCond_FirstUseEver)
    If Not _ImGui_Begin($s_GUI_Script_Name, True, $ImGuiWindowFlags_MenuBar) Then
        ; Close button was clicked
        $g_b_Event_Exit = True
        _ImGui_End()
        _ImGui_EndFrame()
        Return
    EndIf

    _GUI_MenuBar()

    ; Get available content region size
    Local $aWindowSize = _ImGui_GetContentRegionAvail()
    Local $fPanelHeight = $aWindowSize[1] - 30

    If $g_bShowLogConsole Then
        ; Use columns for layout (with log console)
        ; The True parameter enables the border/separator which allows resizing
        _ImGui_Columns(2, "MainColumns", True)
    EndIf

    ; Left column - Main controls
    _ImGui_BeginChild("LeftPanel", -1, $fPanelHeight, False)

    _GUI_ConnectionSection()

    _ImGui_Separator()
    _ImGui_NewLine()

    If $g_bConnected Then
        _GUI_CommandTabs()
    Else
        _ImGui_TextColored("Connect to a character to access commands", 0xFFAAAAAA)
    EndIf

    _ImGui_EndChild()

    If $g_bShowLogConsole Then
        ; Right column - Log console
        _ImGui_NextColumn()

        _GUI_LogConsole($fPanelHeight)

        _ImGui_Columns(1)
    EndIf

    _ImGui_End()
    _ImGui_EndFrame()
EndFunc

; ============================================================================
; GUI Sections
; ============================================================================

Func _GUI_MenuBar()
    If _ImGui_BeginMenuBar() Then
        If _ImGui_BeginMenu("Menu") Then
            If $g_bConnected Then
                If $g_iMode = 0 Then
                    ; Single mode: simple disconnect
                    If _ImGui_MenuItem("Disconnect") Then
                        $g_b_Event_Disconnect = True
                        $g_i_Event_DisconnectIndex = -1
                    EndIf
                Else
                    ; Multi mode: disconnect individual clients
                    For $i = 0 To UBound($g_aConnections) - 1
                        Local $sCharName = _GetCharNameFromConnection($i)
                        If _ImGui_MenuItem("Disconnect " & $sCharName) Then
                            $g_b_Event_Disconnect = True
                            $g_i_Event_DisconnectIndex = $i
                        EndIf
                    Next
                    _ImGui_Separator()
                    If _ImGui_MenuItem("Disconnect All") Then
                        $g_b_Event_Disconnect = True
                        $g_i_Event_DisconnectIndex = -1
                    EndIf
                EndIf
                _ImGui_Separator()
            EndIf
            ; Eject DLL submenu
            If $g_bConnected And _ImGui_BeginMenu("Eject DLL") Then
                If $g_iMode = 0 Then
                    ; Single client mode
                    If _ImGui_MenuItem("Eject from current") Then
                        $g_b_Event_EjectDLL = True
                        $g_i_Event_EjectIndex = 0
                    EndIf
                Else
                    ; Multi-client mode - show each connected client
                    For $i = 0 To UBound($g_aConnections) - 1
                        If $g_aConnections[$i][0] <> -1 Then
                            Local $sCharName = _GetCharNameFromConnection($i)
                            If _ImGui_MenuItem("Eject " & $sCharName) Then
                                $g_b_Event_EjectDLL = True
                                $g_i_Event_EjectIndex = $i
                            EndIf
                        EndIf
                    Next
                    _ImGui_Separator()
                    If _ImGui_MenuItem("Eject All") Then
                        $g_b_Event_EjectDLL = True
                        $g_i_Event_EjectIndex = -1
                    EndIf
                EndIf
                _ImGui_EndMenu()
            EndIf
            _ImGui_Separator()
            If _ImGui_MenuItem("Exit", "Alt+F4") Then
                $g_b_Event_Exit = True
            EndIf
            _ImGui_EndMenu()
        EndIf

        If _ImGui_BeginMenu("Mode") Then
            Local $bSingle = ($g_iMode = 0)
            Local $bMulti = ($g_iMode = 1)
            If _ImGui_MenuItem("Single Client", "", $bSingle) Then
                If $g_iMode <> 0 Then
                    $g_iMode = 0
                    _LogMessage("Mode changed to: Single Client", 0xFF00FFFF)
                    If $g_bConnected Then _DisconnectAll()
                EndIf
            EndIf
            If _ImGui_MenuItem("Multi Client", "", $bMulti) Then
                If $g_iMode <> 1 Then
                    $g_iMode = 1
                    _LogMessage("Mode changed to: Multi Client", 0xFF00FFFF)
                    If $g_bConnected Then _DisconnectAll()
                EndIf
            EndIf
            _ImGui_EndMenu()
        EndIf

        If _ImGui_BeginMenu("Options") Then
            If _ImGui_MenuItem("Always On Top", "", $g_bAlwaysOnTop) Then
                $g_bAlwaysOnTop = Not $g_bAlwaysOnTop
                WinSetOnTop($s_GUI_Script_Name, "", $g_bAlwaysOnTop ? 1 : 0)
                _LogMessage("Always on top: " & ($g_bAlwaysOnTop ? "enabled" : "disabled"), 0xFF00FFFF)
            EndIf
            If _ImGui_MenuItem("Log Console", "", $g_bShowLogConsole) Then
                $g_bShowLogConsole = Not $g_bShowLogConsole
                _LogMessage("Log Console " & ($g_bShowLogConsole ? "enabled" : "disabled"), 0xFF00FFFF)
            EndIf
            _ImGui_EndMenu()
        EndIf

        If _ImGui_BeginMenu("Help") Then
            If _ImGui_MenuItem("About") Then
                _LogMessage("GwNexus Control Panel - ImGui Version", 0xFF00FFFF)
                _LogMessage("Multi-client Guild Wars tool", 0xFFAAAAAA)
            EndIf
            _ImGui_EndMenu()
        EndIf

        _ImGui_EndMenuBar()
    EndIf
EndFunc

Func _GUI_ConnectionSection()
    ; Status display
    If $g_bConnected Then
        Local $sMode = ($g_iMode = 0) ? "Single" : "Multi"
        _ImGui_TextColored("Connected (" & $sMode & " - " & UBound($g_aConnections) & " client(s))", 0xFF00FF00)
    Else
        _ImGui_TextColored("Not Connected", 0xFFFF0000)
    EndIf

    ; If connected, hide character list and show only gold (using cached values)
    If $g_bConnected Then
        If $g_iSelectedClient >= 0 Then
            _ImGui_NewLine()
            _ImGui_Separator()

            _ImGui_Text("Gold: ")
            _ImGui_SameLine()
            _ImGui_TextColored(_FormatGold($g_iCharGold), 0xFFFFD700)

            _ImGui_SameLine()
            _ImGui_Text(" | Storage: ")
            _ImGui_SameLine()
            _ImGui_TextColored(_FormatGold($g_iStorageGold), 0xFFFFD700)

            _ImGui_SameLine()
            _ImGui_Text(" | Total: ")
            _ImGui_SameLine()
            _ImGui_TextColored(_FormatGold($g_iCharGold + $g_iStorageGold), 0xFF00FF00)

            _ImGui_SameLine()
            If _ImGui_SmallButton("Refresh##gold") Then
                _UpdateGoldValues()
                _LogMessage("Gold refreshed", 0xFFAAAAAA)
            EndIf
        EndIf
        Return
    EndIf

    _ImGui_NewLine()

    ; Mode indicator
    _ImGui_Text("Mode: ")
    _ImGui_SameLine()
    If $g_iMode = 0 Then
        _ImGui_TextColored("Single Client", 0xFF00FFFF)
    Else
        _ImGui_TextColored("Multi Client", 0xFFFF00FF)
    EndIf

    _ImGui_NewLine()

    ; DLL selection
    _ImGui_Text("DLL to inject:")
    _ImGui_SameLine()
    _ImGui_SetNextItemWidth(200)
    If UBound($g_aDllNames) > 0 Then
        Local $sCurrentDll = ($g_iSelectedDll < UBound($g_aDllNames)) ? $g_aDllNames[$g_iSelectedDll] : "None"
        If _ImGui_BeginCombo("##DllCombo", $sCurrentDll) Then
            For $i = 0 To UBound($g_aDllNames) - 1
                Local $bSelected = ($g_iSelectedDll = $i)
                If _ImGui_Selectable($g_aDllNames[$i] & "##dll" & $i, $bSelected) Then
                    $g_iSelectedDll = $i
                    $g_sDllPath = $g_aDllList[$i]
                    _LogMessage("Selected DLL: " & $g_aDllNames[$i], 0xFF00FFFF)
                EndIf
            Next
            _ImGui_EndCombo()
        EndIf
    Else
        _ImGui_TextColored("No DLLs found", 0xFFFF0000)
    EndIf

    _ImGui_NewLine()

    ; Client list
    _ImGui_Text("Available Characters:")
    _ImGui_Indent(1)
    _ImGui_BeginChild("CharList", -1, 120, True)

    If UBound($g_aScannedClients) = 0 Then
        _ImGui_TextColored("No characters found. Click 'Scan' to search.", 0xFF888888)
    Else
        For $i = 0 To UBound($g_aScannedClients) - 1
            Local $sLabel = $g_aScannedClients[$i][0]
            If $g_aScannedClients[$i][2] Then
                $sLabel &= " (Injected)"
            EndIf

            If $g_iMode = 0 Then
                ; Single mode: use Selectable (only one selection)
                Local $bSelected = ($g_iSelectedClient = $i)
                If _ImGui_Selectable($sLabel, $bSelected) Then
                    $g_iSelectedClient = $i
                    _LogMessage("Selected: " & $g_aScannedClients[$i][0], 0xFF00FFFF)
                EndIf
            Else
                ; Multi mode: use Checkboxes (multiple selections)
                If $i < UBound($g_aClientSelected) Then
                    Local $bChecked = $g_aClientSelected[$i]
                    If _ImGui_Checkbox($sLabel & "##client" & $i, $bChecked) Then
                        $g_aClientSelected[$i] = $bChecked
                        Local $sState = $bChecked ? "selected" : "deselected"
                        _LogMessage($g_aScannedClients[$i][0] & " " & $sState, 0xFF00FFFF)
                    EndIf
                EndIf
            EndIf
        Next
    EndIf

    _ImGui_EndChild()
    _ImGui_Unindent(1)

    ; Control buttons
    If _ImGui_Button("Scan", 80, 25) Then
        $g_b_Event_Scan = True
    EndIf
    _ImGui_SameLine()

    If $g_bConnected Then
        If _ImGui_Button("Disconnect", 100, 25) Then
            $g_b_Event_Disconnect = True
        EndIf
    Else
        If _ImGui_Button("Connect", 100, 25) Then
            $g_b_Event_Connect = True
        EndIf
    EndIf

    ; Gold display for Multi mode (using cached values)
    If $g_bConnected And $g_iSelectedClient >= 0 Then
        _ImGui_NewLine()
        _ImGui_Separator()

        _ImGui_Text("Gold: ")
        _ImGui_SameLine()
        _ImGui_TextColored(_FormatGold($g_iCharGold), 0xFFFFD700)

        _ImGui_SameLine()
        _ImGui_Text(" | Storage: ")
        _ImGui_SameLine()
        _ImGui_TextColored(_FormatGold($g_iStorageGold), 0xFFFFD700)

        _ImGui_SameLine()
        _ImGui_Text(" | Total: ")
        _ImGui_SameLine()
        _ImGui_TextColored(_FormatGold($g_iCharGold + $g_iStorageGold), 0xFF00FF00)

        _ImGui_SameLine()
        If _ImGui_SmallButton("Refresh##gold") Then
            _UpdateGoldValues()
            _LogMessage("Gold refreshed", 0xFFAAAAAA)
        EndIf
    EndIf
EndFunc

Func _GUI_CommandTabs()
    If _ImGui_BeginTabBar("CommandTabs") Then
        If _ImGui_BeginTabItem("Gold") Then
            _GUI_Tab_Gold()
            _ImGui_EndTabItem()
        EndIf
        If _ImGui_BeginTabItem("MoveTo") Then
            _GUI_Tab_MoveTo()
            _ImGui_EndTabItem()
        EndIf
        If _ImGui_BeginTabItem("Dialog") Then
            _GUI_Tab_Dialog()
            _ImGui_EndTabItem()
        EndIf
        If $g_iMode = 1 Then
            If _ImGui_BeginTabItem("Summary") Then
                _GUI_Tab_Summary()
                _ImGui_EndTabItem()
            EndIf
        EndIf
        _ImGui_EndTabBar()
    EndIf
EndFunc

Func _GUI_Tab_Gold()
    _ImGui_TextColored("Gold Transfer", 0xFF00FFFF)
    _ImGui_Text("Transfer gold between character and storage.")
    _ImGui_TextColored("Note: You must be at a Xunlai Chest!", 0xFFFF6666)
    _ImGui_NewLine()
    _ImGui_Separator()

    ; Amount input
    _ImGui_Text("Amount:")
    _ImGui_SameLine()
    _ImGui_PushItemWidth(100)
    _ImGui_InputText("##goldamount", $g_sInput_GoldAmount)
    _ImGui_PopItemWidth()

    _ImGui_SameLine()
    If _ImGui_Button("Deposit", 80, 0) Then
        Local $iAmount = Int($g_sInput_GoldAmount)
        If $iAmount > 0 Then
            _DoDepositGold($iAmount)
        EndIf
    EndIf

    _ImGui_SameLine()
    If _ImGui_Button("Withdraw", 80, 0) Then
        Local $iAmount = Int($g_sInput_GoldAmount)
        If $iAmount > 0 Then
            _DoWithdrawGold($iAmount)
        EndIf
    EndIf

    _ImGui_NewLine()

    ; Quick actions
    If _ImGui_CollapsingHeader("Quick Actions##gold", $ImGuiTreeNodeFlags_DefaultOpen) Then
        If _ImGui_Button("Deposit ALL", 120, 30) Then
            _DoDepositGold(0)
        EndIf
        _ImGui_SameLine()
        If _ImGui_Button("Withdraw ALL", 120, 30) Then
            _DoWithdrawGold(0)
        EndIf

        If $g_iMode = 1 Then
            _ImGui_NewLine()
            _ImGui_TextColored("Multi-client mode: Actions apply to ALL connected clients", 0xFFFF00FF)
        EndIf
    EndIf
EndFunc

Func _GUI_Tab_MoveTo()
    _ImGui_TextColored("Movement Control", 0xFF00FFFF)
    _ImGui_Text("Move your character to specific coordinates.")
    _ImGui_NewLine()
    _ImGui_Separator()

    ; Coordinate inputs
    _ImGui_Text("X:")
    _ImGui_SameLine()
    _ImGui_PushItemWidth(80)
    _ImGui_InputText("##movex", $g_sInput_MoveX)
    _ImGui_PopItemWidth()

    _ImGui_SameLine()
    _ImGui_Text("Y:")
    _ImGui_SameLine()
    _ImGui_PushItemWidth(80)
    _ImGui_InputText("##movey", $g_sInput_MoveY)
    _ImGui_PopItemWidth()

    _ImGui_SameLine()
    If _ImGui_Button("Move To", 80, 0) Then
        Local $fX = Number($g_sInput_MoveX)
        Local $fY = Number($g_sInput_MoveY)
        _DoMoveTo($fX, $fY)
    EndIf

    _ImGui_NewLine()

    ; Quick movement
    If _ImGui_CollapsingHeader("Quick Move (1000 units)##move", $ImGuiTreeNodeFlags_DefaultOpen) Then
        _ImGui_Dummy(80, 1)
        _ImGui_SameLine()
        If _ImGui_Button("North (+Y)", 100, 30) Then
            _MoveRelative(0, 1000)
        EndIf

        If _ImGui_Button("West (-X)", 100, 30) Then
            _MoveRelative(-1000, 0)
        EndIf
        _ImGui_SameLine()
        _ImGui_Dummy(10, 1)
        _ImGui_SameLine()
        If _ImGui_Button("East (+X)", 100, 30) Then
            _MoveRelative(1000, 0)
        EndIf

        _ImGui_Dummy(80, 1)
        _ImGui_SameLine()
        If _ImGui_Button("South (-Y)", 100, 30) Then
            _MoveRelative(0, -1000)
        EndIf

        If $g_iMode = 1 Then
            _ImGui_NewLine()
            _ImGui_TextColored("Multi-client mode: Movement applies to ALL connected clients", 0xFFFF00FF)
        EndIf
    EndIf
EndFunc

Func _GUI_Tab_Dialog()
    _ImGui_TextColored("Dialog Control", 0xFF00FFFF)
    _ImGui_Text("Send dialog responses to NPCs/Gadgets.")
    _ImGui_TextColored("Note: You must have an active dialog open!", 0xFFFF6666)
    _ImGui_NewLine()
    _ImGui_Separator()

    ; Preset selection
    Local $aPresets[3] = ["Accept (0x0001)", "Decline (0x0002)", "Custom..."]
    _ImGui_Text("Preset:")
    _ImGui_SameLine()
    _ImGui_PushItemWidth(150)
    If _ImGui_BeginCombo("##dialogpreset", $aPresets[$g_iInput_DialogPreset]) Then
        For $i = 0 To 2
            If _ImGui_Selectable($aPresets[$i], ($g_iInput_DialogPreset = $i)) Then
                $g_iInput_DialogPreset = $i
                Switch $i
                    Case 0
                        $g_sInput_DialogId = "0x0001"
                    Case 1
                        $g_sInput_DialogId = "0x0002"
                EndSwitch
            EndIf
        Next
        _ImGui_EndCombo()
    EndIf
    _ImGui_PopItemWidth()

    _ImGui_NewLine()

    ; Dialog ID input
    _ImGui_Text("Dialog ID:")
    _ImGui_SameLine()
    _ImGui_PushItemWidth(100)
    _ImGui_InputText("##dialogid", $g_sInput_DialogId)
    _ImGui_PopItemWidth()

    _ImGui_NewLine()

    ; Send buttons
    If _ImGui_Button("Send Agent Dialog", 150, 30) Then
        Local $iDialogId = _ParseHexOrDec($g_sInput_DialogId)
        _DoSendAgentDialog($iDialogId)
    EndIf
    _ImGui_SameLine()
    If _ImGui_Button("Send Gadget Dialog", 150, 30) Then
        Local $iDialogId = _ParseHexOrDec($g_sInput_DialogId)
        _DoSendGadgetDialog($iDialogId)
    EndIf

    If $g_iMode = 1 Then
        _ImGui_NewLine()
        _ImGui_TextColored("Multi-client mode: Dialog sent to ALL connected clients", 0xFFFF00FF)
    EndIf
EndFunc

Func _GUI_Tab_Summary()
    _ImGui_TextColored("Multi-Client Summary", 0xFF00FFFF)
    _ImGui_Text("Overview of all connected clients.")
    _ImGui_NewLine()
    _ImGui_Separator()

    If UBound($g_aConnections) = 0 Then
        _ImGui_TextColored("No clients connected", 0xFF888888)
        Return
    EndIf

    ; Header
    _ImGui_Columns(4, "SummaryColumns", True)
    _ImGui_SetColumnWidth(0, 100)
    _ImGui_SetColumnWidth(1, 100)
    _ImGui_SetColumnWidth(2, 100)
    _ImGui_SetColumnWidth(3, 100)

    _ImGui_TextColored("Character", 0xFFFFFFFF)
    _ImGui_NextColumn()
    _ImGui_TextColored("Gold", 0xFFFFD700)
    _ImGui_NextColumn()
    _ImGui_TextColored("Storage", 0xFFFFD700)
    _ImGui_NextColumn()
    _ImGui_TextColored("Total", 0xFF00FF00)
    _ImGui_NextColumn()

    _ImGui_Separator()

    ; Data rows
    Local $iTotalAll = 0

    For $i = 0 To UBound($g_aConnections) - 1
        Local $iPID = _GwNexus_GetConnectionPID($g_aConnections[$i])
        Local $sName = _GetCharNameByPID($iPID)
        If $sName = "" Then $sName = "Client " & ($i + 1)

        Local $iChar = 0, $iStorage = 0
        _GetClientGold($i, $iChar, $iStorage)
        Local $iTotal = $iChar + $iStorage
        $iTotalAll += $iTotal

        _ImGui_Text($sName)
        _ImGui_NextColumn()
        _ImGui_Text(_FormatGold($iChar))
        _ImGui_NextColumn()
        _ImGui_Text(_FormatGold($iStorage))
        _ImGui_NextColumn()
        _ImGui_Text(_FormatGold($iTotal))
        _ImGui_NextColumn()
    Next

    _ImGui_Columns(1)

    _ImGui_Separator()
    _ImGui_NewLine()

    _ImGui_Text("Grand Total: ")
    _ImGui_SameLine()
    _ImGui_TextColored(_FormatGold($iTotalAll), 0xFF00FF00)

    _ImGui_SameLine()
    _ImGui_Dummy(20, 1)
    _ImGui_SameLine()
    If _ImGui_Button("Refresh All", 100, 25) Then
        _LogMessage("Refreshed all clients", 0xFFAAAAAA)
    EndIf
EndFunc

Func _GUI_LogConsole($fHeight)
    _ImGui_Text("Log Console")
    _ImGui_SameLine()
    If _ImGui_SmallButton("Clear##log") Then
        ReDim $g_aLogMessages[0][3]
    EndIf
    _ImGui_SameLine()
    If _ImGui_SmallButton("Copy##log") Then
        Local $sClipboard = ""
        For $i = 0 To UBound($g_aLogMessages) - 1
            $sClipboard &= "[" & $g_aLogMessages[$i][0] & "] " & $g_aLogMessages[$i][1] & @CRLF
        Next
        ClipPut($sClipboard)
        _LogMessage("Log copied to clipboard", 0xFF00FFFF)
    EndIf

    _ImGui_BeginChild("LogConsole", -1, $fHeight - 25, True)

    For $i = 0 To UBound($g_aLogMessages) - 1
        _ImGui_TextColored("[" & $g_aLogMessages[$i][0] & "] ", 0xFF888888)
        _ImGui_SameLine()
        _ImGui_TextColored($g_aLogMessages[$i][1], $g_aLogMessages[$i][2])
    Next

    ; Auto-scroll disabled - _ImGui_GetScrollY/_ImGui_GetScrollMaxY cause crash

    _ImGui_EndChild()
EndFunc

; ============================================================================
; Connection Functions
; ============================================================================

Func _ScanProcesses()
    _LogMessage("Scanning for Guild Wars...", 0xFFAAAAAA)

    $g_aScannedClients = _GwNexus_ScanAllClients()

    If UBound($g_aScannedClients) = 0 Then
        _LogMessage("No Guild Wars processes found!", 0xFFFF0000)
        ReDim $g_aClientSelected[0]
        Return
    EndIf

    ; Initialize selection array (all selected by default)
    ReDim $g_aClientSelected[UBound($g_aScannedClients)]
    For $i = 0 To UBound($g_aClientSelected) - 1
        $g_aClientSelected[$i] = True
    Next

    Local $iInjected = 0, $iNotInjected = 0
    For $i = 0 To UBound($g_aScannedClients) - 1
        If $g_aScannedClients[$i][2] Then
            $iInjected += 1
        Else
            $iNotInjected += 1
        EndIf
    Next

    _LogMessage("Found " & UBound($g_aScannedClients) & " character(s): " & $iInjected & " injected, " & $iNotInjected & " not injected", 0xFF00FF00)
EndFunc

Func _DoConnect()
    If UBound($g_aScannedClients) = 0 Then
        _LogMessage("Please scan for clients first!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 0 Then
        ; Single client mode
        If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aScannedClients) Then
            _LogMessage("Please select a client first!", 0xFFFF0000)
            Return
        EndIf
        _ConnectSingle($g_aScannedClients[$g_iSelectedClient][0], $g_aScannedClients[$g_iSelectedClient][1])
    Else
        ; Multi client mode - connect to all
        _ConnectAll()
    EndIf
EndFunc

Func _ConnectSingle($sCharName, $iPID = 0)
    _DisconnectAll()
    _GwNexus_ClearCache()

    _LogMessage("Connecting to " & $sCharName & "...", 0xFFAAAAAA)

    ; Check if injection is needed
    Local $bNeedInject = True
    For $i = 0 To UBound($g_aScannedClients) - 1
        If $g_aScannedClients[$i][0] = $sCharName Then
            $bNeedInject = Not $g_aScannedClients[$i][2]
            If $iPID = 0 Then $iPID = $g_aScannedClients[$i][1]
            ExitLoop
        EndIf
    Next

    ; Inject if needed
    If $bNeedInject Then
        If Not _InjectToClient($sCharName, $iPID) Then
            Return
        EndIf
    EndIf

    Local $aConn = _GwNexus_CreateConnectionByName($sCharName, $iPID)
    If Not _GwNexus_IsConnectionValid($aConn) Then
        _LogMessage("Failed to connect to " & $sCharName, 0xFFFF0000)
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
        $g_sCharName = $sCharName
        $g_iPID = $iPID

        ; Update legacy globals
        $g_iBasePtrAddr = $g_aBasePtrs[0]
        $g_iChangeGoldAddr = $g_aChangeGoldAddrs[0]
        $g_iMoveToAddr = $g_aMoveToAddrs[0]
        $g_iSendAgentDialogAddr = $g_aDialogAddrs[0][0]
        $g_iSendGadgetDialogAddr = $g_aDialogAddrs[0][1]

        _LogMessage("Connected to " & $sCharName & " (PID: " & $iPID & ")", 0xFF00FF00)
        _UpdateGoldValues()
    Else
        _LogMessage("Initialization failed for " & $sCharName, 0xFFFF0000)
    EndIf
EndFunc

Func _ConnectAll()
    _DisconnectAll()
    _GwNexus_ClearCache()

    If UBound($g_aScannedClients) = 0 Then
        _LogMessage("No clients scanned! Please scan first.", 0xFFFF0000)
        Return
    EndIf

    ; Count selected clients
    Local $iSelectedCount = 0
    For $i = 0 To UBound($g_aScannedClients) - 1
        If $i < UBound($g_aClientSelected) And $g_aClientSelected[$i] Then
            $iSelectedCount += 1
        EndIf
    Next

    If $iSelectedCount = 0 Then
        _LogMessage("No clients selected! Please select at least one client.", 0xFFFF0000)
        Return
    EndIf

    _LogMessage("Connecting to " & $iSelectedCount & " selected client(s)...", 0xFFAAAAAA)

    ReDim $g_aConnections[$iSelectedCount]
    ReDim $g_aBasePtrs[$iSelectedCount]
    ReDim $g_aChangeGoldAddrs[$iSelectedCount]
    ReDim $g_aMoveToAddrs[$iSelectedCount]
    ReDim $g_aDialogAddrs[$iSelectedCount][2]

    Local $iConnected = 0

    For $i = 0 To UBound($g_aScannedClients) - 1
        ; Skip unselected clients
        If $i >= UBound($g_aClientSelected) Or Not $g_aClientSelected[$i] Then
            ContinueLoop
        EndIf

        Local $sCharName = $g_aScannedClients[$i][0]
        Local $iPID = $g_aScannedClients[$i][1]
        Local $bInjected = $g_aScannedClients[$i][2]

        ; Inject if needed
        If Not $bInjected Then
            If Not _InjectToClient($sCharName, $iPID) Then
                ContinueLoop
            EndIf
            $g_aScannedClients[$i][2] = True
        EndIf

        ; Connect
        Local $aConn = _GwNexus_CreateConnectionByName($sCharName, $iPID)
        If _GwNexus_IsConnectionValid($aConn) Then
            $g_aConnections[$iConnected] = $aConn
            $g_aBasePtrs[$iConnected] = 0
            $g_aChangeGoldAddrs[$iConnected] = 0
            $g_aMoveToAddrs[$iConnected] = 0
            $g_aDialogAddrs[$iConnected][0] = 0
            $g_aDialogAddrs[$iConnected][1] = 0

            _InitializeClient($iConnected)
            _LogMessage("Connected to " & $sCharName, 0xFF00FF00)
            $iConnected += 1
        Else
            _LogMessage("Failed to connect to " & $sCharName, 0xFFFF0000)
        EndIf
    Next

    ; Resize arrays to actual count
    If $iConnected > 0 Then
        ReDim $g_aConnections[$iConnected]
        ReDim $g_aBasePtrs[$iConnected]
        ReDim $g_aChangeGoldAddrs[$iConnected]
        ReDim $g_aMoveToAddrs[$iConnected]
        ReDim $g_aDialogAddrs[$iConnected][2]

        $g_iSelectedClient = 0
        $g_bConnected = True

        ; Update legacy globals from first client
        $g_iBasePtrAddr = $g_aBasePtrs[0]
        $g_iChangeGoldAddr = $g_aChangeGoldAddrs[0]
        $g_iMoveToAddr = $g_aMoveToAddrs[0]
        $g_iSendAgentDialogAddr = $g_aDialogAddrs[0][0]
        $g_iSendGadgetDialogAddr = $g_aDialogAddrs[0][1]

        _LogMessage("Connected to " & $iConnected & " client(s)", 0xFF00FF00)
    Else
        ReDim $g_aConnections[0]
        ReDim $g_aBasePtrs[0]
        ReDim $g_aChangeGoldAddrs[0]
        ReDim $g_aMoveToAddrs[0]
        ReDim $g_aDialogAddrs[0][2]
        _LogMessage("Failed to connect to any client!", 0xFFFF0000)
    EndIf
EndFunc

Func _InjectToClient($sCharName, $iPID)
    _LogMessage("Injecting DLL to " & $sCharName & "...", 0xFFAAAAAA)

    If Not FileExists($g_sDllPath) Then
        _LogMessage("DLL not found: " & $g_sDllPath, 0xFFFF0000)
        Return False
    EndIf

    If Not _InjectDll($iPID, $g_sDllPath) Then
        _LogMessage("Failed to inject DLL - Error: " & @error, 0xFFFF0000)
        Return False
    EndIf

    ; Wait for pipe - try character name first, then fallback to PID
    Local $sPipeNameChar = "\\.\pipe\GwNexus_" & StringReplace($sCharName, " ", "_")
    Local $sPipeNamePID = "\\.\pipe\GwNexus_" & $iPID
    Local $sPipeFound = ""
    Local $iTimeout = 10000
    Local $hTimer = TimerInit()

    While TimerDiff($hTimer) < $iTimeout
        ; Try character name pipe first
        Local $aWait = DllCall("kernel32.dll", "bool", "WaitNamedPipeW", "wstr", $sPipeNameChar, "dword", 50)
        If Not @error And $aWait[0] <> 0 Then
            $sPipeFound = $sPipeNameChar
            ExitLoop
        EndIf

        ; Try PID-based pipe as fallback (release mode may use this)
        $aWait = DllCall("kernel32.dll", "bool", "WaitNamedPipeW", "wstr", $sPipeNamePID, "dword", 50)
        If Not @error And $aWait[0] <> 0 Then
            $sPipeFound = $sPipeNamePID
            _LogMessage("Using PID-based pipe for " & $sCharName, 0xFFFFAA00)
            ExitLoop
        EndIf

        Sleep(200)
    WEnd

    If $sPipeFound = "" Then
        _LogMessage("Pipe timeout for " & $sCharName, 0xFFFF0000)
        _LogMessage("Tried: " & $sPipeNameChar, 0xFFFF8888)
        _LogMessage("Tried: " & $sPipeNamePID, 0xFFFF8888)
        Return False
    EndIf

    _LogMessage("DLL injected to " & $sCharName, 0xFF00FF00)
    Return True
EndFunc

Func _DisconnectAll()
    For $i = 0 To UBound($g_aConnections) - 1
        If _GwNexus_IsConnectionValid($g_aConnections[$i]) Then
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

    $g_iBasePtrAddr = 0
    $g_iChangeGoldAddr = 0
    $g_iMoveToAddr = 0
    $g_iSendAgentDialogAddr = 0
    $g_iSendGadgetDialogAddr = 0

    $g_iCharGold = 0
    $g_iStorageGold = 0
EndFunc

Func _DisconnectClient($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $sCharName = _GetCharNameFromConnection($iIndex)

    ; Close the connection
    If _GwNexus_IsConnectionValid($g_aConnections[$iIndex]) Then
        If $g_aChangeGoldAddrs[$iIndex] <> 0 Then
            _GwNexus_UnregisterFunctionEx($g_aConnections[$iIndex], "ChangeGold")
        EndIf
        If $g_aMoveToAddrs[$iIndex] <> 0 Then
            _GwNexus_UnregisterFunctionEx($g_aConnections[$iIndex], "MoveTo")
        EndIf
        If $g_aDialogAddrs[$iIndex][0] <> 0 Then
            _GwNexus_UnregisterFunctionEx($g_aConnections[$iIndex], "SendAgentDialog")
        EndIf
        If $g_aDialogAddrs[$iIndex][1] <> 0 Then
            _GwNexus_UnregisterFunctionEx($g_aConnections[$iIndex], "SendGadgetDialog")
        EndIf
        _GwNexus_CloseConnection($g_aConnections[$iIndex])
    EndIf

    ; Remove from arrays
    Local $iCount = UBound($g_aConnections)
    If $iCount = 1 Then
        ; Last client, disconnect all
        _DisconnectAll()
        _RefreshClientComboFromScan()
        _LogMessage("Disconnected from " & $sCharName & " (last client)", 0xFFFF0000)
        Return
    EndIf

    ; Shift arrays to remove the disconnected client
    For $i = $iIndex To $iCount - 2
        $g_aConnections[$i] = $g_aConnections[$i + 1]
        $g_aBasePtrs[$i] = $g_aBasePtrs[$i + 1]
        $g_aChangeGoldAddrs[$i] = $g_aChangeGoldAddrs[$i + 1]
        $g_aMoveToAddrs[$i] = $g_aMoveToAddrs[$i + 1]
        $g_aDialogAddrs[$i][0] = $g_aDialogAddrs[$i + 1][0]
        $g_aDialogAddrs[$i][1] = $g_aDialogAddrs[$i + 1][1]
    Next

    ; Resize arrays
    ReDim $g_aConnections[$iCount - 1]
    ReDim $g_aBasePtrs[$iCount - 1]
    ReDim $g_aChangeGoldAddrs[$iCount - 1]
    ReDim $g_aMoveToAddrs[$iCount - 1]
    ReDim $g_aDialogAddrs[$iCount - 1][2]

    ; Adjust selected client index
    If $g_iSelectedClient >= UBound($g_aConnections) Then
        $g_iSelectedClient = UBound($g_aConnections) - 1
    EndIf

    ; Update legacy globals from first remaining client
    If UBound($g_aConnections) > 0 Then
        $g_iBasePtrAddr = $g_aBasePtrs[0]
        $g_iChangeGoldAddr = $g_aChangeGoldAddrs[0]
        $g_iMoveToAddr = $g_aMoveToAddrs[0]
        $g_iSendAgentDialogAddr = $g_aDialogAddrs[0][0]
        $g_iSendGadgetDialogAddr = $g_aDialogAddrs[0][1]
    EndIf

    _LogMessage("Disconnected from " & $sCharName, 0xFFFF0000)
EndFunc

Func _EjectDLL($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $sCharName = _GetCharNameFromConnection($iIndex)
    Local $aConn = $g_aConnections[$iIndex]

    If Not _GwNexus_IsConnectionValid($aConn) Then
        _LogMessage("Cannot eject DLL: not connected to " & $sCharName, 0xFFFF0000)
        Return
    EndIf

    _LogMessage("Ejecting DLL from " & $sCharName & "...", 0xFFFFAA00)

    ; Send DLL_DETACH request
    Local $tRequest = _GwNexus_CreateDLLDetachRequest()
    Local $tResponse = _GwNexus_SendRequestEx($aConn, $tRequest)

    If @error Then
        _LogMessage("Failed to send eject request to " & $sCharName, 0xFFFF0000)
    Else
        _LogMessage("DLL eject request sent to " & $sCharName, 0xFF00FF00)
    EndIf

    ; Disconnect the client (the DLL will unload itself)
    _DisconnectClient($iIndex)
EndFunc

Func _EjectAllDLLs()
    _LogMessage("Ejecting DLL from all connected clients...", 0xFFFFAA00)

    ; Send eject to all connected clients (iterate in reverse to handle array resizing)
    For $i = UBound($g_aConnections) - 1 To 0 Step -1
        If _GwNexus_IsConnectionValid($g_aConnections[$i]) Then
            _EjectDLL($i)
        EndIf
    Next
EndFunc

Func _RefreshClientComboFromScan()
    ; Just reset selected client
    If UBound($g_aScannedClients) > 0 Then
        $g_iSelectedClient = 0
    Else
        $g_iSelectedClient = -1
    EndIf
EndFunc

Func _InitializeClient($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return False
    If Not _GwNexus_IsConnectionValid($g_aConnections[$iIndex]) Then Return False

    Local $aConn = $g_aConnections[$iIndex]
    Local $iPID = _GwNexus_GetConnectionPID($aConn)

    ; Find base_ptr
    Local $iPatternAddr = _GwNexus_ScanFindEx($aConn, $BASE_PTR_PATTERN, $BASE_PTR_OFFSET)
    If @error Or $iPatternAddr = 0 Then
        _LogMessage("[" & $iPID & "] Base pointer pattern not found", 0xFFFF0000)
        Return False
    EndIf

    Local $iBasePtr = _GwNexus_ReadMemoryValueEx($aConn, $iPatternAddr, "ptr")
    If @error Or $iBasePtr = 0 Then
        _LogMessage("[" & $iPID & "] Failed to read base_ptr", 0xFFFF0000)
        Return False
    EndIf

    $g_aBasePtrs[$iIndex] = $iBasePtr

    ; Initialize ChangeGold
    $iPatternAddr = _GwNexus_ScanFindEx($aConn, $CHANGE_GOLD_PATTERN)
    If Not @error And $iPatternAddr <> 0 Then
        Local $iNearCall = $iPatternAddr + $CHANGE_GOLD_OFFSET
        Local $iChangeGoldAddr = _GwNexus_ScanFunctionFromNearCallEx($aConn, $iNearCall)
        If Not @error And $iChangeGoldAddr <> 0 Then
            If _GwNexus_RegisterFunctionEx($aConn, "ChangeGold", $iChangeGoldAddr, 2, $CONV_CDECL, False) Then
                $g_aChangeGoldAddrs[$iIndex] = $iChangeGoldAddr
            EndIf
        EndIf
    EndIf

    ; Initialize MoveTo
    Local $iMoveToAddr = _InitMoveToForConnection($aConn)
    If $iMoveToAddr <> 0 Then
        $g_aMoveToAddrs[$iIndex] = $iMoveToAddr
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
            EndIf
        EndIf

        ; SendGadgetDialog
        Local $iGadgetNearCall = $iPatternAddr + $SEND_GADGET_DIALOG_OFFSET
        Local $iGadgetAddr = _GwNexus_ScanFunctionFromNearCallEx($aConn, $iGadgetNearCall)
        If Not @error And $iGadgetAddr <> 0 Then
            If _GwNexus_RegisterFunctionEx($aConn, "SendGadgetDialog", $iGadgetAddr, 1, $CONV_CDECL, False) Then
                $g_aDialogAddrs[$iIndex][1] = $iGadgetAddr
            EndIf
        EndIf
    EndIf

    Return True
EndFunc

Func _InitMoveToForConnection($aConnection)
    Local $sPattern = "83 C4 0C 85 FF 74 0B 56 6A 03"
    Local $iPatternAddr = _GwNexus_ScanFindEx($aConnection, $sPattern, -5)
    If @error Or $iPatternAddr = 0 Then Return 0

    Local $iMoveToAddr = _GwNexus_ScanFunctionFromNearCallEx($aConnection, $iPatternAddr)
    If @error Or $iMoveToAddr = 0 Then Return 0

    If _GwNexus_RegisterFunctionEx($aConnection, "MoveTo", $iMoveToAddr, 1, $CONV_CDECL, False) Then
        Return $iMoveToAddr
    EndIf

    Return 0
EndFunc

; ============================================================================
; Action Functions
; ============================================================================

Func _UpdateGoldValues()
    If $g_iSelectedClient < 0 Or $g_iSelectedClient >= UBound($g_aConnections) Then Return
    _GetClientGold($g_iSelectedClient, $g_iCharGold, $g_iStorageGold)
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

Func _DoDepositGold($iAmount)
    If UBound($g_aConnections) = 0 Then
        _LogMessage("No clients connected!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 1 Then
        ; Multi mode - apply to all
        Local $iSuccessCount = 0
        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aChangeGoldAddrs[$i] = 0 Then ContinueLoop

            Local $iChar = 0, $iStorage = 0
            If Not _GetClientGold($i, $iChar, $iStorage) Then ContinueLoop

            Local $iWillMove = 0
            If $iAmount = 0 Then
                $iWillMove = _Min(1000000 - $iStorage, $iChar)
            Else
                If $iStorage + $iAmount > 1000000 Then ContinueLoop
                If $iAmount > $iChar Then ContinueLoop
                $iWillMove = $iAmount
            EndIf

            If $iWillMove > 0 Then
                _CallChangeGoldForClient($i, $iChar - $iWillMove, $iStorage + $iWillMove)
                $iSuccessCount += 1
            EndIf
        Next

        _LogMessage("Deposited gold on " & $iSuccessCount & " client(s)", 0xFF00FF00)
    Else
        ; Single mode
        If $g_iSelectedClient < 0 Then Return
        If $g_aChangeGoldAddrs[$g_iSelectedClient] = 0 Then
            _LogMessage("ChangeGold not initialized", 0xFFFF0000)
            Return
        EndIf

        Local $iChar = 0, $iStorage = 0
        If Not _GetClientGold($g_iSelectedClient, $iChar, $iStorage) Then Return

        Local $iWillMove = 0
        If $iAmount = 0 Then
            $iWillMove = _Min(1000000 - $iStorage, $iChar)
        Else
            If $iStorage + $iAmount > 1000000 Then
                _LogMessage("Would exceed storage limit (1,000,000)", 0xFFFF0000)
                Return
            EndIf
            If $iAmount > $iChar Then
                _LogMessage("Not enough gold on character", 0xFFFF0000)
                Return
            EndIf
            $iWillMove = $iAmount
        EndIf

        If $iWillMove > 0 Then
            _CallChangeGoldForClient($g_iSelectedClient, $iChar - $iWillMove, $iStorage + $iWillMove)
            _LogMessage("Deposited " & _FormatGold($iWillMove) & " gold", 0xFF00FF00)
        EndIf
    EndIf

    Sleep(100)
    _UpdateGoldValues()
EndFunc

Func _DoWithdrawGold($iAmount)
    If UBound($g_aConnections) = 0 Then
        _LogMessage("No clients connected!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 1 Then
        ; Multi mode - apply to all
        Local $iSuccessCount = 0
        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aChangeGoldAddrs[$i] = 0 Then ContinueLoop

            Local $iChar = 0, $iStorage = 0
            If Not _GetClientGold($i, $iChar, $iStorage) Then ContinueLoop

            Local $iWillMove = 0
            If $iAmount = 0 Then
                $iWillMove = _Min($iStorage, 100000 - $iChar)
            Else
                If $iChar + $iAmount > 100000 Then ContinueLoop
                If $iAmount > $iStorage Then ContinueLoop
                $iWillMove = $iAmount
            EndIf

            If $iWillMove > 0 Then
                _CallChangeGoldForClient($i, $iChar + $iWillMove, $iStorage - $iWillMove)
                $iSuccessCount += 1
            EndIf
        Next

        _LogMessage("Withdrew gold on " & $iSuccessCount & " client(s)", 0xFF00FF00)
    Else
        ; Single mode
        If $g_iSelectedClient < 0 Then Return
        If $g_aChangeGoldAddrs[$g_iSelectedClient] = 0 Then
            _LogMessage("ChangeGold not initialized", 0xFFFF0000)
            Return
        EndIf

        Local $iChar = 0, $iStorage = 0
        If Not _GetClientGold($g_iSelectedClient, $iChar, $iStorage) Then Return

        Local $iWillMove = 0
        If $iAmount = 0 Then
            $iWillMove = _Min($iStorage, 100000 - $iChar)
        Else
            If $iChar + $iAmount > 100000 Then
                _LogMessage("Would exceed character limit (100,000)", 0xFFFF0000)
                Return
            EndIf
            If $iAmount > $iStorage Then
                _LogMessage("Not enough gold in storage", 0xFFFF0000)
                Return
            EndIf
            $iWillMove = $iAmount
        EndIf

        If $iWillMove > 0 Then
            _CallChangeGoldForClient($g_iSelectedClient, $iChar + $iWillMove, $iStorage - $iWillMove)
            _LogMessage("Withdrew " & _FormatGold($iWillMove) & " gold", 0xFF00FF00)
        EndIf
    EndIf

    Sleep(100)
    _UpdateGoldValues()
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

Func _DoMoveTo($fX, $fY)
    If UBound($g_aConnections) = 0 Then
        _LogMessage("No clients connected!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 1 Then
        ; Multi mode - apply to all
        Local $iSuccessCount = 0
        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aMoveToAddrs[$i] <> 0 Then
                _MoveToForClient($i, $fX, $fY)
                $iSuccessCount += 1
            EndIf
        Next
        _LogMessage("Moved " & $iSuccessCount & " client(s) to X=" & $fX & ", Y=" & $fY, 0xFF00FF00)
    Else
        ; Single mode
        If $g_iSelectedClient < 0 Then Return
        If $g_aMoveToAddrs[$g_iSelectedClient] = 0 Then
            _LogMessage("MoveTo not initialized", 0xFFFF0000)
            Return
        EndIf

        _MoveToForClient($g_iSelectedClient, $fX, $fY)
        _LogMessage("Moving to X=" & $fX & ", Y=" & $fY, 0xFF00FF00)
    EndIf
EndFunc

Func _MoveRelative($fDX, $fDY)
    Local $fX = Number($g_sInput_MoveX) + $fDX
    Local $fY = Number($g_sInput_MoveY) + $fDY

    $g_sInput_MoveX = String($fX)
    $g_sInput_MoveY = String($fY)

    _DoMoveTo($fX, $fY)
EndFunc

Func _MoveToForClient($iIndex, $fX, $fY, $iZPlane = 0)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aConn = $g_aConnections[$iIndex]

    ; Allocate memory for the float array
    Local $iBuffer = _GwNexus_AllocateMemoryEx($aConn, 16)
    If @error Or $iBuffer = 0 Then Return

    ; Create the float array
    Local $tFloats = DllStructCreate("float[4]")
    DllStructSetData($tFloats, 1, $fX, 1)
    DllStructSetData($tFloats, 1, $fY, 2)
    DllStructSetData($tFloats, 1, $iZPlane, 3)
    DllStructSetData($tFloats, 1, 0.0, 4)

    ; Write and call
    If _GwNexus_WriteMemoryEx($aConn, $iBuffer, $tFloats, 16) Then
        Local $aParams[1][2]
        $aParams[0][0] = $PARAM_POINTER
        $aParams[0][1] = $iBuffer
        _GwNexus_CallFunctionEx($aConn, "MoveTo", $aParams)
    EndIf

    _GwNexus_FreeMemoryEx($aConn, $iBuffer)
EndFunc

Func _DoSendAgentDialog($iDialogId)
    If UBound($g_aConnections) = 0 Then
        _LogMessage("No clients connected!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 1 Then
        Local $iSuccessCount = 0
        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aDialogAddrs[$i][0] <> 0 Then
                _SendDialogForClient($i, "SendAgentDialog", $iDialogId)
                $iSuccessCount += 1
            EndIf
        Next
        _LogMessage("Sent Agent Dialog to " & $iSuccessCount & " client(s): 0x" & Hex($iDialogId), 0xFF00FF00)
    Else
        If $g_iSelectedClient < 0 Then Return
        If $g_aDialogAddrs[$g_iSelectedClient][0] = 0 Then
            _LogMessage("SendAgentDialog not initialized", 0xFFFF0000)
            Return
        EndIf

        _SendDialogForClient($g_iSelectedClient, "SendAgentDialog", $iDialogId)
        _LogMessage("Sent Agent Dialog: 0x" & Hex($iDialogId), 0xFF00FF00)
    EndIf
EndFunc

Func _DoSendGadgetDialog($iDialogId)
    If UBound($g_aConnections) = 0 Then
        _LogMessage("No clients connected!", 0xFFFF0000)
        Return
    EndIf

    If $g_iMode = 1 Then
        Local $iSuccessCount = 0
        For $i = 0 To UBound($g_aConnections) - 1
            If $g_aDialogAddrs[$i][1] <> 0 Then
                _SendDialogForClient($i, "SendGadgetDialog", $iDialogId)
                $iSuccessCount += 1
            EndIf
        Next
        _LogMessage("Sent Gadget Dialog to " & $iSuccessCount & " client(s): 0x" & Hex($iDialogId), 0xFF00FF00)
    Else
        If $g_iSelectedClient < 0 Then Return
        If $g_aDialogAddrs[$g_iSelectedClient][1] = 0 Then
            _LogMessage("SendGadgetDialog not initialized", 0xFFFF0000)
            Return
        EndIf

        _SendDialogForClient($g_iSelectedClient, "SendGadgetDialog", $iDialogId)
        _LogMessage("Sent Gadget Dialog: 0x" & Hex($iDialogId), 0xFF00FF00)
    EndIf
EndFunc

Func _SendDialogForClient($iIndex, $sFuncName, $iDialogId)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return

    Local $aParams[1][2]
    $aParams[0][0] = $PARAM_INT32
    $aParams[0][1] = $iDialogId
    _GwNexus_CallFunctionEx($g_aConnections[$iIndex], $sFuncName, $aParams)
EndFunc

; ============================================================================
; Helpers
; ============================================================================

Func _GetCharNameByPID($iPID)
    For $i = 0 To UBound($g_aScannedClients) - 1
        If $g_aScannedClients[$i][1] = $iPID Then
            Return $g_aScannedClients[$i][0]
        EndIf
    Next
    Return ""
EndFunc

Func _GetCharNameFromConnection($iIndex)
    If $iIndex < 0 Or $iIndex >= UBound($g_aConnections) Then Return "Unknown"
    Local $iPID = _GwNexus_GetConnectionPID($g_aConnections[$iIndex])
    Local $sName = _GetCharNameByPID($iPID)
    If $sName = "" Then Return "Client " & $iIndex
    Return $sName
EndFunc

Func _FormatGold($iGold)
    If $iGold < 0 Then Return "---"

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

Func _ParseHexOrDec($sInput)
    $sInput = StringStripWS($sInput, 3)
    If StringLeft($sInput, 2) = "0x" Or StringLeft($sInput, 2) = "0X" Then
        Return Dec(StringMid($sInput, 3))
    Else
        Return Int($sInput)
    EndIf
EndFunc

Func _ScanAvailableDlls()
    Local $sDllDir = @ScriptDir & "\..\..\API\Dll"

    ; Use native AutoIt file search
    Local $hSearch = FileFindFirstFile($sDllDir & "\*.dll")

    If $hSearch = -1 Then
        ; No DLLs found, set default
        ReDim $g_aDllList[1]
        ReDim $g_aDllNames[1]
        $g_aDllList[0] = $sDllDir & "\GwNexus.dll"
        $g_aDllNames[0] = "GwNexus.dll (default)"
        $g_iSelectedDll = 0
        $g_sDllPath = $g_aDllList[0]
        Return
    EndIf

    ; First pass: count DLLs
    Local $iCount = 0
    Local $sFile
    While 1
        $sFile = FileFindNextFile($hSearch)
        If @error Then ExitLoop
        $iCount += 1
    WEnd
    FileClose($hSearch)

    If $iCount = 0 Then
        ReDim $g_aDllList[1]
        ReDim $g_aDllNames[1]
        $g_aDllList[0] = $sDllDir & "\GwNexus.dll"
        $g_aDllNames[0] = "GwNexus.dll (default)"
        $g_iSelectedDll = 0
        $g_sDllPath = $g_aDllList[0]
        Return
    EndIf

    ; Second pass: fill arrays
    ReDim $g_aDllList[$iCount]
    ReDim $g_aDllNames[$iCount]

    $hSearch = FileFindFirstFile($sDllDir & "\*.dll")
    Local $i = 0
    While 1
        $sFile = FileFindNextFile($hSearch)
        If @error Then ExitLoop
        $g_aDllList[$i] = $sDllDir & "\" & $sFile
        $g_aDllNames[$i] = $sFile
        $i += 1
    WEnd
    FileClose($hSearch)

    $g_iSelectedDll = 0
    $g_sDllPath = $g_aDllList[0]
EndFunc

Func _LogMessage($sMessage, $iColor = 0xFFFFFFFF)
    Local $sTime = @HOUR & ":" & @MIN & ":" & @SEC
    Local $nIndex = UBound($g_aLogMessages)
    ReDim $g_aLogMessages[$nIndex + 1][3]
    $g_aLogMessages[$nIndex][0] = $sTime
    $g_aLogMessages[$nIndex][1] = $sMessage
    $g_aLogMessages[$nIndex][2] = $iColor

    ; Keep only last 100 messages
    If UBound($g_aLogMessages) > 100 Then
        _ArrayDelete($g_aLogMessages, 0)
    EndIf
EndFunc

Func _GUI_ExitApp()
    If $g_bConnected Then
        _DisconnectAll()
    EndIf
    Exit
EndFunc

; ============================================================================
; DLL Injection
; ============================================================================

Func _InjectDll($iPID, $sDllPath)
    If $iPID = 0 Then Return SetError(1, 0, False)
    If Not FileExists($sDllPath) Then Return SetError(2, 0, False)
    If StringRight($sDllPath, 4) <> ".dll" Then Return SetError(3, 0, False)

    Local $hKernel = DllOpen("kernel32.dll")
    If $hKernel = -1 Then Return SetError(4, 0, False)

    ; Get full path
    Local $tDllPath = DllStructCreate("char[260]")
    Local $aFullPath = DllCall($hKernel, "dword", "GetFullPathNameA", "str", $sDllPath, "dword", 260, "ptr", DllStructGetPtr($tDllPath), "ptr", 0)
    If @error Or $aFullPath[0] = 0 Then
        DllClose($hKernel)
        Return SetError(5, 0, False)
    EndIf

    ; Open target process
    Local $aProcess = DllCall($hKernel, "handle", "OpenProcess", "dword", 0x1F0FFF, "bool", False, "dword", $iPID)
    If @error Or $aProcess[0] = 0 Then
        DllClose($hKernel)
        Return SetError(6, 0, False)
    EndIf
    Local $hProcess = $aProcess[0]

    ; Get kernel32 module handle
    Local $aModule = DllCall($hKernel, "handle", "GetModuleHandleA", "str", "kernel32.dll")
    If @error Or $aModule[0] = 0 Then
        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
        DllClose($hKernel)
        Return SetError(7, 0, False)
    EndIf

    ; Get LoadLibraryA address
    Local $aLoadLib = DllCall($hKernel, "ptr", "GetProcAddress", "handle", $aModule[0], "str", "LoadLibraryA")
    If @error Or $aLoadLib[0] = 0 Then
        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
        DllClose($hKernel)
        Return SetError(8, 0, False)
    EndIf

    ; Allocate memory in target process
    Local $iPathLen = StringLen(DllStructGetData($tDllPath, 1)) + 1
    Local $aAlloc = DllCall($hKernel, "ptr", "VirtualAllocEx", "handle", $hProcess, "ptr", 0, "ulong_ptr", $iPathLen, "dword", 0x3000, "dword", 0x04)
    If @error Or $aAlloc[0] = 0 Then
        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
        DllClose($hKernel)
        Return SetError(9, 0, False)
    EndIf
    Local $pRemotePath = $aAlloc[0]

    ; Write DLL path to target process
    Local $aWrite = DllCall($hKernel, "bool", "WriteProcessMemory", "handle", $hProcess, "ptr", $pRemotePath, "str", DllStructGetData($tDllPath, 1), "ulong_ptr", $iPathLen, "ulong_ptr*", 0)
    If @error Or $aWrite[0] = 0 Then
        DllCall($hKernel, "bool", "VirtualFreeEx", "handle", $hProcess, "ptr", $pRemotePath, "ulong_ptr", 0, "dword", 0x8000)
        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
        DllClose($hKernel)
        Return SetError(10, 0, False)
    EndIf

    ; Create remote thread to call LoadLibraryA
    Local $aThread = DllCall($hKernel, "handle", "CreateRemoteThread", "handle", $hProcess, "ptr", 0, "ulong_ptr", 0, "ptr", $aLoadLib[0], "ptr", $pRemotePath, "dword", 0, "dword*", 0)
    If @error Or $aThread[0] = 0 Then
        DllCall($hKernel, "bool", "VirtualFreeEx", "handle", $hProcess, "ptr", $pRemotePath, "ulong_ptr", 0, "dword", 0x8000)
        DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
        DllClose($hKernel)
        Return SetError(11, 0, False)
    EndIf

    ; Wait for thread to complete
    DllCall($hKernel, "dword", "WaitForSingleObject", "handle", $aThread[0], "dword", 10000)

    ; Cleanup
    DllCall($hKernel, "bool", "CloseHandle", "handle", $aThread[0])
    DllCall($hKernel, "bool", "VirtualFreeEx", "handle", $hProcess, "ptr", $pRemotePath, "ulong_ptr", 0, "dword", 0x8000)
    DllCall($hKernel, "bool", "CloseHandle", "handle", $hProcess)
    DllClose($hKernel)

    Return True
EndFunc

#Region Utility Functions
Func _LogCallback($a_s_Message, $a_e_MsgType, $a_s_Author)
    Local $l_i_UtilsMsgType
    Switch $a_e_MsgType
        Case $GC_I_LOG_MSGTYPE_DEBUG
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Debug
        Case $GC_I_LOG_MSGTYPE_INFO
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Info
        Case $GC_I_LOG_MSGTYPE_WARNING
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Warning
        Case $GC_I_LOG_MSGTYPE_ERROR
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Error
        Case $GC_I_LOG_MSGTYPE_CRITICAL
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Critical
        Case Else
            $l_i_UtilsMsgType = $c_UTILS_Msg_Type_Info
    EndSwitch

    _Utils_LogMessage($a_s_Message, $l_i_UtilsMsgType, $a_s_Author)
EndFunc
#EndRegion Utility Functions