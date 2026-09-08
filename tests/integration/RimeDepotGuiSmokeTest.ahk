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
    RunTest("RimeDepot GUI handles synchronous catalog completion and error", RimeDepotGuiSmokeCatalogSynchronous.Bind())
    RunTest("RimeDepot GUI keeps details for the current selection", RimeDepotGuiSmokeSelection.Bind())
    RunTest("RimeDepot GUI switches RPPI and direct modes", RimeDepotGuiSmokeModes.Bind())
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

RimeDepotGuiSmokeCatalogSynchronous() {
    local service, gui
    service := RimeDepotGuiFakeService(true)
    gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-sync.ini")
    try {
        ; The callback runs before LoadCatalog() returns.  StartCatalogLoad()
        ; must re-check the returned job and clear active_job after assignment.
        AssertTrue(gui.StartCatalogLoad(false), "The synchronous catalog job did not start.")
        AssertTrue(!gui.busy && !IsObject(gui.active_job),
            "Synchronous catalog completion left the GUI busy or active_job set.")
        AssertEqual(1, gui.catalog_entries.Length,
            "Synchronous catalog completion did not update the catalog.")
    } finally {
        gui.Dispose()
    }

    service := RimeDepotGuiFakeService(true, true)
    gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke-sync-error.ini")
    try {
        AssertTrue(gui.StartCatalogLoad(false), "The synchronous error job did not start.")
        AssertTrue(!gui.busy && !IsObject(gui.active_job),
            "Synchronous catalog error left the GUI busy or active_job set.")
        AssertTrue(InStr(gui.status_text.Value, "Operation failed") > 0,
            "Synchronous catalog error was not shown in the status control.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeSelection() {
    local service := RimeDepotGuiFakeService()
    local gui := RimeDepotGui(service, RimeDepotGuiSettings(), A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local first := {
        category_path: "demo",
        name: "First scheme",
        repo: "owner/first",
        schemas: ["first.schema"],
        dependencies: ["first-base"],
        reverseDependencies: ["first-child"],
        labels: ["first-label"],
        license: "MIT"
    }
    local second := {
        category_path: "demo",
        name: "Second scheme",
        repo: "owner/second",
        schemas: ["second.schema"],
        dependencies: ["second-base"],
        reverseDependencies: ["second-child"],
        labels: ["second-label"],
        license: "Apache-2.0"
    }
    try {
        gui.catalog_entries := [first, second]
        gui.UpdateCategoryFilter()
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        AssertTrue(InStr(gui.detail_title.Value, "First scheme") > 0,
            "The first selected scheme was not shown in the details.")

        gui.catalog_list.Modify(2, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 2, true)
        ; A delayed deselect notification for row 1 must synchronize from the
        ; ListView's current selection instead of clearing row 2's details.
        gui.OnCatalogSelection(gui.catalog_list, 1, false)
        AssertTrue(InStr(gui.detail_title.Value, "Second scheme") > 0
            && InStr(gui.detail_schemas.Value, "second.schema") > 0
            && InStr(gui.detail_dependencies.Value, "second-base") > 0
            && InStr(gui.detail_reverse_dependencies.Value, "second-child") > 0
            && InStr(gui.detail_labels.Value, "second-label") > 0,
            "A stale deselect notification cleared the current scheme details.")

        gui.catalog_list.Modify(2, "-Select")
        gui.OnCatalogSelection(gui.catalog_list, 2, false)
        AssertTrue(InStr(gui.detail_title.Value, "Select a catalog entry") > 0
            && gui.detail_schemas.Value = "Schemas: "
            && gui.detail_dependencies.Value = "Dependencies: ",
            "Details were not cleared after the ListView lost its selection.")
    } finally {
        gui.Dispose()
    }
}

RimeDepotGuiSmokeModes() {
    local service := RimeDepotGuiFakeService(), settings := RimeDepotGuiSettings(Map("UseGit", true))
    local gui := RimeDepotGui(service, settings, A_Temp . "\\RimeDepot-GuiSmoke.ini")
    local start_time, call, target, options
    try {
        AssertEqual("rppi", gui.mode, "The GUI did not start in RPPI mode.")
        gui.mode_selector.Choose(2)
        gui.OnModeChanged(gui.mode_selector, 2)
        AssertEqual("direct", gui.mode, "The GUI did not enter direct mode.")
        AssertTrue(gui.direct_source_edit.Visible && !gui.catalog_list.Visible,
            "Direct mode did not switch the visible control group.")

        gui.direct_source_edit.Value := "https://github.com/owner/direct-repository"
        gui.direct_ref_kind.Choose(2)
        gui.direct_ref_edit.Value := "feature/direct"
        gui.direct_recipe_edit.Value := "custom"
        gui.use_git_checkbox.Value := 1
        AssertTrue(gui.InstallSelected(), "The direct install action did not start.")
        start_time := A_TickCount
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy && service.calls.Length >= 1, "The direct install did not complete.")
        call := service.calls[service.calls.Length]
        AssertEqual("target", call.kind, "Direct mode called the wrong service operation.")
        target := call.target
        options := call.options
        AssertTrue(target is Map && target["repo"] = "https://github.com/owner/direct-repository"
            && target["ref_kind"] = "branch" && target["ref"] = "feature/direct"
            && target["recipe"] = "custom",
            "Direct mode did not pass the structured target fields.")
        AssertTrue(options["UseGit"] && options["Proxy"] = gui.proxy_edit.Value,
            "Direct mode did not pass the explicit Git/proxy options.")

        gui.SetMode("rppi")
        AssertEqual("rppi", gui.mode, "The GUI did not return to RPPI mode.")
        AssertTrue(gui.catalog_list.Visible && !gui.direct_source_edit.Visible,
            "RPPI mode did not restore the catalog controls.")

        gui.catalog_entries := [{category_path: "demo", name: "Catalog scheme", repo: "owner/catalog"}]
        gui.UpdateCategoryFilter()
        gui.RefreshCatalogView()
        gui.catalog_list.Modify(1, "Select")
        gui.OnCatalogSelection(gui.catalog_list, 1, true)
        gui.use_git_checkbox.Value := 1
        AssertTrue(gui.InstallSelected(), "The RPPI install action did not start.")
        start_time := A_TickCount
        while gui.busy && A_TickCount - start_time < 2000 {
            Sleep(20)
        }
        AssertTrue(!gui.busy && service.calls.Length >= 2, "The RPPI install did not complete.")
        call := service.calls[service.calls.Length]
        AssertEqual("entry", call.kind, "RPPI mode called direct target installation.")
        AssertTrue(!call.options["UseGit"], "RPPI installation did not force archive mode.")
        AssertTrue(InStr(gui.detail_title.Value, "Catalog scheme") > 0,
            "RPPI completion replaced the selected catalog details.")
    } finally {
        gui.Dispose()
    }
}

class RimeDepotGuiFakeService {
    __New(synchronous_catalog := false, catalog_error := false) {
        this.config := 0
        this.jobs := []
        this.calls := []
        this.synchronous_catalog := synchronous_catalog
        this.catalog_error := catalog_error
    }

    Configure(values) {
        this.config := values
    }

    LoadCatalog(options := 0, callbacks := 0) {
        if !callbacks {
            callbacks := options
        }
        local job := RimeDepotGuiFakeJob(callbacks, "catalog")
        job.catalog_error := this.catalog_error
        this.jobs.Push(job)
        if this.synchronous_catalog {
            job.Deliver()
        } else {
            SetTimer(job.Deliver.Bind(job), -30)
        }
        return job
    }

    RefreshCatalog(options := 0, callbacks := 0) {
        return this.LoadCatalog(options, callbacks)
    }

    InstallEntry(entry, options := 0, callbacks := 0) {
        if !callbacks {
            callbacks := options
            options := Map()
        }
        this.calls.Push({kind: "entry", entry: entry, options: RimeDepotGuiFakeCopy(options)})
        return this._Install(callbacks, "entry", entry, options)
    }

    InstallTarget(target, options := 0, callbacks := 0) {
        if !callbacks {
            callbacks := options
            options := Map()
        }
        this.calls.Push({kind: "target", target: target, options: RimeDepotGuiFakeCopy(options)})
        return this._Install(callbacks, "target", target, options)
    }

    _Install(callbacks, kind, target, options) {
        local job := RimeDepotGuiFakeJob(callbacks, kind, target)
        this.jobs.Push(job)
        SetTimer(job.Deliver.Bind(job), -30)
        return job
    }
}

class RimeDepotGuiFakeJob {
    __New(callbacks, kind := "catalog", target := 0) {
        this.callbacks := callbacks
        this.kind := kind
        this.target := target
        this.cancelled := false
        this.delivered := false
        this.catalog_error := false
        this.delivery_callback := this.Deliver.Bind(this)
    }

    IsDone() {
        return this.cancelled || this.delivered
    }

    Deliver(*) {
        local entry
        if this.cancelled || this.delivered {
            return
        }
        this.delivered := true
        if this.catalog_error {
            this.callbacks.ReportError(this, Error("synchronous catalog fixture failure"))
            return
        }
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
        if this.kind = "catalog" {
            this.callbacks.ReportComplete(this, [entry])
        } else {
            this.callbacks.ReportComplete(this, Map("entries", [entry], "target", this.target))
        }
    }

    Cancel() {
        this.cancelled := true
    }
}

RimeDepotGuiFakeCopy(value) {
    local result := Map(), key, item
    if !IsObject(value) {
        return result
    }
    for key, item in value {
        result[key] := item
    }
    return result
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
