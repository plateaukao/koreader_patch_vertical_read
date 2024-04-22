local Blitbuffer = require("ffi/blitbuffer")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local Screen = require("device").screen
local logger = require("logger")
local ReaderView = require("apps/reader/modules/readerview")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

-- Add menu item to toggle the vertical reading hack
ReaderRolling_orig_addToMainMenu = ReaderRolling.addToMainMenu
ReaderRolling.addToMainMenu = function(self, menu_items)
    ReaderRolling_orig_addToMainMenu(self, menu_items)
    menu_items.toggle_vertical_hack =  {
        text = "Toggle verting reading hack",
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
    ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, draw_note_mark)
        isVerticalHackEnabled = self.ui.doc_settings:isTrue("vertical_reading_hack")
        if (not isVerticalHackEnabled) or drawer ~= "underscore" then
            return ReaderView_orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, draw_note_mark)
        end
        local x, y, w, h = rect.x, rect.y, rect.w, rect.h
        bb:paintRect(x - 1, y, Size.line.thick, h, Blitbuffer.COLOR_GRAY_4)
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
