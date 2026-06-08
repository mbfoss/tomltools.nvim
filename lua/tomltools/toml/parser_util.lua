local M = {}

---@param cp integer Unicode codepoint
---@return string UTF-8 encoded byte sequence
function M.utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 64),
            0x80 + (cp % 64))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor((cp % 4096) / 64),
            0x80 + (cp % 64))
    else
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + math.floor((cp % 262144) / 4096),
            0x80 + math.floor((cp % 4096) / 64),
            0x80 + (cp % 64))
    end
end

---@param s string
---@return boolean
function M.validate_utf8(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len
        if b < 0x80 then
            len = 1
        elseif b < 0xC0 then
            return false
        elseif b < 0xE0 then
            len = 2
        elseif b < 0xF0 then
            len = 3
        elseif b < 0xF8 then
            len = 4
        else
            return false
        end
        for j = 1, len - 1 do
            local c = s:byte(i + j)
            if not c or c < 0x80 or c >= 0xC0 then return false end
        end
        i = i + len
    end
    return true
end

---@param y  integer
---@param mo integer
---@param d  integer
---@return string?
function M.validate_date(y, mo, d)
    if mo < 1 or mo > 12 then
        return string.format("invalid month: %d", mo)
    end
    local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local is_leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    if is_leap then days_in_month[2] = 29 end
    if d < 1 or d > days_in_month[mo] then
        return string.format("invalid day %d for month %d", d, mo)
    end
    return nil
end

---@param h   integer
---@param mi  integer
---@param sec number
---@return string?
function M.validate_time(h, mi, sec)
    if h > 23 then return string.format("invalid hour: %d", h) end
    if mi > 59 then return string.format("invalid minute: %d", mi) end
    if sec >= 60 then return string.format("invalid second: %g", sec) end
    return nil
end

---@param oh integer
---@param om integer
---@return string?
function M.validate_offset(oh, om)
    if oh > 23 then return string.format("invalid timezone hour offset: %d", oh) end
    if om > 59 then return string.format("invalid timezone minute offset: %d", om) end
    return nil
end

---@param raw string
---@return string?
function M.validate_number_raw(raw)
    if raw:match("^[%+%-]?$") then return "empty number" end
    if raw:match("__") then return "consecutive underscores in number" end
    if raw:match("^_") or raw:match("_$") then return "leading/trailing underscore in number" end
    if raw:match("%._") or raw:match("_%.") then return "underscore adjacent to decimal point" end
    if raw:match("[eE]_") or raw:match("_[eE]") then return "underscore adjacent to exponent" end
    local dot_count = 0
    for _ in raw:gmatch("%.") do dot_count = dot_count + 1 end
    if dot_count > 1 then return "multiple decimal points in number" end
    local e_count = 0
    for _ in raw:gmatch("[eE]") do e_count = e_count + 1 end
    if e_count > 1 then return "multiple exponent markers in number" end
    if raw:match("%.%s*[eE]") or raw:match("^[%+%-]?%.") then
        return "number has no digits before or after decimal point"
    end
    return nil
end

---@param y   integer
---@param mo  integer
---@param d   integer
---@param h   integer?
---@param mi  integer?
---@param sec number?
---@param zone integer?
---@return string
function M.format_date_str(y, mo, d, h, mi, sec, zone)
    local date = string.format("%04d-%02d-%02d", y, mo, d)
    if h == nil then return date end
    local sec_int   = math.floor(sec or 0)
    local sec_frac  = (sec or 0) - sec_int
    local sec_str   = string.format("%02d", sec_int)
    if sec_frac > 0 then
        local frac_s = string.format("%.9f", sec_frac):sub(2)
        frac_s = frac_s:match("(%.%d-[1-9])0*$") or frac_s
        sec_str = sec_str .. frac_s
    end
    local time = string.format("%02d:%02d:%s", h, mi or 0, sec_str)
    if zone == nil then return date .. "T" .. time end
    if zone == 0 then return date .. "T" .. time .. "Z" end
    local sign = zone >= 0 and "+" or "-"
    return date .. "T" .. time .. string.format("%s%02d:00", sign, math.abs(zone))
end

---@param h   integer
---@param mi  integer
---@param sec number
---@return string
function M.format_time_str(h, mi, sec)
    local sec_int  = math.floor(sec)
    local sec_frac = sec - sec_int
    local sec_str  = string.format("%02d", sec_int)
    if sec_frac > 0 then
        local frac_s = string.format("%.9f", sec_frac):sub(2)
        frac_s = frac_s:match("(%.%d-[1-9])0*$") or frac_s
        sec_str = sec_str .. frac_s
    end
    return string.format("%02d:%02d:%s", h, mi, sec_str)
end

return M
