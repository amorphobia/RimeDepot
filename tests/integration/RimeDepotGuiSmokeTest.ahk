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

#Include ..\support\TestCommon.ahk
#Include ..\..\RimeDepotGui.ahk

try {
    RimeDepotGuiSmokeMain()
} catch as err {
    RimeDepotGuiSmokeReportError(err)
    ExitApp(1)
}

RimeDepotGuiSmokeMain() {
    RunTest("RimeDepot GUI constructs with injected service", RimeDepotGuiSmokeConstruction.Bind())
    RunTest("RimeDepot GUI loads a fake catalog asynchronously", RimeDepotGuiSmokeCatalog.Bind())
    ExitApp(0)
}

RimeDepotGuiSmokeConstruction() {
    local settings := RimeDepotGuiSettings(Map(
        "CachePath", "C:\\Temp\\RimeDepot-cache",
        "RimeDirectory", "C:\\Temp\\Rime",
        "RppiIndexUrl", "https://example.invalid/index.yaml",
        "Proxy", "",
        "UseGit", false,
        "GitPath", ""
    ))
    local gui := RimeDepotGui(RimeDepotGuiFakeService(), settings, A_Temp . "\\RimeDepot-GuiSmoke.ini")
    try {
        AssertTrue(IsObject(gui.catalog_list), "The catalog ListView was not created.")
        AssertTrue(IsObject(gui.cache_path_edit), "The cache-path editor was not created.")
        AssertTrue(!gui.use_git_checkbox.Value, "Git must be disabled by default in this fixture.")
        AssertTrue(!gui.git_path_edit.Enabled, "Git path must be disabled when Git is disabled.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeCatalog() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local start_time := A_TickCount
    try {
        AssertTrue(gui.StartCatalogLoad(false), "The fake catalog job did not start.")
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy, "The fake catalog job did not complete.")
        AssertEqual(1, gui.catalog_entries.Length, "The GUI did not receive the fake catalog entry.")
        AssertEqual("Fake scheme", gui.catalog_list.GetText(1, 2), "The catalog row has the wrong scheme name.")
        gui.catalog_list.Modify(1, "Select")
        ; A hidden ListView does not dispatch ItemSelect consistently on all
        ; Windows versions; invoke the same handler explicitly for a
        ; deterministic smoke check without showing a GUI.
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        Sleep(20)
        AssertTrue(
            InStr(gui.detail_dependencies.Value, "base") > 0,
            "The dependency detail was not populated."
        )
    } finally {
        gui.Dispose()
    }
}

class RimeDepotGuiFakeService {
    __New() {
        this.config := 0
        this.jobs := []
    }

    Configure(values) {
        this.config := values
    }

    LoadCatalog(callbacks) {
        local job := RimeDepotGuiFakeJob(callbacks)
        this.jobs.Push(job)
        SetTimer(job.Deliver.Bind(job), -30)
        return job
    }

    RefreshCatalog(callbacks) {
        return this.LoadCatalog(callbacks)
    }

    InstallEntry(entry, callbacks) {
        return this.LoadCatalog(callbacks)
    }
}

class RimeDepotGuiFakeJob {
    __New(callbacks) {
        this.callbacks := callbacks
        this.cancelled := false
        this.delivered := false
        this.delivery_callback := this.Deliver.Bind(this)
    }

    Deliver(*) {
        local entry
        if this.cancelled || this.delivered {
            return
        }
        this.delivered := true
        entry := {
            category_path: "demo",
            name: "Fake scheme",
            repo: "https://example.invalid/rime/fake",
            branch: "main",
            schemas: ["fake.schema"],
            dependencies: ["base"],
            reverseDependencies: ["fake-child"],
            labels: ["smoke-test"],
            license: "MIT"
        }
        this.callbacks.ReportProgress(this, {percent: 50, message: "fake progress"})
        this.callbacks.ReportComplete(this, [entry])
    }

    Cancel() {
        this.cancelled := true
    }
}

RimeDepotGuiSmokeReportError(err) {
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
