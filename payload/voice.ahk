; =====================================================================
;  OpenCode 语音输入 —— 长按触发键说话，松开自动转写并粘贴
;
;  默认：任意窗口长按回车 → 语音输入；短按回车行为不变
;  暂停：Ctrl+Alt+M 一键暂停/恢复（暂停后所有按键恢复原生行为）
;  设置：托盘 H 图标右键 → 设置…
;
;  依赖:
;    1. voice_server.py 常驻服务（同目录，.venv 环境）
;    2. AutoHotkey v2.0
;    3. 可选：安装器创建的计划任务（以最高权限运行，兼容管理员程序）
;
;  配置见同目录 voice.config.ini
; =====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
; 警告不弹窗（否则会阻塞整个脚本），必要时用 DebugView 查看
#Warn All, OutputDebug
SendMode "Input"
SetWorkingDir A_ScriptDir

; ------------------------------ 配置（由 voice.config.ini 覆盖） ------------------------------
global IniPath := A_ScriptDir . "\voice.config.ini"

global HoldMs := 350               ; 长按判定阈值（毫秒）
global AutoSubmit := false         ; 粘贴后自动回车发送
global RestoreClipboard := true    ; 粘贴后恢复原剪贴板
global TargetWindows := ["*"]      ; 生效窗口：* = 所有窗口
global Port := 17860               ; 语音服务端口
global ServerTask := ""            ; 拉起服务的计划任务名
global HotkeyTask := ""            ; 本助手对应的计划任务名
global OverlayEnabled := true      ; 实时字幕悬浮窗
global OverlayOffsetY := 120       ; 悬浮窗距窗口底部像素
global OverlayMaxChars := 200      ; 悬浮窗最多显示字数
global OverlayPollMs := 150        ; 悬浮窗刷新间隔
global MaxRecordSeconds := 60      ; 单次录音上限（秒）
global TriggerKey := "enter"       ; 触发键：enter | xbutton2
global DisableHotkey := "^!m"      ; 临时关闭快捷键
global InjectMode := "paste"       ; 注入方式：paste（预留 type/auto）
global SettingTheme := "auto"      ; 兼容旧变量名（未使用）
global Theme := "auto"             ; 外观：auto（跟随系统）| light | dark
global ConfigEnabled := true       ; 配置文件里的启用状态（页面开关写入）
global LastConfigEnabled := true
global IniStamp := ""              ; 配置文件修改时间（变更检测）

; ------------------------------ 运行状态 ------------------------------
global VoiceEnabled := true        ; 语音输入启用状态（暂停开关）
global isRecording := false
global OverlayGui := ""
global OverlayTextCtl := ""
global RecordingStartTick := 0
global ServerMonitorFails := 0
global LevelTick := 0
global LastLevelDb := 0
global LowLevelWarned := false
global DeviceKind := ""
global CurrentTrigger := ""
global CurrentDisable := ""
global TriggerMenu := ""
global StateHeartbeat := 0

global VOICE_DIR := A_ScriptDir
global SERVER_PY := VOICE_DIR . "\voice_server.py"
global PYTHONW := VOICE_DIR . "\.venv\Scripts\pythonw.exe"
global LOGFILE := VOICE_DIR . "\voice_server.log"

LoadConfig()
LastConfigEnabled := ConfigEnabled
VoiceEnabled := ConfigEnabled
try IniStamp := FileGetTime(IniPath, "M")
ApplyTheme()
ApplyOverlayConfig()
ApplyTrayIcon()
RegisterTrigger()
RegisterDisableHotkey()
CheckElevation()
BuildTray()
UpdateTrayTip()
WriteStateFile()

; 使用自定义托盘图标（安装时生成，缺失则用默认）
ApplyTrayIcon() {
    global VOICE_DIR
    icon := VOICE_DIR . "\assets\voice.ico"
    if FileExist(icon) {
        try TraySetIcon(icon)
    }
}

; ------------------------------ 配置读写 ------------------------------
LoadConfig() {
    global HoldMs, AutoSubmit, RestoreClipboard, TargetWindows, Port, ServerTask, HotkeyTask
    global OverlayEnabled, OverlayOffsetY, OverlayMaxChars, OverlayPollMs
    global MaxRecordSeconds, TriggerKey, DisableHotkey, InjectMode, Theme, ConfigEnabled
    global IniPath
    HoldMs := Integer(IniRead(IniPath, "hotkey", "hold_ms", "350"))
    if (HoldMs < 80 or HoldMs > 5000)
        HoldMs := 350
    AutoSubmit := IniRead(IniPath, "hotkey", "auto_submit", "0") = "1"
    RestoreClipboard := IniRead(IniPath, "hotkey", "restore_clipboard", "1") = "1"
    Port := Integer(IniRead(IniPath, "voice", "port", "17860"))
    rawTargets := IniRead(IniPath, "hotkey", "targets", "*")
    list := []
    for item in StrSplit(rawTargets, "|") {
        item := Trim(item)
        if (item != "")
            list.Push(item)
    }
    if (list.Length = 0)
        list.Push("*")
    TargetWindows := list
    ServerTask := Trim(IniRead(IniPath, "tasks", "server_task", ""))
    HotkeyTask := Trim(IniRead(IniPath, "tasks", "hotkey_task", ""))
    OverlayEnabled := IniRead(IniPath, "overlay", "enabled", "1") = "1"
    OverlayOffsetY := Integer(IniRead(IniPath, "overlay", "offset_y", "120"))
    OverlayMaxChars := Integer(IniRead(IniPath, "overlay", "max_chars", "200"))
    OverlayPollMs := Integer(IniRead(IniPath, "overlay", "poll_ms", "150"))
    if (OverlayPollMs < 100)
        OverlayPollMs := 150
    if (OverlayMaxChars < 20)
        OverlayMaxChars := 200
    MaxRecordSeconds := Integer(IniRead(IniPath, "voice", "max_record_seconds", "60"))
    if (MaxRecordSeconds < 5 or MaxRecordSeconds > 600)
        MaxRecordSeconds := 60
    TriggerKey := Trim(IniRead(IniPath, "hotkey", "trigger", "enter"))
    if (TriggerKey != "xbutton2")
        TriggerKey := "enter"
    DisableHotkey := Trim(IniRead(IniPath, "hotkey", "disable_hotkey", "^!m"))
    if (DisableHotkey = "")
        DisableHotkey := "^!m"
    InjectMode := Trim(IniRead(IniPath, "hotkey", "inject", "paste"))
    if (InjectMode = "")
        InjectMode := "paste"
    Theme := Trim(IniRead(IniPath, "ui", "theme", "auto"))
    if (Theme != "light" and Theme != "dark")
        Theme := "auto"
    ConfigEnabled := IniRead(IniPath, "hotkey", "enabled", "1") != "0"
}

SaveConfig(values) {
    for section, pairs in values {
        for key, value in pairs
            try IniWrite(value, IniPath, section, key)
    }
    LoadConfig()
    ApplyTheme()
    ApplyOverlayConfig()
    RegisterTrigger()
    RegisterDisableHotkey()
    UpdateTrayTip()
}

; ------------------------------ 触发键 ------------------------------
TriggerKeyName() {
    global TriggerKey
    return (TriggerKey = "xbutton2") ? "XButton2" : "Enter"
}

TriggerKeySpec() {
    global TriggerKey
    return (TriggerKey = "xbutton2") ? "$XButton2" : "$Enter"
}

RegisterTrigger() {
    global CurrentTrigger
    spec := TriggerKeySpec()
    if (CurrentTrigger != "" and CurrentTrigger != spec) {
        try Hotkey(CurrentTrigger, "Off")
        CurrentTrigger := ""
    }
    if (CurrentTrigger = spec)
        return
    try {
        Hotkey(spec, TriggerPressed, "On")
        CurrentTrigger := spec
        WriteStateFile()
    } catch as e {
        ShowTip("注册触发键失败: " . e.Message)
    }
}

ForwardTrigger() {
    global TriggerKey
    if (TriggerKey = "xbutton2")
        Send("{Blind}{XButton2}")
    else
        Send("{Blind}{Enter}")
}

; 触发键按下：短按转发，长按进入语音输入
TriggerPressed(ThisHotkey) {
    global TriggerKey, HoldMs
    if !TargetActive() {
        ForwardTrigger()
        return
    }
    ; 回车 + 修饰键：原样转发（Shift+Enter 换行等）
    if (TriggerKey = "enter" and (GetKeyState("Shift") or GetKeyState("Ctrl") or GetKeyState("Alt"))) {
        Send("{Blind}{Enter}")
        return
    }
    ; 上一段录音还没结束（例如松开事件丢失）→ 本次按下直接收尾，避免卡在"识别中"
    if isRecording {
        FinishRecording()
        return
    }
    if KeyWait(TriggerKeyName(), "T" . (HoldMs / 1000)) {
        ForwardTrigger()
        return
    }
    StartVoiceInput()
}

StartVoiceInput() {
    global isRecording, Port, DeviceKind
    if !ServerAlive(Port) {
        StartServer()
        ShowTip("语音服务正在启动，请几秒后再试（首次需加载模型）")
        SetTimer(HideTip, -5000)
        return
    }
    startResult := Post(Port, "/start")
    if (startResult[1] = 503) {
        ShowTip("语音服务正在加载模型，请稍候几秒再试")
        SetTimer(HideTip, -5000)
        return
    }
    if (startResult[1] != 200) {
        ShowTip("语音服务异常，请查看 voice_server.log")
        SetTimer(HideTip, -5000)
        return
    }
    isRecording := true
    DeviceKind := HttpGet(Port, "/device.txt", 1500)
    ShowOverlay()
    KeyWait(TriggerKeyName())            ; 等物理松开
    FinishRecording()
}

; 备用开关：F8 开始 / 结束（不需要长按，默认可用）
$F8:: {
    global isRecording, DeviceKind
    if !VoiceEnabled
        return
    if isRecording {
        FinishRecording()
        return
    }
    if !ServerAlive(Port) {
        StartServer()
        ShowTip("语音服务正在启动，请几秒后再试")
        SetTimer(HideTip, -5000)
        return
    }
    startResult := Post(Port, "/start")
    if (startResult[1] = 503) {
        ShowTip("语音服务正在加载模型，请稍候几秒再试")
        SetTimer(HideTip, -5000)
        return
    }
    if (startResult[1] = 200) {
        isRecording := true
        DeviceKind := HttpGet(Port, "/device.txt", 1500)
        ShowOverlay("🎤 录音中… 再按 F8 结束")
    }
}

; ------------------------------ 暂停开关 ------------------------------
RegisterDisableHotkey() {
    global DisableHotkey, CurrentDisable, TriggerKey
    spec := DisableHotkey
    if (spec = "")
        spec := "^!m"
    ; 不能与触发键冲突
    if (TriggerKey = "enter" and (spec = "Enter" or spec = "$Enter"))
        spec := "^!m"
    if (CurrentDisable != "" and CurrentDisable != spec) {
        try Hotkey(CurrentDisable, "Off")
        CurrentDisable := ""
    }
    if (CurrentDisable = spec)
        return
    try {
        Hotkey(spec, ToggleVoice, "On")
        CurrentDisable := spec
    } catch as e {
        ShowTip("注册暂停快捷键失败: " . e.Message)
    }
}

ToggleVoice(*) {
    global VoiceEnabled, DisableHotkey
    VoiceEnabled := !VoiceEnabled
    UpdateTrayTip()
    ShowTip(VoiceEnabled ? "🎤 语音输入已恢复" : "⏸ 语音输入已暂停（" . PrettyHotkey(DisableHotkey) . " 恢复）")
    SetTimer(HideTip, -2500)
    WriteStateFile()
}

UpdateTrayTip() {
    global VoiceEnabled, TriggerKey, DisableHotkey
    name := (TriggerKey = "xbutton2") ? "鼠标侧键" : "回车键"
    tip := "OpenCode 语音输入（" . name . "）"
    if !VoiceEnabled
        tip .= " - 已暂停（" . PrettyHotkey(DisableHotkey) . " 恢复）"
    try A_IconTip := tip
}

; ------------------------------ 生效范围 ------------------------------
TargetActive() {
    global VoiceEnabled, TargetWindows
    if !VoiceEnabled
        return false
    for w in TargetWindows {
        if (w = "*")
            return true
        if WinActive(w)
            return true
    }
    return false
}

; ------------------------------ 主流程 ------------------------------
FinishRecording() {
    global isRecording, AutoSubmit, RestoreClipboard, LastLevelDb, LowLevelWarned
    isRecording := false
    StopPartialPolling()
    SetOverlayText("⏳ 转写中…")
    result := Post(Port, "/stop", 60000)
    if (result[1] != 200) {
        msg := result[2] != "" ? result[2] : "无法连接语音服务"
        HideOverlay()
        ShowTip("❌ 转写失败: " . msg)
        SetTimer(HideTip, -6000)
        return
    }
    text := Trim(result[2], " `t`r`n")
    if (text = "") {
        HideOverlay()
        ; 说明原因，便于用户排查（电平过低 / 麦克风问题）
        if (LowLevelWarned or LastLevelDb < -50)
            ShowTip("未识别到语音：输入电平约 " . LastLevelDb . " dBFS，麦克风声音太小`n请调高系统输入音量或靠近麦克风")
        else
            ShowTip("未识别到语音（输入电平约 " . LastLevelDb . " dBFS），请重试或检查麦克风设备")
        SetTimer(HideTip, -6000)
        LowLevelWarned := false
        return
    }
    LowLevelWarned := false
    saved := RestoreClipboard ? ClipboardAll() : ""
    InjectText(text)
    if RestoreClipboard
        SetTimer(() => (A_Clipboard := saved), -900)
    if AutoSubmit {
        Sleep(150)
        Send("{Enter}")
    }
    HideOverlay()
}

; 注入文字：目前使用剪贴板粘贴（预留 type 分支）
InjectText(text) {
    global InjectMode
    if (InjectMode = "type") {
        SendText(text)
        return
    }
    A_Clipboard := text
    Sleep(20)
    Send("^v")
}

; ------------------------------ 实时字幕悬浮窗 ------------------------------
ApplyOverlayConfig() {
    global OverlayGui, OverlayTextCtl, OverlayEnabled
    if OverlayGui {
        try OverlayGui.Destroy()
    }
    OverlayGui := ""
    OverlayTextCtl := ""
    if OverlayEnabled
        CreateOverlay()
}

CreateOverlay() {
    global OverlayGui, OverlayTextCtl, OverlayEnabled
    global C_CARD, C_TEXT, C_SUB
    if !OverlayEnabled
        return
    OverlayGui := Gui("+AlwaysOnTop +ToolWindow -Caption +Border", "OpenCodeVoiceOverlay")
    OverlayGui.BackColor := C_CARD
    FontUI(OverlayGui, "s11", C_TEXT)
    ; 注意：这里不能加 BackgroundTrans —— 透明背景的 Text 控件在改文字时不会擦除旧内容，会出现文字堆叠
    OverlayTextCtl := OverlayGui.AddText("w680 h96 +Wrap", "🎤 识别中…")
    ApplyOverlayStyles(OverlayGui.Hwnd)
    SetWindowDarkMode(OverlayGui.Hwnd, UI_Dark)
    RoundCorners(OverlayGui.Hwnd)
    OverlayGui.Show("Hide")
}

; Windows 11 圆角
RoundCorners(hwnd) {
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33, "int*", 2, "uint", 4)
}

; WS_EX_NOACTIVATE(0x08000000) | WS_EX_TRANSPARENT(0x20)
ApplyOverlayStyles(hwnd) {
    ex := 0
    try
        ex := DllCall("GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")
    catch
        ex := DllCall("GetWindowLongW", "ptr", hwnd, "int", -20, "int")
    ex := ex | 0x08000020
    try
        DllCall("SetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr", ex)
    catch
        DllCall("SetWindowLongW", "ptr", hwnd, "int", -20, "int", ex)
}

ShowOverlay(msg := "") {
    global OverlayGui, OverlayPollMs, RecordingStartTick, LastLevelDb, LowLevelWarned, LevelTick
    if !OverlayGui {
        ShowTip(msg != "" ? msg : "🎤 录音中… 松开结束")
        return
    }
    RecordingStartTick := A_TickCount
    LastLevelDb := 0
    LowLevelWarned := false
    LevelTick := 0
    SetOverlayText(msg != "" ? msg : "🎤 识别中…")
    PositionOverlay()
    try OverlayGui.Show("NoActivate")
    SetTimer(PollPartial, OverlayPollMs)
    SetTimer(AutoStopCheck, 1000)
}

; 录音到达上限自动结束
AutoStopCheck() {
    global MaxRecordSeconds, RecordingStartTick, isRecording
    if !isRecording
        return
    if (A_TickCount - RecordingStartTick >= MaxRecordSeconds * 1000) {
        SetOverlayText("⏱ 已达 " . MaxRecordSeconds . " 秒上限，自动结束")
        Sleep(250)
        FinishRecording()
    }
}

HideOverlay() {
    StopPartialPolling()
    SetTimer(AutoStopCheck, 0)
    global OverlayGui
    if OverlayGui {
        try OverlayGui.Show("Hide")
    }
}

StopPartialPolling() {
    SetTimer(PollPartial, 0)
}

SetOverlayText(text) {
    global OverlayTextCtl, OverlayMaxChars
    if !OverlayTextCtl
        return
    if (StrLen(text) > OverlayMaxChars)
        text := "…" . SubStr(text, -(OverlayMaxChars))
    try {
        ; 由长文本切到短文本时，先清空再写入，确保旧内容被完全擦除（避免文字堆叠）
        if (StrLen(text) < StrLen(OverlayTextCtl.Text))
            OverlayTextCtl.Text := ""
        OverlayTextCtl.Text := text
        ; 防御性重绘
        DllCall("InvalidateRect", "ptr", OverlayTextCtl.Hwnd, "ptr", 0, "int", 1)
    }
}

; 优先锚定当前活动窗口（全局模式）
PositionOverlay() {
    global OverlayGui, OverlayOffsetY, TargetWindows
    if !OverlayGui
        return
    OverlayGui.GetPos(, , &w, &h)
    x := 0
    y := 0
    placed := false
    try {
        hwnd := WinExist("A")
        if hwnd {
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . hwnd)
            x := wx + (ww - w) // 2
            y := wy + wh - h - OverlayOffsetY
            placed := true
        }
    }
    if !placed {
        for target in TargetWindows {
            if (target = "*")
                continue
            try {
                WinGetPos(&wx, &wy, &ww, &wh, target)
                x := wx + (ww - w) // 2
                y := wy + wh - h - OverlayOffsetY
                placed := true
                break
            }
        }
    }
    if !placed {
        x := (A_ScreenWidth - w) // 2
        y := A_ScreenHeight - h - OverlayOffsetY
    }
    if (x < 0)
        x := 0
    if (y < 0)
        y := 0
    try OverlayGui.Move(x, y)
}

PollPartial() {
    global Port, RecordingStartTick, LevelTick, LastLevelDb, LowLevelWarned, DeviceKind
    cpuHint := (DeviceKind = "cpu") ? "（CPU 模式）" : ""
    text := HttpGet(Port, "/partial.txt", 2000)
    if (text = false) {
        SetOverlayText("⚠ 语音服务无响应，正在尝试恢复…")
        return
    }
    text := Trim(text, " `t`r`n")
    if (text != "") {
        SetOverlayText("🎤 " . text)
        return
    }
    elapsed := A_TickCount - RecordingStartTick
    ; 每秒查一次输入电平，用于诊断"没识别到"
    if (elapsed > 1200 and (A_TickCount - LevelTick > 900)) {
        LevelTick := A_TickCount
        lv := HttpGet(Port, "/level.txt", 1500)
        if (lv != false and IsNumber(lv))
            LastLevelDb := Float(lv)
    }
    if (elapsed > 2500) {
        ms := HttpGet(Port, "/audio.txt", 2000)
        if (ms != false and IsNumber(ms) and Integer(ms) < 200) {
            SetOverlayText("⚠ 麦克风没有声音，请检查设备")
            return
        }
        if (LastLevelDb < -50) {
            LowLevelWarned := true
            SetOverlayText("⚠ 麦克风声音太小（" . LastLevelDb . " dBFS）`n请调高输入音量或靠近麦克风")
            return
        }
    }
    if (elapsed > 8000)
        SetOverlayText("🎤 识别中…" . cpuHint . "（还没识别到语音，请用正常音量说话）")
    else
        SetOverlayText("🎤 识别中…" . cpuHint)
}

; ------------------------------ HTTP ------------------------------
ServerAlive(port) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "http://127.0.0.1:" . port . "/health", false)
        req.SetTimeouts(300, 300, 800, 900)
        req.Send()
        return req.Status = 200
    } catch {
        return false
    }
}

HttpGet(port, path, timeoutRecv := 2000) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "http://127.0.0.1:" . port . path, false)
        req.SetTimeouts(300, 300, 1000, timeoutRecv)
        req.Send()
        if (req.Status != 200)
            return false
        return req.ResponseText
    } catch {
        return false
    }
}

Post(port, path, timeoutRecv := 10000) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", "http://127.0.0.1:" . port . path, false)
        req.SetTimeouts(1000, 1000, 3000, timeoutRecv)
        req.SetRequestHeader("Content-Type", "text/plain; charset=utf-8")
        req.Send("")
        return [req.Status, req.ResponseText]
    } catch {
        return [0, ""]
    }
}

StartServer(quiet := false) {
    if VoiceServerRunning() {
        if !quiet {
            ShowTip("语音服务已在启动中，请稍候…")
            SetTimer(HideTip, -5000)
        }
        return false
    }
    if (ServerTask != "") {
        try {
            Run('schtasks.exe /run /tn "' . ServerTask . '"', "", "Hide")
            return true
        } catch {
        }
    }
    if !FileExist(PYTHONW) {
        if !quiet {
            ShowTip("找不到 pythonw: " . PYTHONW)
            SetTimer(HideTip, -6000)
        }
        return false
    }
    try {
        Run('"' . PYTHONW . '" "' . SERVER_PY . '"', VOICE_DIR, "Hide")
        return true
    } catch as e {
        if !quiet {
            ShowTip("启动语音服务失败: " . e.Message)
            SetTimer(HideTip, -6000)
        }
        return false
    }
}

VoiceServerRunning() {
    try {
        wmi := ComObjGet("winmgmts:")
        query := "Select ProcessId from Win32_Process where (Name='pythonw.exe' or Name='python.exe') and CommandLine like '%voice_server.py%'"
        enum := wmi.ExecQuery(query)._NewEnum()
        if enum(&proc)
            return true
    } catch {
        return false
    }
    return false
}

ServerMonitor() {
    global Port, ServerMonitorFails, StateHeartbeat, isRecording, RecordingStartTick, MaxRecordSeconds
    ; 兜底：录音远超上限仍未结束（例如松开事件丢失），强制收尾
    if (isRecording and (A_TickCount - RecordingStartTick) > (MaxRecordSeconds + 15) * 1000)
        FinishRecording()
    if ServerAlive(Port) {
        ServerMonitorFails := 0
    } else {
        ServerMonitorFails += 1
        if (ServerMonitorFails <= 9) {
            if (ServerMonitorFails = 6 and VoiceServerRunning())
                KillVoiceServer()
            StartServer(true)
        }
    }
    ; 定期刷新状态文件（自检脚本据此确认助手存活）
    StateHeartbeat += 1
    if (StateHeartbeat >= 5) {
        StateHeartbeat := 0
        WriteStateFile()
    }
}

KillVoiceServer() {
    pids := []
    try {
        wmi := ComObjGet("winmgmts:")
        query := "Select ProcessId from Win32_Process where (Name='pythonw.exe' or Name='python.exe') and CommandLine like '%voice_server.py%'"
        enum := wmi.ExecQuery(query)._NewEnum()
        while enum(&proc)
            pids.Push(proc.ProcessId)
    } catch {
    }
    for pid in pids {
        try ProcessClose(pid)
    }
    if (pids.Length > 0)
        Sleep(1500)
}

; ------------------------------ 权限 ------------------------------
CheckElevation() {
    if A_IsAdmin
        return
    for w in TargetWindows {
        if (w = "*")
            continue
        try
            pid := WinGetPID(w)
        catch
            continue
        if ProcessIsElevated(pid) {
            ShowTip("检测到目标窗口以管理员身份运行，语音助手权限不足。`n请通过安装器创建的计划任务启动，或右键本脚本『以管理员身份运行』。")
            SetTimer(HideTip, -12000)
            return
        }
    }
}

ProcessIsElevated(pid) {
    h := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr")
    if !h
        return true
    tok := 0
    ok := DllCall("Advapi32\OpenProcessToken", "ptr", h, "uint", 0x0008, "ptr*", &tok)
    DllCall("CloseHandle", "ptr", h)
    if !ok
        return true
    elev := 0
    size := 0
    DllCall("Advapi32\GetTokenInformation", "ptr", tok, "int", 20, "int*", &elev, "uint", 4, "uint*", &size)
    DllCall("CloseHandle", "ptr", tok)
    return elev != 0
}

; ------------------------------ 提示 ------------------------------
ShowTip(msg) {
    ToolTip(msg, A_ScreenWidth // 2 - 200, 60)
    SetTimer(HideTip, -15000)
}

HideTip(*) {
    ToolTip()
}

; ------------------------------ 主题（浅色 / 深色） ------------------------------
global C_BG := "F5F5F7"        ; 窗口背景
global C_CARD := "FFFFFF"      ; 卡片
global C_TEXT := "1D1D1F"      ; 主文字
global C_SUB := "86868B"       ; 次要文字
global C_SEP := "E5E5EA"       ; 分隔线
global C_ACCENT := "0071E3"    ; 强调色
global C_ERROR := "D70015"     ; 错误
global UI_Dark := false        ; 当前是否深色

DetectSystemDark() {
    try
        return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    catch
        return false
}

; 计算当前应使用的主题并刷新配色
ApplyTheme() {
    global Theme, UI_Dark
    global C_BG, C_CARD, C_TEXT, C_SUB, C_SEP, C_ACCENT, C_ERROR
    dark := (Theme = "dark")
    if (Theme = "auto")
        dark := DetectSystemDark()
    UI_Dark := dark
    if dark {
        C_BG := "1C1C1E"
        C_CARD := "2C2C2E"
        C_TEXT := "F5F5F7"
        C_SUB := "98989D"
        C_SEP := "3A3A3C"
        C_ACCENT := "0A84FF"
        C_ERROR := "FF453A"
    } else {
        C_BG := "F5F5F7"
        C_CARD := "FFFFFF"
        C_TEXT := "1D1D1F"
        C_SUB := "86868B"
        C_SEP := "E5E5EA"
        C_ACCENT := "0071E3"
        C_ERROR := "D70015"
    }
    SetAppDarkMode(dark)
}

; 让系统按深色渲染标准控件（uxtheme 未公开序号，Win10 1809+ / Win11 可用）
SetAppDarkMode(enable) {
    try {
        hUx := DllCall("GetModuleHandle", "str", "uxtheme", "ptr")
        if !hUx
            hUx := DllCall("LoadLibrary", "str", "uxtheme", "ptr")
        if !hUx
            return
        addr := DllCall("GetProcAddress", "ptr", hUx, "ushort", 135, "ptr")
        if addr
            DllCall(addr, "int", enable ? 1 : 0, "int")
        flush := DllCall("GetProcAddress", "ptr", hUx, "ushort", 136, "ptr")
        if flush
            DllCall(flush)
    } catch {
    }
}

SetWindowDarkMode(hwnd, enable) {
    try {
        hUx := DllCall("GetModuleHandle", "str", "uxtheme", "ptr")
        if hUx {
            addr := DllCall("GetProcAddress", "ptr", hUx, "ushort", 133, "ptr")
            if addr
                DllCall(addr, "ptr", hwnd, "int", enable ? 1 : 0)
        }
        DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "wstr", enable ? "DarkMode_Explorer" : "Explorer", "wstr", "")
    } catch {
    }
}

; 深色下给输入控件着色（uxtheme 对 Edit/ComboBox 内部不一定生效，这里兜底）
OnMessage(0x0133, WM_CTLCOLOREDIT)
OnMessage(0x0134, WM_CTLCOLORLISTBOX)

WM_CTLCOLOREDIT(wParam, lParam, msg, hwnd) {
    global UI_Dark, C_CARD, C_TEXT
    if !UI_Dark
        return ""
    try {
        DllCall("gdi32\SetTextColor", "ptr", wParam, "uint", BGR(C_TEXT))
        DllCall("gdi32\SetBkColor", "ptr", wParam, "uint", BGR(C_CARD))
        return BrushFor(C_CARD)
    } catch {
        return ""
    }
}

WM_CTLCOLORLISTBOX(wParam, lParam, msg, hwnd) {
    global UI_Dark, C_CARD, C_TEXT
    if !UI_Dark
        return ""
    try {
        DllCall("gdi32\SetTextColor", "ptr", wParam, "uint", BGR(C_TEXT))
        DllCall("gdi32\SetBkColor", "ptr", wParam, "uint", BGR(C_CARD))
        return BrushFor(C_CARD)
    } catch {
        return ""
    }
}

global UI_Brushes := Map()
BrushFor(color) {
    global UI_Brushes
    if UI_Brushes.Has(color)
        return UI_Brushes[color]
    handle := DllCall("gdi32\CreateSolidBrush", "uint", BGR(color), "ptr")
    UI_Brushes[color] := handle
    return handle
}

BGR(rgb) {
    r := Integer("0x" . SubStr(rgb, 1, 2))
    g := Integer("0x" . SubStr(rgb, 3, 2))
    b := Integer("0x" . SubStr(rgb, 5, 2))
    return (b << 16) | (g << 8) | r
}

; ------------------------------ 设置面板（Apple 极简风） ------------------------------
global SettingsWin := ""
global SettingsStatusCtl := ""
global SettingsSubtitleCtl := ""
global SettingsErrorCtl := ""
global SettingsControls := Map()
global MicList := []

FontUI(g, spec := "s10", color := "") {
    text := spec . (color != "" ? " c" . color : "")
    try
        g.SetFont(text, "Segoe UI Variable Text")
    catch
        g.SetFont(text, "Segoe UI")
}

Card(g, x, y, w, h) {
    return g.AddProgress("x" . x . " y" . y . " w" . w . " h" . h . " Background" . C_CARD, 100)
}

CardTitle(g, text, x, y, w := 400) {
    FontUI(g, "s10 Bold", C_TEXT)
    return g.AddText("x" . x . " y" . y . " w" . w . " BackgroundTrans", text)
}

Separator(g, x, y, w) {
    return g.AddProgress("x" . x . " y" . y . " w" . w . " h1 Background" . C_SEP, 100)
}

FieldLabel(g, text, x, y, w := 110) {
    FontUI(g, "s10", C_SUB)
    return g.AddText("x" . x . " y" . (y + 4) . " w" . w . " Right BackgroundTrans", text)
}

Hint(g, text, x, y, w := 330) {
    FontUI(g, "s9", C_SUB)
    return g.AddText("x" . x . " y" . (y + 5) . " w" . w . " BackgroundTrans", text)
}

Unit(g, text, x, y, w := 60) {
    FontUI(g, "s10", C_SUB)
    return g.AddText("x" . x . " y" . (y + 4) . " w" . w . " BackgroundTrans", text)
}

CheckBox(g, text, x, y, w := 330) {
    FontUI(g, "s10", C_TEXT)
    return g.AddCheckbox("x" . x . " y" . y . " w" . w . " BackgroundTrans", text)
}

EditBox(g, x, y, w := 80, value := "") {
    FontUI(g, "s10", C_TEXT)
    return g.AddEdit("x" . x . " y" . y . " w" . w, value)
}

Combo(g, x, y, w := 330, items := []) {
    FontUI(g, "s10", C_TEXT)
    return g.AddDropDownList("x" . x . " y" . y . " w" . w, items)
}

ShowSettings() {
    global HoldMs, MaxRecordSeconds, TriggerKey, DisableHotkey, InjectMode, TargetWindows
    global OverlayEnabled, OverlayOffsetY, OverlayMaxChars, OverlayPollMs
    global AutoSubmit, RestoreClipboard, Port, VoiceEnabled, MicList, Theme
    global SettingsWin, SettingsStatusCtl, SettingsSubtitleCtl, SettingsErrorCtl, SettingsControls
    global C_BG, C_CARD, C_TEXT, C_SUB, C_SEP, C_ACCENT
    global IniPath, UI_Dark

    if IsObject(SettingsWin) {
        try {
            RefreshSettingsStatus()
            SettingsWin.Show("Center")
            return
        } catch {
            SettingsWin := ""
        }
    }

    ApplyTheme()
    g := Gui("+AlwaysOnTop -DPIScale", "OpenCode 语音输入")
    g.MarginX := 0
    g.MarginY := 0
    g.BackColor := C_BG

    ; ---- 顶栏：标题 + 外观选择 ----
    FontUI(g, "s17 Bold", C_TEXT)
    g.AddText("x28 y20 w600 BackgroundTrans", "🎤  语音输入")
    FontUI(g, "s9", C_SUB)
    SettingsSubtitleCtl := g.AddText("x30 y54 w700 BackgroundTrans", "")
    FontUI(g, "s9", C_SUB)
    g.AddText("x850 y32 w80 Right BackgroundTrans", "外观")
    FontUI(g, "s10", C_TEXT)
    ddlTheme := Combo(g, 940, 28, 84, ["跟随系统", "浅色", "深色"])
    ddlTheme.Value := (Theme = "light") ? 2 : ((Theme = "dark") ? 3 : 1)
    ddlTheme.OnEvent("Change", (*) => OnThemeChanged(ddlTheme.Value))

    ; ================= 左列 =================
    ; ---- 触发与开关 ----
    Card(g, 24, 86, 486, 206)
    CardTitle(g, "触发与开关", 48, 104)
    Separator(g, 48, 130, 438)
    FieldLabel(g, "触发键", 48, 146, 92)
    ddlTrigger := Combo(g, 150, 142, 340, ["回车键（默认）", "鼠标侧键"])
    ddlTrigger.Value := (TriggerKey = "xbutton2") ? 2 : 1
    FieldLabel(g, "长按阈值", 48, 184, 92)
    edHold := EditBox(g, 150, 180, 80, String(HoldMs))
    Unit(g, "毫秒", 238, 184)
    FieldLabel(g, "临时关闭", 48, 222, 92)
    hkDisable := g.AddHotkey("x150 y218 w180", DisableHotkey)
    cbEnabled := CheckBox(g, "当前启用语音输入", 344, 222, 150)
    cbEnabled.Value := VoiceEnabled ? 1 : 0

    ; ---- 录音 ----
    Card(g, 24, 304, 486, 210)
    CardTitle(g, "录音", 48, 322)
    Separator(g, 48, 348, 438)
    FieldLabel(g, "最长录音", 48, 364, 92)
    edMax := EditBox(g, 150, 360, 80, String(MaxRecordSeconds))
    Unit(g, "秒", 238, 364)
    FieldLabel(g, "分段时长", 48, 402, 92)
    edSeg := EditBox(g, 150, 398, 80, String(IniRead(IniPath, "voice", "segment_seconds", "5")))
    Unit(g, "秒", 238, 402)
    FieldLabel(g, "麦克风", 48, 440, 92)
    ddlMic := Combo(g, 150, 436, 270, ["系统默认"])
    btnRefreshMic := g.AddButton("x430 y435 w90", "刷新")
    btnRefreshMic.OnEvent("Click", (*) => LoadMicList(ddlMic))
    FieldLabel(g, "识别语言", 48, 478, 92)
    ddlLang := Combo(g, 150, 474, 200, ["自动识别", "中文", "English"])
    lang := IniRead(IniPath, "voice", "language", "")
    ddlLang.Value := (lang = "Chinese") ? 2 : ((lang = "English") ? 3 : 1)

    ; ================= 右列 =================
    ; ---- 注入与范围 ----
    Card(g, 530, 86, 486, 260)
    CardTitle(g, "注入与范围", 554, 104)
    Separator(g, 554, 130, 438)
    FieldLabel(g, "注入方式", 554, 146, 92)
    ddlInject := Combo(g, 656, 142, 336, ["粘贴（剪贴板 + Ctrl+V）"])
    ddlInject.Value := 1
    FieldLabel(g, "生效范围", 554, 184, 92)
    ddlScope := Combo(g, 656, 180, 200, ["所有窗口", "仅 OpenCode", "自定义"])
    scopeIndex := 1
    if (TargetWindows.Length = 1) {
        if (TargetWindows[1] = "ahk_exe OpenCode.exe")
            scopeIndex := 2
        else if (TargetWindows[1] != "*")
            scopeIndex := 3
    } else if (TargetWindows.Length > 1)
        scopeIndex := 3
    ddlScope.Value := scopeIndex
    FieldLabel(g, "自定义窗口", 554, 222, 92)
    edScope := EditBox(g, 656, 218, 336, (scopeIndex = 3) ? JoinList(TargetWindows) : "")
    Hint(g, "例如 ahk_exe notepad.exe|ahk_exe chrome.exe", 554, 252, 430)
    cbSubmit := CheckBox(g, "粘贴后自动回车发送", 554, 282, 220)
    cbSubmit.Value := AutoSubmit ? 1 : 0
    cbRestore := CheckBox(g, "粘贴后恢复原剪贴板", 790, 282, 200)
    cbRestore.Value := RestoreClipboard ? 1 : 0

    ; ---- 悬浮窗 ----
    Card(g, 530, 358, 486, 200)
    CardTitle(g, "悬浮窗", 554, 376)
    Separator(g, 554, 402, 438)
    cbOverlay := CheckBox(g, "显示实时字幕", 554, 418, 220)
    cbOverlay.Value := OverlayEnabled ? 1 : 0
    FieldLabel(g, "距窗口底部", 554, 452, 100)
    edOffset := EditBox(g, 664, 448, 80, String(OverlayOffsetY))
    Unit(g, "像素", 752, 452)
    FieldLabel(g, "最多显示", 554, 490, 100)
    edChars := EditBox(g, 664, 486, 80, String(OverlayMaxChars))
    Unit(g, "字", 752, 490)
    FieldLabel(g, "刷新间隔", 810, 490, 90)
    edPoll := EditBox(g, 908, 486, 70, String(OverlayPollMs))
    Unit(g, "毫秒", 984, 490)
    btnPreview := g.AddButton("x664 y520 w120", "预览悬浮窗")
    btnPreview.OnEvent("Click", (*) => PreviewOverlay())

    ; ---- 状态栏 ----
    Card(g, 24, 576, 992, 54)
    FontUI(g, "s9", C_SUB)
    SettingsStatusCtl := g.AddText("x44 y588 w960 h34 BackgroundTrans", "")
    FontUI(g, "s9", C_ERROR)
    SettingsErrorCtl := g.AddText("x44 y622 w960 h18 BackgroundTrans", "")

    ; ---- 底部按钮 ----
    btnRestart := g.AddButton("x24 y648 w110", "重启服务")
    btnRestart.OnEvent("Click", (*) => RestartServerFromSettings())
    btnLog := g.AddButton("x144 y648 w110", "打开日志")
    btnLog.OnEvent("Click", (*) => Run("notepad.exe `"" . LOGFILE . "`""))
    btnReset := g.AddButton("x676 y648 w100", "恢复默认")
    btnReset.OnEvent("Click", (*) => ResetSettingsToDefault())
    btnCancel := g.AddButton("x786 y648 w100", "取消")
    btnCancel.OnEvent("Click", (*) => g.Hide())
    btnSave := g.AddButton("x896 y648 w120 Default", "保存并应用")
    btnSave.OnEvent("Click", (*) => CollectAndSave())
    FontUI(g, "s10", C_TEXT)
    btnRestart.SetFont("s10 c" . C_TEXT, "Segoe UI Variable Text")
    btnLog.SetFont("s10 c" . C_TEXT, "Segoe UI Variable Text")
    btnReset.SetFont("s10 c" . C_TEXT, "Segoe UI Variable Text")
    btnCancel.SetFont("s10 c" . C_TEXT, "Segoe UI Variable Text")
    btnSave.SetFont("s10 c" . C_ACCENT, "Segoe UI Variable Text")

    SettingsControls := Map(
        "theme", ddlTheme,
        "trigger", ddlTrigger,
        "hold", edHold,
        "disable", hkDisable,
        "enabled", cbEnabled,
        "max", edMax,
        "seg", edSeg,
        "mic", ddlMic,
        "lang", ddlLang,
        "inject", ddlInject,
        "scope", ddlScope,
        "custom", edScope,
        "submit", cbSubmit,
        "restore", cbRestore,
        "overlay", cbOverlay,
        "offset", edOffset,
        "chars", edChars,
        "poll", edPoll
    )

    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())

    SettingsWin := g
    LoadMicList(ddlMic)
    RefreshSettingsStatus()
    g.Show("Center w1040 h700")
    ApplyWindowTheme(g)
    SetTimer(SettingsTick, 2000)
}

; 把深色/浅色应用到窗口与所有控件
ApplyWindowTheme(g) {
    global SettingsControls, UI_Dark
    try SetWindowDarkMode(g.Hwnd, UI_Dark)
    for key, ctl in SettingsControls {
        try SetWindowDarkMode(ctl.Hwnd, UI_Dark)
    }
}

; 外观切换：写配置 → 保存当前改动 → 按新主题重建界面
OnThemeChanged(index) {
    global Theme, IniPath
    Theme := (index = 2) ? "light" : ((index = 3) ? "dark" : "auto")
    try IniWrite(Theme, IniPath, "ui", "theme")
    ApplyTheme()
    ApplyOverlayConfig()
    CollectAndSave(true)
}

RebuildSettingsUI() {
    global SettingsWin, SettingsControls, SettingsStatusCtl, SettingsSubtitleCtl, SettingsErrorCtl
    SetTimer(SettingsTick, 0)
    if IsObject(SettingsWin) {
        try SettingsWin.Destroy()
    }
    SettingsWin := ""
    SettingsControls := Map()
    SettingsStatusCtl := ""
    SettingsSubtitleCtl := ""
    SettingsErrorCtl := ""
    ShowSettings()
}

; AHK 热键写法转成可读文本：^!m -> Ctrl+Alt+M
PrettyHotkey(spec) {
    text := Trim(spec)
    if (text = "")
        return "(未设置)"
    out := ""
    for ch in StrSplit(text) {
        if (ch = "^")
            out .= "Ctrl+"
        else if (ch = "!")
            out .= "Alt+"
        else if (ch = "+")
            out .= "Shift+"
        else if (ch = "#")
            out .= "Win+"
        else
            out .= StrUpper(ch)
    }
    return out
}

SettingsTick() {
    global SettingsWin
    if !IsObject(SettingsWin) {
        SetTimer(SettingsTick, 0)
        return
    }
    try {
        if !WinExist("ahk_id " . SettingsWin.Hwnd) {
            SetTimer(SettingsTick, 0)
            return
        }
    } catch {
        SetTimer(SettingsTick, 0)
        return
    }
    RefreshSettingsStatus()
}

; 读取 /health 的扁平 JSON 字段
HealthField(json, name) {
    if RegExMatch(json, '"' . name . '"\s*:\s*("?)([^",}]*)\1', &m)
        return m[2]
    return ""
}

RefreshSettingsStatus() {
    global SettingsStatusCtl, SettingsSubtitleCtl, Port, TriggerKey, TargetWindows, VoiceEnabled, DisableHotkey
    if !SettingsStatusCtl
        return
    health := HttpGet(Port, "/health", 1500)
    line1 := ""
    if (health = false) {
        line1 := "🔴 语音服务未运行（助手会自动尝试拉起）"
    } else {
        ready := HealthField(health, "ready") = "true"
        flowing := HealthField(health, "audio_flowing") = "true"
        micErr := HealthField(health, "mic_error")
        recording := HealthField(health, "recording") = "true"
        line1 := (ready ? "🟢 服务运行中" : "🟡 正在加载模型…")
        line1 .= flowing ? "   ·   🎤 麦克风有音频" : "   ·   ⚠ 麦克风无音频"
        if (micErr != "" and micErr != "null")
            line1 .= "   ·   ⚠ " . micErr
        if recording
            line1 .= "   ·   ⏺ 录音中"
        line1 .= "   ·   权限：" . (A_IsAdmin ? "管理员" : "普通")
    }
    triggerName := (TriggerKey = "xbutton2") ? "鼠标侧键" : "回车键"
    scopeName := "自定义"
    if (TargetWindows.Length = 1 and TargetWindows[1] = "*")
        scopeName := "所有窗口"
    else if (TargetWindows.Length = 1 and TargetWindows[1] = "ahk_exe OpenCode.exe")
        scopeName := "仅 OpenCode"
    line2 := "触发键：" . triggerName . "   ·   范围：" . scopeName . "   ·   状态：" . (VoiceEnabled ? "已启用" : "已暂停（" . PrettyHotkey(DisableHotkey) . "）")
    try SettingsStatusCtl.Text := line1 . "`n" . line2
    if SettingsSubtitleCtl
        try SettingsSubtitleCtl.Text := "按住 " . triggerName . " 说话，松开自动粘贴；" . PrettyHotkey(DisableHotkey) . " 暂停/恢复"
}

LoadMicList(ddlMic) {
    global MicList, Port
    txt := HttpGet(Port, "/devices.txt", 3000)
    items := ["系统默认"]
    MicList := []
    if (txt != false) {
        for line in StrSplit(txt, "`n") {
            line := Trim(line)
            if (line = "")
                continue
            parts := StrSplit(line, "|", , 2)
            if (parts.Length < 2)
                continue
            MicList.Push({ index: parts[1], name: parts[2] })
            items.Push(parts[2] . "  (#" . parts[1] . ")")
        }
    }
    try {
        ddlMic.Delete()
        ddlMic.Add(items)
        ; 选中当前配置
        spec := Trim(IniRead(IniPath, "voice", "device", ""))
        ddlMic.Value := 1
        if (spec != "") {
            for i, mic in MicList {
                if (mic.index = spec or InStr(mic.name, spec)) {
                    ddlMic.Value := i + 1
                    break
                }
            }
        }
    } catch {
    }
}

MicValueFromIndex(index) {
    global MicList
    if (index <= 1 or index - 1 > MicList.Length)
        return ""
    return MicList[index - 1].index
}

LangValueFromIndex(index) {
    if (index = 2)
        return "Chinese"
    if (index = 3)
        return "English"
    return ""
}

CollectAndSave(quiet := false) {
    global VoiceEnabled, Port, SettingsErrorCtl, SettingsControls, DisableHotkey, Theme

    if !IsObject(SettingsControls) or SettingsControls.Count = 0 {
        SetSettingsError("设置窗口尚未初始化")
        return
    }
    ddlTrigger := SettingsControls["trigger"]
    edHold := SettingsControls["hold"]
    hkDisable := SettingsControls["disable"]
    cbEnabled := SettingsControls["enabled"]
    edMax := SettingsControls["max"]
    edSeg := SettingsControls["seg"]
    ddlMic := SettingsControls["mic"]
    ddlLang := SettingsControls["lang"]
    ddlScope := SettingsControls["scope"]
    edScope := SettingsControls["custom"]
    cbSubmit := SettingsControls["submit"]
    cbRestore := SettingsControls["restore"]
    cbOverlay := SettingsControls["overlay"]
    edOffset := SettingsControls["offset"]
    edChars := SettingsControls["chars"]
    edPoll := SettingsControls["poll"]

    hold := Integer(edHold.Value)
    if (hold < 200 or hold > 800) {
        SetSettingsError("长按阈值请在 200~800 毫秒之间")
        return
    }
    maxSec := Integer(edMax.Value)
    if (maxSec < 5 or maxSec > 600) {
        SetSettingsError("最长录音请在 5~600 秒之间")
        return
    }
    segSec := Integer(edSeg.Value)
    if (segSec < 1 or segSec > 10) {
        SetSettingsError("分段时长请在 1~10 秒之间")
        return
    }
    offset := Integer(edOffset.Value)
    if (offset < 0 or offset > 2000) {
        SetSettingsError("悬浮窗距底部请在 0~2000 像素之间")
        return
    }
    chars := Integer(edChars.Value)
    if (chars < 20 or chars > 2000) {
        SetSettingsError("悬浮窗最多显示字数请在 20~2000 之间")
        return
    }
    poll := Integer(edPoll.Value)
    if (poll < 100 or poll > 2000) {
        SetSettingsError("悬浮窗刷新间隔请在 100~2000 毫秒之间")
        return
    }
    disableKey := Trim(hkDisable.Value)
    if (disableKey = "") {
        SetSettingsError("请设置临时关闭快捷键")
        return
    }
    trigger := (ddlTrigger.Value = 2) ? "xbutton2" : "enter"
    if (trigger = "enter" and (disableKey = "Enter" or disableKey = "$Enter")) {
        SetSettingsError("临时关闭快捷键不能与触发键相同")
        return
    }
    scope := ddlScope.Value
    targets := "*"
    if (scope = 2)
        targets := "ahk_exe OpenCode.exe"
    else if (scope = 3) {
        targets := Trim(edScope.Value)
        if (targets = "") {
            SetSettingsError("自定义范围不能为空，例如 ahk_exe notepad.exe|ahk_exe chrome.exe")
            return
        }
    }
    SetSettingsError("")

    oldTheme := Theme
    newTheme := (SettingsControls["theme"].Value = 2) ? "light" : ((SettingsControls["theme"].Value = 3) ? "dark" : "auto")
    SaveConfig(Map(
        "ui", Map("theme", newTheme),
        "hotkey", Map(
            "trigger", trigger,
            "hold_ms", String(hold),
            "disable_hotkey", disableKey,
            "inject", "paste",
            "targets", targets,
            "auto_submit", cbSubmit.Value ? "1" : "0",
            "restore_clipboard", cbRestore.Value ? "1" : "0"
        ),
        "overlay", Map(
            "enabled", cbOverlay.Value ? "1" : "0",
            "offset_y", String(offset),
            "max_chars", String(chars),
            "poll_ms", String(poll)
        ),
        "voice", Map(
            "max_record_seconds", String(maxSec),
            "segment_seconds", String(segSec),
            "device", MicValueFromIndex(ddlMic.Value),
            "language", LangValueFromIndex(ddlLang.Value)
        )
    ))

    ; 启用/暂停状态即时同步
    wantEnabled := cbEnabled.Value ? true : false
    if (wantEnabled != VoiceEnabled)
        ToggleVoice()

    ; 麦克风/语言改动同步给服务端（立即生效，不用重启）
    ApplyServerConfig()

    RefreshSettingsStatus()
    if !quiet {
        ShowTip("设置已保存并生效")
        SetTimer(HideTip, -2500)
        if IsObject(SettingsWin)
            SettingsWin.Hide()
    }
    if (newTheme != oldTheme)
        SetTimer(RebuildSettingsUI, -80)
}

; 把麦克风/语言/录音相关配置推给服务端（服务端会写回同一份 INI）
ApplyServerConfig() {
    global Port
    device := JsonEscape(IniRead(IniPath, "voice", "device", ""))
    language := JsonEscape(IniRead(IniPath, "voice", "language", ""))
    maxSec := IniRead(IniPath, "voice", "max_record_seconds", "60")
    segSec := IniRead(IniPath, "voice", "segment_seconds", "5")
    body := '{"voice":{"device":"' . device . '","language":"' . language . '","max_record_seconds":"' . maxSec . '","segment_seconds":"' . segSec . '"}}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", "http://127.0.0.1:" . Port . "/config", false)
        req.SetTimeouts(1000, 1000, 3000, 8000)
        req.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        req.Send(body)
    } catch {
    }
}

JsonEscape(text) {
    text := StrReplace(text, '\', '\\')
    text := StrReplace(text, '"', '\"')
    return text
}

SetSettingsError(msg) {
    global SettingsErrorCtl
    if SettingsErrorCtl
        try SettingsErrorCtl.Text := msg
}

ResetSettingsToDefault() {
    global SettingsControls
    if !IsObject(SettingsControls) or SettingsControls.Count = 0
        return
    SettingsControls["theme"].Value := 1
    SettingsControls["trigger"].Value := 1
    SettingsControls["hold"].Value := "350"
    SettingsControls["disable"].Value := "^!m"
    SettingsControls["enabled"].Value := 1
    SettingsControls["max"].Value := "60"
    SettingsControls["seg"].Value := "5"
    SettingsControls["lang"].Value := 1
    SettingsControls["scope"].Value := 1
    SettingsControls["custom"].Value := ""
    SettingsControls["submit"].Value := 0
    SettingsControls["restore"].Value := 1
    SettingsControls["overlay"].Value := 1
    SettingsControls["offset"].Value := "120"
    SettingsControls["chars"].Value := "200"
    SettingsControls["poll"].Value := "150"
    SetSettingsError("已填入默认值，点『保存并应用』生效")
}

PreviewOverlay() {
    global OverlayEnabled
    if !OverlayEnabled {
        SetSettingsError("悬浮窗当前为关闭状态，保存开启后可预览")
        return
    }
    SetOverlayText("🎤 这是实时字幕预览：长按触发键说话，文字会在这里逐段出现")
    PositionOverlay()
    try OverlayGui.Show("NoActivate")
    SetTimer(() => HideOverlay(), -2500)
    SetSettingsError("")
}

RestartServerFromSettings() {
    global Port
    SetSettingsError("正在重启语音服务…")
    KillVoiceServer()
    StartServer(true)
    SetTimer(() => RefreshSettingsStatus(), -3000)
    SetTimer(() => SetSettingsError(""), -4000)
}

JoinList(list) {
    out := ""
    for item in list {
        if (out != "")
            out .= "|"
        out .= item
    }
    return out
}

ServiceStatusText() {
    global Port
    perm := A_IsAdmin ? "管理员" : "普通权限"
    if ServerAlive(Port)
        return "运行中（" . perm . "）"
    return "未运行（" . perm . "）"
}

; ------------------------------ 托盘菜单 ------------------------------
BuildTray() {
    global TriggerMenu
    A_TrayMenu.Delete()
    A_TrayMenu.Add("语音输入：启用/暂停", (*) => ToggleVoice())
    TriggerMenu := Menu()
    TriggerMenu.Add("回车键", (*) => SwitchTrigger("enter"))
    TriggerMenu.Add("鼠标侧键", (*) => SwitchTrigger("xbutton2"))
    A_TrayMenu.Add("触发键", TriggerMenu)
    A_TrayMenu.Add("设置…（推荐）", (*) => OpenSettingsUI())
    A_TrayMenu.Add("经典设置窗口", (*) => ShowSettings())
    A_TrayMenu.Add()
    A_TrayMenu.Add("打开日志", (*) => Run("notepad.exe `"" . LOGFILE . "`""))
    A_TrayMenu.Add("重载配置", (*) => ReloadConfig())
    A_TrayMenu.Add("重载脚本", (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add("以管理员身份重启", (*) => RestartAsAdmin())
    A_TrayMenu.Add("退出", (*) => ExitApp())
    RefreshTrayChecks()
}

RefreshTrayChecks() {
    global VoiceEnabled, TriggerKey, TriggerMenu
    try {
        if VoiceEnabled
            A_TrayMenu.Check("语音输入：启用/暂停")
        else
            A_TrayMenu.Uncheck("语音输入：启用/暂停")
    } catch {
    }
    if IsObject(TriggerMenu) {
        try {
            if (TriggerKey = "xbutton2") {
                TriggerMenu.Check("鼠标侧键")
                TriggerMenu.Uncheck("回车键")
            } else {
                TriggerMenu.Check("回车键")
                TriggerMenu.Uncheck("鼠标侧键")
            }
        } catch {
        }
    }
}

SwitchTrigger(which) {
    global TriggerKey
    SaveConfig(Map("hotkey", Map("trigger", which)))
    RefreshTrayChecks()
    ShowTip((which = "xbutton2") ? "触发键已切换为：鼠标侧键" : "触发键已切换为：回车键")
    SetTimer(HideTip, -2500)
}

ReloadConfig() {
    LoadConfig()
    ApplyOverlayConfig()
    RegisterTrigger()
    RegisterDisableHotkey()
    UpdateTrayTip()
    ShowTip("配置已重载")
    SetTimer(HideTip, -2000)
}

RestartAsAdmin() {
    if A_IsAdmin {
        ShowTip("已经是管理员权限")
        return
    }
    try {
        Run('*RunAs "' . A_AhkPath . '" "' . A_ScriptFullPath . '"')
        ExitApp()
    } catch {
        ShowTip("已取消提权")
    }
}

; 启动时确保语音服务在运行，并周期性监控
if !ServerAlive(Port)
    StartServer()
SetTimer(ServerMonitor, 20000)
SetTimer(WatchExternalChanges, 2000)

; ------------------------------ 外部变更监听 ------------------------------
; 设置页面（网页）或手工编辑 INI 后，助手自动应用；同时处理命令文件
WatchExternalChanges() {
    global IniPath, IniStamp, ConfigEnabled, LastConfigEnabled, VoiceEnabled

    cmdPath := A_ScriptDir . "\voice.command"
    if FileExist(cmdPath) {
        cmd := ""
        try {
            cmd := Trim(FileRead(cmdPath, "UTF-8"))
            if (SubStr(cmd, 1, 1) = Chr(0xFEFF))
                cmd := SubStr(cmd, 2)
            FileDelete(cmdPath)
        } catch {
            cmd := ""
        }
        if (cmd = "preview")
            PreviewOverlay()
        else if (cmd = "reload")
            ApplyExternalConfig()
        else if (SubStr(cmd, 1, 12) = "overlaytext=")
            DebugShowOverlayText(SubStr(cmd, 13))
    }

    try
        stamp := FileGetTime(IniPath, "M")
    catch
        return
    if (stamp = IniStamp)
        return
    IniStamp := stamp
    ApplyExternalConfig()
}

ApplyExternalConfig() {
    global ConfigEnabled, LastConfigEnabled, VoiceEnabled
    LoadConfig()
    ApplyTheme()
    ApplyOverlayConfig()
    RegisterTrigger()
    RegisterDisableHotkey()
    UpdateTrayTip()
    RefreshTrayChecks()
    if (ConfigEnabled != LastConfigEnabled) {
        LastConfigEnabled := ConfigEnabled
        VoiceEnabled := ConfigEnabled
        UpdateTrayTip()
        RefreshTrayChecks()
        ShowTip(VoiceEnabled ? "🎤 语音输入已启用" : "⏸ 语音输入已暂停")
        SetTimer(HideTip, -2000)
    }
    WriteStateFile()
}

; 把当前生效状态写到 voice.state（供诊断与设置页确认）
WriteStateFile() {
    global TriggerKey, Theme, VoiceEnabled, CurrentTrigger, CurrentDisable, OverlayEnabled, Port
    text := "applied=" . FormatTime(, "HH:mm:ss") . "`n"
        . "port=" . Port . "`n"
        . "trigger=" . TriggerKey . "`n"
        . "theme=" . Theme . "`n"
        . "enabled=" . (VoiceEnabled ? "1" : "0") . "`n"
        . "overlay=" . (OverlayEnabled ? "1" : "0") . "`n"
        . "hotkey=" . CurrentTrigger . "`n"
        . "disable_hotkey=" . CurrentDisable . "`n"
    path := A_ScriptDir . "\voice.state"
    try FileDelete(path)
    try FileAppend(text, path, "UTF-8")
}

; 调试/测试：直接让悬浮窗显示指定文字（用于验证重绘不堆叠）
DebugShowOverlayText(text) {
    global OverlayGui
    if !OverlayGui
        return
    SetOverlayText(text)
    PositionOverlay()
    try OverlayGui.Show("NoActivate")
    SetTimer(() => HideOverlay(), -8000)
}

; ------------------------------ 打开设置界面（网页版） ------------------------------
FindEdge() {
    candidates := []
    candidates.Push(A_ProgramFiles . "\Microsoft\Edge\Application\msedge.exe")
    pf86 := EnvGet("ProgramFiles(x86)")
    if (pf86 != "")
        candidates.Push(pf86 . "\Microsoft\Edge\Application\msedge.exe")
    localAppData := EnvGet("LOCALAPPDATA")
    if (localAppData != "")
        candidates.Push(localAppData . "\Microsoft\Edge\Application\msedge.exe")
    for path in candidates {
        if (path != "" and FileExist(path))
            return path
    }
    return ""
}

OpenSettingsUI() {
    global Port
    if !ServerAlive(Port) {
        StartServer()
        loop 40 {
            Sleep 500
            if ServerAlive(Port)
                break
        }
    }
    url := "http://127.0.0.1:" . Port . "/settings"
    edge := FindEdge()
    if (edge != "") {
        try {
            Run('"' . edge . '" --app=' . url . ' --window-size=1000,900')
            return
        } catch {
        }
    }
    try {
        Run(url)
        return
    } catch {
    }
    ShowSettings()
}
