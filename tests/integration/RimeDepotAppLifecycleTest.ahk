/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Requires AutoHotkey v2.0
#SingleInstance Off

#Include ..\..\RimeDepotGui.ahk

try {
    RimeDepotAppLifecycleMain()
} catch as err {
    RimeDepotAppLifecycleReportError(err)
    ExitApp(1)
}

RimeDepotAppLifecycleMain() {
    local app_path := A_ScriptDir . "\\..\\..\\RimeDepotApp.ahk"
    local app_source := FileRead(app_path, "UTF-8")
    local gui := RimeDepotGui(RimeDepotAppLifecycleFakeService(), RimeDepotGuiSettings(),
        A_Temp . "\\RimeDepot-AppLifecycle.ini")
    try {
        ; This harness has two independent checks: source assertions protect
        ; the standalone entry's ownership/lifetime contract, while the
        ; hidden GUI run verifies natural process exit after Destroy().
        RimeDepotAppLifecycleAssert(!RegExMatch(app_source, "mi)^[ \t]*(?!;).*?Persistent\s*\("),
            "RimeDepotApp.ahk still contains an active Persistent() call.")
        RimeDepotAppLifecycleAssert(InStr(app_source, "RimeDepotAppGui := RimeDepotGui(") > 0,
            "RimeDepotApp.ahk no longer constructs the standalone GUI.")
        RimeDepotAppLifecycleAssert(InStr(app_source, "RimeDepotAppGui.Show(") > 0,
            "RimeDepotApp.ahk no longer shows the standalone GUI.")

        ; Exercise the standalone host's non-persistent lifetime without
        ; showing a visible window or starting a real network operation.
        gui.Show("Hide")
        gui.OnClose()
        if !gui.disposed {
            throw Error("The GUI was not disposed by the close path.")
        }
        FileAppend("PASS: app source and standalone GUI close lifecycle`n", "*")
    } finally {
        if IsObject(gui) && !gui.disposed {
            gui.Dispose()
        }
    }
    ; Do not call ExitApp on success: the harness must terminate naturally
    ; after Destroy() once no Persistent() setting or active timer remains.
}

RimeDepotAppLifecycleAssert(condition, message) {
    if !condition {
        throw Error(message)
    }
}

class RimeDepotAppLifecycleFakeService {
    Configure(config) {
        this.config := config
    }
}

RimeDepotAppLifecycleReportError(err) {
    local message := "Uncaught exception: "
    if IsObject(err) && HasProp(err, "Message") {
        message .= err.Message . "`n"
        if HasProp(err, "What") && err.What {
            message .= "  at " . err.What . "`n"
        }
        if HasProp(err, "File") && err.File {
            message .= "  Location: " . err.File
            if HasProp(err, "Line") && err.Line {
                message .= ":" . err.Line
            }
            message .= "`n"
        }
        if HasProp(err, "Stack") && err.Stack {
            message .= "Stack:`n" . err.Stack . "`n"
        }
    } else {
        message .= String(err) . "`n"
    }
    FileAppend(message, "*")
}
