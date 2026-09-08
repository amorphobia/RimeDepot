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
    RimeDepotGuiMiniProbeMain()
    ExitApp(0)
} catch as err {
    message := "Uncaught exception: " . err.Message . "`n"
    if HasProp(err, "What") {
        message .= "  at " . err.What . "`n"
    }
    if HasProp(err, "File") {
        message .= "  Location: " . err.File
        if HasProp(err, "Line") {
            message .= ":" . err.Line
        }
        message .= "`n"
    }
    if HasProp(err, "Stack") {
        message .= "Stack:`n" . err.Stack . "`n"
    }
    FileAppend(message, "*")
    ExitApp(1)
}

RimeDepotGuiMiniProbeMain() {
    local probe_path := A_Temp . "\RimeDepotGuiProbe-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt") . "-" . Random(100000, 999999) . ".txt"
    try {
        FileAppend("mini-core`n", probe_path)
    } finally {
        if FileExist(probe_path) {
            try FileDelete(probe_path)
        }
    }
}
