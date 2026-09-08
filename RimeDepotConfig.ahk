/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk

class RimeDepotConfig {
    static DEFAULT_RPPI_INDEX_URL := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"

    __New(values := 0) {
        this.CachePath := A_WorkingDir . "\cache"
        this.RimeDirectory := ""
        this.RppiIndexUrl := RimeDepotConfig.DEFAULT_RPPI_INDEX_URL
        this.Proxy := ""
        this.UseGit := false
        this.GitPath := ""
        this.IniPath := ""
        this._Apply(values)
        this._Normalize()
    }

    static Load(options := 0, ini_path := "") {
        if !IsObject(options) {
            options := Map()
        }
        if ini_path = "" {
            ini_path := RimeDepotUtil.GetString(options, ["IniPath", "ini_path"], "")
        }
        if ini_path = "" {
            ; A local file is deliberately optional.  The library remains
            ; usable when an application keeps settings elsewhere.
            candidate := A_WorkingDir . "\RimeDepot.ini"
            if FileExist(candidate) {
                ini_path := candidate
            }
        }

        ini_values := Map()
        if ini_path != "" && FileExist(ini_path) {
            for _, key in ["CachePath", "RimeDirectory", "RppiIndexUrl", "Proxy", "UseGit", "GitPath"] {
                value := IniRead(ini_path, "RimeDepot", key, "")
                if value != "" {
                    ini_values[key] := value
                }
            }
        }
        config := RimeDepotConfig(ini_values)
        config.IniPath := ini_path
        config._Apply(options)
        config._Normalize()
        return config
    }

    static From(options := 0, ini_path := "") {
        return RimeDepotConfig.Load(options, ini_path)
    }

    With(options := 0) {
        values := this.AsMap()
        if IsObject(options) {
            for key, value in options {
                values[key] := value
            }
        }
        return RimeDepotConfig(values)
    }

    AsMap() {
        return Map(
            "CachePath", this.CachePath,
            "RimeDirectory", this.RimeDirectory,
            "RppiIndexUrl", this.RppiIndexUrl,
            "Proxy", this.Proxy,
            "UseGit", this.UseGit,
            "GitPath", this.GitPath,
            "IniPath", this.IniPath
        )
    }

    ResolveGitPath() {
        if this.GitPath != "" {
            return this.GitPath
        }
        path_value := EnvGet("PATH")
        for _, directory in StrSplit(path_value, ";") {
            directory := RTrim(directory, " ")
            directory := RTrim(directory, "\")
            directory := RTrim(directory, Chr(34))
            if directory = "" {
                continue
            }
            candidate := directory . "\git.exe"
            if FileExist(candidate) {
                return candidate
            }
        }
        return "git.exe"
    }

    _Apply(values) {
        if !IsObject(values) {
            return
        }
        this.CachePath := RimeDepotUtil.GetString(values, ["CachePath", "cache_path"], this.CachePath)
        this.RimeDirectory := RimeDepotUtil.GetString(values, ["RimeDirectory", "rime_directory"], this.RimeDirectory)
        this.RppiIndexUrl := RimeDepotUtil.GetString(
            values, ["RppiIndexUrl", "RPPIIndexUrl", "rppi_index_url"], this.RppiIndexUrl)
        this.Proxy := RimeDepotUtil.GetString(values, ["Proxy", "proxy"], this.Proxy)
        use_git := RimeDepotUtil.GetValue(values, ["UseGit", "use_git"], this.UseGit)
        if use_git is String {
            this.UseGit := RimeDepotConfig.ParseBoolean(use_git, this.UseGit)
        } else {
            this.UseGit := !!use_git
        }
        this.GitPath := RimeDepotUtil.GetString(values, ["GitPath", "git_path"], this.GitPath)
    }

    _Normalize() {
        if this.CachePath = "" {
            this.CachePath := A_WorkingDir . "\cache"
        }
        if this.RppiIndexUrl = "" {
            this.RppiIndexUrl := RimeDepotConfig.DEFAULT_RPPI_INDEX_URL
        }
        ; Expand environment variables at the service boundary as well as in
        ; the GUI settings model.  This keeps direct INI users consistent
        ; with the standalone window (the example uses %APPDATA%).
        this.CachePath := RimeDepotUtil.NormalizePath(
            RimeDepotUtil.ExpandEnvironment(Trim(String(this.CachePath)))
        )
        if this.RimeDirectory != "" {
            this.RimeDirectory := RimeDepotUtil.NormalizePath(
                RimeDepotUtil.ExpandEnvironment(Trim(String(this.RimeDirectory)))
            )
        }
        this.GitPath := RimeDepotUtil.ExpandEnvironment(Trim(String(this.GitPath)))
        this.Proxy := String(this.Proxy)
    }

    static ParseBoolean(value, default := false) {
        value := StrLower(Trim(String(value)))
        if value = "true" || value = "yes" || value = "on" || value = "1" {
            return true
        }
        if value = "false" || value = "no" || value = "off" || value = "0" {
            return false
        }
        return default
    }
}
