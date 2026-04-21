local mp = require "mp"
local assdraw = require "mp.assdraw"

local M = {}
M.__index = M

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function normalize_color(color, fallback)
    color = tostring(color or "")
    if color:find("^#%x%x%x%x%x%x$") == nil then
        color = fallback
    end
    return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3)
end

local function sanitize_font(font)
    font = tostring(font or "")
    return font:gsub("[{}\\]", "")
end

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function escape_ass(text)
    text = tostring(text or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    text = text:gsub("\n", " ")
    return text
end

local function append_rect(ass, x, y, width, height, fill_color, fill_alpha, border_color, border_alpha, border_size)
    ass:new_event()
    ass:append(string.format(
        "{\\an7\\pos(0,0)\\bord%.2f\\shad0\\1c&H%s&\\1a&H%s&\\3c&H%s&\\3a&H%s&\\p1}",
        border_size or 0,
        fill_color,
        fill_alpha or "00",
        border_color or fill_color,
        border_alpha or fill_alpha or "00"
    ))
    ass:draw_start()
    ass:rect_cw(x, y, x + width, y + height)
    ass:draw_stop()
end

local function append_text(ass, theme, x, y, text, size, color, bold, align)
    ass:new_event()
    ass:append(string.format(
        "{\\an%d\\pos(%.2f,%.2f)%s\\fs%d\\bord0\\shad0\\q2\\1c&H%s&%s}%s",
        align or 7,
        x,
        y,
        theme.font_tag,
        size,
        color,
        bold and "\\b1" or "\\b0",
        escape_ass(text)
    ))
end

function M.new(overlay, options)
    local measure = mp.create_osd_overlay("ass-events")
    measure.hidden = true
    measure.compute_bounds = true

    local font_size = math.max(12, tonumber(options.font_size) or 16)
    local panel_chars = tonumber(options.panel_chars)
    if not panel_chars or panel_chars < 28 then
        panel_chars = 44
    else
        panel_chars = math.floor(panel_chars)
    end

    local font = sanitize_font(options.font)
    local theme = {
        x = tonumber(options.left) or 36,
        y = tonumber(options.top) or 44,
        panel_chars = panel_chars,
        font_tag = font ~= "" and ("\\fn" .. font) or "",
        body_size = font_size,
        title_size = font_size + 4,
        note_size = math.max(11, font_size - 2),
        section_size = math.max(10, font_size - 3),
        padding_x = math.max(18, math.floor(font_size * 1.1)),
        padding_y = math.max(16, math.floor(font_size * 0.95)),
        header_height = math.max(54, font_size + 28),
        row_height = math.max(36, font_size + 18),
        note_height = math.max(20, font_size + 4),
        section_height = math.max(18, font_size + 2),
        divider_height = 12,
        badge_padding_x = 9,
        badge_padding_y = 4,
        accent_color = normalize_color(options.accent_color, "#FF8232"),
        text_color = normalize_color(options.text_color, "#FFFFFF"),
        muted_color = normalize_color(options.muted_color, "#A8A8A8"),
        shadow_color = normalize_color(options.shadow_color, "#111111"),
        panel_color = normalize_color(options.panel_color, "#121212"),
        surface_color = normalize_color(options.surface_color, "#1E1E1E"),
        selection_color = normalize_color(options.selection_color, "#362217"),
    }

    return setmetatable({
        overlay = overlay,
        measure = measure,
        theme = theme,
        width_cache = {},
        hitboxes = {},
        panel_bounds = nil,
    }, M)
end

function M:get_osd_size()
    local width, height = mp.get_osd_size()
    if not width or width <= 0 then
        width = 1280
    end
    if not height or height <= 0 then
        height = 720
    end
    return width, height
end

function M:measure_text(text, size, bold)
    text = compact_text(text)
    if text == "" then
        return 0
    end

    local cache_key = table.concat({
        tostring(size),
        bold and "1" or "0",
        text,
    }, "\31")

    local cached = self.width_cache[cache_key]
    if cached then
        return cached
    end

    local osd_width, osd_height = self:get_osd_size()
    self.measure.res_x = osd_width
    self.measure.res_y = osd_height
    self.measure.data = string.format(
        "{\\an7\\pos(0,0)%s\\fs%d\\bord0\\shad0\\q2%s}%s",
        self.theme.font_tag,
        size,
        bold and "\\b1" or "\\b0",
        escape_ass(text)
    )

    local width = 0
    local bounds = self.measure:update()
    if bounds and bounds.x0 and bounds.x1 then
        width = math.max(0, bounds.x1 - bounds.x0)
    end

    if width == 0 then
        width = #text * size * 0.58
    end

    self.width_cache[cache_key] = width
    return width
end

function M:fit_text(text, max_width, size, bold)
    text = compact_text(text)
    if text == "" or max_width <= 0 then
        return ""
    end

    if self:measure_text(text, size, bold) <= max_width then
        return text
    end

    local ellipsis = "..."
    if self:measure_text(ellipsis, size, bold) >= max_width then
        return ""
    end

    local low = 0
    local high = #text
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        local candidate = text:sub(1, mid) .. ellipsis
        if self:measure_text(candidate, size, bold) <= max_width then
            low = mid
        else
            high = mid - 1
        end
    end

    if low <= 0 then
        return ellipsis
    end
    return text:sub(1, low) .. ellipsis
end

function M:panel_inner_width()
    if self._inner_width then
        return self._inner_width
    end

    local probe = string.rep("0", self.theme.panel_chars)
    local measured = self:measure_text(probe, self.theme.body_size, false)
    local fallback = self.theme.panel_chars * math.max(7, self.theme.body_size * 0.62)
    self._inner_width = math.floor(math.max(320, measured > 0 and measured or fallback))
    return self._inner_width
end

function M:block_height(row)
    if row.kind == "section" then
        return self.theme.section_height
    end
    if row.kind == "note" then
        return self.theme.note_height
    end
    if row.kind == "divider" then
        return self.theme.divider_height
    end
    return self.theme.row_height
end

function M:draw_badge(ass, x, y, text, fill_color, text_color, size)
    text = compact_text(text)
    if text == "" then
        return 0
    end

    local badge_height = size + (self.theme.badge_padding_y * 2)
    local badge_width = math.ceil(self:measure_text(text, size, true) + (self.theme.badge_padding_x * 2))
    append_rect(ass, x, y, badge_width, badge_height, fill_color, "00", fill_color, "00", 0)
    append_text(
        ass,
        self.theme,
        x + self.theme.badge_padding_x,
        y + self.theme.badge_padding_y - 1,
        text,
        size,
        text_color,
        true,
        7
    )
    return badge_width
end

function M:render(spec)
    local osd_width, osd_height = self:get_osd_size()
    local theme = self.theme
    local inner_width = self:panel_inner_width()
    local panel_width = inner_width + (theme.padding_x * 2)
    local panel_height = theme.padding_y + theme.header_height

    for _, row in ipairs(spec.rows or {}) do
        panel_height = panel_height + self:block_height(row)
    end

    local footer = spec.footer or {}
    if #footer > 0 then
        panel_height = panel_height + 10 + (#footer * theme.note_height)
    end
    panel_height = panel_height + theme.padding_y

    local x = clamp(theme.x, 12, math.max(12, osd_width - panel_width - 12))
    local y = clamp(theme.y, 12, math.max(12, osd_height - panel_height - 12))
    local row_x = x + theme.padding_x
    local row_width = inner_width
    local cursor_y = y + theme.padding_y + theme.header_height

    local ass = assdraw.ass_new()
    local hitboxes = {}

    append_rect(ass, x + 8, y + 10, panel_width, panel_height, theme.shadow_color, "C0", theme.shadow_color, "C0", 0)
    append_rect(ass, x, y, panel_width, panel_height, theme.panel_color, "54", theme.panel_color, "7C", 1.2)
    append_rect(ass, x, y, panel_width, 4, theme.accent_color, "00", theme.accent_color, "00", 0)

    local title_y = y + theme.padding_y + 2
    append_text(ass, theme, x + theme.padding_x, title_y, compact_text(spec.title or ""), theme.title_size, theme.text_color, true, 7)

    local header_badge = compact_text(spec.badge or "")
    if header_badge ~= "" then
        local badge_size = math.max(10, theme.note_size)
        local badge_width = math.ceil(self:measure_text(header_badge, badge_size, true) + (theme.badge_padding_x * 2))
        self:draw_badge(
            ass,
            x + panel_width - theme.padding_x - badge_width,
            y + theme.padding_y,
            header_badge,
            theme.accent_color,
            theme.panel_color,
            badge_size
        )
    end

    for _, row in ipairs(spec.rows or {}) do
        local block_height = self:block_height(row)

        if row.kind == "divider" then
            append_rect(
                ass,
                row_x,
                cursor_y + math.floor(block_height / 2),
                row_width,
                1,
                theme.surface_color,
                "82",
                theme.surface_color,
                "82",
                0
            )
        elseif row.kind == "section" then
            local section_text = self:fit_text(string.upper(compact_text(row.text or "")), row_width, theme.section_size, true)
            append_text(
                ass,
                theme,
                row_x,
                cursor_y + 2,
                section_text,
                theme.section_size,
                row.muted and theme.muted_color or theme.accent_color,
                true,
                7
            )
        elseif row.kind == "note" then
            local note_text = self:fit_text(compact_text(row.text or ""), row_width, theme.note_size, false)
            append_text(
                ass,
                theme,
                row_x,
                cursor_y + 1,
                note_text,
                theme.note_size,
                row.accent and theme.accent_color or theme.muted_color,
                row.bold == true,
                7
            )
        else
            local selected = row.selected == true
            local muted = row.muted == true
            local badge_text = compact_text(row.badge or "")
            local badge_width = 0
            local badge_gap = 0
            local item_y = cursor_y
            local item_height = block_height - 2

            append_rect(
                ass,
                row_x,
                item_y,
                row_width,
                item_height,
                selected and theme.selection_color or theme.surface_color,
                selected and "48" or "7C",
                selected and theme.accent_color or theme.surface_color,
                selected and "74" or "A4",
                selected and 1.4 or 1.0
            )

            if selected then
                append_rect(ass, row_x, item_y, 4, item_height, theme.accent_color, "00", theme.accent_color, "00", 0)
            end

            local badge_x = row_x + row_width - 14
            if badge_text ~= "" then
                local badge_fill = row.badge_fill == "muted" and theme.surface_color or theme.accent_color
                local badge_text_color = row.badge_fill == "muted" and theme.text_color or theme.panel_color
                badge_width = math.ceil(self:measure_text(badge_text, theme.section_size, true) + (theme.badge_padding_x * 2))
                badge_gap = 10
                self:draw_badge(
                    ass,
                    badge_x - badge_width,
                    item_y + math.floor((item_height - (theme.section_size + (theme.badge_padding_y * 2))) / 2),
                    badge_text,
                    badge_fill,
                    badge_text_color,
                    theme.section_size
                )
            end

            local content_y = item_y + math.floor((item_height - theme.body_size) / 2) - 1
            local label_x = row_x + 14
            local value_right = badge_x - badge_width - badge_gap
            local value_width = math.max(0, value_right - label_x - 18)
            local raw_value = compact_text(row.value or "")
            local value_size = row.value_size or theme.body_size
            local value_bold = row.value_bold == true
            local value_share = clamp(tonumber(row.value_share) or 0.46, 0.25, 0.8)
            local value_text = raw_value ~= "" and self:fit_text(raw_value, math.max(0, math.floor(value_width * value_share)), value_size, value_bold) or ""
            local value_measured = value_text ~= "" and self:measure_text(value_text, value_size, value_bold) or 0
            local label_limit = math.max(0, value_width - value_measured - (value_text ~= "" and 20 or 0))
            local label_text = self:fit_text(compact_text(row.label or ""), label_limit, theme.body_size, true)

            if label_text == "" then
                label_text = self:fit_text(compact_text(row.label or ""), value_width, theme.body_size, true)
                value_text = ""
                value_measured = 0
            end

            local label_color = muted and theme.muted_color or theme.text_color
            local value_color = theme.muted_color
            if row.value_color == "accent" then
                value_color = theme.accent_color
            elseif row.value_color == "text" then
                value_color = theme.text_color
            elseif muted then
                value_color = theme.muted_color
            end

            append_text(ass, theme, label_x, content_y, label_text, theme.body_size, label_color, true, 7)

            if value_text ~= "" then
                append_text(
                    ass,
                    theme,
                    value_right,
                    content_y,
                    value_text,
                    value_size,
                    value_color,
                    value_bold,
                    9
                )
            end

            if row.action then
                hitboxes[#hitboxes + 1] = {
                    x1 = row_x,
                    y1 = item_y,
                    x2 = row_x + row_width,
                    y2 = item_y + item_height,
                    action = row.action,
                }
            end
        end

        cursor_y = cursor_y + block_height
    end

    if #footer > 0 then
        cursor_y = cursor_y + 10
        for _, line in ipairs(footer) do
            local footer_text = self:fit_text(compact_text(line), row_width, theme.note_size, false)
            append_text(ass, theme, row_x, cursor_y + 1, footer_text, theme.note_size, theme.muted_color, false, 7)
            cursor_y = cursor_y + theme.note_height
        end
    end

    self.hitboxes = hitboxes
    self.panel_bounds = {
        x1 = x,
        y1 = y,
        x2 = x + panel_width,
        y2 = y + panel_height,
    }

    self.overlay.res_x = osd_width
    self.overlay.res_y = osd_height
    self.overlay.z = 2000
    self.overlay.data = ass.text
    self.overlay:update()
end

function M:clear()
    self.hitboxes = {}
    self.panel_bounds = nil
    self.overlay:remove()
end

function M:handle_click(x, y)
    if not self.panel_bounds then
        return "outside"
    end

    if x < self.panel_bounds.x1 or x > self.panel_bounds.x2 or y < self.panel_bounds.y1 or y > self.panel_bounds.y2 then
        return "outside"
    end

    for _, hitbox in ipairs(self.hitboxes) do
        if x >= hitbox.x1 and x <= hitbox.x2 and y >= hitbox.y1 and y <= hitbox.y2 then
            if hitbox.action then
                hitbox.action()
            end
            return "handled"
        end
    end

    return "inside"
end

return M
