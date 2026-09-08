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

try {
    RimeDepotRppiLiveProbeMain()
    ExitApp(0)
} catch as err {
    RimeDepotRppiLiveProbeReportError(err)
    ExitApp(1)
}

RimeDepotRppiLiveProbeMain() {
    local root, cache_path, url, proxy, service_options, request_options, service, observer
    local callbacks, job, count, refresh_count, entries, nested_entry, online_ids, refresh_ids
    local offline_service, offline_observer, offline_callbacks, offline_job, offline_count
    local offline_ids
    root := A_Temp . "\RimeDepot-RPPI-live-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt") . "-" . Random(100000, 999999)
    cache_path := root . "\cache"
    url := "https://raw.githubusercontent.com/rime/rppi/HEAD/index.json"
    proxy := A_Args.Length > 0 ? Trim(String(A_Args[1])) : ""
    service_options := Map(
        "CachePath", cache_path,
        "RppiIndexUrl", url
    )
    request_options := Map()
    if proxy != "" {
        ; An explicit argument is an opt-in override.  Leaving this key out
        ; lets RimeDepotConfig use the local INI value, or direct WinHTTP.
        service_options["Proxy"] := proxy
        request_options["Proxy"] := proxy
    }
    try {
        service := RimeDepotService(service_options)

        observer := RimeDepotRppiLiveProbeObserver()
        callbacks := RimeDepotCallbacks(
            ObjBindMethod(observer, "Progress"),
            ObjBindMethod(observer, "Complete"),
            ObjBindMethod(observer, "Error")
        )
        job := service.LoadCatalog(request_options, callbacks)
        RimeDepotRppiLiveProbeWait(job, 60000)
        RimeDepotRppiLiveProbeAssert(job.Status = "completed" && observer.Success,
            "Live RPPI LoadCatalog failed: " . observer.ErrorText)
        entries := service.Catalog.ToArray()
        count := entries.Length
        RimeDepotRppiLiveProbeAssert(count > 0, "Live RPPI LoadCatalog returned no catalog entries.")
        nested_entry := RimeDepotRppiLiveProbeHasNestedEntry(entries, url)
        online_ids := RimeDepotRppiLiveProbeEntryIds(entries)
        RimeDepotRppiLiveProbeAssert(service.Catalog.Sources.Length > 1 && nested_entry,
            "Live RPPI LoadCatalog did not recursively load a nested category entry.")
        FileAppend("LIVE RPPI LoadCatalog status=completed entries=" . count
            . " sources=" . service.Catalog.Sources.Length
            . " nested_entry=" . (nested_entry ? "true" : "false")
            . " warnings=" . service.Catalog.Warnings.Length . "`n", "*")

        observer := RimeDepotRppiLiveProbeObserver()
        callbacks := RimeDepotCallbacks(
            ObjBindMethod(observer, "Progress"),
            ObjBindMethod(observer, "Complete"),
            ObjBindMethod(observer, "Error")
        )
        job := service.RefreshCatalog(request_options, callbacks)
        RimeDepotRppiLiveProbeWait(job, 60000)
        RimeDepotRppiLiveProbeAssert(job.Status = "completed" && observer.Success,
            "Live RPPI RefreshCatalog failed: " . observer.ErrorText)
        entries := service.Catalog.ToArray()
        refresh_count := entries.Length
        RimeDepotRppiLiveProbeAssert(refresh_count > 0,
            "Live RPPI RefreshCatalog returned no catalog entries.")
        refresh_ids := RimeDepotRppiLiveProbeEntryIds(entries)
        nested_entry := RimeDepotRppiLiveProbeHasNestedEntry(entries, url)
        RimeDepotRppiLiveProbeAssert(service.Catalog.Sources.Length > 1 && nested_entry
            && refresh_count = count
            && RimeDepotRppiLiveProbeSameEntryIds(online_ids, refresh_ids),
            "Live RPPI RefreshCatalog changed the nested catalog entries.")
        FileAppend("LIVE RPPI RefreshCatalog status=completed entries=" . refresh_count
            . " sources=" . service.Catalog.Sources.Length
            . " nested_entry=" . (nested_entry ? "true" : "false")
            . " warnings=" . service.Catalog.Warnings.Length . "`n", "*")

        ; Reuse the committed generations through a separate offline
        ; transport.  This checks the user-visible stale-cache fallback while
        ; leaving the configured proxy untouched.
        offline_service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RppiIndexUrl", url
        ), "", Map("Http", RimeDepotRppiLiveProbeOfflineTransport()))
        offline_observer := RimeDepotRppiLiveProbeObserver()
        offline_callbacks := RimeDepotCallbacks(
            ObjBindMethod(offline_observer, "Progress"),
            ObjBindMethod(offline_observer, "Complete"),
            ObjBindMethod(offline_observer, "Error")
        )
        offline_job := offline_service.LoadCatalog(request_options, offline_callbacks)
        RimeDepotRppiLiveProbeWait(offline_job, 60000)
        RimeDepotRppiLiveProbeAssert(offline_job.Status = "completed" && offline_observer.Success,
            "Offline RPPI cache fallback failed: " . offline_observer.ErrorText)
        entries := offline_service.Catalog.ToArray()
        offline_count := entries.Length
        offline_ids := RimeDepotRppiLiveProbeEntryIds(entries)
        nested_entry := RimeDepotRppiLiveProbeHasNestedEntry(entries, url)
        RimeDepotRppiLiveProbeAssert(offline_count > 0 && offline_service.Catalog.Warnings.Length > 0,
            "Offline RPPI cache fallback returned no entries or warning.")
        RimeDepotRppiLiveProbeAssert(offline_count = count
            && RimeDepotRppiLiveProbeSameEntryIds(online_ids, offline_ids) && nested_entry,
            "Offline RPPI cache fallback changed the complete nested entry set.")
        FileAppend("LIVE RPPI cache fallback status=completed entries=" . offline_count
            . " warnings=" . offline_service.Catalog.Warnings.Length . "`n", "*")
    } finally {
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotRppiLiveProbeHasNestedEntry(entries, root_url) {
    local entry
    for _, entry in entries {
        if entry.CategoryPath != "" && entry.IndexUrl != "" && entry.IndexUrl != root_url {
            return true
        }
    }
    return false
}

RimeDepotRppiLiveProbeEntryIds(entries) {
    local ids := Map(), entry, key
    for _, entry in entries {
        key := StrLower(String(entry.Id))
        if key != "" {
            ids[key] := true
        }
    }
    return ids
}

RimeDepotRppiLiveProbeSameEntryIds(expected, actual) {
    local key
    if expected.Count != actual.Count {
        return false
    }
    for key, _ in expected {
        if !actual.Has(key) {
            return false
        }
    }
    return true
}

RimeDepotRppiLiveProbeWait(job, timeout) {
    local deadline := A_TickCount + timeout
    while !job.IsDone() && A_TickCount < deadline {
        Sleep(25)
    }
    if !job.IsDone() {
        job.Cancel()
        throw Error("Live RPPI request timed out after " . timeout . " ms.")
    }
}

RimeDepotRppiLiveProbeAssert(condition, message) {
    if !condition {
        throw Error(message)
    }
}

RimeDepotRppiLiveProbeReportError(err) {
    local message := "Uncaught exception: " . err.Message . "`n"
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
    FileAppend(message, "*")
}

class RimeDepotRppiLiveProbeObserver {
    __New() {
        this.Done := false
        this.Success := false
        this.ErrorText := ""
        this.ProgressCount := 0
    }

    Progress(job, value) {
        this.ProgressCount += 1
    }

    Complete(job, value) {
        this.Done := true
        this.Success := true
    }

    Error(job, error) {
        this.Done := true
        this.Success := false
        this.ErrorText := IsObject(error) && HasProp(error, "Message") ? error.Message : String(error)
    }
}

class RimeDepotRppiLiveProbeOfflineTransport {
    Get(url, options := 0, job := 0) {
        return RimeDepotHttpResponse(url, 0, "", Map(), Error("simulated offline transport"))
    }
}
