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

#Include ..\RimeDepot.ahk
#Include ..\RimeDepotGui.ahk

try {
    FileAppend("RimeDepot GUI facade loaded`n", "*")
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
