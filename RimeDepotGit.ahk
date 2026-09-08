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

/** Direct git.exe process runner.  No shell command is ever constructed. */
class RimeDepotGitRunner {
    __New(git_path := "", launcher := 0) {
        this.GitPath := git_path != "" ? git_path : "git.exe"
        this.Launcher := launcher
    }

    RunAsync(arguments, working_directory, callback, job := 0) {
        if !(arguments is Array) {
            throw RimeDepotError("Git arguments must be an array.", "RimeDepotGitRunner")
        }
        RimeDepotGitRunner.ValidateExecutable(this.GitPath)
        if this.Launcher {
            if HasMethod(this.Launcher, "RunAsync") {
                return this.Launcher.RunAsync(this.GitPath, arguments, working_directory, callback, job)
            }
            throw RimeDepotError("Git launcher does not implement RunAsync.", "RimeDepotGitRunner")
        }
        process := RimeDepotGitProcess(this, arguments, working_directory, callback, job)
        process.Start()
        return process
    }

    static ValidateExecutable(path) {
        path := String(path)
        if path = "" || path ~= "[\r\n]" || InStr(path, Chr(34)) || path ~= "i)(?:cmd|powershell|pwsh|bash)(?:\.exe)?$" {
            throw RimeDepotSecurityError("GitPath must identify git.exe directly.")
        }
        name := StrLower(RegExReplace(path, ".*[\\/]", ""))
        if name != "git.exe" && name != "git" {
            throw RimeDepotSecurityError("GitPath must identify git.exe directly: " . path)
        }
        return true
    }

    static QuoteArgument(value) {
        local result, slash_count, char
        value := String(value)
        if value ~= "[\r\n]" {
            throw RimeDepotSecurityError("Git argument contains a line break.")
        }
        ; Windows command-line quoting for a CreateProcess-style command
        ; line.  Backslashes are data except when they precede a quote or
        ; the closing quote, where the Windows argv parser consumes them.
        result := Chr(34)
        slash_count := 0
        Loop Parse, value {
            char := A_LoopField
            if char = "\" {
                slash_count += 1
                continue
            }
            if char = Chr(34) {
                result .= RimeDepotGitRunner._Repeat("\", slash_count * 2 + 1) . Chr(34)
                slash_count := 0
                continue
            }
            if slash_count {
                result .= RimeDepotGitRunner._Repeat("\", slash_count)
                slash_count := 0
            }
            result .= char
        }
        if slash_count {
            result .= RimeDepotGitRunner._Repeat("\", slash_count * 2)
        }
        return result . Chr(34)
    }

    static _Repeat(value, count) {
        local result := ""
        Loop count {
            result .= value
        }
        return result
    }

    static BuildCommand(path, arguments) {
        command := this.QuoteArgument(path)
        for _, argument in arguments {
            command .= " " . this.QuoteArgument(argument)
        }
        return command
    }
}

class RimeDepotGitProcess {
    __New(runner, arguments, working_directory, callback, job := 0) {
        this.Runner := runner
        this.Arguments := arguments
        this.WorkingDirectory := working_directory
        this.Callback := callback
        this.Job := job
        this.Id := RimeDepotUtil.NextId()
        this.Pid := 0
        this.Handle := 0
        this.Status := "pending"
        this.ExitCode := ""
        this._poll_timer := ObjBindMethod(this, "_Poll")
        this._completed := false
    }

    Start() {
        try {
            command := RimeDepotGitRunner.BuildCommand(this.Runner.GitPath, this.Arguments)
            Run(command, this.WorkingDirectory, "Hide", &pid)
            this.Pid := pid
            ; Keep the process handle while the child is running.  Looking up
            ; a PID only after ProcessExist() becomes false races with PID
            ; reuse and loses the real exit status.
            this.Handle := DllCall("OpenProcess", "UInt", 0x101000, "Int", false, "UInt", this.Pid, "Ptr")
            if !this.Handle {
                try ProcessClose(this.Pid)
                throw Error("Unable to open the Git process handle.")
            }
            this.Status := "running"
            SetTimer(this._poll_timer, 50)
        } catch as err {
            this._Finish(false, -1, err)
        }
        return this
    }

    Cancel(*) {
        if this._completed {
            return false
        }
        SetTimer(this._poll_timer, 0)
        if this.Pid {
            try ProcessClose(this.Pid)
        }
        this._Finish(false, -1, RimeDepotCancelledError("Git operation cancelled."))
        return true
    }

    _Poll() {
        if this._completed {
            SetTimer(this._poll_timer, 0)
            return
        }
        if !this.Handle {
            SetTimer(this._poll_timer, 0)
            this._Finish(false, -1, Error("Git process handle is unavailable."))
            return
        }
        exit_code := 0
        if !DllCall("GetExitCodeProcess", "Ptr", this.Handle, "UInt*", &exit_code) {
            SetTimer(this._poll_timer, 0)
            this._Finish(false, -1, Error("GetExitCodeProcess failed for Git."))
            return
        }
        if exit_code = 259 {
            return
        }
        SetTimer(this._poll_timer, 0)
        if exit_code = 0 {
            this._Finish(true, exit_code, 0)
        } else {
            this._Finish(false, exit_code, Error("git.exe exited with code " . exit_code . "."))
        }
    }

    _Finish(success, exit_code, error) {
        if this._completed {
            return
        }
        this._completed := true
        SetTimer(this._poll_timer, 0)
        this._CloseHandle()
        this.ExitCode := exit_code
        this.Status := success ? "completed" : "failed"
        try {
            this.Callback.Call(success, exit_code, error)
        } catch as callback_error {
            OutputDebug("RimeDepot git callback failed: " . callback_error.Message)
        }
    }

    _CloseHandle() {
        handle := this.Handle
        this.Handle := 0
        if handle {
            DllCall("CloseHandle", "Ptr", handle)
        }
    }
}

/** Clone/fetch/submodule orchestration for a catalog entry. */
class RimeDepotGitClient {
    __New(config, runner := 0) {
        this.Config := config
        this.Runner := runner ? runner : RimeDepotGitRunner(config.ResolveGitPath())
    }

    FetchAsync(repo, destination, ref, job, callback) {
        repo_url := RimeDepotGitClient.RepoUrl(repo)
        destination := RimeDepotUtil.NormalizePath(destination)
        if !RimeDepotUtil.IsPathInside(this.Config.CachePath, destination) {
            throw RimeDepotSecurityError("Git destination must remain inside CachePath.")
        }
        if ref != "" {
            RimeDepotUtil.ValidateRef(ref, ref ~= "i)^[0-9a-f]{7,40}$")
        }
        operation := RimeDepotGitOperation(this, repo_url, destination, ref, job, callback)
        operation.Start()
        return operation
    }

    static RepoUrl(repo) {
        repo := String(repo)
        if RimeDepotUtil.IsUrl(repo) || repo ~= "i)^git@[^:]+:" {
            return repo
        }
        repo := Trim(repo, " /\\")
        if !RegExMatch(repo, "^[^/\\]+/[^/\\]+$") {
            throw RimeDepotTargetError("Git target must be owner/repository or a repository URL: " . repo)
        }
        return "https://github.com/" . repo . ".git"
    }
}

class RimeDepotGitOperation {
    __New(client, repo_url, destination, ref, job, callback) {
        this.Client := client
        this.RepoUrl := repo_url
        this.Destination := destination
        this.Ref := ref
        this.Job := job
        this.Callback := callback
        this.Process := 0
        this.State := "pending"
        this.Done := false
    }

    Start() {
        is_sha := this.IsSha()
        if DirExist(this.Destination) {
            if !DirExist(RimeDepotUtil.JoinPath(this.Destination, ".git"))
                && !FileExist(RimeDepotUtil.JoinPath(this.Destination, ".git")) {
                if !this._DirectoryIsEmpty() {
                    this._Fail(RimeDepotError("Existing package directory is not a Git checkout.", "RimeDepotGit"))
                    return this
                }
                if is_sha {
                    this._InitSha()
                } else {
                    this._CloneIntoExisting()
                }
                return this
            }
            this._FetchExisting()
        } else {
            RimeDepotUtil.EnsureDirectory(RegExReplace(this.Destination, "[\\/][^\\/]*$"))
            if is_sha {
                this._InitSha()
            } else {
                args := ["clone", "--depth", "1"]
                if this.Ref != "" {
                    args.Push("--branch")
                    args.Push(this.Ref)
                }
                args.Push(this.RepoUrl)
                args.Push(this.Destination)
                this._Run(args, ObjBindMethod(this, "_Cloned"))
            }
        }
        return this
    }

    _CloneIntoExisting() {
        args := ["clone", "--depth", "1"]
        if this.Ref != "" {
            args.Push("--branch")
            args.Push(this.Ref)
        }
        args.Push(this.RepoUrl)
        args.Push(this.Destination)
        this._Run(args, ObjBindMethod(this, "_Cloned"))
    }

    _DirectoryIsEmpty() {
        Loop Files, RimeDepotUtil.JoinPath(this.Destination, "*"), "FD" {
            return false
        }
        return true
    }

    Cancel(*) {
        if this.Process && HasMethod(this.Process, "Cancel") {
            this.Process.Cancel()
        }
        this.Done := true
    }

    _FetchExisting() {
        args := ["-C", this.Destination, "fetch", "--depth", "1", "origin"]
        if this.Ref != "" {
            args.Push(this.Ref)
        }
        this._Run(args, ObjBindMethod(this, "_Fetched"))
    }

    _Cloned(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Submodules()
    }

    _Fetched(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Checkout()
    }

    _Checkout() {
        if this.Ref = "" {
            this._Submodules()
            return
        }
        if this.IsSha() {
            this._Run(["-C", this.Destination, "checkout", "--force", "--detach", "FETCH_HEAD"],
                ObjBindMethod(this, "_CheckedOut"))
            return
        }
        this._Run(["-C", this.Destination, "checkout", "--force", this.Ref], ObjBindMethod(this, "_CheckedOut"))
    }

    _InitSha() {
        this._Run(["init", this.Destination], ObjBindMethod(this, "_ShaInitialized"))
    }

    _ShaInitialized(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Run(["-C", this.Destination, "remote", "add", "origin", this.RepoUrl],
            ObjBindMethod(this, "_ShaRemoteAdded"))
    }

    _ShaRemoteAdded(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Run(["-C", this.Destination, "fetch", "--depth", "1", "origin", this.Ref],
            ObjBindMethod(this, "_ShaFetched"))
    }

    _ShaFetched(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Checkout()
    }

    _CheckedOut(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Submodules()
    }

    _Submodules() {
        if !FileExist(RimeDepotUtil.JoinPath(this.Destination, ".gitmodules")) {
            this._Finish(true, "")
            return
        }
        this._Run(["-C", this.Destination, "submodule", "update", "--init", "--recursive"],
            ObjBindMethod(this, "_SubmodulesDone"))
    }

    _SubmodulesDone(success, exit_code, error) {
        this.Process := 0
        if !success {
            this._Fail(error)
            return
        }
        this._Finish(true, "")
    }

    _Run(arguments, callback) {
        if this.Done || this.Job.IsCancelled() {
            return
        }
        this.State := "running"
        this.Job.ReportProgress(Map("phase", "git", "state", arguments[1], "repo", this.RepoUrl))
        try {
            this.Process := this.Client.Runner.RunAsync(arguments, A_WorkingDir, callback, this.Job)
        } catch as err {
            this._Fail(err)
        }
    }

    _Fail(error) {
        if this.Done {
            return
        }
        this.Done := true
        this.State := "failed"
        this.Callback.Call(false, "", error)
    }

    _Finish(success, root) {
        if this.Done {
            return
        }
        this.Done := true
        this.State := success ? "completed" : "failed"
        this.Callback.Call(success, root, 0)
    }

    IsSha() {
        return this.Ref ~= "i)^[0-9a-f]{7,40}$"
    }
}
