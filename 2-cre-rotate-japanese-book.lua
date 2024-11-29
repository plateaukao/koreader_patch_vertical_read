local Blitbuffer = require("ffi/blitbuffer")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local Screen = require("device").screen
local logger = require("logger")
local ReaderView = require("apps/reader/modules/readerview")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local util = require("util")

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")

local DataStorage = require("datastorage")
local _ = require("gettext")
if G_reader_settings == nil then
    G_reader_settings = require("luasettings"):open(
        DataStorage:getDataDir().."/settings.reader.lua")
end

-- Add menu item to toggle the vertical reading hack
ReaderRolling_orig_addToMainMenu = ReaderRolling.addToMainMenu
ReaderRolling.addToMainMenu = function(self, menu_items)
    ReaderRolling_orig_addToMainMenu(self, menu_items)
    menu_items.toggle_vertical_hack =  {
        sorting_hint = "typeset",
        text = "Toggle vertical reading",
        checked_func = function()
            return self.ui.doc_settings:isTrue("vertical_reading_hack")
        end,
        callback = function(touchmenu_instance)
            self.ui.doc_settings:flipNilOrFalse("vertical_reading_hack")
            UIManager:nextTick(function()
                self.ui:reloadDocument()
            end)
        end,
    }
    menu_items.toggle_dictionary_lookup =  {
        sorting_hint = "typeset",
        text = _("Dictionary on single word selection"),
        checked_func = function()
            return not self.view.highlight.disabled and G_reader_settings:nilOrFalse("highlight_action_on_single_word")
        end,
        enabled_func = function()
            return not self.view.highlight.disabled
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse("highlight_action_on_single_word")
        end,
    }
end


ReaderRolling.onPreRenderDocument = function(self)
    -- Let's do it with a setting toggable via the menu item defined above
    isVerticalHackEnabled = self.ui.doc_settings:isTrue("vertical_reading_hack")
    if not isVerticalHackEnabled then
        return
    end    

    -- Inverse reading order (not sure this is for the best, as ToC items are RTL,
    -- but BookMap and PageBrowser may look as expected)
    if not self.ui.view.inverse_reading_order then
        self.ui.view:onToggleReadingOrder()
    end

    -- Hack a few credocument methods
    local document = self.ui.document

    local ReaderView_orig_drawHighlightRect = ReaderView.drawHighlightRect
    ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
        isVerticalHackEnabled = self.ui.doc_settings:isTrue("vertical_reading_hack")
        if (not isVerticalHackEnabled) then
            return ReaderView_orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
        end
        local x, y, w, h = rect.x, rect.y, rect.w, rect.h
        -- bb:paintRect(x + w - 10, y, Size.line.thick, h, Blitbuffer.COLOR_GRAY_4)
        if drawer == "lighten" or drawer == "invert" then
            local pct = G_reader_settings:readSetting("highlight_height_pct")
            if pct ~= nil then
                w = math.floor(w * pct / 100)
                x = x + math.ceil((rect.w - w) / 2)
            end
        end
        if drawer == "lighten" then
            if not color then
                bb:darkenRect(x, y, w, h, self.highlight.lighten_factor)
            else
                if bb:getInverse() == 1 then
                    -- MUL doesn't really work on a black background, so, switch to OVER if we're in software nightmode...
                    -- NOTE: If we do *not* invert the color here, it *will* get inverted by the blitter given that the target bb is inverted.
                    --       While not particularly pretty, this (roughly) matches with hardware nightmode, *and* how MuPDF renders highlights...
                    --       But it's *really* not pretty (https://github.com/koreader/koreader/pull/11044#issuecomment-1902886069), so we'll fix it ;p.
                    local c = Blitbuffer.ColorRGB32(color.r, color.g, color.b, 0xFF * self.highlight.lighten_factor):invert()
                    bb:blendRectRGB32(x, y, w, h, c)
                else
                    bb:multiplyRectRGB(x, y, w, h, color)
                end
            end
        elseif drawer == "strikeout" then
            if not color then
                color = Blitbuffer.COLOR_BLACK
            end
            local line_x = x + math.floor(w / 2) + 1
            if self.ui.paging then
                line_x = line_x + 2
            end
            if Blitbuffer.isColor8(color) then
                bb:paintRect(line_x, y, Size.line.thick, h, color)
            else
                bb:paintRectRGB32(line_x, y, Size.line.thick, h, color)
            end
        elseif drawer == "underscore" then
            if not color then
                color = Blitbuffer.COLOR_GRAY_4
            end
            if Blitbuffer.isColor8(color) then
                bb:paintRect(x + w - 12 , y, Size.line.thick, h, color)
            else
                bb:paintRectRGB32(x + w - 12, y, Size.line.thick, h, color)
            end
        elseif drawer == "invert" then
            bb:invertRect(x, y, w, h)
        end
    end


    document.setViewDimen = function(self, dimen)
        self._document:setViewDimen(dimen.h, dimen.w)
    end
    document:setViewDimen(Screen:getSize())

    -- Cut and pasted from the original, with a few lines added here and there
    document.drawCurrentView = function(self, target, x, y, rect, pos)
        self.orig_rect_w = rect.w -- added
        self.orig_rect_h = rect.h -- added
        rect = rect:copy() -- added
        rect.w, rect.h = rect.h, rect.w -- added
        if self.buffer and (self.buffer.w ~= rect.w or self.buffer.h ~= rect.h) then
            self.buffer:free()
            self.buffer = nil
        end
        if not self.buffer then
            self.buffer = Blitbuffer.new(rect.w, rect.h, self.render_color and Blitbuffer.TYPE_BBRGB32 or nil)
        end
        self._drawn_images_count, self._drawn_images_surface_ratio =
            self._document:drawCurrentPage(self.buffer, self.render_color, Screen.night_mode and self._nightmode_images, self._smooth_scaling, Screen.sw_dithering)
        self.buffer:rotate(-90) -- added
        target:blitFrom(self.buffer, x, y, 0, 0, rect.h, rect.w) -- h and w inverted here
        self.buffer:rotate(90) -- added
    end

    local orig_getWordFromPosition = document.getWordFromPosition
    document.getWordFromPosition = function(self, pos)
        pos = pos:copy()
        pos.x, pos.y = pos.y, self.orig_rect_w - pos.x
        local wordbox = orig_getWordFromPosition(self, pos)
        if wordbox and wordbox.sbox then
            local box = wordbox.sbox
            box.x, box.y = self.orig_rect_w - box.y - box.h, box.x
            box.w, box.h = box.h, box.w
            wordbox.sbox = box
        end
        return wordbox
    end

    local orig_getTextFromPositions = document.getTextFromPositions
    document.getTextFromPositions = function(self, pos0, pos1, do_not_draw_selection)
        if not pos0.copy then -- not a real Geom object
            return orig_getTextFromPositions(self, pos0, pos1, do_not_draw_selection)
        end
        pos0 = pos0:copy()
        pos1 = pos1:copy()
        pos0.x, pos0.y = pos0.y, self.orig_rect_w - pos0.x
        pos1.x, pos1.y = pos1.y, self.orig_rect_w - pos1.x
        return orig_getTextFromPositions(self, pos0, pos1, do_not_draw_selection)
    end

    local orig_getScreenBoxesFromPositions = document.getScreenBoxesFromPositions
    document.getScreenBoxesFromPositions = function(self, pos0, pos1, get_segments)
        local line_boxes = orig_getScreenBoxesFromPositions(self, pos0, pos1, get_segments)
        for _, box in ipairs(line_boxes) do
            -- These results may be cached in the cre call cache, so be sure we don't
            -- rotate those we already did.
            if not box._already_rotated then
                box._already_rotated = true
                box.x, box.y = self.orig_rect_w - box.y - box.h, box.x
                box.w, box.h = box.h, box.w
            end
        end
        return line_boxes
    end

    local orig_getImageFromPosition = document.getImageFromPosition
    document.getImageFromPosition = function(self, pos, want_frames, accept_cre_scalable_image)
        pos = pos:copy()
        pos.x, pos.y = pos.y, self.orig_rect_w - pos.x
        return orig_getImageFromPosition(self, pos, want_frames, accept_cre_scalable_image)
    end

    local orig_getLinkFromPosition = document.getLinkFromPosition
    document.getLinkFromPosition = function(self, pos)
        -- We may not always get a Geom object, so we can't use :copy()
        pos = { x = pos.x, y = pos.y }
        pos.x, pos.y = pos.y, self.orig_rect_w - pos.x
        return orig_getLinkFromPosition(self, pos)
    end

    local orig_getScreenPositionFromXPointer = document.getScreenPositionFromXPointer
    document.getScreenPositionFromXPointer = function(self, xp)
        local y, x = orig_getScreenPositionFromXPointer(self, xp)
        x, y = self.orig_rect_w - y, x
        return y, x
    end

    local orig_getPageLinks = document.getPageLinks
    document.getPageLinks = function(self, internal_links_only)
        local links = orig_getPageLinks(self, internal_links_only)
        for _, link in ipairs(links) do
            if not link._already_rotated then
                link._already_rotated = true
                if link.segments and #link.segments > 0 then
                    for i=1, #link.segments do
                        local segment = link.segments[i]
                        segment.x0, segment.y0 = self.orig_rect_w - segment.y0, segment.x0
                        segment.x1, segment.y1 = self.orig_rect_w - segment.y1, segment.x1
                    end
                end
                link.start_x, link.start_y = self.orig_rect_w - link.start_y, link.start_x
                link.end_x, link.end_y = self.orig_rect_w - link.end_y, link.end_x
            end
        end
        return links
    end
end

ReaderRolling.onToggleVerticalRead = function(self)
    self.ui.doc_settings:flipNilOrFalse("vertical_reading_hack")
    UIManager:nextTick(function()
        self.ui:reloadDocument()
    end)
end

Dispatcher:registerAction("toggle_vertical_read", {category="none", event="ToggleVerticalRead", title="Toggle Vertical Read", rolling=true})

function onToggleVerticalRead()
    ReaderRolling:onToggleVerticalRead()
end

ReaderRolling.onToggleDictionaryLookup = function(self)
    G_reader_settings:flipNilOrFalse("highlight_action_on_single_word")
    local isOn = G_reader_settings:nilOrFalse("highlight_action_on_single_word")
    local loading = InfoMessage:new{
      text = "Dictionary Lookup: "..(isOn and _("Enabled") or _("disabled")),
      timeout = 2
    }
    UIManager:show(loading)
end

Dispatcher:registerAction("toggle_dictionary_lookup", {category="none", event="ToggleDictionaryLookup", title="Toggle Dictionary Lookup on Word", rolling=true})

function onToggleDictionaryLookup()
    ReaderRolling:onToggleDictionaryLookup()
end


-- add an action to toggle highlight action or show action menu
Dispatcher:registerAction("toggle_highlight_or_menu", {category="none", event="ToggleHighlightOrMenu", title="Select to Highlight or Menu", rolling=true})

ReaderRolling.onToggleHighlightOrMenu = function(self)
    local current_highlight_action = G_reader_settings:readSetting("default_highlight_action", "ask")
    if current_highlight_action == "highlight" then
        G_reader_settings:saveSetting("default_highlight_action", "ask")
        UIManager:show(InfoMessage:new{
            text = _("Action menu is enabled.\nSelect text to show actions."),
            timeout = 2
        })
    else
        G_reader_settings:saveSetting("default_highlight_action", "highlight")
        UIManager:show(InfoMessage:new{
            text = _("Highlight is enabled.\nSelect text to highlight."),
            timeout = 2
        })
    end
end

function onToggleHighlightOrMenu()
    ReaderRolling:onToggleHighlightOrMenu()
end

local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ButtonDialog = require("ui/widget/buttondialog")
local C_ = _.pgettext

ReaderHighlight_orig_onShowHighlightDialog = ReaderHighlight.onShowHighlightDialog
ReaderHighlight.onShowHighlightDialog = function(self, index)
    isVerticalHackEnabled = self.ui.doc_settings:isTrue("vertical_reading_hack")
    if not isVerticalHackEnabled then
        ReaderHighlight_orig_onShowHighlightDialog(self, index)
        return
    end    

    local item = self.ui.annotation.annotations[index]
    local enabled = not item.text_edited
    local start_prev = "▒△"
    local start_next = "▒▽"
    local end_prev = "△▒"
    local end_next = "▽▒"

    local buttons = {
        {
            {
                text = _("Delete"),
                callback = function()
                    self:deleteHighlight(index)
                    UIManager:close(self.edit_highlight_dialog)
                    self.edit_highlight_dialog = nil
                end,
            },
            {
                text = C_("Highlight", "Style"),
                callback = function()
                    self:editHighlightStyle(index)
                    UIManager:close(self.edit_highlight_dialog)
                    self.edit_highlight_dialog = nil
                end,
            },
            {
                text = C_("Highlight", "Color"),
                enabled = item.drawer ~= "invert",
                callback = function()
                    self:editHighlightColor(index)
                    UIManager:close(self.edit_highlight_dialog)
                    self.edit_highlight_dialog = nil
                end,
            },
        },
        {
            {
                text = _("Note"),
                callback = function()
                    self:editNote(index)
                    UIManager:close(self.edit_highlight_dialog)
                    self.edit_highlight_dialog = nil
                end,
            },
            {
                text = "…",
                callback = function()
                    self.selected_text = util.tableDeepCopy(item)
                    self:onShowHighlightMenu(index)
                    UIManager:close(self.edit_highlight_dialog)
                    self.edit_highlight_dialog = nil
                end,
            },
        },
        {
            {
                text = end_prev,
                enabled = enabled,
                callback = function()
                    self:updateHighlight(index, 1, -1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(index, 1, -1, true)
                end
            },
            {
                text = start_prev,
                enabled = enabled,
                callback = function()
                    self:updateHighlight(index, 0, -1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(index, 0, -1, true)
                    return true
                end
            },
        },
        {
            {
                text = end_next,
                enabled = enabled,
                callback = function()
                    self:updateHighlight(index, 1, 1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(index, 1, 1, true)
                end
            },
            {
                text = start_next,
                enabled = enabled,
                callback = function()
                    self:updateHighlight(index, 0, 1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(index, 0, 1, true)
                    return true
                end
            },
        }
    }

    self.edit_highlight_dialog = ButtonDialog:new{
        buttons = buttons,
    }
    UIManager:show(self.edit_highlight_dialog)
    return true
end