/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk

/** Normalized completion object emitted by RimeDepotHttpClient. */
class RimeDepotHttpResponse {
    __New(url := "", status := 0, body := "", headers := 0, error := 0) {
        this.Url := url
        this.Status := status
        this.Body := body
        this.Headers := headers is Map ? headers : Map()
        this.Error := error
        this.FromCache := false
        this.Stale := false
        this.ETag := this._Header("etag")
        this.LastModified := this._Header("last-modified")
    }

    Ok() {
        return !this.Error && this.Status >= 200 && this.Status < 300
    }

    _Header(name) {
        name := StrLower(name)
        for key, value in this.Headers {
            if StrLower(String(key)) = name {
                return String(value)
            }
        }
        return ""
    }
}

/**
 * WinHTTP request wrapper.  WinHTTP is opened in asynchronous mode and the
 * completion event is delivered to the supplied callback, so no network
 * operation blocks a GUI message loop.
 */
class RimeDepotHttpClient {
    __New(transport := 0) {
        this.Transport := transport
        this._requests := Map()
    }

    GetAsync(url, callback, options := 0, job := 0) {
        if this.Transport {
            return this._CallTransport(url, callback, options, job)
        }
        request := RimeDepotHttpRequest(this, url, callback, options, job)
        this._requests[request.Id] := request
        try {
            request.Start()
        } catch as err {
            request.Fail(err)
        }
        return request
    }

    RequestAsync(url, callback, options := 0, job := 0) {
        return this.GetAsync(url, callback, options, job)
    }

    _CallTransport(url, callback, options, job) {
        try {
            if HasMethod(this.Transport, "GetAsync") {
                return this.Transport.GetAsync(url, callback, options, job)
            }
            if HasMethod(this.Transport, "RequestAsync") {
                return this.Transport.RequestAsync(url, callback, options, job)
            }
            if HasMethod(this.Transport, "Get") {
                ; Adapters for deterministic tests may expose a synchronous
                ; Get().  Completion is still posted through a short timer.
                response := this.Transport.Get(url, options, job)
                handle := RimeDepotDeferredResponse(callback, response)
                handle.Start()
                return handle
            }
        } catch as err {
            handle := RimeDepotDeferredResponse(callback, RimeDepotHttpResponse(url, 0, "", Map(), err))
            handle.Start()
            return handle
        }
        throw RimeDepotError("HTTP transport does not implement GetAsync, RequestAsync, or Get.", "RimeDepotHttpClient")
    }

    _Forget(request) {
        if this._requests.Has(request.Id) {
            this._requests.Delete(request.Id)
        }
    }
}

class RimeDepotHttpRequest {
    __New(client, url, callback, options := 0, job := 0) {
        this.Client := client
        this.Url := url
        this.Callback := callback
        this.Options := IsObject(options) ? options : Map()
        this.Job := job
        this.Id := RimeDepotUtil.NextId()
        this.Status := "pending"
        this.Request := 0
        this.Sink := 0
        this.Response := 0
        this._completed := false
    }

    Start() {
        if this.Status != "pending" {
            return this
        }
        this.Request := ComObject("WinHttp.WinHttpRequest.5.1")
        this.Sink := RimeDepotHttpEventSink(this)
        ComObjConnect(this.Request, this.Sink)
        this.Request.Open("GET", this.Url, true)

        proxy := RimeDepotUtil.GetString(this.Options, ["Proxy", "proxy"], "")
        if proxy != "" {
            this.Request.SetProxy(2, proxy)
        } else {
            ; Explicitly select WinHTTP's normal direct/default behavior on
            ; every request; this prevents proxy settings leaking between
            ; requests when a transport object is reused.
            this.Request.SetProxy(0)
        }
        timeout := RimeDepotUtil.GetValue(this.Options, ["Timeout", "timeout"], 30000)
        try this.Request.SetTimeouts(timeout, timeout, timeout, timeout)

        headers := RimeDepotUtil.GetValue(this.Options, ["Headers", "headers"], 0)
        if IsObject(headers) {
            for name, value in headers {
                this.Request.SetRequestHeader(String(name), String(value))
            }
        }
        this.Status := "running"
        this.Request.Send()
        return this
    }

    Cancel(*) {
        if this._completed {
            return false
        }
        try {
            if this.Request {
                this.Request.Abort()
            }
        }
        this._completed := true
        this.Status := "cancelled"
        this._Disconnect()
        this.Client._Forget(this)
        return true
    }

    OnResponseFinished(request, error := 0) {
        if this._completed {
            return
        }
        if error {
            this.Fail(Error("WinHTTP asynchronous request failed (" . error . ")."))
            return
        }
        try {
            status := request.Status
            binary := RimeDepotUtil.GetValue(this.Options, ["Binary", "binary"], false)
            body := binary ? request.ResponseBody : request.ResponseText
            headers := this._ParseHeaders(request.GetAllResponseHeaders())
            this._Complete(RimeDepotHttpResponse(this.Url, status, body, headers))
        } catch as err {
            this.Fail(err)
        }
    }

    OnError(error := 0) {
        if !this._completed {
            this.Fail(IsObject(error) ? error : Error("WinHTTP request error: " . error))
        }
    }

    Fail(error) {
        if this._completed {
            return
        }
        this._Complete(RimeDepotHttpResponse(this.Url, 0, "", Map(), error))
    }

    _Complete(response) {
        if this._completed {
            return
        }
        this._completed := true
        this.Status := response.Error ? "failed" : "completed"
        this.Response := response
        this._Disconnect()
        this.Client._Forget(this)
        if this.Callback {
            try {
                this.Callback.Call(response)
            } catch as err {
                OutputDebug("RimeDepot HTTP callback failed: " . err.Message)
            }
        }
    }

    _Disconnect() {
        if this.Request && this.Sink {
            ; Omitting the event object disconnects the active event sink.
            try ComObjConnect(this.Request)
        }
        this.Sink := 0
    }

    _ParseHeaders(value) {
        result := Map()
        for _, line in StrSplit(StrReplace(String(value), "`r", ""), "`n") {
            separator := InStr(line, ":")
            if separator > 1 {
                result[Trim(SubStr(line, 1, separator - 1))] := Trim(SubStr(line, separator + 1))
            }
        }
        return result
    }
}

class RimeDepotHttpEventSink {
    __New(request) {
        this.Request := request
    }

    OnResponseFinished(request, error := 0) {
        this.Request.OnResponseFinished(request, error)
    }

    OnError(error := 0) {
        this.Request.OnError(error)
    }
}

/** Adapter used only by deterministic mock transports exposing Get(). */
class RimeDepotDeferredResponse {
    __New(callback, response) {
        this.Callback := callback
        this.Response := response
        this.Id := RimeDepotUtil.NextId()
        this.Status := "pending"
        this._timer := ObjBindMethod(this, "_Deliver")
    }

    Start() {
        this.Status := "running"
        SetTimer(this._timer, -1)
        return this
    }

    Cancel(*) {
        if this.Status = "completed" {
            return false
        }
        SetTimer(this._timer, 0)
        this.Status := "cancelled"
        return true
    }

    _Deliver() {
        if this.Status = "cancelled" {
            return
        }
        this.Status := "completed"
        if this.Callback {
            this.Callback.Call(this.Response)
        }
    }
}
