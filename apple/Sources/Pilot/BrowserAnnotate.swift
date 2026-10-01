import AppKit
import Foundation
import WebKit

/// "Browser Annotate" — point at a web element, describe a change, and dispatch
/// it (screenshot + element context + instruction) to the agent in a terminal.
///
/// The hover-highlight, click-to-select, the text box, and the Send button all
/// live as an injected in-page overlay (so there's no Swift↔web coordinate
/// math); the only Swift↔web boundary is the single `send` message. On send,
/// Swift screenshots the page, composes a prompt, and reuses Pilot's existing
/// `.pilotSendIssuePrompt` path (paste + Enter into the active terminal).
enum BrowserAnnotate {
    /// WKScriptMessageHandler name + the JS toggle entry point.
    static let messageName = "pilotAnnotate"
    @MainActor static let contentWorld = WKContentWorld.world(name: "PilotBrowserAnnotate")
    static let grantLifetime: TimeInterval = 120

    struct MessagePayload: Equatable {
        let instruction: String
        let url: String
        let selector: String
        let outerHTML: String
        let selectionID: String
        let bridgeToken: String
        let rectX: Int
        let rectY: Int
        let rectW: Int
        let rectH: Int

        static func parse(_ body: Any) -> MessagePayload? {
            guard let body = body as? [String: Any],
                  Set(body.keys) == [
                      "action", "instruction", "url", "selector", "outerHTML",
                      "selectionID", "bridgeToken", "rect",
                  ],
                  body["action"] as? String == "send",
                  let instruction = boundedString(body["instruction"], max: 2_000, allowEmpty: false),
                  let url = boundedString(body["url"], max: 2_048, allowEmpty: false),
                  let selector = boundedString(body["selector"], max: 2_048, allowEmpty: true),
                  let outerHTML = boundedString(body["outerHTML"], max: 8_192, allowEmpty: true),
                  let selectionID = boundedString(body["selectionID"], max: 128, allowEmpty: false),
                  let bridgeToken = boundedString(body["bridgeToken"], max: 128, allowEmpty: false),
                  let rect = body["rect"] as? [String: Any],
                  Set(rect.keys) == ["x", "y", "w", "h"],
                  let x = coordinate(rect["x"], allowsNegative: true),
                  let y = coordinate(rect["y"], allowsNegative: true),
                  let width = coordinate(rect["w"], allowsNegative: false),
                  let height = coordinate(rect["h"], allowsNegative: false) else { return nil }
            return MessagePayload(
                instruction: instruction,
                url: url,
                selector: selector,
                outerHTML: outerHTML,
                selectionID: selectionID,
                bridgeToken: bridgeToken,
                rectX: x,
                rectY: y,
                rectW: width,
                rectH: height
            )
        }

        private static func boundedString(_ value: Any?, max: Int, allowEmpty: Bool) -> String? {
            guard let string = value as? String,
                  string.utf8.count <= max,
                  allowEmpty || !string.isEmpty else { return nil }
            return string
        }

        private static func coordinate(_ value: Any?, allowsNegative: Bool) -> Int? {
            guard let number = value as? NSNumber else { return nil }
            let double = number.doubleValue
            guard double.isFinite, abs(double) <= 1_000_000,
                  allowsNegative || double >= 0 else { return nil }
            return Int(double.rounded())
        }
    }

    struct BridgeGrant {
        let token: String
        let navigationURL: String
        let expiresAt: Date
        private(set) var consumed = false

        mutating func consume(_ payload: MessagePayload, currentURL: String, now: Date = Date()) -> Bool {
            guard !consumed,
                  now < expiresAt,
                  payload.bridgeToken == token,
                  payload.url == navigationURL,
                  currentURL == navigationURL else { return false }
            consumed = true
            return true
        }
    }

    /// A send captures its terminal before the asynchronous WebKit snapshot
    /// starts. Keeping that target in this value prevents a later pane/workspace
    /// click from silently rerouting the prompt when the snapshot completes.
    struct DispatchContext {
        let targetPaneID: UUID?

        func notificationUserInfo(prompt: String) -> [AnyHashable: Any] {
            [
                BrowserAnnotate.promptUserInfoKey: prompt,
                // Preserve the distinction between an explicitly captured
                // "no terminal" and a legacy notification with no routing
                // metadata. The former must beep, not fall through to whichever
                // terminal happens to become active a moment later.
                BrowserAnnotate.targetPaneIDUserInfoKey: targetPaneID?.uuidString ?? NSNull(),
            ]
        }
    }

    static let promptUserInfoKey = "prompt"
    static let targetPaneIDUserInfoKey = "targetPaneID"

    static func hasCapturedTarget(in userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?[targetPaneIDUserInfoKey] != nil
    }

    static func targetPaneID(in userInfo: [AnyHashable: Any]?) -> UUID? {
        guard let value = userInfo?[targetPaneIDUserInfoKey] else { return nil }
        if let id = value as? UUID { return id }
        if let raw = value as? String { return UUID(uuidString: raw) }
        return nil
    }

    /// Injected at document start in the main frame. Guarded so re-injection (SPA
    /// navigations, reloads) is harmless; `window.__pilotAnnotate.setEnabled`
    /// toggles it from Swift.
    static let userScript = """
    (function () {
      if (window.__pilotAnnotate) return;
      var initiallyEnabled = !!window.__pilotAnnotateDesiredEnabled;
      var enabled = false;
      var highlight = null, cursorStyle = null, box = null;
      var hovered = null, selected = null, sending = false;
      var selectionID = null, sendingID = null;
      var bridgeToken = null, selectionBridgeToken = null;
      var fallbackSelectionSequence = 0;
      var lastPointerX = null, lastPointerY = null, pointerInside = false;
      var pendingRawTarget = null, pendingHover = false;
      var hoverFrame = 0, hoverTimer = 0, layoutFrame = 0;
      var lastHighlightedElement = null, lastHighlightKey = null;

      var interactiveSelector = [
        'a[href]', 'button', 'input:not([type="hidden"])', 'textarea', 'select', 'summary',
        '[contenteditable=""]', '[contenteditable="true"]',
        '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="option"]',
        '[role="tab"]', '[role="checkbox"]', '[role="radio"]', '[role="switch"]'
      ].join(',');
      var containerTags = {
        DIV: true, SECTION: true, ARTICLE: true, LI: true, NAV: true, HEADER: true,
        FOOTER: true, MAIN: true, ASIDE: true, FORM: true
      };

      function ensureCursorStyle() {
        var root = document.documentElement;
        if (!root) return null;
        if (!cursorStyle) {
          cursorStyle = document.createElement('style');
          cursorStyle.setAttribute('data-pilot-annotate-cursor', '');
          cursorStyle.textContent = 'html.__pilot-lasso-active, html.__pilot-lasso-active body, html.__pilot-lasso-active body * { cursor: crosshair !important; } html.__pilot-lasso-active [data-pilot-annotate-box], html.__pilot-lasso-active [data-pilot-annotate-box] * { cursor: default !important; } html.__pilot-lasso-active [data-pilot-annotate-box] textarea { cursor: text !important; } html.__pilot-lasso-active [data-pilot-annotate-box] button { cursor: pointer !important; }';
        }
        if (!cursorStyle.isConnected) root.appendChild(cursorStyle);
        return cursorStyle;
      }

      function ensureHighlight() {
        var root = document.documentElement;
        if (!root) return null;
        if (!highlight) {
          highlight = document.createElement('div');
          highlight.setAttribute('data-pilot-annotate-highlight', '');
          highlight.style.cssText = 'all:initial!important;position:fixed!important;pointer-events:none!important;z-index:2147483646!important;box-sizing:border-box!important;border:2px solid #3b82f6!important;background:rgba(59,130,246,0.12)!important;border-radius:3px!important;display:none!important;';
          lastHighlightedElement = null;
          lastHighlightKey = null;
        }
        if (!highlight.isConnected) root.appendChild(highlight);
        return highlight;
      }

      function isPilotUI(el) {
        return !el || el === highlight || (box && (el === box || box.contains(el)));
      }

      function rawEventElement(e) {
        var path = typeof e.composedPath === 'function' ? e.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var node = path[i];
          if (node && node.nodeType === 1 && !isPilotUI(node)) return node;
        }
        var fallback = document.elementFromPoint(e.clientX, e.clientY);
        return isPilotUI(fallback) ? null : fallback;
      }

      function visibleRect(el) {
        if (!el || el.nodeType !== 1 || !el.isConnected || isPilotUI(el)) return null;
        var style = window.getComputedStyle(el);
        if (style.display === 'none' || style.display === 'contents' ||
            style.visibility === 'hidden' || style.visibility === 'collapse' ||
            parseFloat(style.opacity || '1') <= 0) return null;
        var r = el.getBoundingClientRect();
        if (!Number.isFinite(r.left) || !Number.isFinite(r.top) ||
            !Number.isFinite(r.width) || !Number.isFinite(r.height) ||
            r.width < 2 || r.height < 2 || r.right <= 0 || r.bottom <= 0 ||
            r.left >= window.innerWidth || r.top >= window.innerHeight) return null;
        return r;
      }

      function rectContainsPoint(r, x, y) {
        if (!Number.isFinite(x) || !Number.isFinite(y)) return true;
        return x >= r.left - 1 && x <= r.right + 1 && y >= r.top - 1 && y <= r.bottom + 1;
      }

      function hasPaintedBox(style) {
        var background = style.backgroundColor;
        var hasBackground = style.backgroundImage !== 'none' && style.backgroundImage !== '';
        if (background && background !== 'transparent' && background !== 'rgba(0, 0, 0, 0)') {
          hasBackground = true;
        }
        var hasBorder = parseFloat(style.borderTopWidth || '0') > 0 ||
          parseFloat(style.borderRightWidth || '0') > 0 ||
          parseFloat(style.borderBottomWidth || '0') > 0 ||
          parseFloat(style.borderLeftWidth || '0') > 0;
        return hasBackground || hasBorder || (style.boxShadow && style.boxShadow !== 'none');
      }

      function smartElement(raw, x, y) {
        if (!raw || raw.nodeType !== 1 || isPilotUI(raw)) return null;

        var interactive = typeof raw.closest === 'function' ? raw.closest(interactiveSelector) : null;
        var interactiveRect = visibleRect(interactive);
        if (interactiveRect && rectContainsPoint(interactiveRect, x, y)) return interactive;

        // Once a useful container owns the pointer, keep it while traversing
        // its non-interactive descendants. This avoids flicker between a card,
        // its labels, and its icons, and skips the expensive ancestor scoring
        // path for the common case. Interactive descendants still win above.
        if (hovered && hovered.isConnected &&
            (hovered === raw || (typeof hovered.contains === 'function' && hovered.contains(raw)))) {
          var hoveredRect = visibleRect(hovered);
          if (hoveredRect && rectContainsPoint(hoveredRect, x, y)) return hovered;
        }

        var viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
        var best = null, bestScore = -Infinity;
        var node = raw, depth = 0;
        while (node && node.nodeType === 1 && node !== document.body && node !== document.documentElement && depth < 12) {
          if (containerTags[node.tagName]) {
            var r = visibleRect(node);
            if (r && rectContainsPoint(r, x, y)) {
              var areaRatio = (r.width * r.height) / viewportArea;
              // Whole-page shells make almost every point look identical and
              // are rarely the component the user intends to annotate.
              if (areaRatio < 0.9) {
                var style = window.getComputedStyle(node);
                var score = node.tagName === 'DIV' ? 12 : 9;
                score -= depth * 1.5;
                score += r.width >= 32 && r.height >= 20 ? 2 : -6;
                score += hasPaintedBox(style) ? 8 : 0;
                score += node.children.length > 1 ? 3 : 0;
                score += node.id || node.hasAttribute('role') || node.hasAttribute('data-testid') ? 4 : 0;
                if (areaRatio > 0.65) score -= 12;
                else if (areaRatio > 0.4) score -= 5;
                if (score > bestScore) {
                  best = node;
                  bestScore = score;
                }
              }
            }
          }
          node = node.parentElement;
          depth += 1;
        }
        if (best) return best;

        var rawRect = visibleRect(raw);
        return rawRect && rectContainsPoint(rawRect, x, y) ? raw : null;
      }

      function rememberPointer(e) {
        var x = Number(e.clientX), y = Number(e.clientY);
        pointerInside = Number.isFinite(x) && Number.isFinite(y) &&
          x >= 0 && y >= 0 && x <= window.innerWidth && y <= window.innerHeight;
        if (pointerInside) {
          lastPointerX = x;
          lastPointerY = y;
        }
      }

      function eventElement(e) {
        rememberPointer(e);
        return smartElement(rawEventElement(e), Number(e.clientX), Number(e.clientY));
      }

      function makeSelectionID() {
        // IDs must remain unique across navigations. A snapshot from the prior
        // document can finish after the new page has already made a selection;
        // a document-local counter would let that stale completion clear it.
        if (window.crypto && typeof window.crypto.randomUUID === 'function') {
          return window.crypto.randomUUID();
        }
        fallbackSelectionSequence += 1;
        return Date.now().toString(36) + '-' + fallbackSelectionSequence.toString(36) + '-' + Math.random().toString(36).slice(2);
      }

      function cssPath(el) {
        if (!el || el.nodeType !== 1) return '';
        if (el.id) return '#' + CSS.escape(el.id);
        var parts = [];
        while (el && el.nodeType === 1 && parts.length < 6) {
          var sel = el.tagName.toLowerCase();
          if (el.classList && el.classList.length) {
            sel += '.' + Array.prototype.slice.call(el.classList, 0, 2).map(function (c) { return CSS.escape(c); }).join('.');
          }
          var parent = el.parentElement;
          if (parent) {
            var sibs = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
            if (sibs.length > 1) sel += ':nth-of-type(' + (sibs.indexOf(el) + 1) + ')';
          }
          parts.unshift(sel);
          el = parent;
        }
        return parts.join(' > ');
      }

      function positionHighlight(el) {
        if (!el || !el.isConnected) { hideHighlight(); return; }
        var r = el.getBoundingClientRect();
        ensureCursorStyle();
        var h = ensureHighlight();
        if (!h || !Number.isFinite(r.left) || !Number.isFinite(r.top) ||
            !Number.isFinite(r.width) || !Number.isFinite(r.height) ||
            r.width < 1 || r.height < 1) { hideHighlight(); return; }
        var isSelected = selected === el;
        var key = [r.left, r.top, r.width, r.height, isSelected ? 1 : 0].join('|');
        if (lastHighlightedElement === el && lastHighlightKey === key &&
            h.style.getPropertyValue('display') === 'block') return;
        h.style.setProperty('display', 'block', 'important');
        h.style.setProperty('left', r.left + 'px', 'important');
        h.style.setProperty('top', r.top + 'px', 'important');
        h.style.setProperty('width', r.width + 'px', 'important');
        h.style.setProperty('height', r.height + 'px', 'important');
        h.style.setProperty('border-color', isSelected ? '#0a84ff' : '#3b82f6', 'important');
        h.style.setProperty('background', isSelected ? 'rgba(10,132,255,0.18)' : 'rgba(59,130,246,0.12)', 'important');
        h.style.setProperty('box-shadow', isSelected ? '0 0 0 1px rgba(255,255,255,0.8)' : 'none', 'important');
        lastHighlightedElement = el;
        lastHighlightKey = key;
      }

      function hideHighlight() {
        if (highlight) highlight.style.setProperty('display', 'none', 'important');
        lastHighlightedElement = null;
        lastHighlightKey = null;
      }

      function resolveHoverAtPointer(raw) {
        if (!enabled || selected || sending || !pointerInside ||
            !Number.isFinite(lastPointerX) || !Number.isFinite(lastPointerY)) return;
        if (!raw || !raw.isConnected || isPilotUI(raw)) {
          raw = document.elementFromPoint(lastPointerX, lastPointerY);
        }
        var el = smartElement(raw, lastPointerX, lastPointerY);
        if (!el) {
          hovered = null;
          hideHighlight();
          return;
        }
        hovered = el;
        positionHighlight(el);
      }

      function flushPendingHover() {
        if (!pendingHover) return;
        var raw = pendingRawTarget;
        pendingHover = false;
        pendingRawTarget = null;
        resolveHoverAtPointer(raw);
      }

      function cancelScheduledHover() {
        if (hoverFrame) window.cancelAnimationFrame(hoverFrame);
        if (hoverTimer) window.clearTimeout(hoverTimer);
        hoverFrame = 0;
        hoverTimer = 0;
        pendingHover = false;
        pendingRawTarget = null;
      }

      // Resolve the first movement immediately, then collapse every additional
      // event in the same display frame to the latest pointer target. Complex
      // pages commonly emit pointermove + mousemove + mouseover together; doing
      // ancestor style/layout work for all three makes the lasso trail badly.
      function scheduleHover(raw) {
        pendingRawTarget = raw || pendingRawTarget;
        pendingHover = true;
        if (hoverFrame || hoverTimer) return;
        flushPendingHover();
        hoverFrame = window.requestAnimationFrame(function () {
          hoverFrame = 0;
          if (hoverTimer) window.clearTimeout(hoverTimer);
          hoverTimer = 0;
          flushPendingHover();
        });
        // WebKit may pause animation frames while a view is being attached,
        // uncovered, or moved between panes. Never let the latest target wait
        // indefinitely for a frame that the web process has throttled.
        hoverTimer = window.setTimeout(function () {
          hoverTimer = 0;
          if (hoverFrame) window.cancelAnimationFrame(hoverFrame);
          hoverFrame = 0;
          flushPendingHover();
        }, 16);
      }

      function refreshHoverAtPointer() {
        resolveHoverAtPointer(null);
      }

      function onMove(e) {
        rememberPointer(e);
        if (!enabled || selected || sending) return;
        scheduleHover(rawEventElement(e));
      }

      function onPointerLeave(e) {
        // `mouseout` also fires between descendants. Only clear the remembered
        // position when the pointer actually exits the document/WebView.
        if (e && (e.relatedTarget || e.toElement)) return;
        pointerInside = false;
        cancelScheduledHover();
        if (!enabled || selected || sending) return;
        hovered = null;
        hideHighlight();
      }

      // Keep the highlight glued to its element while the page scrolls; the box
      // is position:fixed so it stays put on its own.
      function onScroll() {
        if (!enabled || layoutFrame) return;
        layoutFrame = window.requestAnimationFrame(function () {
          layoutFrame = 0;
          if (!enabled) return;
          var target = selected || hovered;
          if (target && target.isConnected) {
            positionHighlight(target);
          } else {
            if (selected) clearSelection();
            hovered = null;
            hideHighlight();
          }
        });
      }

      function blockPageEvent(e) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }

      function onPointerDown(e) {
        if (!enabled || (box && box.contains(e.target))) return;
        var target = eventElement(e);
        blockPageEvent(e);
        cancelScheduledHover();
        if (sending) return;
        if (target) showBox(target);
      }

      // The pointerdown owns selection. Suppress the compatibility click so
      // the page cannot activate a link/button after the lasso has selected it.
      function onClick(e) {
        if (!enabled || (box && box.contains(e.target))) return;
        blockPageEvent(e);
      }

      function removeBox() { if (box) { box.remove(); box = null; } }

      function clearSelection() {
        removeBox();
        hovered = null;
        selected = null;
        sending = false;
        selectionID = null;
        sendingID = null;
        selectionBridgeToken = null;
        hideHighlight();
        if (enabled) refreshHoverAtPointer();
      }

      function showBox(el) {
        removeBox();
        selectionID = makeSelectionID();
        selectionBridgeToken = bridgeToken;
        selected = el;
        hovered = el;
        positionHighlight(el);
        var r = el.getBoundingClientRect();
        box = document.createElement('div');
        box.setAttribute('data-pilot-annotate-box', '');
        box.style.cssText = 'position:fixed;z-index:2147483647;left:' + Math.max(8, Math.min(r.left, window.innerWidth - 340)) + 'px;top:' + Math.min(r.bottom + 8, window.innerHeight - 210) + 'px;width:324px;background:rgba(32,32,34,0.97);color:#fff;border:1px solid rgba(255,255,255,0.14);border-radius:12px;padding:12px;box-shadow:0 12px 40px rgba(0,0,0,0.5);font:13px -apple-system,system-ui;backdrop-filter:blur(20px) saturate(1.4);-webkit-backdrop-filter:blur(20px) saturate(1.4);';

        var style = document.createElement('style');
        style.textContent = '[data-pilot-annotate-box] .pa-close:hover{background:rgba(255,255,255,0.12)!important;color:#fff!important;}' +
          '[data-pilot-annotate-box] textarea:focus{outline:none!important;border-color:#0a84ff!important;box-shadow:0 0 0 3px rgba(10,132,255,0.25)!important;}' +
          '[data-pilot-annotate-box] textarea::placeholder{color:#636366!important;}' +
          '[data-pilot-annotate-box] .pa-send:hover{background:#2f8cff!important;}';
        box.appendChild(style);

        var header = document.createElement('div');
        header.style.cssText = 'display:flex;align-items:center;gap:6px;margin-bottom:8px;';
        var title = document.createElement('span');
        title.textContent = 'Annotate element';
        title.style.cssText = 'font:600 12px -apple-system,system-ui;color:#ebebf0;';
        header.appendChild(title);
        var tag = document.createElement('span');
        tag.textContent = '<' + el.tagName.toLowerCase() + '>';
        tag.style.cssText = 'font:11px ui-monospace,Menlo,monospace;color:#8e8e93;background:rgba(255,255,255,0.08);border-radius:4px;padding:1px 5px;overflow:hidden;text-overflow:ellipsis;max-width:120px;white-space:nowrap;';
        header.appendChild(tag);
        var close = document.createElement('button');
        close.className = 'pa-close';
        close.textContent = '×';
        close.title = 'Dismiss';
        close.setAttribute('aria-label', 'Dismiss');
        close.style.cssText = 'margin-left:auto;width:22px;height:22px;line-height:20px;text-align:center;background:transparent;color:#8e8e93;border:none;border-radius:6px;font-size:16px;cursor:pointer;padding:0;transition:background 0.12s;';
        close.addEventListener('click', clearSelection);
        header.appendChild(close);
        box.appendChild(header);

        var ta = document.createElement('textarea');
        ta.placeholder = 'Describe what you want to happen…';
        ta.style.cssText = 'width:100%;height:64px;background:rgba(255,255,255,0.06);color:#fff;border:1px solid rgba(255,255,255,0.14);border-radius:8px;padding:8px;resize:none;box-sizing:border-box;font:13px -apple-system,system-ui;transition:border-color 0.12s,box-shadow 0.12s;';
        box.appendChild(ta);

        var footer = document.createElement('div');
        footer.style.cssText = 'display:flex;align-items:center;gap:8px;margin-top:8px;';
        var hint = document.createElement('div');
        hint.textContent = 'Press Enter, click a terminal, then Send';
        hint.style.cssText = 'color:#8e8e93;font-size:11px;flex:1;';
        footer.appendChild(hint);
        var send = document.createElement('button');
        send.className = 'pa-send';
        send.textContent = 'Send';
        send.style.cssText = 'display:none;background:#0a84ff;color:#fff;border:none;border-radius:7px;padding:6px 14px;font:600 12px -apple-system,system-ui;cursor:pointer;transition:background 0.12s;';
        footer.appendChild(send);
        box.appendChild(footer);
        var root = document.documentElement;
        if (!root) { clearSelection(); return; }
        root.appendChild(box);
        ta.focus();

        ta.addEventListener('keydown', function (ev) {
          if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); send.style.display = 'block'; hint.textContent = 'Click a terminal, then Send'; }
          else if (ev.key === 'Escape') { clearSelection(); }
        });
        send.addEventListener('click', function () {
          // Re-read geometry now — the page may have scrolled or reflowed since
          // the box opened, so the captured `r` could be stale.
          var live = el.isConnected ? el.getBoundingClientRect() : r;
          var payload = {
            action: 'send',
            instruction: ta.value,
            selector: cssPath(el),
            outerHTML: (el.outerHTML || '').slice(0, 8000),
            rect: { x: live.left, y: live.top, w: live.width, h: live.height },
            selectionID: selectionID,
            bridgeToken: selectionBridgeToken,
            url: document.location.href
          };
          // Keep the selected outline visible while Swift snapshots the page.
          // `finishSend` clears it only after the image has been captured.
          sending = true;
          sendingID = selectionID;
          removeBox();
          selected = el;
          positionHighlight(el);
          try {
            window.webkit.messageHandlers.pilotAnnotate.postMessage(payload);
          } catch (_) {
            finishSend(selectionID);
          }
        });
      }

      function setEnabled(v, token) {
        window.__pilotAnnotateDesiredEnabled = !!v;
        enabled = !!v;
        bridgeToken = enabled && typeof token === 'string' ? token : null;
        ensureCursorStyle();
        if (document.documentElement) {
          document.documentElement.classList.toggle('__pilot-lasso-active', enabled);
        }
        if (!enabled) {
          cancelScheduledHover();
          clearSelection();
        }
        else refreshHoverAtPointer();
      }

      function syncDocumentState() {
        if (!document.documentElement) return;
        ensureCursorStyle();
        document.documentElement.classList.toggle('__pilot-lasso-active', enabled);
        if (enabled) refreshHoverAtPointer();
      }

      function finishSend(completedSelectionID) {
        // A stale snapshot must not clear a newer selection made after a rapid
        // off/on toggle. Only the send that owns the outline may release it.
        if (completedSelectionID !== sendingID) return;
        removeBox();
        hovered = null;
        selected = null;
        sending = false;
        selectionID = null;
        sendingID = null;
        selectionBridgeToken = null;
        hideHighlight();
      }

      // Install on `window` at document start, before page scripts can register
      // capture handlers that stop propagation before events reach `document`.
      // Mouse listeners remain as a WebKit compatibility fallback; the frame
      // scheduler above coalesces duplicate pointer/mouse delivery.
      window.addEventListener('pointermove', onMove, true);
      window.addEventListener('mousemove', onMove, true);
      window.addEventListener('pointerover', onMove, true);
      window.addEventListener('mouseover', onMove, true);
      window.addEventListener('pointerout', onPointerLeave, true);
      window.addEventListener('mouseout', onPointerLeave, true);
      window.addEventListener('pointerdown', onPointerDown, true);
      window.addEventListener('click', onClick, true);
      window.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', onScroll, true);
      document.addEventListener('DOMContentLoaded', syncDocumentState, true);
      window.__pilotAnnotate = { setEnabled: setEnabled, finishSend: finishSend };
      setEnabled(initiallyEnabled, null);
    })();
    """

    /// JS to push the current enabled state into the page (after toggle / load).
    static func setEnabledScript(_ enabled: Bool, token: String? = nil) -> String {
        let tokenData = try? JSONEncoder().encode(token)
        let tokenLiteral = tokenData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return """
        window.__pilotAnnotateDesiredEnabled = \(enabled);
        window.__pilotAnnotate && window.__pilotAnnotate.setEnabled(\(enabled), \(tokenLiteral));
        """
    }

    /// Clears the locked selection only after WebKit has captured its outline.
    static func finishSendScript(selectionID: String) -> String {
        let data = try? JSONEncoder().encode(selectionID)
        let literal = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "window.__pilotAnnotate && window.__pilotAnnotate.finishSend(\(literal))"
    }

    @MainActor
    static func evaluate(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(script, in: nil, in: contentWorld) { _ in }
    }

    /// Collapse control chars (newlines, tabs, ESC sequences) + whitespace runs
    /// to single spaces. The element HTML/selector/URL/instruction are
    /// page-controlled, so this neutralizes newline command-injection and
    /// terminal-escape injection before any of it reaches a terminal.
    private static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Compose the agent prompt from the captured element + screenshot.
    ///
    /// The result is a *single line* (no embedded newlines): it's delivered to
    /// the terminal by typing the text and then pressing Enter once, so a
    /// newline anywhere in the prompt would submit it early — and, with
    /// page-controlled content, would execute the tail as a separate command.
    /// Every field is run through `singleLine`, and the sections are joined with
    /// " | " so one Enter sends exactly one message to the agent.
    static func buildPrompt(instruction: String, url: String, selector: String,
                            outerHTML: String, rectX: Int, rectY: Int, rectW: Int, rectH: Int,
                            screenshotPath: String?) -> String {
        let rawHTML = singleLine(outerHTML)
        let html = rawHTML.count > 2000 ? String(rawHTML.prefix(2000)) + " …(truncated)" : rawHTML
        var parts = [
            "[Cockpit Browser Annotate]",
            "Instruction: \(singleLine(instruction))",
            "BEGIN UNTRUSTED PAGE CONTEXT",
            "Page URL: \(singleLine(url))",
            "Element selector: \(singleLine(selector))",
            "Element rect: x=\(rectX) y=\(rectY) w=\(rectW) h=\(rectH) (CSS px, viewport coords)",
            "Element HTML: \(html)",
            "END UNTRUSTED PAGE CONTEXT",
        ]
        if let screenshotPath { parts.append("Screenshot saved at: \(singleLine(screenshotPath))") }
        parts.append("Please make the requested change. The screenshot shows the page; the selector and HTML identify the exact element.")
        return parts.joined(separator: " | ")
    }

    /// Write a page snapshot to a per-user temp PNG; returns its absolute path.
    /// Snapshots live in a private 0700 subdirectory (not world-readable like
    /// bare `/tmp`) and stale ones are swept on each write so they don't pile up.
    static func writeScreenshot(_ image: NSImage?) -> String? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-annotate", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        sweepStale(in: dir)
        let url = dir.appendingPathComponent("annotate-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch { return nil }
    }

    /// Delete snapshots older than an hour — the agent reads them within
    /// seconds of dispatch, so anything lingering is abandoned.
    private static func sweepStale(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date(timeIntervalSinceNow: -3600)
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
