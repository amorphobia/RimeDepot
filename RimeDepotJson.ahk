/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk

/** A small strict JSON implementation used for RPPI and cache metadata. */
class RimeDepotJson {
    static Parse(text) {
        parser := RimeDepotJsonParser(String(text))
        return parser.Parse()
    }

    static Stringify(value, pretty := false, indent := 0) {
        return RimeDepotJsonWriter(pretty, indent).Write(value)
    }
}

class RimeDepotJsonParser {
    __New(text) {
        this._text := text
        this._length := StrLen(text)
        this._position := 1
    }

    Parse() {
        this._SkipWhitespace()
        if this._position > this._length {
            throw RimeDepotCatalogError("JSON is empty.")
        }
        result := this._ParseValue()
        this._SkipWhitespace()
        if this._position <= this._length {
            throw this._Error("Unexpected characters after JSON value.")
        }
        return result
    }

    _ParseValue() {
        this._SkipWhitespace()
        char := SubStr(this._text, this._position, 1)
        switch char {
            case "{":
                return this._ParseObject()
            case "[":
                return this._ParseArray()
            case '"':
                return this._ParseString()
            case "t":
                return this._ParseLiteral("true", true)
            case "f":
                return this._ParseLiteral("false", false)
            case "n":
                return this._ParseLiteral("null", "")
        }
        if char = "-" || char ~= "\d" {
            return this._ParseNumber()
        }
        throw this._Error("Unexpected JSON value.")
    }

    _ParseObject() {
        result := Map()
        this._position += 1
        this._SkipWhitespace()
        if SubStr(this._text, this._position, 1) = "}" {
            this._position += 1
            return result
        }
        while true {
            this._SkipWhitespace()
            if SubStr(this._text, this._position, 1) != '"' {
                throw this._Error("JSON object keys must be strings.")
            }
            key := this._ParseString()
            this._SkipWhitespace()
            if SubStr(this._text, this._position, 1) != ":" {
                throw this._Error("Expected ':' after JSON object key.")
            }
            this._position += 1
            result[key] := this._ParseValue()
            this._SkipWhitespace()
            char := SubStr(this._text, this._position, 1)
            if char = "}" {
                this._position += 1
                return result
            }
            if char != "," {
                throw this._Error("Expected ',' or '}' in JSON object.")
            }
            this._position += 1
        }
    }

    _ParseArray() {
        result := []
        this._position += 1
        this._SkipWhitespace()
        if SubStr(this._text, this._position, 1) = "]" {
            this._position += 1
            return result
        }
        while true {
            result.Push(this._ParseValue())
            this._SkipWhitespace()
            char := SubStr(this._text, this._position, 1)
            if char = "]" {
                this._position += 1
                return result
            }
            if char != "," {
                throw this._Error("Expected ',' or ']' in JSON array.")
            }
            this._position += 1
        }
    }

    _ParseString() {
        this._position += 1
        result := ""
        while this._position <= this._length {
            char := SubStr(this._text, this._position, 1)
            this._position += 1
            if char = '"' {
                return result
            }
            if char = "`n" || char = "`r" || char = "`t" {
                throw this._Error("Unescaped control character in JSON string.")
            }
            if char != "\" {
                if Ord(char) < 0x20 {
                    throw this._Error("Unescaped control character in JSON string.")
                }
                result .= char
                continue
            }
            if this._position > this._length {
                throw this._Error("Unterminated JSON escape.")
            }
            escaped := SubStr(this._text, this._position, 1)
            this._position += 1
            switch escaped {
                case '"': result .= '"'
                case "\": result .= "\"
                case "/": result .= "/"
                case "b": result .= Chr(8)
                case "f": result .= Chr(12)
                case "n": result .= "`n"
                case "r": result .= "`r"
                case "t": result .= "`t"
                case "u":
                    hex := SubStr(this._text, this._position, 4)
                    if StrLen(hex) != 4 || hex ~= "i)[^0-9a-f]" {
                        throw this._Error("Invalid Unicode escape in JSON string.")
                    }
                    this._position += 4
                    code := Integer("0x" . hex)
                    ; Combine a UTF-16 surrogate pair when one is present.
                    if code >= 0xD800 && code <= 0xDBFF
                        && SubStr(this._text, this._position, 2) = "\u" {
                        low_hex := SubStr(this._text, this._position + 2, 4)
                        if low_hex ~= "i)^[0-9a-f]{4}$" {
                            low := Integer("0x" . low_hex)
                            if low >= 0xDC00 && low <= 0xDFFF {
                                this._position += 6
                                result .= Chr(0x10000 + ((code - 0xD800) << 10) + low - 0xDC00)
                                continue
                            }
                        }
                    }
                    result .= Chr(code)
                default:
                    throw this._Error("Invalid JSON escape sequence.")
            }
        }
        throw this._Error("Unterminated JSON string.")
    }

    _ParseLiteral(expected, value) {
        if SubStr(this._text, this._position, StrLen(expected)) != expected {
            throw this._Error("Invalid JSON literal.")
        }
        this._position += StrLen(expected)
        return value
    }

    _ParseNumber() {
        remaining := SubStr(this._text, this._position)
        if !RegExMatch(remaining, "^(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)", &match) {
            throw this._Error("Invalid JSON number.")
        }
        token := match[1]
        this._position += StrLen(token)
        return token + 0
    }

    _SkipWhitespace() {
        while this._position <= this._length {
            if !InStr(" `t`r`n", SubStr(this._text, this._position, 1)) {
                return
            }
            this._position += 1
        }
    }

    _Error(message) {
        return RimeDepotCatalogError(message . " (at character " . this._position . ").")
    }
}

class RimeDepotJsonWriter {
    __New(pretty := false, indent := 0) {
        this.Pretty := !!pretty
        this.Indent := indent
        this._stack := Map()
    }

    Write(value, level := 0) {
        if !IsObject(value) {
            if value is String {
                return this._Quote(String(value))
            }
            if value = true {
                return "true"
            }
            if value = false {
                return "false"
            }
            return String(value)
        }
        if this._stack.Has(ObjPtr(value)) {
            throw RimeDepotCatalogError("Cannot stringify a cyclic JSON value.")
        }
        this._stack[ObjPtr(value)] := true
        try {
            if value is Array {
                result := this._WriteArray(value, level)
            } else {
                result := this._WriteObject(value, level)
            }
        } finally {
            this._stack.Delete(ObjPtr(value))
        }
        return result
    }

    _WriteArray(value, level) {
        if value.Length = 0 {
            return "[]"
        }
        parts := []
        for _, item in value {
            parts.Push(this.Write(item, level + 1))
        }
        if !this.Pretty {
            return "[" . RimeDepotJsonWriter.Join(parts, ",") . "]"
        }
        padding := this._Padding(level + 1)
        closing := this._Padding(level)
        return "[`n" . padding . RimeDepotJsonWriter.Join(parts, ",`n" . padding) . "`n" . closing . "]"
    }

    _WriteObject(value, level) {
        parts := []
        for key, item in value {
            parts.Push(this._Quote(String(key)) . (this.Pretty ? ": " : ":") . this.Write(item, level + 1))
        }
        if parts.Length = 0 {
            return "{}"
        }
        if !this.Pretty {
            return "{" . RimeDepotJsonWriter.Join(parts, ",") . "}"
        }
        padding := this._Padding(level + 1)
        closing := this._Padding(level)
        return "{`n" . padding . RimeDepotJsonWriter.Join(parts, ",`n" . padding) . "`n" . closing . "}"
    }

    _Quote(value) {
        value := StrReplace(value, "\", "\\")
        value := StrReplace(value, '"', '\"')
        value := StrReplace(value, "`b", "\b")
        value := StrReplace(value, "`f", "\f")
        value := StrReplace(value, "`n", "\n")
        value := StrReplace(value, "`r", "\r")
        value := StrReplace(value, "`t", "\t")
        return '"' . value . '"'
    }

    _Padding(level) {
        result := ""
        Loop level * this.Indent {
            result .= " "
        }
        return result
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
