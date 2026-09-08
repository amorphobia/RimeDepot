/*
 * Copyright (c) 2023 - 2026 Xuesong Peng <pengxuesong.cn@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#Include RimeDepotTypes.ahk
#Include RimeDepotJson.ahk

/**
 * Deliberately small YAML reader for plum recipe documents.  It accepts only
 * mappings, sequences, scalars, and literal/folded block strings; anchors,
 * tags, aliases, and executable YAML constructs are rejected.
 */
class RimeDepotYaml {
    static Parse(text) {
        parser := RimeDepotYamlParser(String(text))
        return parser.Parse()
    }
}

class RimeDepotYamlParser {
    __New(text) {
        this._lines := []
        for _, line in StrSplit(StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n"), "`n") {
            if InStr(line, "`t") {
                throw RimeDepotCatalogError("Tabs are not allowed in a RimeDepot recipe YAML file.")
            }
            this._lines.Push(line)
        }
        this._index := 1
    }

    Parse() {
        this._SkipBlank()
        if this._index > this._lines.Length {
            return Map()
        }
        indent := this._Indent(this._lines[this._index])
        result := this._Block(indent)
        this._SkipBlank()
        if this._index <= this._lines.Length {
            throw RimeDepotCatalogError("Unexpected YAML content near line " . this._index . ".")
        }
        return result
    }

    _Block(indent) {
        line := this._lines[this._index]
        content := Trim(SubStr(line, indent + 1))
        return SubStr(content, 1, 1) = "-" ? this._Sequence(indent) : this._Mapping(indent)
    }

    _Mapping(indent) {
        result := Map()
        while this._index <= this._lines.Length {
            this._SkipBlank()
            if this._index > this._lines.Length {
                break
            }
            line := this._lines[this._index]
            current_indent := this._Indent(line)
            if current_indent < indent {
                break
            }
            if current_indent > indent {
                throw this._Error("Unexpected YAML indentation")
            }
            content := Trim(SubStr(line, indent + 1))
            if SubStr(content, 1, 1) = "-" {
                break
            }
            separator := this._Colon(content)
            if !separator {
                throw this._Error("Expected a YAML mapping key")
            }
            key := Trim(SubStr(content, 1, separator - 1))
            if key = "" {
                throw this._Error("YAML mapping key cannot be empty")
            }
            key := this._Scalar(key)
            this._index += 1
            remainder := Trim(SubStr(content, separator + 1))
            if remainder ~= "^[|>][+-]?$" {
                result[key] := this._BlockString(indent, SubStr(remainder, 1, 1) = ">", SubStr(remainder, 2))
            } else if remainder = "" {
                this._SkipBlank()
                if this._index > this._lines.Length || this._Indent(this._lines[this._index]) <= indent {
                    result[key] := Map()
                } else {
                    result[key] := this._Block(this._Indent(this._lines[this._index]))
                }
            } else {
                result[key] := this._Scalar(remainder)
            }
        }
        return result
    }

    _Sequence(indent) {
        result := []
        while this._index <= this._lines.Length {
            this._SkipBlank()
            if this._index > this._lines.Length {
                break
            }
            line := this._lines[this._index]
            current_indent := this._Indent(line)
            if current_indent < indent {
                break
            }
            if current_indent > indent {
                throw this._Error("Unexpected YAML sequence indentation")
            }
            content := Trim(SubStr(line, indent + 1))
            if SubStr(content, 1, 1) != "-" {
                break
            }
            remainder := Trim(SubStr(content, 2))
            this._index += 1
            if remainder = "" {
                this._SkipBlank()
                if this._index > this._lines.Length || this._Indent(this._lines[this._index]) <= indent {
                    result.Push("")
                } else {
                    result.Push(this._Block(this._Indent(this._lines[this._index])))
                }
                continue
            }
            separator := this._Colon(remainder)
            if separator {
                map_value := Map()
                key := this._Scalar(Trim(SubStr(remainder, 1, separator - 1)))
                value_text := Trim(SubStr(remainder, separator + 1))
                if value_text = "" {
                    this._SkipBlank()
                    if this._index > this._lines.Length || this._Indent(this._lines[this._index]) <= indent {
                        map_value[key] := Map()
                    } else {
                        map_value[key] := this._Block(this._Indent(this._lines[this._index]))
                    }
                } else if value_text ~= "^[|>][+-]?$" {
                    map_value[key] := this._BlockString(indent, SubStr(value_text, 1, 1) = ">", SubStr(value_text, 2))
                } else {
                    map_value[key] := this._Scalar(value_text)
                }
                ; Remaining indented mapping lines belong to this sequence item.
                this._SkipBlank()
                if this._index <= this._lines.Length && this._Indent(this._lines[this._index]) > indent {
                    extra := this._Mapping(this._Indent(this._lines[this._index]))
                    for extra_key, extra_value in extra {
                        map_value[extra_key] := extra_value
                    }
                }
                result.Push(map_value)
            } else {
                result.Push(this._Scalar(remainder))
            }
        }
        return result
    }

    _BlockString(parent_indent, folded, chomping := "") {
        result := ""
        first_indent := 0
        while this._index <= this._lines.Length {
            line := this._lines[this._index]
            if Trim(line) = "" {
                result .= "`n"
                this._index += 1
                continue
            }
            indent := this._Indent(line)
            if indent <= parent_indent {
                break
            }
            if !first_indent {
                first_indent := indent
            }
            if indent < first_indent {
                break
            }
            piece := SubStr(line, first_indent + 1)
            result .= folded ? (Trim(piece) . " ") : (piece . "`n")
            this._index += 1
        }
        if folded {
            result := RTrim(result)
            if chomping != "-" {
                result .= "`n"
            }
        } else if chomping = "-" {
            result := RTrim(result, "`r`n")
        }
        return result
    }

    _Scalar(value) {
        value := Trim(value)
        if value = "" {
            return ""
        }
        ; Strip comments only when they are separated from an unquoted scalar.
        if SubStr(value, 1, 1) != '"' && SubStr(value, 1, 1) != "'" {
            comment := InStr(value, " #")
            if comment {
                value := RTrim(SubStr(value, 1, comment - 1))
            }
        }
        if (SubStr(value, 1, 1) = '"' && SubStr(value, -1) = '"')
            || (SubStr(value, 1, 1) = "'" && SubStr(value, -1) = "'") {
            if SubStr(value, 1, 1) = '"' {
                try return RimeDepotJson.Parse(value)
            }
            return StrReplace(SubStr(value, 2, StrLen(value) - 2), "''", "'")
        }
        lower := StrLower(value)
        if lower = "true" || lower = "yes" || lower = "on" {
            return true
        }
        if lower = "false" || lower = "no" || lower = "off" {
            return false
        }
        if lower = "null" || lower = "~" {
            return ""
        }
        if value ~= "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$" {
            return value + 0
        }
        if (SubStr(value, 1, 1) = "[" && SubStr(value, -1) = "]")
            || (SubStr(value, 1, 1) = "{" && SubStr(value, -1) = "}") {
            ; YAML flow collections commonly contain unquoted scalars (for
            ; example `[default, pinyin]`), which strict JSON does not accept.
            ; Parse the small flow subset explicitly instead of silently
            ; returning the whole collection as a scalar on a JSON failure.
            return RimeDepotYamlFlowParser(value).Parse()
        }
        return value
    }

    _Colon(value) {
        quoted := ""
        escaped := false
        for index, char in StrSplit(value) {
            if escaped {
                escaped := false
                continue
            }
            if char = '"' {
                quoted := quoted = '"' ? "" : '"'
            } else if char = "\" && quoted = '"' {
                escaped := true
            } else if char = ":" && quoted = "" {
                next := SubStr(value, index + 1, 1)
                if next = "" || next = " " {
                    return index
                }
            }
        }
        return 0
    }

    _Indent(line) {
        return StrLen(line) - StrLen(LTrim(line, " "))
    }

    _SkipBlank() {
        while this._index <= this._lines.Length {
            line := Trim(this._lines[this._index])
            if line != "" && SubStr(line, 1, 1) != "#" && line != "---" && line != "..." {
                return
            }
            this._index += 1
        }
    }

    _Error(message) {
        return RimeDepotCatalogError(message . " at YAML line " . this._index . ".")
    }
}

/** Parser for YAML flow sequences and mappings used by compact recipe data. */
class RimeDepotYamlFlowParser {
    __New(text) {
        this._text := String(text)
        this._length := StrLen(this._text)
        this._position := 1
    }

    Parse() {
        this._SkipWhitespace()
        if this._position > this._length {
            throw RimeDepotCatalogError("YAML flow collection is empty.")
        }
        result := this._Value()
        this._SkipWhitespace()
        if this._position <= this._length {
            throw this._Error("Unexpected YAML flow content")
        }
        return result
    }

    _Value() {
        this._SkipWhitespace()
        char := SubStr(this._text, this._position, 1)
        if char = "[" {
            return this._Sequence()
        }
        if char = "{" {
            return this._Mapping()
        }
        return this._Scalar(this._ReadPlain())
    }

    _Sequence() {
        result := []
        this._position += 1
        this._SkipWhitespace()
        if SubStr(this._text, this._position, 1) = "]" {
            this._position += 1
            return result
        }
        while true {
            result.Push(this._Value())
            this._SkipWhitespace()
            char := SubStr(this._text, this._position, 1)
            if char = "]" {
                this._position += 1
                return result
            }
            if char != "," {
                throw this._Error("Expected ',' or ']' in YAML flow sequence")
            }
            this._position += 1
            this._SkipWhitespace()
            if SubStr(this._text, this._position, 1) = "]" {
                ; YAML permits a trailing comma in a flow collection.
                this._position += 1
                return result
            }
        }
    }

    _Mapping() {
        result := Map()
        this._position += 1
        this._SkipWhitespace()
        if SubStr(this._text, this._position, 1) = "}" {
            this._position += 1
            return result
        }
        while true {
            key_text := this._ReadKey()
            key := this._Scalar(key_text)
            this._SkipWhitespace()
            if SubStr(this._text, this._position, 1) != ":" {
                throw this._Error("Expected ':' in YAML flow mapping")
            }
            this._position += 1
            result[key] := this._Value()
            this._SkipWhitespace()
            char := SubStr(this._text, this._position, 1)
            if char = "}" {
                this._position += 1
                return result
            }
            if char != "," {
                throw this._Error("Expected ',' or '}' in YAML flow mapping")
            }
            this._position += 1
            this._SkipWhitespace()
            if SubStr(this._text, this._position, 1) = "}" {
                this._position += 1
                return result
            }
        }
    }

    _ReadKey() {
        start := this._position
        quote := ""
        escaped := false
        depth := 0
        while this._position <= this._length {
            char := SubStr(this._text, this._position, 1)
            if quote != "" {
                if quote = '"' && escaped {
                    escaped := false
                } else if quote = '"' && char = "\\" {
                    escaped := true
                } else if char = quote {
                    quote := ""
                }
                this._position += 1
                continue
            }
            if char = '"' || char = "'" {
                quote := char
            } else if char = "[" || char = "{" {
                depth += 1
            } else if char = "]" || char = "}" {
                if depth > 0 {
                    depth -= 1
                }
            } else if char = ":" && depth = 0 {
                return Trim(SubStr(this._text, start, this._position - start))
            }
            this._position += 1
        }
        throw this._Error("Expected ':' in YAML flow mapping")
    }

    _ReadPlain() {
        start := this._position
        quote := ""
        escaped := false
        depth := 0
        while this._position <= this._length {
            char := SubStr(this._text, this._position, 1)
            if quote != "" {
                if quote = '"' && escaped {
                    escaped := false
                } else if quote = '"' && char = "\\" {
                    escaped := true
                } else if char = quote {
                    quote := ""
                }
                this._position += 1
                continue
            }
            if char = '"' || char = "'" {
                quote := char
            } else if char = "[" || char = "{" {
                depth += 1
            } else if char = "]" || char = "}" {
                if depth > 0 {
                    depth -= 1
                } else {
                    break
                }
            } else if char = "," && depth = 0 {
                break
            }
            this._position += 1
        }
        value := Trim(SubStr(this._text, start, this._position - start))
        if value = "" {
            throw this._Error("YAML flow value cannot be empty")
        }
        return value
    }

    _Scalar(value) {
        value := Trim(value)
        if (SubStr(value, 1, 1) = '"' && SubStr(value, -1) = '"')
            || (SubStr(value, 1, 1) = "'" && SubStr(value, -1) = "'") {
            if SubStr(value, 1, 1) = '"' {
                return RimeDepotJson.Parse(value)
            }
            return StrReplace(SubStr(value, 2, StrLen(value) - 2), "''", "'")
        }
        lower := StrLower(value)
        if lower = "true" || lower = "yes" || lower = "on" {
            return true
        }
        if lower = "false" || lower = "no" || lower = "off" {
            return false
        }
        if lower = "null" || lower = "~" {
            return ""
        }
        if value ~= "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$" {
            return value + 0
        }
        if (SubStr(value, 1, 1) = "[" && SubStr(value, -1) = "]")
            || (SubStr(value, 1, 1) = "{" && SubStr(value, -1) = "}") {
            return RimeDepotYamlFlowParser(value).Parse()
        }
        return value
    }

    _SkipWhitespace() {
        while this._position <= this._length {
            if !InStr(" `r`n`t", SubStr(this._text, this._position, 1)) {
                return
            }
            this._position += 1
        }
    }

    _Error(message) {
        return RimeDepotCatalogError(message . " at YAML flow character " . this._position . ".")
    }
}
