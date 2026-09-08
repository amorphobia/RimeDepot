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

#Include RimeDepot.ahk

/**
 * The settings model used by the standalone RimeDepot window.
 *
 * The six keys in ToMap() intentionally use the same spelling as the INI
 * example.  The GUI keeps lower-case fields for normal AHK property style,
 * while this boundary makes it straightforward for a service or a test
 * double to consume a settings map without depending on the GUI.
 */
class RimeDepotGuiSettings {
    static SECTION := "RimeDepot"
    static KEYS := ["CachePath", "RimeDirectory", "RppiIndexUrl", "Proxy", "UseGit", "GitPath"]
    static DEFAULT_RPPI_INDEX_URL := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"

    __New(values := 0) {
        this.cache_path := A_WorkingDir . "\cache"
        this.rime_directory := A_AppData . "\Rime"
        this.rppi_index_url := RimeDepotGuiSettings.DEFAULT_RPPI_INDEX_URL
        this.proxy := ""
        this.use_git := false
        this.git_path := ""
        if values {
            this.Apply(values)
        }
    }

    static Load(path) {
        local settings := this(), value
        if !path || !FileExist(path) {
            return settings
        }
        value := IniRead(path, this.SECTION, "CachePath", settings.cache_path)
        if value != "" {
            settings.cache_path := RimeDepotGuiExpandEnvironment(value)
        }
        value := IniRead(path, this.SECTION, "RimeDirectory", settings.rime_directory)
        if value != "" {
            settings.rime_directory := RimeDepotGuiExpandEnvironment(value)
        }
        value := IniRead(path, this.SECTION, "RppiIndexUrl", settings.rppi_index_url)
        if value != "" {
            settings.rppi_index_url := value
        }
        settings.proxy := IniRead(path, this.SECTION, "Proxy", settings.proxy)
        settings.use_git := RimeDepotGuiToBoolean(
            IniRead(path, this.SECTION, "UseGit", settings.use_git ? "1" : "0")
        )
        settings.git_path := RimeDepotGuiExpandEnvironment(IniRead(path, this.SECTION, "GitPath", settings.git_path))
        return settings
    }

    Apply(values) {
        local value
        value := RimeDepotGuiGetValue(values, ["CachePath", "cache_path"], "")
        if value != "" {
            this.cache_path := RimeDepotGuiExpandEnvironment(value)
        }
        value := RimeDepotGuiGetValue(values, ["RimeDirectory", "rime_directory"], "")
        if value != "" {
            this.rime_directory := RimeDepotGuiExpandEnvironment(value)
        }
        value := RimeDepotGuiGetValue(values, ["RppiIndexUrl", "rppi_index_url"], "")
        if value != "" {
            this.rppi_index_url := String(value)
        }
        this.proxy := String(RimeDepotGuiGetValue(values, ["Proxy", "proxy"], this.proxy))
        this.use_git := RimeDepotGuiToBoolean(
            RimeDepotGuiGetValue(values, ["UseGit", "use_git"], this.use_git)
        )
        this.git_path := RimeDepotGuiExpandEnvironment(
            RimeDepotGuiGetValue(values, ["GitPath", "git_path"], this.git_path)
        )
    }

    ToMap() {
        return Map(
            "CachePath", this.cache_path,
            "RimeDirectory", this.rime_directory,
            "RppiIndexUrl", this.rppi_index_url,
            "Proxy", this.proxy,
            "UseGit", this.use_git,
            "GitPath", this.git_path
        )
    }

    AsMap() {
        return this.ToMap()
    }

    Save(path) {
        local directory, key, value
        if !path {
            throw ValueError("An INI path is required.")
        }
        SplitPath(path, , &directory)
        if directory && !DirExist(directory) {
            DirCreate(directory)
        }
        for key in this.KEYS {
            switch key {
                case "CachePath": value := this.cache_path
                case "RimeDirectory": value := this.rime_directory
                case "RppiIndexUrl": value := this.rppi_index_url
                case "Proxy": value := this.proxy
                case "UseGit": value := this.use_git ? "1" : "0"
                case "GitPath": value := this.git_path
            }
            IniWrite(value, path, this.SECTION, key)
        }
    }
}

/**
 * A small, deliberately dependency-light browser for the RPPI catalog.
 *
 * The service is injected so the window remains independent of its host and
 * is easy to exercise with a fake service.  Service calls are made only through
 * the asynchronous RimeDepotJob contract; no network or Git operation runs
 * on the GUI event callback.
 */
class RimeDepotGui extends Gui {
    static WINDOW_WIDTH := 1080
    static WINDOW_HEIGHT := 760

    __New(service, settings := 0, settings_path := "") {
        if settings is String && settings_path = "" {
            settings_path := settings
            settings := 0
        }
        local initial_settings := settings ? settings : RimeDepotGuiSettings()
        super.__New("+MinSize800x620", "RimeDepot — Rime package catalog")
        this.service := service
        this.settings := initial_settings is RimeDepotGuiSettings
            ? initial_settings
            : RimeDepotGuiSettings(initial_settings)
        this.settings_path := settings_path ? settings_path : A_ScriptDir . "\RimeDepot.ini"
        this.active_job := 0
        this.active_kind := ""
        this.callbacks := 0
        this.operation_token := 0
        this.catalog_entries := []
        this.visible_entries := Map()
        this.busy := false
        this.disposed := false
        this.initial_load_started := false
        this.initial_load_callback := this.StartInitialLoad.Bind(this)
        this.progress_callback := 0
        this.complete_callback := 0
        this.error_callback := 0

        this.CreateControls()
        this.LoadSettingsIntoControls()
        this.ApplyServiceSettings()
        this.OnEvent("Close", this.OnClose.Bind(this))
        this.OnEvent("Escape", this.OnClose.Bind(this))
    }

    CreateControls() {
        this.SetFont("s10", "Microsoft YaHei UI")
        this.MarginX := 12
        this.MarginY := 12

        this.settings_group := this.AddGroupBox("x12 y10 w1056 h170", "Settings")
        this.AddText("x28 y38 w76 h24 +0x200", "Cache path")
        this.cache_path_edit := this.AddEdit("x110 y34 w278 h26")
        this.cache_browse_button := this.AddButton("x394 y34 w78 h26", "Browse…")
        this.cache_browse_button.OnEvent("Click", this.BrowseCachePath.Bind(this))

        this.AddText("x488 y38 w104 h24 +0x200", "Rime directory")
        this.rime_directory_edit := this.AddEdit("x594 y34 w338 h26")
        this.rime_browse_button := this.AddButton("x938 y34 w78 h26", "Browse…")
        this.rime_browse_button.OnEvent("Click", this.BrowseRimeDirectory.Bind(this))

        this.AddText("x28 y78 w76 h24 +0x200", "RPPI URL")
        this.rppi_index_url_edit := this.AddEdit("x110 y74 w520 h26")
        this.AddText("x648 y78 w68 h24 +0x200", "Proxy")
        this.proxy_edit := this.AddEdit("x720 y74 w296 h26")

        this.use_git_checkbox := this.AddCheckbox("x28 y114 w110 h26", "Use Git")
        this.use_git_checkbox.OnEvent("Click", this.OnUseGitChanged.Bind(this))
        this.AddText("x152 y118 w68 h24 +0x200", "Git path")
        this.git_path_edit := this.AddEdit("x224 y114 w406 h26")
        this.git_path_browse_button := this.AddButton("x638 y114 w78 h26", "Browse…")
        this.git_path_browse_button.OnEvent("Click", this.BrowseGitPath.Bind(this))
        this.git_path_hint := this.AddText("x724 y118 w206 h24 cGray", "Empty uses git from PATH.")

        this.save_settings_button := this.AddButton("x938 y112 w78 h28 +0x2000", "Save")
        this.save_settings_button.OnEvent("Click", this.SaveSettings.Bind(this))

        this.AddText("x22 y198 w54 h24 +0x200", "Search")
        this.search_edit := this.AddEdit("x78 y194 w280 h26")
        this.search_edit.OnEvent("Change", this.OnFilterChanged.Bind(this))
        this.AddText("x378 y198 w66 h24 +0x200", "Category")
        this.category_filter := this.AddDropDownList("x448 y194 w210 h26 Choose1", ["All categories"])
        this.category_filter.OnEvent("Change", this.OnFilterChanged.Bind(this))
        this.refresh_button := this.AddButton("x774 y194 w94 h28 +0x2000", "Refresh index")
        this.refresh_button.OnEvent("Click", this.RefreshCatalog.Bind(this))
        this.install_button := this.AddButton("x876 y194 w94 h28 +0x2000 Disabled", "Install")
        this.install_button.OnEvent("Click", this.InstallSelected.Bind(this))
        this.cancel_button := this.AddButton("x978 y194 w78 h28 +0x2000 Disabled", "Cancel")
        this.cancel_button.OnEvent("Click", this.CancelActiveJob.Bind(this))

        this.catalog_list := this.AddListView(
            "x22 y230 w1036 h264 -Multi Grid",
            ["Category", "Scheme", "Schemas", "Repository", "Branch/ref", "License"]
        )
        this.catalog_list.ModifyCol(1, 150)
        this.catalog_list.ModifyCol(2, 190)
        this.catalog_list.ModifyCol(3, 185)
        this.catalog_list.ModifyCol(4, 250)
        this.catalog_list.ModifyCol(5, 110)
        this.catalog_list.ModifyCol(6, 110)
        this.catalog_list.OnEvent("ItemSelect", this.OnCatalogSelection.Bind(this))
        this.catalog_list.OnEvent("DoubleClick", this.InstallSelected.Bind(this))

        this.details_group := this.AddGroupBox("x12 y504 w1056 h176", "Selected scheme")
        this.detail_title := this.AddText("x28 y530 w1020 h24", "Select a catalog entry to see its details.")
        this.detail_summary := this.AddText("x28 y556 w1020 h24 cGray", "")
        this.detail_schemas := this.AddText("x28 y584 w1020 h22", "Schemas: ")
        this.detail_dependencies := this.AddText("x28 y608 w1020 h22", "Dependencies: ")
        this.detail_reverse_dependencies := this.AddText("x28 y632 w1020 h22", "Reverse dependencies: ")
        this.detail_labels := this.AddText("x28 y656 w760 h22", "Labels: ")
        this.detail_license := this.AddText("x802 y656 w236 h22", "License: ")

        this.status_text := this.AddText("x22 y692 w700 h22 cGray", "Ready.")
        this.progress_bar := this.AddProgress("x730 y694 w328 h18", 0)
        this.progress_bar.Value := 0
    }

    Show(options := "") {
        super.Show(Trim(options . Format(" w{} h{}", RimeDepotGui.WINDOW_WIDTH, RimeDepotGui.WINDOW_HEIGHT)))
        if !this.initial_load_started {
            this.initial_load_started := true
            SetTimer(this.initial_load_callback, -1)
        }
    }

    StartInitialLoad(*) {
        if !this.disposed {
            this.StartCatalogLoad(false)
        }
    }

    LoadSettingsIntoControls() {
        this.cache_path_edit.Value := this.settings.cache_path
        this.rime_directory_edit.Value := this.settings.rime_directory
        this.rppi_index_url_edit.Value := this.settings.rppi_index_url
        this.proxy_edit.Value := this.settings.proxy
        this.use_git_checkbox.Value := this.settings.use_git ? 1 : 0
        this.git_path_edit.Value := this.settings.git_path
        this.UpdateGitPathState()
    }

    ReadSettingsFromControls() {
        this.settings.cache_path := Trim(this.cache_path_edit.Value)
        this.settings.rime_directory := Trim(this.rime_directory_edit.Value)
        this.settings.rppi_index_url := Trim(this.rppi_index_url_edit.Value)
        this.settings.proxy := Trim(this.proxy_edit.Value)
        this.settings.use_git := !!this.use_git_checkbox.Value
        this.settings.git_path := Trim(this.git_path_edit.Value)
    }

    SaveSettings(*) {
        if this.busy {
            return false
        }
        try {
            this.ReadSettingsFromControls()
            this.settings.Save(this.settings_path)
            this.ApplyServiceSettings()
            this.SetStatus("Settings saved to " . this.settings_path . ".")
            return true
        } catch as err {
            this.SetStatus("Could not save settings: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    ApplyServiceSettings() {
        local values := this.settings.ToMap(), config
        if !IsObject(this.service) {
            return
        }
        config := RimeDepotConfig(values)
        if HasMethod(this.service, "SetConfig") {
            this.service.SetConfig(config)
        } else if HasMethod(this.service, "Configure") {
            this.service.Configure(config)
        } else if HasProp(this.service, "Config") {
            try this.service.Config := config
        } else if HasProp(this.service, "config") {
            try this.service.config := config
        }
    }

    BrowseCachePath(*) {
        this.BrowseDirectory(this.cache_path_edit, "Select the RimeDepot cache directory")
    }

    BrowseRimeDirectory(*) {
        this.BrowseDirectory(this.rime_directory_edit, "Select the Rime user-data directory")
    }

    BrowseDirectory(edit, prompt) {
        local selected
        try {
            selected := DirSelect(edit.Value, 0, prompt)
            if selected {
                edit.Value := selected
            }
        } catch as err {
            this.SetStatus("Could not open the folder picker: " . RimeDepotGuiErrorText(err), true)
        }
    }

    BrowseGitPath(*) {
        local selected
        try {
            selected := FileSelect(3, A_WinDir, "Select the Git executable", "Executable (*.exe)")
            if selected {
                this.git_path_edit.Value := selected
            }
        } catch as err {
            this.SetStatus("Could not open the Git picker: " . RimeDepotGuiErrorText(err), true)
        }
    }

    OnUseGitChanged(*) {
        this.UpdateGitPathState()
    }

    UpdateGitPathState() {
        local enabled := !this.busy && !!this.use_git_checkbox.Value
        this.git_path_edit.Enabled := enabled
        this.git_path_browse_button.Enabled := enabled
    }

    RefreshCatalog(*) {
        this.StartCatalogLoad(true)
    }

    StartCatalogLoad(force_refresh) {
        local token, callbacks
        if this.disposed || this.busy {
            return false
        }
        if !IsObject(this.service) {
            this.SetStatus("No RimeDepot service is configured.", true)
            return false
        }
        this.ReadSettingsFromControls()
        try {
            this.ApplyServiceSettings()
            this.operation_token += 1
            token := this.operation_token
            this.active_kind := "catalog"
            this.progress_bar.Value := 0
            this.SetStatus(force_refresh ? "Refreshing RPPI index…" : "Loading RPPI index…")
            callbacks := this.CreateCallbacks(token)
            this.callbacks := callbacks
            this.SetBusy(true)
            this.active_job := force_refresh
                ? this.service.RefreshCatalog(callbacks)
                : this.service.LoadCatalog(callbacks)
            if !IsObject(this.active_job) {
                throw Error("The catalog operation did not return a RimeDepotJob.")
            }
            return true
        } catch as err {
            this.FinishOperation(token ?? this.operation_token)
            this.SetStatus("Could not start catalog operation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CreateCallbacks(token) {
        this.progress_callback := this.OnProgress.Bind(this, token)
        this.complete_callback := this.OnCatalogComplete.Bind(this, token)
        this.error_callback := this.OnOperationError.Bind(this, token)
        return RimeDepotCallbacks(this.progress_callback, this.complete_callback, this.error_callback)
    }

    InstallSelected(*) {
        local row := this.catalog_list.GetNext(0), entry, token, callbacks
        if this.disposed || this.busy || row < 1 || !this.visible_entries.Has(row) {
            return false
        }
        entry := this.visible_entries[row]
        try {
            this.operation_token += 1
            token := this.operation_token
            this.active_kind := "install"
            this.progress_bar.Value := 0
            this.SetStatus("Installing " . RimeDepotGuiEntryText(entry, ["name", "Name"], "selected scheme") . "…")
            callbacks := this.CreateCallbacks(token)
            this.callbacks := callbacks
            this.SetBusy(true)
            this.active_job := this.service.InstallEntry(entry, callbacks)
            if !IsObject(this.active_job) {
                throw Error("The install operation did not return a RimeDepotJob.")
            }
            return true
        } catch as err {
            this.FinishOperation(token ?? this.operation_token)
            this.SetStatus("Could not start installation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CancelActiveJob(*) {
        local job := this.active_job
        if !this.busy || !IsObject(job) {
            return false
        }
        try {
            if HasMethod(job, "Cancel") {
                job.Cancel()
            } else if HasMethod(job, "cancel") {
                job.cancel()
            } else {
                throw Error("The active RimeDepotJob cannot be cancelled.")
            }
            this.SetStatus("Cancellation requested…")
            return true
        } catch as err {
            this.SetStatus("Could not cancel operation: " . RimeDepotGuiErrorText(err), true)
            return false
        }
    }

    CreateOperationCallbacks(token) {
        return this.CreateCallbacks(token)
    }

    OnProgress(token, job_or_progress := 0, progress_or_message := "", extra*) {
        local progress, message, percent, text
        if this.disposed || token != this.operation_token || !this.busy {
            return
        }
        if RimeDepotGuiLooksLikeJob(job_or_progress) {
            progress := progress_or_message
            message := extra.Length ? extra[1] : ""
        } else {
            progress := job_or_progress
            message := progress_or_message
        }
        percent := RimeDepotGuiProgressPercent(progress)
        if percent >= 0 {
            this.progress_bar.Value := percent
        }
        text := RimeDepotGuiProgressText(progress, message)
        if text != "" {
            this.SetStatus(text)
        }
    }

    OnCatalogComplete(token, job_or_result := 0, result_or_extra := 0, extra*) {
        local result, result_extra, entries, warning, count, value
        if this.disposed || token != this.operation_token {
            return
        }
        if RimeDepotGuiLooksLikeJob(job_or_result) {
            result := result_or_extra
            result_extra := extra
        } else {
            result := job_or_result
            result_extra := [result_or_extra]
            for _, value in extra {
                result_extra.Push(value)
            }
        }
        entries := RimeDepotGuiExtractCatalog(result, result_extra)
        this.catalog_entries := entries
        this.UpdateCategoryFilter()
        this.RefreshCatalogView()
        warning := RimeDepotGuiCatalogWarning(result, result_extra)
        count := entries.Length
        this.FinishOperation(token)
        if warning != "" {
            this.SetStatus("Loaded " . count . " scheme(s). Warning: " . warning, true)
        } else {
            this.SetStatus("Loaded " . count . " scheme(s).")
        }
    }

    OnOperationError(token, job_or_error := 0, error_or_extra := 0, extra*) {
        local error_value, text
        if RimeDepotGuiLooksLikeJob(job_or_error) {
            error_value := error_or_extra
        } else {
            error_value := job_or_error
        }
        text := RimeDepotGuiErrorText(error_value)
        if text = "" {
            text := RimeDepotGuiErrorText(extra.Length ? extra[1] : "The RimeDepot operation failed.")
        }
        if this.disposed || token != this.operation_token {
            return
        }
        this.FinishOperation(token)
        this.SetStatus("Operation failed: " . text, true)
    }

    FinishOperation(token) {
        local callback_object := this.callbacks
        if token != this.operation_token {
            return
        }
        this.active_job := 0
        this.active_kind := ""
        this.callbacks := 0
        this.SetBusy(false)
        if IsObject(callback_object) && HasMethod(callback_object, "Dispose") {
            try callback_object.Dispose()
        }
    }

    SetBusy(busy) {
        local enabled := !busy
        this.busy := !!busy
        this.cache_path_edit.Enabled := enabled
        this.cache_browse_button.Enabled := enabled
        this.rime_directory_edit.Enabled := enabled
        this.rime_browse_button.Enabled := enabled
        this.rppi_index_url_edit.Enabled := enabled
        this.proxy_edit.Enabled := enabled
        this.use_git_checkbox.Enabled := enabled
        this.save_settings_button.Enabled := enabled
        this.refresh_button.Enabled := enabled
        this.install_button.Enabled := enabled && this.catalog_list.GetNext(0) > 0
        this.cancel_button.Enabled := !!busy
        this.UpdateGitPathState()
    }

    OnFilterChanged(*) {
        if !this.disposed {
            this.RefreshCatalogView()
        }
    }

    UpdateCategoryFilter() {
        local selected := this.category_filter.Text, categories := ["All categories"], seen := Map(), category, index
        seen["All categories"] := true
        for entry in this.catalog_entries {
            category := RimeDepotGuiEntryText(
                entry,
                ["category_path", "CategoryPath", "category", "Category"],
                "Uncategorized"
            )
            if !seen.Has(category) {
                seen[category] := true
                categories.Push(category)
            }
        }
        this.category_filter.Delete()
        this.category_filter.Add(categories)
        index := 1
        for index, category in categories {
            if category = selected {
                this.category_filter.Choose(index)
                return
            }
        }
        this.category_filter.Choose(1)
    }

    RefreshCatalogView(*) {
        local query := StrLower(Trim(this.search_edit.Value)), category := this.category_filter.Text
        local entry, row, values, name, entry_category
        this.catalog_list.Delete()
        this.visible_entries := Map()
        for entry in this.catalog_entries {
            name := RimeDepotGuiEntryText(entry, ["name"], "")
            entry_category := RimeDepotGuiEntryText(
                entry,
                ["category_path", "CategoryPath", "category", "Category"],
                "Uncategorized"
            )
            if category != "All categories" && entry_category != category {
                continue
            }
            if query != "" && !InStr(StrLower(
                name . " " . entry_category . " " . RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], "")
                    . " " . RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], "")
            ), query) {
                continue
            }
            values := [
                entry_category,
                name,
                RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], ""),
                RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], ""),
                RimeDepotGuiEntryRef(entry),
                RimeDepotGuiEntryText(entry, ["license", "License", "licence", "Licence"], "")
            ]
            row := this.catalog_list.Add("", values*)
            this.visible_entries[row] := entry
        }
        this.install_button.Enabled := !this.busy && this.catalog_list.GetNext(0) > 0
        this.ClearDetails()
    }

    OnCatalogSelection(ctrl, row, selected) {
        if selected && row > 0 && this.visible_entries.Has(row) {
            this.ShowDetails(this.visible_entries[row])
        } else if !selected {
            this.ClearDetails()
        }
        this.install_button.Enabled := !this.busy && this.catalog_list.GetNext(0) > 0
    }

    ShowDetails(entry) {
        local category := RimeDepotGuiEntryText(
            entry,
            ["category_path", "CategoryPath", "category", "Category"],
            "Uncategorized"
        )
        local name := RimeDepotGuiEntryText(entry, ["name", "Name"], "")
        local repo := RimeDepotGuiEntryText(entry, ["repo", "Repo", "repository", "Repository"], "")
        local branch := RimeDepotGuiEntryRef(entry)
        this.detail_title.Value := name != "" ? name : "Selected scheme"
        this.detail_summary.Value := "Category: " . category . "    Repository: " . repo . "    Branch/ref: " . branch
        this.detail_schemas.Value := "Schemas: " . RimeDepotGuiEntryText(entry, ["schemas", "Schemas"], "(none)")
        this.detail_dependencies.Value := "Dependencies: "
            . RimeDepotGuiEntryText(entry, ["dependencies", "Dependencies"], "(none)")
        this.detail_reverse_dependencies.Value := "Reverse dependencies: "
            . RimeDepotGuiEntryText(
                entry,
                ["reverseDependencies", "ReverseDependencies", "reverse_dependencies"],
                "(none)"
            )
        this.detail_labels.Value := "Labels: " . RimeDepotGuiEntryText(entry, ["labels", "Labels"], "(none)")
        this.detail_license.Value := "License: "
            . RimeDepotGuiEntryText(entry, ["license", "License"], "(unspecified)")
    }

    ClearDetails() {
        this.detail_title.Value := this.catalog_entries.Length ? "Select a catalog entry to see its details." : "No catalog entries."
        this.detail_summary.Value := ""
        this.detail_schemas.Value := "Schemas: "
        this.detail_dependencies.Value := "Dependencies: "
        this.detail_reverse_dependencies.Value := "Reverse dependencies: "
        this.detail_labels.Value := "Labels: "
        this.detail_license.Value := "License: "
    }

    SetStatus(text, warning := false) {
        this.status_text.Value := text
        try this.status_text.Opt(warning ? "cB00020" : "cGray")
    }

    OnClose(*) {
        this.Dispose()
        return true
    }

    Dispose() {
        local callback_object
        if this.disposed {
            return
        }
        this.disposed := true
        SetTimer(this.initial_load_callback, 0)
        if IsObject(this.active_job) {
            try {
                if HasMethod(this.active_job, "Cancel") {
                    this.active_job.Cancel()
                }
            }
        }
        this.active_job := 0
        callback_object := this.callbacks
        this.callbacks := 0
        if IsObject(callback_object) && HasMethod(callback_object, "Dispose") {
            try callback_object.Dispose()
        }
        this.progress_callback := 0
        this.complete_callback := 0
        this.error_callback := 0
        try this.Destroy()
    }
}

RimeDepotGuiToBoolean(value) {
    if IsObject(value) {
        return !!value
    }
    return value = true || value = 1 || StrLower(Trim(String(value))) = "true"
        || StrLower(Trim(String(value))) = "yes"
}

RimeDepotGuiExpandEnvironment(value) {
    local match, name, replacement
    value := String(value)
    while RegExMatch(value, "%([^%]+)%", &match) {
        name := match[1]
        replacement := EnvGet(name)
        if replacement = "" {
            break
        }
        value := StrReplace(value, match[0], replacement)
    }
    return value
}

RimeDepotGuiGetValue(value, keys, fallback := "") {
    local key
    if !IsObject(value) {
        return fallback
    }
    if !(keys is Array) {
        keys := [keys]
    }
    for key in keys {
        if value is Map {
            if value.Has(key) {
                return value[key]
            }
        } else if HasProp(value, key) {
            return value.%key%
        }
    }
    return fallback
}

RimeDepotGuiEntryText(entry, keys, fallback := "") {
    local value := RimeDepotGuiGetValue(entry, keys, ""), raw
    if value = "" {
        raw := RimeDepotGuiGetValue(entry, ["Raw", "raw"], 0)
        value := RimeDepotGuiGetValue(raw, keys, "")
    }
    return RimeDepotGuiFormatValue(value, fallback)
}

RimeDepotGuiEntryRef(entry) {
    local value := RimeDepotGuiEntryText(entry, ["branch", "Branch"], "")
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["ref", "Ref", "branch_ref", "branchRef"], "")
    }
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["tag", "Tag"], "")
    }
    if value = "" {
        value := RimeDepotGuiEntryText(entry, ["sha", "Sha", "SHA", "commit", "revision"], "")
    }
    return value
}

RimeDepotGuiFormatValue(value, fallback := "") {
    local parts, item, key
    if !IsObject(value) {
        return value = "" ? fallback : String(value)
    }
    if value is Array {
        parts := []
        for item in value {
            parts.Push(RimeDepotGuiFormatValue(item, ""))
        }
        return parts.Length ? RimeDepotGuiJoin(parts, ", ") : fallback
    }
    if value is Map {
        for key in ["name", "id", "value", "path"] {
            if value.Has(key) {
                return RimeDepotGuiFormatValue(value[key], fallback)
            }
        }
    }
    try {
        return String(value)
    } catch {
        return fallback
    }
}

RimeDepotGuiJoin(values, separator) {
    local result := "", index, value
    for index, value in values {
        if index > 1 {
            result .= separator
        }
        result .= value
    }
    return result
}

RimeDepotGuiProgressPercent(progress) {
    local value
    if IsObject(progress) {
        value := RimeDepotGuiGetValue(progress, ["percent", "percentage"], "")
        if value = "" {
            value := RimeDepotGuiGetValue(progress, ["progress", "fraction"], "")
        }
    } else {
        value := progress
    }
    if value = "" || !IsNumber(value) {
        return -1
    }
    value := Number(value)
    if value >= 0 && value <= 1 {
        value *= 100
    }
    return Max(0, Min(100, value))
}

RimeDepotGuiProgressText(progress, message := "") {
    local text := message, phase, state, url
    if IsObject(progress) {
        text := RimeDepotGuiGetValue(progress, ["message", "status", "text"], text)
        if text = "" {
            phase := RimeDepotGuiGetValue(progress, ["phase", "Phase"], "")
            state := RimeDepotGuiGetValue(progress, ["state", "State"], "")
            url := RimeDepotGuiGetValue(progress, ["url", "Url", "URL"], "")
            text := phase . (phase != "" && state != "" ? ": " : "") . state
            if url != "" {
                text .= " — " . url
            }
        }
    }
    return RimeDepotGuiFormatValue(text, "")
}

RimeDepotGuiExtractCatalog(result, extra) {
    local entries, candidate
    if result is Array {
        return result
    }
    if IsObject(result) && HasMethod(result, "ToArray") {
        try {
            entries := result.ToArray()
            if entries is Array {
                return entries
            }
        }
    }
    candidate := RimeDepotGuiGetValue(result, ["entries", "Entries", "catalog", "Catalog"], 0)
    if candidate is Array {
        return candidate
    }
    for candidate in extra {
        if candidate is Array {
            return candidate
        }
        if IsObject(candidate) && HasMethod(candidate, "ToArray") {
            try {
                entries := candidate.ToArray()
                if entries is Array {
                    return entries
                }
            }
        }
        entries := RimeDepotGuiGetValue(candidate, ["entries", "Entries", "catalog", "Catalog"], 0)
        if entries is Array {
            return entries
        }
    }
    return []
}

RimeDepotGuiCatalogWarning(result, extra) {
    local warning, from_cache, candidate, values
    candidate := result
    warning := RimeDepotGuiGetValue(candidate, ["warning", "Warning", "warnings", "Warnings", "cache_warning"], "")
    if warning != "" {
        return RimeDepotGuiFormatValue(warning, "")
    }
    from_cache := RimeDepotGuiGetValue(
        candidate,
        ["cache_fallback", "cacheFallback", "from_cache", "FromCache", "used_cache", "usedCache"],
        false
    )
    if RimeDepotGuiToBoolean(from_cache) {
        return "using the local cache because the index could not be fetched"
    }
    for _, candidate in extra {
        warning := RimeDepotGuiGetValue(
            candidate,
            ["warning", "Warning", "warnings", "Warnings", "cache_warning"],
            ""
        )
        if warning != "" {
            return RimeDepotGuiFormatValue(warning, "")
        }
        from_cache := RimeDepotGuiGetValue(
            candidate,
            ["cache_fallback", "cacheFallback", "from_cache", "FromCache", "used_cache", "usedCache"],
            false
        )
        if RimeDepotGuiToBoolean(from_cache) {
            return "using the local cache because the index could not be fetched"
        }
        if candidate is Array {
            values := candidate
            for _, item in values {
                warning := RimeDepotGuiGetValue(
                    item,
                    ["warning", "Warning", "message", "Message"],
                    ""
                )
                if warning != "" {
                    return RimeDepotGuiFormatValue(warning, "")
                }
            }
        }
    }
    return ""
}

RimeDepotGuiLooksLikeJob(value) {
    if !IsObject(value) {
        return false
    }
    if value is RimeDepotJob {
        return true
    }
    return HasMethod(value, "IsDone") && HasMethod(value, "Cancel")
}

RimeDepotGuiErrorText(error_value) {
    local message
    if !IsObject(error_value) {
        return error_value = "" ? "" : String(error_value)
    }
    message := RimeDepotGuiGetValue(error_value, ["message", "Message", "error"], "")
    return message != "" ? String(message) : Type(error_value)
}
