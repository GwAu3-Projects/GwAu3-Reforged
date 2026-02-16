# 🧩 GwAu3-Reforged

Advanced automation framework for **Guild Wars (32-bit)** combining:
- ⚙️ **Injected C++ DLL**
- 🤖 **AutoIt Scripts**
- 🔌 **IPC Communication via Named Pipes**

Enables **memory scanning**, **internal function calls**, **hooking**, and **multi-client control** of the game.

---

## 📐 Architecture Overview

```
AutoIt Scripts
       │
       │ Named Pipes (\\.\pipe\GwNexus_{CharName})
       ▼
GwNexus.dll (injected)
├─ NamedPipe Server
├─ RPC Dispatcher
├─ Memory Scanner / Hooks
├─ MinHook
└─ ImGui (Debug)
       ▼
Guild Wars (Gw.exe – 32-bit)
```

🔁 **Flow**
1. AutoIt sends a request
2. The DLL receives it via Named Pipe
3. The dispatcher executes the action
4. The result is sent back to the script

---

## 🧰 Key Features

- 🔍 Memory scanning (patterns, assertions, pointer chains)
- ✏️ Memory read / write operations
- 📞 Internal function calls (cdecl, stdcall, thiscall...)
- 🪝 Runtime hooks (MinHook)
- 🧪 Integrated ImGui interface (Debug mode)
- 👥 Multi-client support
- ⚡ Smart caching for scans

---

## 📦 Prerequisites

### 🔧 DLL Compilation
- Windows 10 / 11
- Visual Studio 2019 or 2022 (C++)
- CMake >= 3.16
- Git

### ▶️ Execution
- AutoIt v3
- Guild Wars (**32-bit** client)
- Administrator rights (DLL injection)

---

## 🚀 Installation

### 1️⃣ Compile the DLL

```bash
git clone https://github.com/your-repo/GwAu3-Reforged.git
cd GwAu3-Reforged/API/Dll
setup.bat
```

📦 **Generated files:**
```
Debug/GwNexus.dll    # With ImGui interface
Release/GwNexus.dll  # Without UI (production)
```

### 2️⃣ AutoIt Configuration

Minimal structure:
```
API/
 ├─ _GwAu3.au3
 ├─ Core/
 └─ Dll/GwNexus.dll
Scripts/
 └─ Examples/
```

▶️ Run `Example - GwNexus.au3` as administrator

---

## 🧠 GwNexus DLL

### ⚙️ Lifecycle

```
Initializing → Running → ShuttingDown → Stopped
```

### 🐞 Debug vs Release

| Option | Debug | Release |
|--------|-------|---------|
| ImGui Interface | ✅ | ❌ |
| Logs | Verbose | Minimal |
| Performance | Normal | Optimized |

---

## 🔌 IPC Communication (Named Pipes)

- Packed binary protocol (1 byte alignment)
- Requests <= 2644 bytes
- Responses <= 2576 bytes

### 📡 Main Categories

- 🔍 Memory scanner
- 🧠 Memory read / write
- 📞 Function calls
- 🪝 Hooks
- 🧭 Control & status

---

## 🧪 AutoIt API – Examples

### 🔗 Connection

```autoit
#include "../../API/_GwAu3.au3"
_GwNexus_ConnectToFirstGW()
```

### 🔍 Memory Scan

```autoit
$iAddr = _GwNexus_ScanFind("55 8B EC ?? ??", "", 0)
```

### ✏️ Memory Read

```autoit
$iGold = _GwNexus_ReadMemoryValue($iAddr, "dword")
```

### 📞 Function Call

```autoit
_GwNexus_RegisterFunction("MoveTo", $iAddr, 1, $CONV_CDECL, False)
_GwNexus_CallFunction("MoveTo", $aParams)
```

### 👥 Multi-client

```autoit
$aConn = _GwNexus_CreateConnectionByName("CharName", $iPID)
_GwNexus_ReadMemoryValueEx($aConn, $iAddr, "dword")
```

---

## 🖥️ Control Interface (provided example)

- 🔌 Connection & DLL injection
- 💰 Gold management (character / storage)
- 🧭 Movement control (MoveTo)
- 💬 Dialogs & interactions
- 📊 Multi-client global view
- 📝 Real-time log console

---

## 🛠️ Quick Troubleshooting

### ❌ DLL not injected
- Check GW is 32-bit
- Run script as admin
- Verify DLL exists
- Check logs

### ❌ Pattern not found
- Game updated
- Wrong memory section
- Clear cache:

```autoit
_GwNexus_ClearCache()
```

---

## 🔐 Security & Best Practices

- 🧪 Test in Debug mode first
- 💾 Backup before writing to memory
- ✅ Validate addresses
- ♻️ Release memory and hooks
- 🛑 Proper disconnection (DLL_DETACH)

---

## 📄 License

This project is provided as-is, without warranty. Use at your own risk.

---

## 🤝 Contributions

Contributions are welcome:
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Open a Pull Request
