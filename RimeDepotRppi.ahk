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
#Include RimeDepotJson.ahk
#Include RimeDepotHttp.ahk

class RimeDepotCatalog {
    __New() {
        this.Entries := Map()
        this.Warnings := []
        this.Sources := []
    }

    Add(entry, id := "") {
        if !(entry is RimeDepotCatalogEntry) {
            entry := RimeDepotCatalogEntry(entry, id)
        }
        if id != "" && entry.Id = "" {
            entry.Id := id
        }
        if entry.Id = "" {
            entry.Id := entry.Name != "" ? entry.Name : entry.Repo
        }
        if entry.Name = "" {
            entry.Name := entry.Id
        }
        key := this._Key(entry.Id)
        if key = "" {
            throw RimeDepotCatalogError("Catalog entry has no usable identifier.")
        }
        if this.Entries.Has(key) {
            previous := this.Entries[key]
            ; Preserve a richer record when a child index only repeats a
            ; short record from its parent.
            if entry.Repo = "" {
                entry.Repo := previous.Repo
            }
            if entry.Dependencies.Length = 0 {
                entry.Dependencies := previous.Dependencies
            }
            if entry.Recipe = 0 {
                entry.Recipe := previous.Recipe
            }
        }
        this.Entries[key] := entry
        return entry
    }

    Resolve(value, allow_unknown := false) {
        if value is RimeDepotCatalogEntry {
            return value
        }
        if value is RimeDepotTarget {
            value := value.RawBase != "" ? value.RawBase : value.Name
        }
        value := String(value)
        candidates := [value]
        if InStr(value, "/") {
            candidates.Push(SubStr(value, InStr(value, "/", , -1) + 1))
            candidates.Push(RegExReplace(SubStr(value, InStr(value, "/", , -1) + 1), "i)^rime-", ""))
        }
        for _, candidate in candidates {
            key := this._Key(candidate)
            if key != "" && this.Entries.Has(key) {
                return this.Entries[key]
            }
            for _, entry in this.Entries {
                if this._Key(entry.Name) = key || this._Key(entry.Repo) = key {
                    return entry
                }
                repo_name := RegExReplace(SubStr(entry.Repo, InStr(entry.Repo, "/", , -1) + 1), "i)^rime-", "")
                if this._Key(repo_name) = key {
                    return entry
                }
            }
        }
        if allow_unknown {
            return 0
        }
        throw RimeDepotCatalogError("Unknown package dependency or target: " . value)
    }

    Validate() {
        states := Map()
        stack := []
        reverse := Map()
        for key, entry in this.Entries {
            for _, dependency in entry.Dependencies {
                dependency_value := RimeDepotCatalog.DependencyValue(dependency)
                if dependency_value = "" {
                    throw RimeDepotCatalogError("Empty dependency in catalog entry '" . entry.Id . "'.")
                }
                dependency_entry := this.Resolve(dependency_value)
                dependency_key := this._Key(dependency_entry.Id)
                if !reverse.Has(dependency_key) {
                    reverse[dependency_key] := []
                }
                reverse[dependency_key].Push(entry.Id)
            }
        }
        for key, entry in this.Entries {
            if !states.Has(key) || states[key] = 0 {
                this._Visit(entry, states, stack)
            }
        }
        for key, entry in this.Entries {
            if entry.ReverseDependencies.Length = 0 && reverse.Has(key) {
                entry.ReverseDependencies := reverse[key]
            }
        }
        return this
    }

    ToArray() {
        result := []
        for _, entry in this.Entries {
            result.Push(entry)
        }
        return result
    }

    static DependencyValue(value) {
        if !IsObject(value) {
            return String(value)
        }
        return RimeDepotUtil.GetString(value, ["id", "name", "repo", "package", "target"], "")
    }

    _Visit(entry, states, stack) {
        key := this._Key(entry.Id)
        state := states.Has(key) ? states[key] : 0
        if state = 1 {
            cycle := []
            found := false
            for _, item in stack {
                if this._Key(item.Id) = key {
                    found := true
                }
                if found {
                    cycle.Push(item.Id)
                }
            }
            cycle.Push(entry.Id)
            throw RimeDepotCatalogError("Circular package dependency: " . RimeDepotCatalog.Join(cycle, " -> "))
        }
        if state = 2 {
            return
        }
        states[key] := 1
        stack.Push(entry)
        for _, dependency in entry.Dependencies {
            dependency_entry := this.Resolve(RimeDepotCatalog.DependencyValue(dependency))
            this._Visit(dependency_entry, states, stack)
        }
        stack.Pop()
        states[key] := 2
    }

    _Key(value) {
        value := String(value)
        value := RegExReplace(value, "i)^https?://github\.com/", "")
        value := RegExReplace(value, "i)\.git$", "")
        return StrLower(Trim(value, " /\\"))
    }

    static Join(values, separator) {
        result := ""
        for index, value in values {
            if index > 1 {
                result .= separator
            }
            result .= value
        }
        return result
    }
}

class RimeDepotRppiCache {
    __New(cache_path, atomic_writer := 0) {
        this.Root := RimeDepotUtil.JoinPath(cache_path, "rppi")
        this.AtomicWriter := atomic_writer
        RimeDepotUtil.EnsureDirectory(this.Root)
    }

    Read(url) {
        local paths, metadata, cached_url, body_hash, generation, body_file, body_path, body, response
        paths := this._Paths(url)
        if !FileExist(paths.Meta) {
            return 0
        }
        try {
            metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
            cached_url := RimeDepotUtil.GetString(metadata, ["url", "URL"], "")
            if cached_url != url {
                return 0
            }
            body_hash := RimeDepotUtil.GetString(metadata, ["bodyHash", "body_hash"], "")
            generation := RimeDepotUtil.GetString(metadata, ["generation"], "")
            if body_hash = "" || generation = "" {
                return 0
            }
            body_file := RimeDepotUtil.GetString(metadata, ["BodyFile", "body_file"], "")
            if body_file != "" {
                body_path := this._BodyPath(url, body_file, generation)
                if !body_path || !FileExist(body_path) {
                    return 0
                }
            } else {
                ; Older releases used one fixed body file.  Keep accepting
                ; that format while all new commits use generation bodies.
                body_path := paths.Body
                if !FileExist(body_path) {
                    return 0
                }
            }
            body := FileRead(body_path, "UTF-8")
            if RimeDepotRppiCache.Hash(body) != body_hash {
                return 0
            }
            RimeDepotJson.Parse(body)
            response := RimeDepotHttpResponse(url, 200, body, Map(
                "ETag", RimeDepotUtil.GetString(metadata, ["etag", "ETag"], ""),
                "Last-Modified", RimeDepotUtil.GetString(metadata, ["lastModified", "last_modified"], "")
            ))
            response.FromCache := true
            response.StoredAt := RimeDepotUtil.GetString(metadata, ["storedAt", "stored_at"], "")
            return response
        } catch {
            ; A truncated body or metadata is not a usable cache entry.
            return 0
        }
    }

    Write(url, body, response) {
        local paths, old_body_file, old_generation, old_metadata, generation, body_file, body_path
        local metadata, old_body_path
        ; Validate before touching any cache file.  This is deliberately done
        ; here as well as in the catalog loader so callers cannot cache an
        ; arbitrary HTML error page as an index.
        RimeDepotJson.Parse(body)
        paths := this._Paths(url)
        old_body_file := ""
        old_generation := ""
        if FileExist(paths.Meta) {
            try {
                old_metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
                old_body_file := RimeDepotUtil.GetString(old_metadata, ["BodyFile", "body_file"], "")
                old_generation := RimeDepotUtil.GetString(old_metadata, ["generation"], "")
            }
        }
        generation := RimeDepotUtil.NextId()
        body_file := paths.Prefix . generation . ".json"
        body_path := RimeDepotUtil.JoinPath(this.Root, body_file)
        metadata := RimeDepotJson.Stringify(Map(
            "url", url,
            "etag", response.ETag,
            "lastModified", response.LastModified,
            "storedAt", A_NowUTC,
            "generation", generation,
            "bodyHash", RimeDepotRppiCache.Hash(body),
            "BodyFile", body_file
        ))
        ; The generation body is durable before metadata points at it.  The
        ; metadata replacement is the commit point; the previous pointer and
        ; body remain intact if either write is interrupted.
        this._AtomicWrite(body_path, body)
        this._AtomicWrite(paths.Meta, metadata)
        old_body_path := this._BodyPath(url, old_body_file, old_generation)
        if old_body_path && old_body_path != body_path {
            try FileDelete(old_body_path)
        }
        return this.Read(url)
    }

    _Paths(url) {
        key := RimeDepotRppiCache.Hash(url)
        return {
            Key: key,
            Prefix: "index-" . key . "-",
            Body: RimeDepotUtil.JoinPath(this.Root, "index-" . key . ".json"),
            Meta: RimeDepotUtil.JoinPath(this.Root, "index-" . key . ".meta.json")
        }
    }

    _BodyPath(url, body_file, generation := "") {
        local paths := this._Paths(url)
        if body_file = "" || body_file ~= "[\\/\r\n]" {
            return ""
        }
        if body_file != RegExReplace(body_file, ".*[\\/]", "") {
            return ""
        }
        if !RegExMatch(body_file, "^" . paths.Prefix . "[A-Za-z0-9-]+\.json$") {
            return ""
        }
        if generation != "" && body_file != paths.Prefix . generation . ".json" {
            return ""
        }
        return RimeDepotUtil.JoinPath(this.Root, body_file)
    }

    _AtomicWrite(path, content) {
        if this.AtomicWriter {
            if HasMethod(this.AtomicWriter, "Call") {
                return this.AtomicWriter.Call(path, content)
            }
            if HasMethod(this.AtomicWriter, "Write") {
                return this.AtomicWriter.Write(path, content)
            }
            throw RimeDepotError("Cache atomic writer has no Call or Write method.", "RimeDepotRppiCache")
        }
        return RimeDepotUtil.AtomicWrite(path, content)
    }

    static Hash(value) {
        hash := 5381
        for _, char in StrSplit(String(value)) {
            hash := Mod(hash * 33 + Ord(char), 2147483647)
        }
        return Format("{:x}", hash)
    }
}

/** Asynchronous loader for one or more linked RPPI index.json documents. */
class RimeDepotRppiLoadOperation {
    __New(client, cache, root_url, options, job, callback) {
        this.Client := client
        this.Cache := cache
        this.RootUrl := root_url
        this.Options := IsObject(options) ? options : Map()
        this.Job := job
        this.Callback := callback
        ; Keep the category path alongside each URL.  A child index can be
        ; referenced by more than one category, so the first path is retained
        ; for deterministic display and search results.
        this.Queue := [{Url: root_url, CategoryPath: ""}]
        this.Visited := Map()
        this.Catalog := RimeDepotCatalog()
        this.Warnings := []
        this.ActiveRequest := 0
        this.Done := false
        this._step_timer := ObjBindMethod(this, "_Step")
    }

    Start() {
        SetTimer(this._step_timer, -1)
        return this
    }

    Cancel(*) {
        if this.ActiveRequest && HasMethod(this.ActiveRequest, "Cancel") {
            this.ActiveRequest.Cancel()
        }
        this.Done := true
        this.Queue := []
    }

    _Step() {
        if this.Done || this.Job.IsCancelled() {
            return
        }
        while this.Queue.Length {
            queued := this.Queue.RemoveAt(1)
            if IsObject(queued) {
                url := RimeDepotUtil.GetString(queued, ["Url", "url"], "")
                category_path := RimeDepotUtil.GetString(queued, ["CategoryPath", "category_path"], "")
            } else {
                url := String(queued)
                category_path := ""
            }
            if url = "" {
                continue
            }
            key := StrLower(url)
            if this.Visited.Has(key) {
                continue
            }
            this.Visited[key] := true
            this._Fetch(url, category_path)
            return
        }
        this._Finish()
    }

    _Fetch(url, category_path := "") {
        cached := this.Cache.Read(url)
        headers := Map()
        if cached {
            if cached.ETag != "" {
                headers["If-None-Match"] := cached.ETag
            }
            if cached.LastModified != "" {
                headers["If-Modified-Since"] := cached.LastModified
            }
        }
        request_options := Map(
            "Proxy", RimeDepotUtil.GetString(this.Options, ["Proxy", "proxy"], ""),
            "Headers", headers
        )
        this.Job.ReportProgress(Map("phase", "catalog", "state", "fetching", "url", url,
            "cached", !!cached))
        try {
            this.ActiveRequest := this.Client.GetAsync(
                url, ObjBindMethod(this, "_Response", url, cached, category_path), request_options, this.Job)
        } catch as err {
            this._Response(url, cached, category_path, RimeDepotHttpResponse(url, 0, "", Map(), err))
        }
    }

    _Response(url, cached, category_path, response) {
        this.ActiveRequest := 0
        if this.Done || this.Job.IsCancelled() {
            return
        }
        try {
            if response && response.Status = 304 && cached {
                response := cached
            } else if response && response.Ok() {
                body := response.Body
                ; Parse and inspect before atomic cache replacement.
                document := RimeDepotJson.Parse(body)
                this.Cache.Write(url, body, response)
                this._Consume(document, url, category_path)
                this.Job.ReportProgress(Map("phase", "catalog", "state", "loaded", "url", url,
                    "cached", false))
                SetTimer(this._step_timer, -1)
                return
            } else if cached {
                cached.Stale := true
                warning := Map("kind", "stale", "url", url,
                    "message", "Network failed; using the last complete cached RPPI index.",
                    "error", response && response.Error ? response.Error : "HTTP status " . (response ? response.Status : 0))
                this.Warnings.Push(warning)
                this.Catalog.Warnings.Push(warning)
                this.Job.ReportProgress(Map("phase", "catalog", "state", "warning", "warning", warning))
                this._Consume(RimeDepotJson.Parse(cached.Body), url, category_path)
                SetTimer(this._step_timer, -1)
                return
            } else {
                message := response && response.Error ? response.Error.Message : "HTTP status " . (response ? response.Status : 0)
                throw RimeDepotCatalogError("Unable to load RPPI index '" . url . "': " . message)
            }
            this._Consume(RimeDepotJson.Parse(response.Body), url, category_path)
            SetTimer(this._step_timer, -1)
        } catch as err {
            this.Done := true
            this.Callback.Call(0, err, this.Warnings)
        }
    }

    _Consume(document, url, category_path := "") {
        this.Catalog.Sources.Push(url)
        this._Collect(document, url, "", "", category_path)
    }

    _Collect(value, base_url, suggested_id := "", container := "", category_path := "") {
        if value is Array {
            for _, item in value {
                if !IsObject(item) {
                    if RimeDepotUtil.IsUrl(String(item)) || container = "links" {
                        this._QueueUrl(base_url, String(item), category_path)
                    }
                } else {
                    this._Collect(item, base_url, "", container, category_path)
                }
            }
            return
        }
        if !IsObject(value) {
            if RimeDepotUtil.IsUrl(String(value)) || container = "links" {
                this._QueueUrl(base_url, String(value), category_path)
            } else if suggested_id != "" && container != "" {
                this._AddScalarEntry(suggested_id, value, base_url, category_path)
            }
            return
        }

        ; Official RPPI documents put package records below a parent
        ; `categories` array and expose records in a child document's
        ; `recipes` array.  Handle those containers before the generic entry
        ; test: a category's display `name` must not become a fake package.
        if value.Has("categories") {
            this._CollectCategories(value["categories"], base_url, category_path)
        }
        if value.Has("recipes") {
            this._CollectRecipes(value["recipes"], base_url, category_path)
        }

        if this._IsEntry(value) && (suggested_id != "" || container != "" || base_url = this.RootUrl) {
            entry_data := this._CopyMap(value)
            if suggested_id != "" && !entry_data.Has("id") {
                entry_data["id"] := suggested_id
            }
            this._SetCategory(entry_data, category_path)
            entry := this.Catalog.Add(RimeDepotCatalogEntry(entry_data, suggested_id), suggested_id)
            if entry.IndexUrl = "" {
                entry.IndexUrl := base_url
            }
            return
        }

        known_containers := ["entries", "packages", "repos", "repositories", "repo", "catalog", "data", "items"]
        for _, field in known_containers {
            if value.Has(field) {
                this._CollectContainer(value[field], base_url, field, category_path)
            }
        }
        for _, field in ["index", "indexes", "sources", "children", "includes", "manifests"] {
            if value.Has(field) {
                this._Collect(value[field], base_url, "", "links", category_path)
            }
        }

        ; Some RPPI versions use a map directly at the root: package id ->
        ; metadata.  Traverse only unclaimed map members as entries/links.
        for key, item in value {
            if key ~= "i)^(categories|recipes|entries|packages|repos|repositories|repo|catalog|data|items|index|indexes|sources|children|includes|manifests|date|last_update|lastUpdated)$" {
                continue
            }
            if !IsObject(item) && RimeDepotUtil.IsUrl(String(item)) {
                this._QueueUrl(base_url, String(item), category_path)
            } else if IsObject(item) && this._IsEntry(item) {
                this._Collect(item, base_url, key, "map", category_path)
            }
        }
    }

    _CollectCategories(value, base_url, parent_category := "") {
        if value is Array {
            for _, category in value {
                if IsObject(category) {
                    this._CollectCategory(category, base_url, parent_category)
                }
            }
            return
        }
        if IsObject(value) {
            ; Accept a mapping keyed by category id as a compatibility form.
            for key, category in value {
                if IsObject(category) {
                    this._CollectCategory(category, base_url, parent_category, key)
                }
            }
        }
    }

    _CollectCategory(category, base_url, parent_category := "", suggested_name := "") {
        category_name := RimeDepotUtil.GetString(
            category, ["display_name", "displayName", "title", "name", "label"], suggested_name)
        category_key := RimeDepotUtil.GetString(category, ["key", "id", "path"], "")
        category_path := parent_category
        if category_name != "" {
            category_path := category_path = "" ? category_name : parent_category . " / " . category_name
        }
        if category.Has("categories") {
            this._CollectCategories(category["categories"], base_url, category_path)
        }
        if category.Has("recipes") {
            this._CollectRecipes(category["recipes"], base_url, category_path)
        }
        if category.Has("entries") {
            this._CollectContainer(category["entries"], base_url, "entries", category_path)
        }
        ; Official RPPI category records identify their child index by key.
        ; Resolve it relative to the parent index without treating the key as
        ; a package record, while carrying the display path to child recipes.
        if category_key != "" {
            this._QueueUrl(base_url, category_key . "/index.json", category_path)
        }
        ; A category may point to a child index directly.  Do not treat its
        ; descriptive URL as a package record when `recipes` is absent.
        for _, field in ["index", "url", "source", "href"] {
            if category.Has(field) && !IsObject(category[field]) {
                candidate := String(category[field])
                if candidate != "" {
                    this._QueueUrl(base_url, candidate, category_path)
                }
            }
        }
    }

    _CollectRecipes(value, base_url, category_path := "") {
        if value is Array {
            for _, recipe in value {
                if IsObject(recipe) {
                    this._Collect(recipe, base_url, "", "recipes", category_path)
                } else if RimeDepotUtil.IsUrl(String(recipe)) {
                    this._QueueUrl(base_url, String(recipe), category_path)
                }
            }
            return
        }
        if IsObject(value) {
            for key, recipe in value {
                if IsObject(recipe) {
                    this._Collect(recipe, base_url, key, "recipes", category_path)
                } else if RimeDepotUtil.IsUrl(String(recipe)) {
                    this._QueueUrl(base_url, String(recipe), category_path)
                }
            }
        } else if RimeDepotUtil.IsUrl(String(value)) {
            this._QueueUrl(base_url, String(value), category_path)
        }
    }

    _CollectContainer(value, base_url, container, category_path := "") {
        if value is Array {
            for _, item in value {
                if IsObject(item) {
                    this._Collect(item, base_url, "", container, category_path)
                } else if RimeDepotUtil.IsUrl(String(item)) {
                    this._QueueUrl(base_url, String(item), category_path)
                }
            }
            return
        }
        if !IsObject(value) {
            return
        }
        if this._IsEntry(value) {
            this._Collect(value, base_url, "", container, category_path)
            return
        }
        for key, item in value {
            if IsObject(item) {
                this._Collect(item, base_url, key, container, category_path)
            } else if RimeDepotUtil.IsUrl(String(item)) {
                ; A repositories map may contain linked index documents.
                this._QueueUrl(base_url, String(item), category_path)
            } else if container = "repos" || container = "repositories" || container = "repo" {
                this._AddScalarEntry(key, item, base_url, category_path)
            }
        }
    }

    _AddScalarEntry(id, value, base_url, category_path := "") {
        data := Map("id", id, "name", id, "repo", String(value), "indexUrl", base_url)
        this._SetCategory(data, category_path)
        this.Catalog.Add(data, id)
    }

    _SetCategory(data, category_path) {
        if category_path != "" {
            data["category_path"] := category_path
            if !data.Has("category") {
                data["category"] := category_path
            }
        }
    }

    _IsEntry(value) {
        for _, key in ["repo", "repository", "package", "dependencies", "branch", "tag", "sha", "ref", "license", "labels", "schemas", "recipe"] {
            if value.Has(key) {
                return true
            }
        }
        return false
    }

    _CopyMap(value) {
        result := Map()
        for key, item in value {
            result[key] := item
        }
        return result
    }

    _QueueUrl(base_url, child, category_path := "") {
        child := RimeDepotRppiLoadOperation.ResolveUrl(base_url, child)
        if child != "" && !this.Visited.Has(StrLower(child)) {
            this.Queue.Push({Url: child, CategoryPath: category_path})
        }
    }

    _Finish() {
        if this.Done {
            return
        }
        try {
            this.Catalog.Validate()
            this.Done := true
            this.Callback.Call(this.Catalog, 0, this.Warnings)
        } catch as err {
            this.Done := true
            this.Callback.Call(0, err, this.Warnings)
        }
    }

    static ResolveUrl(base, child) {
        child := String(child)
        if RimeDepotUtil.IsUrl(child) {
            return child
        }
        if SubStr(child, 1, 2) = "//" {
            scheme := RegExMatch(base, "i)^(https?):", &match) ? match[1] : "https"
            return scheme . ":" . child
        }
        if SubStr(child, 1, 1) = "/" {
            if RegExMatch(base, "i)^(https?://[^/]+)", &match) {
                return match[1] . child
            }
            return ""
        }
        ; Keep the authority's double slash intact.  Splitting the complete
        ; URL on `/` and joining it again turns `https://` into `https:/`.
        ; Resolve the path separately, then prepend the original authority.
        if RegExMatch(base, "i)^(https?://[^/]+)(/.*)?$", &match) {
            authority := match[1]
            base_path := match[2] != "" ? match[2] : "/"
            base_path := RegExReplace(base_path, "/[^/]*$", "/")
            parts := StrSplit(base_path . child, "/")
            output := []
            for _, part in parts {
                if part = "" || part = "." {
                    continue
                }
                if part = ".." {
                    if output.Length {
                        output.Pop()
                    }
                    continue
                }
                output.Push(part)
            }
            return authority . "/" . RimeDepotCatalog.Join(output, "/")
        }
        base := RegExReplace(base, "[/\\][^/\\]*$", "")
        parts := StrSplit(base . "/" . child, "/")
        output := []
        for _, part in parts {
            if part = "" || part = "." {
                continue
            }
            if part = ".." {
                if output.Length {
                    output.Pop()
                }
                continue
            }
            output.Push(part)
        }
        return RimeDepotCatalog.Join(output, "/")
    }
}
