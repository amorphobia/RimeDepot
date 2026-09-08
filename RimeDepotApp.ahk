/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#Requires AutoHotkey v2.0
#SingleInstance Ignore

#Include RimeDepot.ahk
#Include RimeDepotGui.ahk

global RimeDepotAppGui := 0

try {
    RimeDepotAppMain()
} catch as err {
    RimeDepotAppReportError(err)
    ExitApp(1)
}

RimeDepotAppMain() {
    global RimeDepotAppGui
    local settings_path := A_ScriptDir . "\RimeDepot.ini"
    local settings := RimeDepotGuiSettings.Load(settings_path)
    local service := RimeDepotService(settings.ToMap(), settings_path)

    RimeDepotAppGui := RimeDepotGui(service, settings, settings_path)
    OnExit(RimeDepotAppOnExit)
    Persistent(true)
    RimeDepotAppGui.Show()
}

RimeDepotAppOnExit(*) {
    global RimeDepotAppGui
    try {
        if IsObject(RimeDepotAppGui) {
            RimeDepotAppGui.Dispose()
            RimeDepotAppGui := 0
        }
    } catch as err {
        RimeDepotAppReportError(err)
    }
}

RimeDepotAppReportError(err) {
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
