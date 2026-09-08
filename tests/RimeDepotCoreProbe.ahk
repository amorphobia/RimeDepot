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
    RimeDepotCoreProbeMain()
} catch as err {
    RimeDepotCoreProbeReportError(err)
    ExitApp(1)
}

RimeDepotCoreProbeMain() {
    RimeDepotCoreProbeTest("JSON", RimeDepotCoreProbeJson.Bind())
    RimeDepotCoreProbeTest("YAML", RimeDepotCoreProbeYaml.Bind())
    RimeDepotCoreProbeTest("target and security", RimeDepotCoreProbeTarget.Bind())
    RimeDepotCoreProbeTest("config precedence", RimeDepotCoreProbeConfig.Bind())
    RimeDepotCoreProbeTest("GUI settings INI round-trip", RimeDepotCoreProbeGuiSettings.Bind())
    RimeDepotCoreProbeTest("catalog async and cache fallback", RimeDepotCoreProbeCatalog.Bind())
    RimeDepotCoreProbeTest("official RPPI categories and recipes", RimeDepotCoreProbeOfficialRppi.Bind())
    RimeDepotCoreProbeTest("git safety", RimeDepotCoreProbeGit.Bind())
    RimeDepotCoreProbeTest("git argv quoting", RimeDepotCoreProbeGitQuoting.Bind())
    RimeDepotCoreProbeTest("git SHA command plan", RimeDepotCoreProbeGitSha.Bind())
    RimeDepotCoreProbeTest("local git --version process", RimeDepotCoreProbeGitVersion.Bind())
    RimeDepotCoreProbeTest("recipe safety", RimeDepotCoreProbeRecipe.Bind())
    RimeDepotCoreProbeTest("recipe apply", RimeDepotCoreProbeRecipeApply.Bind())
    RimeDepotCoreProbeTest("direct owner/repository InstallTarget", RimeDepotCoreProbeInstallTarget.Bind())
    RimeDepotCoreProbeTest("archive async and cancellation", RimeDepotCoreProbeArchive.Bind())
    RimeDepotCoreProbeTest("cache generation integrity", RimeDepotCoreProbeCacheIntegrity.Bind())
    RimeDepotCoreProbeTest("HTTP request lifecycle", RimeDepotCoreProbeHttpLifecycle.Bind())
    FileAppend("RimeDepot core probe passed`n", "*")
    ExitApp(0)
}

RimeDepotCoreProbeTest(name, callback) {
    try {
        callback.Call()
        FileAppend("PASS " . name . "`n", "*")
    } catch as err {
        FileAppend("FAIL " . name . ": " . err.Message . "`n", "*")
        throw err
    }
}

RimeDepotCoreProbeJson() {
    value := RimeDepotJson.Parse('{"a":[true,false,null,"x\n"],"n":-1.25e2}')
    RimeDepotCoreProbeAssert(value["a"][1] = true, "JSON true value was not parsed.")
    RimeDepotCoreProbeAssert(value["a"][2] = false, "JSON false value was not parsed.")
    RimeDepotCoreProbeAssert(value["a"][3] = "", "JSON null value was not normalized.")
    RimeDepotCoreProbeAssert(value["n"] = -125, "JSON number was not parsed.")
    text := RimeDepotJson.Stringify(value)
    RimeDepotCoreProbeAssert(IsObject(RimeDepotJson.Parse(text)), "JSON writer output was not readable.")
}

RimeDepotCoreProbeYaml() {
    value := RimeDepotYaml.Parse("entries:`n  foo:`n    repo: owner/foo`n    labels: [one, two]`n  bar:`n    repo: owner/bar`nrecipe: |`n  line one`n  line two`n")
    RimeDepotCoreProbeAssert(value["entries"]["foo"]["repo"] = "owner/foo", "YAML mapping failed.")
    RimeDepotCoreProbeAssert(value["entries"]["foo"]["labels"][2] = "two", "YAML flow array failed.")
    RimeDepotCoreProbeAssert(InStr(value["recipe"], "line two") > 0, "YAML block string failed.")
}

RimeDepotCoreProbeTarget() {
    target := RimeDepotTarget.Parse("owner/repo@v1:basic:mode=fast")
    RimeDepotCoreProbeAssert(target.Name = "owner/repo", "Target name was not parsed.")
    RimeDepotCoreProbeAssert(target.Ref = "v1" && target.Recipe = "basic", "Target ref or recipe was not parsed.")
    RimeDepotCoreProbeAssert(target.Parameters["mode"] = "fast", "Target parameter was not parsed.")
    RimeDepotCoreProbeThrows(RimeDepotTargetError, RimeDepotTarget.Parse.Bind("owner/repo:bad:1unsafe=x"),
        "Unsafe target parameter was accepted.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotUtil.SafeRelativePath.Bind("..\\escape"),
        "Parent path was accepted.")
}

RimeDepotCoreProbeConfig() {
    ini_path := A_Temp . "\\RimeDepotCoreProbe-" . A_TickCount . ".ini"
    FileAppend("[RimeDepot]`nCachePath=ini-cache`nRimeDirectory=ini-rime`nUseGit=1`nGitPath=ini-git.exe`n", ini_path)
    try {
        config := RimeDepotConfig.Load(Map(
            "CachePath", "api-cache",
            "UseGit", false,
            "GitPath", "api-git.exe"
        ), ini_path)
        RimeDepotCoreProbeAssert(config.CachePath = "api-cache", "API did not override INI CachePath.")
        RimeDepotCoreProbeAssert(config.RimeDirectory = "ini-rime", "INI RimeDirectory was not loaded.")
        RimeDepotCoreProbeAssert(!config.UseGit, "API did not override INI UseGit.")
        RimeDepotCoreProbeAssert(config.GitPath = "api-git.exe", "API did not override INI GitPath.")
    } finally {
        if FileExist(ini_path) {
            FileDelete(ini_path)
        }
    }
}

RimeDepotCoreProbeGuiSettings() {
    local root, cache_path, rime_path, settings_path, url, values, service, gui, loaded, result
    root := A_Temp . "\RimeDepotGuiSettings-" . A_TickCount . "-"
        . DllCall("GetCurrentProcessId", "UInt") . "-" . Random(100000, 999999)
    cache_path := root . "\cache"
    rime_path := root . "\rime"
    settings_path := root . "\settings.ini"
    url := "https://example.invalid/index.json"
    values := Map(
        "CachePath", cache_path,
        "RimeDirectory", rime_path,
        "RppiIndexUrl", url,
        "Proxy", "http://127.0.0.1:7890",
        "UseGit", true,
        "GitPath", "C:\Tools\git.exe"
    )
    gui := 0
    try {
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", url
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map())))
        gui := RimeDepotGui(service, RimeDepotGuiSettings(values), settings_path)
        ; Invoke the same bound callback installed on the Save button, without
        ; showing a window or dispatching a native click.
        RimeDepotCoreProbeAssert(gui.save_settings_button.OnEvent,
            "GUI Save button was not created.")
        result := gui.SaveSettings.Bind(gui).Call(gui.save_settings_button, 0)
        RimeDepotCoreProbeAssert(result, "GUI Save button callback failed: " . gui.status_text.Value)
        loaded := RimeDepotGuiSettings.Load(settings_path)
        RimeDepotCoreProbeAssert(loaded.cache_path = cache_path
            && loaded.rime_directory = rime_path
            && loaded.rppi_index_url = url
            && loaded.proxy = values["Proxy"]
            && loaded.use_git
            && loaded.git_path = values["GitPath"],
            "GUI Save button did not round-trip all six settings fields.")
    } finally {
        if IsObject(gui) {
            try gui.Dispose()
        }
        if FileExist(settings_path) {
            try FileDelete(settings_path)
        }
        if DirExist(root) {
            try RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeCatalog() {
    local loaded_count, fallback_count
    cache_path := A_Temp . "\\RimeDepotCoreProbe-cache-" . A_TickCount
    root_url := "https://example.invalid/index.json"
    child_url := "https://example.invalid/child.json"
    first_transport := RimeDepotCoreProbeTransport(Map(
        root_url, RimeDepotHttpResponse(root_url, 200,
            '{"entries":{"foo":{"repo":"owner/foo","dependencies":["bar"]},"bar":{"repo":"owner/bar"}},"indexes":["child.json"]}',
            Map("ETag", "probe")),
        child_url, RimeDepotHttpResponse(child_url, 200, '{"entries":{"child":{"repo":"owner/child"}}}')
    ))
    try {
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", first_transport))
        callbacks := RimeDepotCoreProbeCallbacks()
        job := service.LoadCatalog(callbacks)
        RimeDepotCoreProbeWait(job)
        error_text := job.Error ? job.Error.Message : ""
        RimeDepotCoreProbeAssert(job.Status = "completed", "Catalog load did not complete (status=" . job.Status . ", error=" . error_text . ").")
        RimeDepotCoreProbeAssert(service.GetEntry("foo").Dependencies.Length = 1, "Catalog dependency was not loaded.")
        RimeDepotCoreProbeAssert(service.GetEntry("child").Repo = "owner/child", "Linked catalog was not loaded.")
        loaded_count := service.Catalog.ToArray().Length

        fallback_transport := RimeDepotCoreProbeTransport(Map(
            root_url, RimeDepotHttpResponse(root_url, 0, "", Map(), Error("offline")),
            child_url, RimeDepotHttpResponse(child_url, 0, "", Map(), Error("offline"))
        ))
        fallback_service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", fallback_transport))
        fallback_job := fallback_service.LoadCatalog(callbacks)
        RimeDepotCoreProbeWait(fallback_job)
        RimeDepotCoreProbeAssert(fallback_job.Status = "completed", "Cached catalog fallback did not complete.")
        RimeDepotCoreProbeAssert(fallback_service.Catalog.Warnings.Length > 0, "Stale cache warning was not recorded.")
        fallback_count := fallback_service.Catalog.ToArray().Length
        RimeDepotCoreProbeAssert(fallback_count = loaded_count
            && fallback_service.GetEntry("foo").Dependencies.Length = 1
            && fallback_service.GetEntry("bar").Repo = "owner/bar"
            && fallback_service.GetEntry("child").Repo = "owner/child",
            "Cached catalog fallback changed the complete fixture entry set.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeOfficialRppi() {
    local cache_path, root_url, child_url, transport, service, job, entry
    cache_path := A_Temp . "\\RimeDepotCoreProbe-rppi-official-" . A_TickCount
    root_url := "https://example.invalid/index.json"
    child_url := "https://example.invalid/recipes/index.json"
    transport := RimeDepotCoreProbeTransport(Map(
        root_url, RimeDepotHttpResponse(root_url, 200,
            '{"categories":[{"key":"recipes","name":"Schemes"}]}', Map()),
        child_url, RimeDepotHttpResponse(child_url, 200,
            '{"recipes":[{"id":"demo","name":"Demo scheme","repo":"owner/demo","schemas":["demo.schema"]}]}', Map())
    ))
    try {
        service := RimeDepotService(Map("CachePath", cache_path, "RppiIndexUrl", root_url), "",
            Map("Http", transport))
        job := service.LoadCatalog(RimeDepotCoreProbeCallbacks())
        RimeDepotCoreProbeWait(job)
        RimeDepotCoreProbeAssert(job.Status = "completed", "Official RPPI fixture did not complete.")
        RimeDepotCoreProbeAssert(service.Catalog.ToArray().Length >= 1,
            "Official RPPI categories/recipes fixture produced no catalog entries.")
        entry := service.GetEntry("demo")
        RimeDepotCoreProbeAssert(entry.Name = "Demo scheme", "Official RPPI recipe name was not retained.")
        RimeDepotCoreProbeAssert(entry.CategoryPath = "Schemes",
            "Official RPPI category display name was not retained in the category path.")
        RimeDepotCoreProbeAssert(entry.IndexUrl = child_url, "Child RPPI index URL was not retained.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeGit() {
    RimeDepotCoreProbeAssert(RimeDepotGitRunner.ValidateExecutable("C:\\Program Files\\Git\\cmd\\git.exe"),
        "Valid git executable was rejected.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotGitRunner.ValidateExecutable.Bind("cmd.exe"),
        "Shell executable was accepted as GitPath.")
    RimeDepotCoreProbeThrows(RimeDepotSecurityError, RimeDepotGitRunner.ValidateExecutable.Bind("git.exe & whoami"),
        "Command-injected GitPath was accepted.")
}

RimeDepotCoreProbeGitQuoting() {
    local ordinary, trailing, embedded
    ordinary := RimeDepotGitRunner.QuoteArgument("C:\Program Files\Git\bin\git.exe")
    RimeDepotCoreProbeAssert(ordinary = Chr(34) . "C:\Program Files\Git\bin\git.exe" . Chr(34),
        "Git quoting changed ordinary path backslashes.")
    trailing := RimeDepotGitRunner.QuoteArgument("C:\git\")
    RimeDepotCoreProbeAssert(trailing = Chr(34) . "C:\git" . Chr(92) . Chr(92) . Chr(34),
        "Git quoting did not double a trailing backslash before the closing quote.")
    embedded := RimeDepotGitRunner.QuoteArgument('a"b')
    RimeDepotCoreProbeAssert(embedded = Chr(34) . "a" . Chr(92) . Chr(34) . "b" . Chr(34),
        "Git quoting did not escape an embedded quote.")
}

RimeDepotCoreProbeGitSha() {
    local cache_path, destination, sha, config, launcher, runner, client, job, outcome, operation, commands
    local command, built
    cache_path := A_Temp . "\\RimeDepotCoreProbe-git-sha-" . A_TickCount
    destination := RimeDepotUtil.NormalizePath(cache_path . "\\owner-repository")
    sha := "0123456789abcdef0123456789abcdef01234567"
    try {
        config := RimeDepotConfig(Map("CachePath", cache_path))
        launcher := RimeDepotCoreProbeGitLauncher()
        runner := RimeDepotGitRunner("git.exe", launcher)
        client := RimeDepotGitClient(config, runner)
        job := RimeDepotJob("git-sha")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        operation := client.FetchAsync("owner/repository", destination, sha, job,
            ObjBindMethod(outcome, "Git"))
        RimeDepotCoreProbeAssert(outcome.Done && outcome.Success,
            "The fake SHA Git state machine did not complete successfully.")
        commands := launcher.Commands
        RimeDepotCoreProbeAssert(commands.Length = 4,
            "SHA fetch planned an unexpected number of Git commands.")
        command := commands[1].Arguments
        RimeDepotCoreProbeAssert(command.Length = 2 && command[1] = "init" && command[2] = destination,
            "SHA fetch did not begin with git init.")
        command := commands[2].Arguments
        RimeDepotCoreProbeAssert(command.Length = 6 && command[1] = "-C" && command[2] = destination
            && command[3] = "remote" && command[4] = "add" && command[5] = "origin"
            && command[6] = "https://github.com/owner/repository.git",
            "SHA fetch did not add the origin with direct Git arguments.")
        command := commands[3].Arguments
        RimeDepotCoreProbeAssert(command.Length = 7 && command[3] = "fetch" && command[4] = "--depth"
            && command[5] = "1" && command[6] = "origin" && command[7] = sha,
            "SHA fetch did not fetch the requested object directly.")
        command := commands[4].Arguments
        RimeDepotCoreProbeAssert(command.Length = 6 && command[3] = "checkout" && command[4] = "--force"
            && command[5] = "--detach" && command[6] = "FETCH_HEAD",
            "SHA fetch did not checkout FETCH_HEAD in detached mode.")
        RimeDepotCoreProbeAssert(!RimeDepotCoreProbeGitHasToken(commands, "clone"),
            "SHA fetch incorrectly used clone before fetching the full SHA.")
        built := RimeDepotGitRunner.BuildCommand("git.exe", ["fetch", "origin", "a&b"])
        RimeDepotCoreProbeAssert(!InStr(built, "cmd.exe") && InStr(built, '"a&b"') > 0,
            "Git command planning did not preserve direct executable argument quoting.")
    } finally {
        if DirExist(cache_path) {
            RimeDepotUtil.DeleteTree(cache_path)
        }
    }
}

RimeDepotCoreProbeGitVersion() {
    local config, git_path, runner, outcome, job, process
    config := RimeDepotConfig()
    git_path := config.ResolveGitPath()
    if git_path = "git.exe" {
        FileAppend("SKIP git --version: git.exe was not found on PATH`n", "*")
        return
    }
    runner := RimeDepotGitRunner(git_path)
    outcome := RimeDepotCoreProbeOutcome()
    job := RimeDepotJob("git-version")
    job.Start()
    process := runner.RunAsync(["--version"], A_WorkingDir, ObjBindMethod(outcome, "Git"), job)
    try {
        RimeDepotCoreProbeWaitSignal(outcome, 5000)
        RimeDepotCoreProbeAssert(outcome.Success && outcome.Value = 0,
            "The local git --version process did not exit successfully.")
        RimeDepotCoreProbeAssert(process.Status = "completed" && !process.Handle,
            "The local git process did not finish and release its process handle.")
    } finally {
        if !job.IsDone() {
            job.Complete(outcome.Value)
        }
    }
}

RimeDepotCoreProbeGitHasToken(commands, token) {
    local command, argument
    for _, command in commands {
        for _, argument in command.Arguments {
            if StrLower(String(argument)) = StrLower(token) {
                return true
            }
        }
    }
    return false
}

RimeDepotCoreProbeRecipe() {
    local plum_fixture, plum_recipe
    recipe := RimeDepotRecipe.Parse(Map(
        "rx", "demo",
        "install_files", ["*.yaml"],
        "patch_files", Map("default.custom.yaml", "patch")
    ), "demo")
    RimeDepotCoreProbeAssert(recipe.Name = "demo", "Recipe name was not retained.")
    RimeDepotCoreProbeThrows(RimeDepotUnsupportedError, RimeDepotRecipe.Parse.Bind(Map("command", "echo hi")),
        "Executable recipe key was accepted.")
    plum_fixture := "recipe:`n  Rx: morse`n  description: >-`n    A nested recipe fixture`ninstall_files: >-`n  morse.schema.yaml`n  lua/morse/morse.lua`n  lua/morse/morse_processor.lua`n  lua/morse/morse_translator.lua`n  lua/morse/morse_filter.lua`n"
    plum_recipe := RimeDepotRecipe.Parse(plum_fixture, "morse")
    RimeDepotCoreProbeAssert(plum_recipe.Rx = "morse", "Plum nested recipe metadata was not parsed.")
    RimeDepotCoreProbeAssert(plum_recipe.InstallFiles.Length = 5, "Plum folded install list was not split.")
}

RimeDepotCoreProbeRecipeApply() {
    local root, source_root, destination_root, url, fixture, recipe, transport, client, job, outcome, operation
    local installed_path, patch_path, installed_text, patch_text
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-recipe-" . A_TickCount)
    source_root := RimeDepotUtil.JoinPath(root, "source")
    destination_root := RimeDepotUtil.JoinPath(root, "destination")
    url := "https://example.invalid/demo.txt"
    fixture := '{"recipe":{"rx":"demo","description":"fixture recipe","args":{"name":{"default":"Alice"},"channel":"stable"}},"download_files":[{"url":"https://example.invalid/demo.txt","filename":"${name:-fallback}.txt"}],"install_files":["*.txt"],"patch_files":{"config.yaml":{"name":"${name:-fallback}","files":["${channel}","literal"],"nested":{"enabled":true}}}}'
    try {
        recipe := RimeDepotRecipe.Parse(fixture, "fixture")
        RimeDepotCoreProbeAssert(recipe.Args.Has("name"), "Recipe args metadata was not parsed.")
        RimeDepotCoreProbeAssert(RimeDepotRecipe.Expand("${missing:-fallback}", Map()) = "fallback",
            "Recipe default parameter syntax was not expanded.")
        transport := RimeDepotCoreProbeTransport(Map(
            url, RimeDepotHttpResponse(url, 200, "downloaded recipe data`n", Map())
        ))
        client := RimeDepotHttpClient(transport)
        job := RimeDepotJob("recipe-apply")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        operation := recipe.ApplyAsync(client, source_root, destination_root, Map(), job,
            ObjBindMethod(outcome, "Recipe"))
        RimeDepotCoreProbeWaitSignal(outcome, 3000)
        RimeDepotCoreProbeAssert(outcome.Success, "Recipe Apply fixture failed.")
        installed_path := RimeDepotUtil.JoinPath(destination_root, "Alice.txt")
        patch_path := RimeDepotUtil.JoinPath(destination_root, "config.yaml")
        RimeDepotCoreProbeAssert(FileExist(installed_path), "Recipe Apply did not install the downloaded file.")
        installed_text := FileRead(installed_path, "UTF-8")
        RimeDepotCoreProbeAssert(InStr(installed_text, "downloaded recipe data") > 0,
            "Recipe Apply installed the wrong file content.")
        RimeDepotCoreProbeAssert(FileExist(patch_path), "Recipe Apply did not create the patch file.")
        patch_text := FileRead(patch_path, "UTF-8")
        RimeDepotCoreProbeAssert(InStr(patch_text, "Alice") > 0 && InStr(patch_text, "stable") > 0,
            "Recipe Apply did not expand args/defaults in nested patch data.")
        RimeDepotCoreProbeAssert(InStr(patch_text, '"nested"') > 0 && InStr(patch_text, '"files"') > 0,
            "Recipe Apply did not serialize nested mapping/list patch data.")
        RimeDepotCoreProbeAssert(InStr(patch_text, "__patch:") > 0, "Recipe patch marker was not written.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeInstallTarget() {
    local root, cache_path, rime_path, service, job, error_text
    root := RimeDepotUtil.NormalizePath(A_Temp . "\\RimeDepotCoreProbe-direct-install-" . A_TickCount)
    cache_path := RimeDepotUtil.JoinPath(root, "cache")
    rime_path := RimeDepotUtil.JoinPath(root, "rime")
    try {
        service := RimeDepotService(Map(
            "CachePath", cache_path,
            "RimeDirectory", rime_path,
            "RppiIndexUrl", "https://example.invalid/index.json"
        ), "", Map("Http", RimeDepotCoreProbeTransport(Map())))
        job := service.InstallTarget("owner/repository", Map("UseGit", false))
        RimeDepotCoreProbeAssert(job is RimeDepotJob && job.Kind = "install",
            "Direct InstallTarget did not create an installation job.")
        RimeDepotCoreProbeAssert(service.Catalog is RimeDepotCatalog && service.Catalog.ToArray().Length = 1,
            "Direct InstallTarget did not create a temporary catalog entry.")
        RimeDepotCoreProbeAssert(job.Status = "running" && !job.Error,
            "Direct InstallTarget failed before its asynchronous job was built.")
        RimeDepotCoreProbeAssert(job.Cancel(), "Direct InstallTarget job could not be cancelled.")
        error_text := job.Error ? job.Error.Message : ""
        RimeDepotCoreProbeAssert(job.Status = "cancelled",
            "Direct InstallTarget cancellation was not observed (status=" . job.Status . ", error=" . error_text . ").")
        Sleep(100)
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeArchive() {
    local root, staging_root, archive_body, leaf, zip_child, zip_folder, zip_namespace, destination_namespace
    local shell, transport, job, outcome, operation, start_time, cancel_root, cancel_staging, cancel_destination
    local cancel_shell, cancel_transport, cancel_job, cancel_outcome, cancel_operation
    root := A_Temp . "\\RimeDepotCoreProbe-archive-" . A_TickCount
    staging_root := root . "\\staging"
    cancel_root := root . "\\cancel"
    cancel_staging := cancel_root . "\\staging"
    archive_body := Buffer(22, 0)
    NumPut("UInt", 0x06054B50, archive_body, 0)
    try {
        leaf := RimeDepotCoreProbeArchiveItem(false)
        zip_child := RimeDepotCoreProbeArchiveNamespace([leaf])
        zip_folder := RimeDepotCoreProbeArchiveItem(true, zip_child)
        zip_namespace := RimeDepotCoreProbeArchiveNamespace([zip_folder])
        destination_namespace := RimeDepotCoreProbeArchiveNamespace([], zip_namespace.Items)
        shell := RimeDepotCoreProbeArchiveShell(zip_namespace, destination_namespace)
        transport := RimeDepotCoreProbeArchiveTransport(archive_body)
        job := RimeDepotJob("archive")
        job.Start()
        outcome := RimeDepotCoreProbeOutcome()
        RimeDepotCoreProbeAssert(RimeDepotArchive.CountNamespaceItems(zip_namespace) = 2,
            "Archive namespace counting did not recurse into nested folders.")
        start_time := A_TickCount
        operation := RimeDepotArchive.DownloadAndExtractAsync(transport, "https://example.invalid/archive.zip",
            staging_root, job, ObjBindMethod(outcome, "Archive"), "", ObjBindMethod(shell, "Open"))
        RimeDepotCoreProbeAssert(A_TickCount - start_time < 500,
            "Archive Start blocked while scheduling extraction.")
        RimeDepotCoreProbeAssert(!outcome.Done, "Archive completion happened synchronously on Start.")
        RimeDepotCoreProbeWaitSignal(outcome, 3000)
        RimeDepotCoreProbeAssert(outcome.Success, "Archive async extraction fixture failed.")
        RimeDepotCoreProbeAssert(operation.ExpectedCount = 2 && destination_namespace.CopyCalls = 1,
            "Archive extraction did not use recursive stable polling after CopyHere.")

        cancel_destination := RimeDepotCoreProbeArchiveNamespace([])
        cancel_shell := RimeDepotCoreProbeArchiveShell(zip_namespace, cancel_destination)
        cancel_transport := RimeDepotCoreProbeArchiveTransport(archive_body)
        cancel_job := RimeDepotJob("archive-cancel")
        cancel_job.Start()
        cancel_outcome := RimeDepotCoreProbeOutcome()
        cancel_operation := RimeDepotArchive.DownloadAndExtractAsync(cancel_transport,
            "https://example.invalid/cancel.zip", cancel_staging, cancel_job,
            ObjBindMethod(cancel_outcome, "Archive"), "", ObjBindMethod(cancel_shell, "Open"))
        RimeDepotCoreProbeAssert(!cancel_outcome.Done, "Archive cancel fixture completed before cancellation.")
        RimeDepotCoreProbeAssert(cancel_operation.Cancel(), "Archive cancellation was not accepted.")
        Sleep(100)
        RimeDepotCoreProbeAssert(cancel_operation.Done && !cancel_outcome.Done,
            "Archive cancellation did not stop the deferred callback.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeCacheIntegrity() {
    local root, url, body_one, body_two, body_three, cache, response_one, response_two, response_three
    local cached, paths, metadata_one, metadata_two, failing_cache, writer, tampered_metadata, body_path
    local legacy_url, legacy_body, legacy_paths, legacy
    root := A_Temp . "\\RimeDepotCoreProbe-cache-generation-" . A_TickCount
    url := "https://example.invalid/cache.json"
    body_one := '{"entries":{"cached":{"repo":"owner/cached-v1"}}}'
    body_two := '{"entries":{"cached":{"repo":"owner/cached-v2"}}}'
    body_three := '{"entries":{"cached":{"repo":"owner/cached-v3"}}}'
    try {
        cache := RimeDepotRppiCache(root)
        response_one := RimeDepotHttpResponse(url, 200, body_one, Map("ETag", "one"))
        cached := cache.Write(url, body_one, response_one)
        RimeDepotCoreProbeAssert(cached && cached.FromCache && cached.Body = body_one,
            "RPPI cache first generation was not readable.")
        paths := cache._Paths(url)
        metadata_one := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        RimeDepotCoreProbeAssert(metadata_one.Has("generation") && metadata_one["generation"] != "",
            "RPPI cache metadata has no generation.")
        RimeDepotCoreProbeAssert(metadata_one.Has("BodyFile")
            && metadata_one["BodyFile"] = RegExReplace(metadata_one["BodyFile"], ".*[\\/]", ""),
            "RPPI cache metadata has no safe generation body pointer.")
        RimeDepotCoreProbeAssert(metadata_one.Has("bodyHash")
            && metadata_one["bodyHash"] = RimeDepotRppiCache.Hash(body_one),
            "RPPI cache metadata has no matching body hash.")

        response_two := RimeDepotHttpResponse(url, 200, body_two, Map("ETag", "two"))
        cached := cache.Write(url, body_two, response_two)
        metadata_two := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        RimeDepotCoreProbeAssert(cached && cached.Body = body_two && cached.ETag = "two",
            "RPPI cache did not read its newest generation.")
        RimeDepotCoreProbeAssert(metadata_two["generation"] != metadata_one["generation"]
            && metadata_two["BodyFile"] != metadata_one["BodyFile"],
            "RPPI cache generations did not advance.")

        ; A failure after the candidate body write but before metadata commit
        ; must leave the previous committed pointer and body readable.
        writer := RimeDepotCoreProbeCacheWriter()
        failing_cache := RimeDepotRppiCache(root, writer)
        response_three := RimeDepotHttpResponse(url, 200, body_three, Map("ETag", "three"))
        RimeDepotCoreProbeThrows(Error, failing_cache.Write.Bind(url, body_three, response_three),
            "RPPI cache accepted a simulated metadata commit failure.")
        cached := cache.Read(url)
        RimeDepotCoreProbeAssert(cached && cached.Body = body_two && cached.ETag = "two",
            "RPPI cache lost the last committed generation after a failed commit.")

        ; A pointer naming another key is not allowed to escape this cache's
        ; generation namespace, and a body hash mismatch is rejected too.
        tampered_metadata := RimeDepotJson.Parse(FileRead(paths.Meta, "UTF-8"))
        tampered_metadata["BodyFile"] := "index-foreign-generation.json"
        RimeDepotUtil.AtomicWrite(paths.Meta, RimeDepotJson.Stringify(tampered_metadata))
        RimeDepotCoreProbeAssert(!cache.Read(url), "RPPI cache accepted a foreign generation pointer.")
        RimeDepotUtil.AtomicWrite(paths.Meta, RimeDepotJson.Stringify(metadata_two))
        body_path := RimeDepotUtil.JoinPath(cache.Root, metadata_two["BodyFile"])
        RimeDepotUtil.AtomicWrite(body_path, body_two . "tampered")
        RimeDepotCoreProbeAssert(!cache.Read(url), "RPPI cache accepted a body/hash mismatch.")

        ; Preserve compatibility with the pre-pointer fixed body format.
        legacy_url := "https://example.invalid/legacy-cache.json"
        legacy_body := '{"entries":{"legacy":{"repo":"owner/legacy"}}}'
        legacy_paths := cache._Paths(legacy_url)
        RimeDepotUtil.AtomicWrite(legacy_paths.Body, legacy_body)
        RimeDepotUtil.AtomicWrite(legacy_paths.Meta, RimeDepotJson.Stringify(Map(
            "url", legacy_url,
            "generation", "legacy",
            "bodyHash", RimeDepotRppiCache.Hash(legacy_body)
        )))
        legacy := cache.Read(legacy_url)
        RimeDepotCoreProbeAssert(legacy && legacy.Body = legacy_body,
            "RPPI cache no longer accepts the legacy fixed-body format.")
    } finally {
        if DirExist(root) {
            RimeDepotUtil.DeleteTree(root)
        }
    }
}

RimeDepotCoreProbeHttpLifecycle() {
    local client, outcome, request, request2, request3, calls_after_fail, calls_after_cancel
    local poll_request, poll_fake, poll_outcome, error_request, error_fake, error_outcome
    local cancel_request, cancel_fake, cancel_outcome
    client := RimeDepotHttpClient()
    outcome := RimeDepotCoreProbeOutcome()

    request := RimeDepotHttpRequest(client, "https://example.invalid/complete", ObjBindMethod(outcome, "Http"))
    request.Request := Map("fake", true)
    client._requests[request.Id] := request
    request._Complete(RimeDepotHttpResponse(request.Url, 200, "ok", Map()))
    RimeDepotCoreProbeAssert(request.Status = "completed",
        "Completed HTTP request did not reach its terminal state.")
    RimeDepotCoreProbeAssert(!client._requests.Has(request.Id) && outcome.Calls = 1,
        "Completed HTTP request was not forgotten or delivered once.")

    request2 := RimeDepotHttpRequest(client, "https://example.invalid/fail", ObjBindMethod(outcome, "Http"))
    request2.Request := Map("fake", true)
    client._requests[request2.Id] := request2
    request2.Fail(Error("fixture failure"))
    RimeDepotCoreProbeAssert(request2.Status = "failed" && !client._requests.Has(request2.Id),
        "Failed HTTP request did not reach terminal cleanup.")
    calls_after_fail := outcome.Calls
    request2._Complete(RimeDepotHttpResponse(request2.Url, 200, "late", Map()))
    RimeDepotCoreProbeAssert(outcome.Calls = calls_after_fail,
        "A late HTTP completion invoked a failed request callback twice.")

    request3 := RimeDepotHttpRequest(client, "https://example.invalid/cancel", ObjBindMethod(outcome, "Http"))
    request3.Request := Map("fake", true)
    client._requests[request3.Id] := request3
    RimeDepotCoreProbeAssert(request3.Cancel(), "HTTP cancellation was not accepted.")
    RimeDepotCoreProbeAssert(request3.Status = "cancelled" && !client._requests.Has(request3.Id),
        "Cancelled HTTP request did not reach terminal cleanup.")
    calls_after_cancel := outcome.Calls
    request3._Complete(RimeDepotHttpResponse(request3.Url, 200, "late", Map()))
    RimeDepotCoreProbeAssert(outcome.Calls = calls_after_cancel,
        "A late HTTP completion invoked a cancelled request callback.")

    ; The production request path uses non-blocking WaitForResponse(0)
    ; polling.  Exercise pending -> complete transitions and timer cleanup
    ; without creating a WinHTTP object or any callback connection.
    poll_outcome := RimeDepotCoreProbeOutcome()
    poll_request := RimeDepotHttpRequest(client, "https://example.invalid/poll",
        ObjBindMethod(poll_outcome, "Http"))
    poll_fake := RimeDepotCoreProbeHttpPollRequest([false, true], 200, "polled", "X-Test: ok`r`n")
    poll_request.Request := poll_fake
    poll_request.Status := "running"
    poll_request._start_tick := A_TickCount
    poll_request._timeout := 5000
    poll_request._timer_active := true
    client._requests[poll_request.Id] := poll_request
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_fake.WaitCalls = 1 && poll_request.Status = "running"
        && poll_request._timer_active, "HTTP polling did not retain a pending request.")
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_request.Status = "completed" && !poll_request._timer_active
        && poll_outcome.Calls = 1 && poll_outcome.Success && poll_outcome.Value.Body = "polled",
        "HTTP polling did not complete and release its timer.")
    poll_request._Poll()
    RimeDepotCoreProbeAssert(poll_outcome.Calls = 1, "A late HTTP poll delivered twice.")

    error_outcome := RimeDepotCoreProbeOutcome()
    error_request := RimeDepotHttpRequest(client, "https://example.invalid/poll-error",
        ObjBindMethod(error_outcome, "Http"))
    error_fake := RimeDepotCoreProbeHttpPollRequest([Error("poll fixture failure")])
    error_request.Request := error_fake
    error_request.Status := "running"
    error_request._start_tick := A_TickCount
    error_request._timeout := 5000
    error_request._timer_active := true
    client._requests[error_request.Id] := error_request
    error_request._Poll()
    RimeDepotCoreProbeAssert(error_request.Status = "failed" && !error_request._timer_active
        && error_outcome.Calls = 1 && !error_outcome.Success,
        "HTTP polling error did not complete exactly once.")
    error_request._Poll()
    RimeDepotCoreProbeAssert(error_outcome.Calls = 1, "A late failed HTTP poll delivered twice.")

    cancel_outcome := RimeDepotCoreProbeOutcome()
    cancel_request := RimeDepotHttpRequest(client, "https://example.invalid/poll-cancel",
        ObjBindMethod(cancel_outcome, "Http"))
    cancel_fake := RimeDepotCoreProbeHttpPollRequest([false])
    cancel_request.Request := cancel_fake
    cancel_request.Status := "running"
    cancel_request._start_tick := A_TickCount
    cancel_request._timeout := 5000
    cancel_request._timer_active := true
    client._requests[cancel_request.Id] := cancel_request
    RimeDepotCoreProbeAssert(cancel_request.Cancel(), "HTTP polling cancellation was not accepted.")
    RimeDepotCoreProbeAssert(cancel_fake.AbortCalls = 1 && cancel_request.Status = "cancelled"
        && !cancel_request._timer_active && cancel_outcome.Calls = 0
        && !client._requests.Has(cancel_request.Id),
        "HTTP polling cancellation did not abort and clean up its timer.")
    cancel_request._Poll()
    RimeDepotCoreProbeAssert(cancel_outcome.Calls = 0, "A late cancelled HTTP poll delivered a callback.")
}

RimeDepotCoreProbeWait(job) {
    deadline := A_TickCount + 5000
    while !job.IsDone() && A_TickCount < deadline {
        Sleep(20)
    }
    RimeDepotCoreProbeAssert(job.IsDone(), "Asynchronous job did not finish before timeout (status=" . job.Status . ").")
}

RimeDepotCoreProbeAssert(condition, message) {
    if !condition {
        throw Error(message)
    }
}

RimeDepotCoreProbeThrows(error_type, callback, message) {
    caught := false
    try {
        callback.Call()
    } catch as err {
        caught := true
    }
    RimeDepotCoreProbeAssert(caught, message)
}

RimeDepotCoreProbeReportError(err) {
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
}

RimeDepotCoreProbeWaitSignal(signal, timeout := 3000) {
    local deadline := A_TickCount + timeout
    while !signal.Done && A_TickCount < deadline {
        Sleep(20)
    }
    RimeDepotCoreProbeAssert(signal.Done, "Asynchronous fixture did not finish before timeout.")
}

class RimeDepotCoreProbeCallbacks extends RimeDepotCallbacks {
}

class RimeDepotCoreProbeTransport {
    __New(responses) {
        this.Responses := responses
    }

    Get(url, options := 0, job := 0) {
        if this.Responses.Has(url) {
            response := this.Responses[url]
            return RimeDepotHttpResponse(response.Url, response.Status, response.Body, response.Headers, response.Error)
        }
        return RimeDepotHttpResponse(url, 404, "", Map())
    }
}

class RimeDepotCoreProbeOutcome {
    __New() {
        this.Done := false
        this.Success := false
        this.Value := 0
        this.Error := 0
        this.Calls := 0
    }

    Git(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Recipe(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Archive(success, value := "", error := 0) {
        this.Calls += 1
        this.Done := true
        this.Success := !!success
        this.Value := value
        this.Error := error
    }

    Http(response) {
        this.Calls += 1
        this.Done := true
        this.Success := response && response.Ok()
        this.Value := response
    }
}

class RimeDepotCoreProbeGitLauncher {
    __New() {
        this.Commands := []
    }

    RunAsync(path, arguments, working_directory, callback, job := 0) {
        local copied, argument, process
        copied := []
        for _, argument in arguments {
            copied.Push(String(argument))
        }
        this.Commands.Push({Path: path, Arguments: copied, WorkingDirectory: working_directory})
        process := RimeDepotCoreProbeFakeProcess()
        callback.Call(true, 0, 0)
        return process
    }
}

class RimeDepotCoreProbeFakeProcess {
    __New() {
        this.Cancelled := false
    }

    Cancel() {
        this.Cancelled := true
        return true
    }
}

class RimeDepotCoreProbeArchiveTransport {
    __New(body) {
        this.Body := body
    }

    GetAsync(url, callback, options := 0, job := 0) {
        request := RimeDepotCoreProbeArchiveRequest(callback,
            RimeDepotHttpResponse(url, 200, this.Body, Map()))
        return request.Start()
    }
}

class RimeDepotCoreProbeArchiveRequest {
    __New(callback, response) {
        this.Callback := callback
        this.Response := response
        this.Cancelled := false
        this.Delivered := false
        this._timer := ObjBindMethod(this, "_Deliver")
    }

    Start() {
        SetTimer(this._timer, -1)
        return this
    }

    Cancel() {
        if this.Cancelled || this.Delivered {
            return false
        }
        this.Cancelled := true
        SetTimer(this._timer, 0)
        return true
    }

    _Deliver() {
        if this.Cancelled || this.Delivered {
            return
        }
        this.Delivered := true
        this.Callback.Call(this.Response)
    }
}

class RimeDepotCoreProbeArchiveItem {
    __New(is_folder, folder := 0) {
        this.IsFolder := !!is_folder
        this.GetFolder := folder
    }
}

class RimeDepotCoreProbeArchiveNamespace {
    __New(items, copied_items := 0) {
        this.Items := items
        this.CopiedItems := copied_items
        this.CopyCalls := 0
    }

    CopyHere(items, flags) {
        this.CopyCalls += 1
        this.Items := this.CopiedItems ? this.CopiedItems : items
    }
}

class RimeDepotCoreProbeArchiveShell {
    __New(zip, destination) {
        this.Zip := zip
        this.Destination := destination
    }

    Open(path, destination) {
        return Map("Zip", this.Zip, "Destination", this.Destination)
    }
}

class RimeDepotCoreProbeCacheWriter {
    Call(path, content) {
        if InStr(StrLower(path), ".meta.json") {
            throw Error("simulated metadata commit failure")
        }
        RimeDepotUtil.AtomicWrite(path, content)
    }
}

class RimeDepotCoreProbeHttpPollRequest {
    __New(results, status := 200, body := "ok", headers := "") {
        this.Results := results
        this.Status := status
        this.ResponseText := body
        this.ResponseBody := body
        this.Headers := headers
        this.WaitCalls := 0
        this.AbortCalls := 0
    }

    WaitForResponse(timeout) {
        local result
        this.WaitCalls += 1
        if !this.Results.Length {
            return true
        }
        result := this.Results.RemoveAt(1)
        if IsObject(result) {
            throw result
        }
        return !!result
    }

    GetAllResponseHeaders() {
        return this.Headers
    }

    Abort() {
        this.AbortCalls += 1
    }
}
