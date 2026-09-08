/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotConfig.ahk
#Include RimeDepotRppi.ahk
#Include RimeDepotInstaller.ahk

/** Public facade.  A service owns at most one active asynchronous job. */
class RimeDepotService {
    __New(options := 0, ini_path := "", dependencies := 0) {
        if !IsObject(options) {
            options := Map()
        }
        if !IsObject(dependencies) {
            dependencies := Map()
        }
        this.Config := RimeDepotConfig.Load(options, ini_path)
        this.Dependencies := dependencies
        http := RimeDepotUtil.GetValue(dependencies, ["Http", "HttpClient", "Transport"], 0)
        this.Http := http ? (http is RimeDepotHttpClient ? http : RimeDepotHttpClient(http)) : RimeDepotHttpClient()
        this.GitRunner := RimeDepotUtil.GetValue(dependencies, ["GitRunner", "git_runner"], 0)
        this.Catalog := 0
        this.ActiveJob := 0
    }

    LoadCatalog(options := 0, callbacks := 0) {
        return this._LoadCatalog(options, callbacks, false)
    }

    RefreshCatalog(options := 0, callbacks := 0) {
        return this._LoadCatalog(options, callbacks, true)
    }

    InstallEntry(entry, options := 0, callbacks := 0) {
        if !this.Catalog {
            throw RimeDepotCatalogError("LoadCatalog must complete before InstallEntry.")
        }
        if !(entry is RimeDepotCatalogEntry) {
            entry := this.Catalog.Resolve(entry)
        }
        return this._Install(entry, options, callbacks)
    }

    InstallTarget(target, options := 0, callbacks := 0) {
        if target is RimeDepotTarget {
            parsed := target
        } else if target is RimeDepotCatalogEntry {
            parsed := RimeDepotTarget(target.Id)
        } else {
            parsed := RimeDepotTarget.Parse(target)
        }
        return this._Install(parsed, options, callbacks)
    }

    Cancel() {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            return this.ActiveJob.Cancel()
        }
        return false
    }

    SetConfig(config) {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            throw RimeDepotBusyError("Cannot change RimeDepotService configuration during an active job.")
        }
        this.Config := config is RimeDepotConfig ? config : RimeDepotConfig(config)
        this.Config._Normalize()
        return this.Config
    }

    Configure(config) {
        return this.SetConfig(config)
    }

    GetCatalog() {
        return this.Catalog
    }

    GetEntry(target) {
        if !this.Catalog {
            throw RimeDepotCatalogError("The catalog has not been loaded.")
        }
        return this.Catalog.Resolve(target)
    }

    _LoadCatalog(options, callbacks, refresh) {
        if options is RimeDepotCallbacks || IsObject(options) && HasMethod(options, "Call") {
            if !callbacks {
                callbacks := options
            }
            options := Map()
        } else if !IsObject(options) {
            options := Map()
        }
        if !callbacks {
            callbacks := RimeDepotUtil.GetValue(options, ["Callbacks", "callbacks"], 0)
        }
        callbacks := this._NormalizeCallbacks(callbacks)
        job := this._Begin("refresh-catalog", callbacks)
        try {
            config := this.Config.With(options)
            cache := RimeDepotRppiCache(config.CachePath)
            operation := RimeDepotRppiLoadOperation(this.Http, cache, config.RppiIndexUrl,
                config.AsMap(), job, ObjBindMethod(this, "_CatalogDone", job, refresh))
            job.SetCancelHandler(ObjBindMethod(operation, "Cancel"))
            operation.Start()
        } catch as err {
            job.Fail(err)
        }
        return job
    }

    _Install(target, options, callbacks) {
        if options is RimeDepotCallbacks || IsObject(options) && HasMethod(options, "Call") {
            if !callbacks {
                callbacks := options
            }
            options := Map()
        } else if !IsObject(options) {
            options := Map()
        }
        if !callbacks {
            callbacks := RimeDepotUtil.GetValue(options, ["Callbacks", "callbacks"], 0)
        }
        callbacks := this._NormalizeCallbacks(callbacks)
        if !this.Catalog {
            ; A direct owner/repository target is allowed for private packages
            ; that are intentionally absent from RPPI.  The empty catalog is
            ; still passed through the normal installer validation path.
            this.Catalog := RimeDepotCatalog()
        }
        target := this._ResolveTarget(target)
        job := this._Begin("install", callbacks)
        try {
            config := this.Config.With(options)
            config._Normalize()
            git_client := 0
            use_git := RimeDepotUtil.GetValue(options, ["UseGit", "use_git"], config.UseGit)
            if use_git {
                git_client := RimeDepotGitClient(config, this.GitRunner)
            }
            installer := RimeDepotInstaller(config, this.Http, git_client)
            operation := installer.InstallAsync(target, this.Catalog, options, job,
                ObjBindMethod(this, "_InstallDone", job))
            job.SetCancelHandler(ObjBindMethod(operation, "Cancel"))
        } catch as err {
            job.Fail(err)
        }
        return job
    }

    _ResolveTarget(target) {
        if target is RimeDepotCatalogEntry {
            return target
        }
        if target is RimeDepotTarget {
            parsed := target
        } else {
            parsed := RimeDepotTarget.Parse(target)
        }
        try {
            return this.Catalog.Resolve(parsed)
        } catch as err {
            ; Direct owner/repository targets are useful when an application
            ; has no RPPI record for a private package.  They remain subject
            ; to the same archive/Git and path safety checks.
            if InStr(parsed.RawBase, "/") {
                entry := RimeDepotCatalogEntry(Map(
                    "id", parsed.RawBase,
                    "name", parsed.RawBase,
                    "repo", parsed.RawBase,
                    "branch", parsed.Ref
                ), parsed.RawBase)
                this.Catalog.Add(entry, entry.Id)
                return entry
            }
            throw err
        }
    }

    _CatalogDone(job, refresh, catalog, error, warnings) {
        if job.IsDone() {
            return
        }
        if error {
            job.Fail(error)
            return
        }
        this.Catalog := catalog
        job.Complete(catalog)
    }

    _InstallDone(job, success, result, error) {
        if job.IsDone() {
            return
        }
        if !success {
            job.Fail(error)
            return
        }
        job.Complete(result)
    }

    _Begin(kind, callbacks) {
        if this.ActiveJob && !this.ActiveJob.IsDone() {
            throw RimeDepotBusyError()
        }
        job := RimeDepotJob(kind, callbacks, this)
        this.ActiveJob := job
        job.SetFinishHandler(ObjBindMethod(this, "_JobFinished"))
        job.Start()
        return job
    }

    _JobFinished(job) {
        if this.ActiveJob = job {
            this.ActiveJob := 0
        }
    }

    _NormalizeCallbacks(callbacks) {
        if callbacks is RimeDepotCallbacks {
            return callbacks
        }
        if IsObject(callbacks) {
            if HasMethod(callbacks, "Call") {
                return RimeDepotCallbacks(0, callbacks, 0)
            }
            progress := RimeDepotUtil.GetValue(callbacks, ["Progress", "progress"], 0)
            complete := RimeDepotUtil.GetValue(callbacks, ["Complete", "complete"], 0)
            error := RimeDepotUtil.GetValue(callbacks, ["Error", "error"], 0)
            return RimeDepotCallbacks(progress, complete, error)
        }
        return RimeDepotCallbacks()
    }
}
