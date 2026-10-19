#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()
; ============================================================================
;  鼠标宏心跳  v2.1  (AutoHotkey v2.0)
;  ---------------------------------------------------------------
;  任何宏软件（罗技 G HUB、雷云、iCUE、SteelSeries GG、国产驱动、开源替代）
;  只要在【循环宏】里插入一步「按一下 F8」，桌面角标就实时显示宏的开/关。
;
;  状态：绿底「宏：开」/ 橙底「宏：关」/ 灰底「宏：待机」/ 红底「未提权」
;  自检：按 F9 相当于模拟收到一次信号
;  日志：脚本同目录 signal.log（看 RX 行判断信号有没有进来）
;
;  ⚠ 本工具需要管理员权限 + 全局键盘钩子，部分游戏反作弊可能敏感，
;    竞技类网游请谨慎使用、风险自负。
; ============================================================================


; ############################################################################
; ##                        配置区（只改这里）                                ##
; ############################################################################

; ---- 信号键：宏动作列表里那个用来发信号的键 ----
SignalKey := "F8"

; ---- 信号键是否透传给游戏 ----
; false = 吞掉（游戏收不到，推荐） / true = 透传
PassThroughSignalKey := false

; ---- 超时阈值自动测算 ----
; true  = 按「最近 5 次间隔的中位数 × TimeoutFactor + TimeoutPadMs」自动计算
; false = 固定使用 F8Timeout
AutoTimeout := true

; ---- 固定超时阈值（毫秒），仅 AutoTimeout=false 时生效 ----
; 公式：阈值 = 宏一轮时长 + 2000
F8Timeout := 8000

; ---- 自动测算系数 ----
TimeoutFactor := 1.05
TimeoutPadMs  := 400

; ---- 提示音 ----
SoundOn := true

; ---- 手动自检键（留空 "" 可关闭） ----
SelfTestKey := "F9"

; ---- 角标位置 ----
; OsdCorner: "BR" 右下 / "BL" 左下 / "TR" 右上 / "TL" 左上
OsdCorner   := "BR"
OsdMarginX  := 24          ; 距屏幕边缘（水平，像素）
OsdMarginY  := 12          ; 距屏幕边缘（垂直，像素）
OsdFontSize := 19
OsdShowIdle := true        ; 待机时是否显示角标

; ---- 多显示器 ----
FollowForegroundMonitor := true   ; 角标跟随当前活动窗口所在显示器
MonitorIndex := 1                 ; 不跟随时固定用第几个显示器

; ---- 权限 ----
AutoElevate := true        ; 权限不足时自动以管理员身份重启（弹一次 UAC）

; ---- 日志 ----
LogEnabled := true         ; 写 signal.log（目录不可写时自动改到临时目录）

; ############################################################################
; ##                      以下一般不用改                                     ##
; ############################################################################

; ---- 配色（RGB 顺序）----
COLOR_IDLE_BG := "101318", COLOR_IDLE_FG := "FFFFFF"   ; 待机：近黑 + 白字
COLOR_ON_BG   := "052E18", COLOR_ON_FG   := "39FF6E"   ; 开：深绿 + 亮绿
COLOR_OFF_BG  := "3B2A12", COLOR_OFF_FG  := "FFA028"   ; 关：深褐 + 亮橙
COLOR_ERR_BG  := "2A0A0A", COLOR_ERR_FG  := "FF5A5A"   ; 未提权：深红 + 亮红

OSD_TITLE := "鼠标宏心跳"
OSD_ALPHA := 245           ; 0-255
osdW := 124                ; 逻辑尺寸（高 DPI 会放大，脚本按真实尺寸重算位置）
osdH := 36

; ---- 运行状态 ----
macroOn := false
lastSignal := 0
justResumed := false
everSignal := false
ivHist := []
timeoutNow := F8Timeout
osdVisible := true
osdHwnd := 0
realW := osdW
realH := osdH
og := ""
logPath := ""
paused := false


; ============================================================================
; 启动
; ============================================================================
LogInit()

; ---- 权限自检 ----
if (!A_IsAdmin && AutoElevate) {
    isRetry := false
    if (A_Args.Length > 0 && A_Args[1] = "--elevated")
        isRetry := true
    if (!isRetry) {
        ; 兼容两种形态：解释器跑 .ahk，或编译成 .exe
        exe := A_AhkPath
        if (exe = "")
            exe := A_ScriptFullPath
        try {
            Run('*RunAs "' . exe . '" "' . A_ScriptFullPath . '" --elevated')
            Log("RELAUNCH elevated -> exit")
            ExitApp()
        } catch {
            Log("RELAUNCH denied by user")
        }
    }
}
if (!A_IsAdmin)
    Log("WARN 未提权：如果游戏以管理员运行，脚本将收不到任何按键")

BuildOsd()
BuildTray()

; ---- 热键 ----
signalHotkey := (PassThroughSignalKey ? "~" : "") . "*" . SignalKey
hotkeyOK := true
try {
    Hotkey(signalHotkey, OnSignal)
} catch {
    hotkeyOK := false
}
if (SelfTestKey != "") {
    try
        Hotkey("*" . SelfTestKey, OnSelfTest)
}

; ---- 定时器 ----
SetTimer(CheckSignal, 250)          ; 心跳判定
SetTimer(WatchMonitor, 3000)        ; 跟随显示器
SetTimer(FirstRunHint, -45000)      ; 45 秒还没信号就提示

Log("READY hotkey=" . signalHotkey . " ok=" . hotkeyOK . " autoTimeout=" . AutoTimeout
    . " initTimeout=" . F8Timeout)
if (!hotkeyOK)
    TrayTip("信号键 " . SignalKey . " 注册失败，可能被别的软件占用。请改用其它键（SignalKey）。"
          , OSD_TITLE, 8)
return


; ============================================================================
; 角标
; ============================================================================
BuildOsd() {
    global og, osdHwnd, osdVisible, realW, realH, osdW, osdH
    global OSD_TITLE, OSD_ALPHA, OsdFontSize, OsdShowIdle
    global COLOR_IDLE_BG, COLOR_IDLE_FG, COLOR_ERR_BG, COLOR_ERR_FG

    og := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20", OSD_TITLE)
    og.BackColor := COLOR_IDLE_BG
    og.SetFont("s" . OsdFontSize . " w700 c" . COLOR_IDLE_FG, "Microsoft YaHei")
    og.AddText("vStatusText x0 y0 w" . osdW . " h" . osdH . " Center", "宏：待机")
    og.Show("NoActivate w" . osdW . " h" . osdH . " x100 y100")
    osdHwnd := og.Hwnd

    ; 取真实渲染尺寸（不同 DPI 缩放下 w/h 会被系统缩放）
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . osdHwnd)
    if (ww >= 1)
        realW := ww
    if (wh >= 1)
        realH := wh

    ; 关键：必须按 hwnd 操作。写 Gui 控件名（如 "OSD"）匹配不到窗口，
    ;       会导致半透明 / LAYERED / 点击穿透 全部静默失效。
    WinSetTransparent(OSD_ALPHA, "ahk_id " . osdHwnd)
    WinSetExStyle("+0x80020", "ahk_id " . osdHwnd)     ; WS_EX_LAYERED | WS_EX_TRANSPARENT
    ex := WinGetExStyle("ahk_id " . osdHwnd)

    UpdateOsdPos()

    if (!A_IsAdmin) {
        og.BackColor := COLOR_ERR_BG
        og["StatusText"].SetFont("c" . COLOR_ERR_FG)
        og["StatusText"].Text := "未提权"
    } else if (!OsdShowIdle) {
        og.Hide()
        osdVisible := false
    }
    Log("OSD hwnd=" . osdHwnd . " ex=" . ex . " size=" . realW . "x" . realH)
}

UpdateOsdPos() {
    global osdHwnd, realW, realH
    global OsdCorner, OsdMarginX, OsdMarginY

    GetWorkArea(&workL, &workT, &workR, &workB)
    if (OsdCorner = "BL" || OsdCorner = "TL")
        osdX := workL + OsdMarginX
    else
        osdX := workR - OsdMarginX - realW
    if (OsdCorner = "TR" || OsdCorner = "TL")
        osdY := workT + OsdMarginY
    else
        osdY := workB - OsdMarginY - realH

    ; 越界钳制
    if (osdX < workL)
        osdX := workL
    if (osdY < workT)
        osdY := workT
    if (osdX + realW > workR)
        osdX := workR - realW
    if (osdY + realH > workB)
        osdY := workB - realH

    if (osdHwnd)
        WinMove(osdX, osdY, , , "ahk_id " . osdHwnd)
}

; 取目标显示器的工作区（已排除任务栏）
GetWorkArea(&workL, &workT, &workR, &workB) {
    global FollowForegroundMonitor, MonitorIndex

    workL := 0, workT := 0
    workR := A_ScreenWidth, workB := A_ScreenHeight

    if (FollowForegroundMonitor) {
        fg := DllCall("GetForegroundWindow", "Ptr")
        hMon := DllCall("MonitorFromWindow", "Ptr", fg, "UInt", 2, "Ptr")   ; NEAREST
        if (hMon) {
            mi := Buffer(40, 0)                 ; MONITORINFO
            NumPut("UInt", 40, mi, 0)           ; cbSize
            if DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi) {
                workL := NumGet(mi, 20, "Int"), workT := NumGet(mi, 24, "Int")
                workR := NumGet(mi, 28, "Int"), workB := NumGet(mi, 32, "Int")
                return
            }
        }
    }

    count := MonitorGetCount()
    idx := MonitorIndex
    if (idx < 1 || idx > count)
        idx := 1
    MonitorGetWorkArea(idx, &workL, &workT, &workR, &workB)
}

ShowOsd() {
    global og, osdVisible
    if (!osdVisible && IsObject(og)) {
        og.Show("NoActivate")
        osdVisible := true
    }
}

SetOsdState(state) {
    global og
    global COLOR_ON_BG, COLOR_ON_FG, COLOR_OFF_BG, COLOR_OFF_FG
    global COLOR_IDLE_BG, COLOR_IDLE_FG

    if (!IsObject(og))
        return
    if (state = "on")
        TraySetIcon("imageres.dll", 102)          ; 开：绿色盾牌+对勾
    else if (state = "off")
        TraySetIcon("imageres.dll", 94)           ; 关：红色圆圈叉
    else
        TraySetIcon("imageres.dll", 95)           ; 待机：蓝色问号
    if (state = "on") {
        og.BackColor := COLOR_ON_BG
        og["StatusText"].SetFont("c" . COLOR_ON_FG)
        og["StatusText"].Text := "宏：开"
    } else if (state = "off") {
        og.BackColor := COLOR_OFF_BG
        og["StatusText"].SetFont("c" . COLOR_OFF_FG)
        og["StatusText"].Text := "宏：关"
    } else {
        og.BackColor := COLOR_IDLE_BG
        og["StatusText"].SetFont("c" . COLOR_IDLE_FG)
        og["StatusText"].Text := "宏：待机"
    }
}

Beep(freq) {
    global SoundOn
    if (SoundOn)
        SoundBeep(freq, 140)
}


; ============================================================================
; 托盘菜单
; ============================================================================
BuildTray() {
    global OSD_TITLE, SignalKey

    TraySetIcon("imageres.dll", 95)          ; 待机：蓝色问号
    A_IconTip := OSD_TITLE . " — 信号键 " . SignalKey
    m := A_TrayMenu
    m.Delete()
    m.Add("显示 / 隐藏角标", ToggleOsd)
    m.Add("暂停 / 恢复提醒", TogglePause)
    m.Add()
    m.Add("打开日志", OpenLog)
    m.Add("打开说明", OpenReadme)
    m.Add("重载脚本", ReloadScript)
    m.Add("退出", QuitScript)
    m.Default := "显示 / 隐藏角标"
}

ToggleOsd(*) {
    global og, osdVisible
    if (osdVisible) {
        og.Hide()
        osdVisible := false
    } else {
        og.Show("NoActivate")
        osdVisible := true
    }
}

TogglePause(*) {
    global paused, OSD_TITLE, SignalKey
    paused := !paused
    if (paused) {
        Suspend(true)
        A_IconTip := OSD_TITLE . " — 已暂停"
    } else {
        Suspend(false)
        A_IconTip := OSD_TITLE . " — 信号键 " . SignalKey
    }
}

OpenLog(*) {
    global logPath, LogEnabled, OSD_TITLE
    if (logPath != "" && FileExist(logPath))
        Run('notepad.exe "' . logPath . '"')
    else
        MsgBox("还没有日志文件。`n日志开关 LogEnabled = " . LogEnabled, OSD_TITLE, 64)
}

OpenReadme(*) {
    global logPath, OSD_TITLE, SignalKey
    readme := A_ScriptDir . "\README.md"
    if FileExist(readme)
        Run('notepad.exe "' . readme . '"')
    else
        MsgBox("同目录下没有 README.md。`n`n信号键：" . SignalKey . "`n日志：" . logPath, OSD_TITLE, 64)
}

ReloadScript(*) {
    Reload()
}

QuitScript(*) {
    ExitApp()
}


; ============================================================================
; 心跳逻辑
; ============================================================================
OnSignal(*) {
    global lastSignal, justResumed, macroOn, everSignal, ivHist
    global AutoTimeout, TimeoutFactor, TimeoutPadMs, timeoutNow

    if (lastSignal > 0 && !justResumed) {
        iv := A_TickCount - lastSignal
        if (iv >= 200 && iv <= 60000) {          ; 只接受 0.2s ~ 60s
            ivHist.Push(iv)
            if (ivHist.Length > 5)
                ivHist.RemoveAt(1)
            Log("INTERVAL " . iv . "ms  (最近 " . ivHist.Length . " 次)")

            if (AutoTimeout) {
                med := Median(ivHist)
                newTimeout := Round(med * TimeoutFactor) + TimeoutPadMs
                if (newTimeout < 2000)
                    newTimeout := 2000
                if (newTimeout > 60000)
                    newTimeout := 60000
                if (newTimeout != timeoutNow) {
                    timeoutNow := newTimeout
                    Log("AUTO timeout -> " . timeoutNow . "ms  (中位数 " . med
                        . "ms × " . TimeoutFactor . " + " . TimeoutPadMs . ")")
                }
            }
        }
    }
    justResumed := false
    lastSignal := A_TickCount
    everSignal := true

    if (!macroOn) {
        macroOn := true
        Log("RX signal -> ON  (timeout=" . timeoutNow . "ms)")
        Beep(1300)
        SetOsdState("on")
        ShowOsd()
    }
}

CheckSignal() {
    global macroOn, lastSignal, timeoutNow, justResumed

    if (macroOn && (A_TickCount - lastSignal > timeoutNow)) {
        macroOn := false
        justResumed := true
        Log("TIMEOUT " . (A_TickCount - lastSignal) . "ms > " . timeoutNow . "ms -> OFF")
        Beep(650)
        SetOsdState("off")
        ShowOsd()
    }
}

WatchMonitor() {
    UpdateOsdPos()
}

FirstRunHint() {
    global everSignal, SignalKey, OSD_TITLE
    if (!everSignal) {
        Log("HINT 45 秒内没收到任何 " . SignalKey . " 信号")
        TrayTip("还没收到 " . SignalKey . " 信号：请确认宏动作列表里已添加「键盘按键 "
              . SignalKey . "」，且每轮循环只发一次。`n`n详情见 signal.log", OSD_TITLE, 10)
    }
}

OnSelfTest(*) {
    global lastSignal, macroOn, everSignal, timeoutNow, SelfTestKey
    Log("SELFTEST (" . SelfTestKey . ")  timeout=" . timeoutNow . "ms")
    lastSignal := A_TickCount
    macroOn := true
    everSignal := true
    SetOsdState("on")
    ShowOsd()
    Beep(1300)
}


; ============================================================================
; 工具函数
; ============================================================================
LogInit() {
    global logPath, LogEnabled
    if (!LogEnabled)
        return

    logPath := A_ScriptDir . "\signal.log"
    ok := true
    try {
        if FileExist(logPath)
            FileDelete(logPath)
        FileAppend(A_Now . "  --- session start ---`n", logPath, "UTF-8")
        if (!FileExist(logPath))
            ok := false
    } catch {
        ok := false
    }
    if (!ok) {
        ; 脚本目录不可写（放在 Program Files / 只读介质），退到临时目录
        logPath := A_Temp . "\鼠标宏心跳.log"
    }
    Log("BOOT admin=" . A_IsAdmin . " v" . A_AhkVersion . " screen=" . A_ScreenWidth
        . "x" . A_ScreenHeight . " dpi=" . A_ScreenDPI . " log=" . logPath)
}

Log(msg) {
    global logPath, LogEnabled
    if (!LogEnabled || logPath = "")
        return
    try {
        if (FileExist(logPath) && FileGetSize(logPath) > 500000)
            FileDelete(logPath)
        FileAppend(A_Now . "." . A_MSec . "  " . msg . "`n", logPath, "UTF-8")
    } catch {
    }
}

; 中位数（短数组专用插入排序）
Median(arr) {
    n := arr.Length
    if (!n)
        return 0
    a := arr.Clone()
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if (a[j] > a[j + 1]) {
                t := a[j], a[j] := a[j + 1], a[j + 1] := t
            }
        }
    }
    if (Mod(n, 2))
        return a[(n + 1) // 2]
    return Round((a[n // 2] + a[n // 2 + 1]) / 2)
}
