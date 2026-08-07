# appModules/explorer.py  —  NVDA scratchpad
#
# Two behaviors for File Explorer windows:
#
# 1. Silent-focus recovery. When you return to an Explorer window, focus
#    sometimes lands on the frame's client window itself (CabinetWClass,
#    IAccessible ROLE_SYSTEM_CLIENT / role PANE, OBJID_CLIENT) instead of on
#    a control inside it. That PANE has nothing speakable, so NVDA goes
#    silent and you have to Tab to descend into the list. We detect that
#    dead-frame focus and redirect it down into the items list, which makes
#    Explorer restore the remembered item -- exactly what Tab would do.
#
# 2. Simplified F6 navigation:
#      F6        -> next pane   (list view -> navigation pane -> address bar)
#      Shift+F6  -> previous pane
#    Ribbon, search box, column headers, status bar and details pane are
#    skipped. On non-file-browser explorer.exe windows (desktop, taskbar)
#    F6 is passed through and focus recovery is inert.

import appModuleHandler
import api
import core
import ui
from controlTypes import Role
from scriptHandler import script
from keyboardHandler import KeyboardInputGesture
from logHandler import log

# Extend NVDA's BUILT-IN explorer appModule, don't replace it. A scratchpad
# appModule shadows the built-in one (only one loads per app), so subclassing
# appModuleHandler.AppModule would drop everything NVDA's explorer module does
# -- e.g. keeping the Alt+Tab "Task switching" window quiet. nvdaBuiltin is the
# supported way to reach the built-in class from the scratchpad / an add-on.
try:
    from nvdaBuiltin.appModules.explorer import AppModule as _ExplorerBase
    _BASE = "nvdaBuiltin.explorer"
except Exception:
    _ExplorerBase = appModuleHandler.AppModule
    _BASE = "appModuleHandler(FALLBACK)"

# --- configuration ---------------------------------------------------------

# Order the F6 chain visits the panes. Reorder to taste.
ZONE_ORDER = ["list", "nav", "address"]

# File-browser frame window classes. Both features only act inside these.
EXPLORER_FRAME_CLASSES = ("CabinetWClass", "ExploreWClass")

# Roles that mean "a real item took focus" -> NVDA has already spoken it.
_ITEM_ROLES = frozenset({Role.LISTITEM, Role.DATAITEM, Role.TREEVIEWITEM})

# Roles that can host the file listing (details view can present as any).
_LIST_ROLES = frozenset({Role.LIST, Role.TABLE, Role.DATAGRID})

# Search is breadth-first with a depth cap; we never descend INTO these
# roles, so enumerating a folder of 10k files never happens.
_CONTAINER_ROLES = _LIST_ROLES | frozenset({Role.TREEVIEW})
_MAX_DEPTH = 16


# --- object matching / search ---------------------------------------------

def _aid(obj):
    """UIA AutomationId, or '' — only call on objects worth the UIA hop."""
    try:
        return obj.UIAAutomationId or ""
    except Exception:
        return ""


def _find(root, predicate):
    """Bounded BFS from root. Tests container nodes but does not walk into
    their children, so we get the list/tree container without touching items."""
    from collections import deque
    queue = deque([(root, 0)])
    while queue:
        obj, depth = queue.popleft()
        try:
            if predicate(obj):
                return obj
        except Exception:
            log.debugWarning("explorer F6/recovery predicate failed", exc_info=True)
        if depth >= _MAX_DEPTH:
            continue
        if getattr(obj, "role", None) in _CONTAINER_ROLES:
            continue  # don't recurse into list/tree items
        try:
            children = obj.children
        except Exception:
            children = []
        for child in children:
            queue.append((child, depth + 1))
    return None


def _is_nav_tree(obj):
    return obj.role == Role.TREEVIEW  # Explorer has a single tree: the nav pane


def _is_items_list(obj):
    if obj.role not in _LIST_ROLES:
        return False
    if (getattr(obj, "windowClassName", "") or "") == "DirectUIHWND":
        return True
    return _aid(obj) == "Items View"


def _is_any_list(obj):
    return obj.role in _LIST_ROLES


def _is_lost_frame_focus(obj):
    """Focus has fallen onto the bare Explorer frame client (the silent state)."""
    return ((getattr(obj, "windowClassName", "") or "") in EXPLORER_FRAME_CLASSES
            and obj.role == Role.PANE)


def _zone_of(obj):
    """Which of the three panes currently holds focus, or None."""
    node = obj
    while node is not None:
        role = getattr(node, "role", None)
        wcn = getattr(node, "windowClassName", "") or ""
        if role == Role.TREEVIEW:
            return "nav"
        if role in _LIST_ROLES and (wcn == "DirectUIHWND" or _aid(node) == "Items View"):
            return "list"
        if wcn == "Address Band Root":
            return "address"
        node = node.parent
    return None


# --- focusing the items list (shared by F6 and recovery) -------------------

def _ensure_item_focused(listObj):
    """Called shortly after focusing the list. If Explorer restored a real
    item, NVDA has already announced it and we do nothing. Only if focus is
    still stuck on a container/frame do we force an item with Home."""
    focus = api.getFocusObject()
    role = getattr(focus, "role", None)
    log.info("explorerNav: post-redirect focus role=%r cls=%r"
             % (role, getattr(focus, "windowClassName", "?")))
    if role in _ITEM_ROLES:
        return
    if focus is listObj or role in (_LIST_ROLES | {Role.PANE}):
        KeyboardInputGesture.fromName("home").send()


def _focus_items_list(root):
    lst = _find(root, _is_items_list) or _find(root, _is_any_list)
    if lst is None:
        return False
    lst.setFocus()
    core.callLater(30, _ensure_item_focused, lst)
    return True


# --- pane movers (F6) ------------------------------------------------------
# Each returns True on success so the caller can fall back if a pane is absent.

def _go_address():
    KeyboardInputGesture.fromName("alt+d").send()  # reliable: jumps to the path edit
    return True


def _go_nav():
    tree = _find(api.getForegroundObject(), _is_nav_tree)
    if tree is None:
        return False
    tree.setFocus()
    return True


def _go_list():
    return _focus_items_list(api.getForegroundObject())


_MOVERS = {"address": _go_address, "nav": _go_nav, "list": _go_list}


# --- appModule -------------------------------------------------------------

class AppModule(_ExplorerBase):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._recovering = False
        log.info("explorerNav appModule loaded (base=%s)" % _BASE)

    def _clear_recovering(self):
        self._recovering = False

    # -- silent-focus recovery --
    def event_gainFocus(self, obj, nextHandler):
        if (not self._recovering) and _is_lost_frame_focus(obj):
            self._recovering = True
            core.callLater(150, self._clear_recovering)
            found = _focus_items_list(obj)
            log.info("explorerNav: dead-frame focus on %r; redirect=%s"
                     % (getattr(obj, "windowClassName", "?"), found))
            if found:
                # Swallow the dead-frame event; the redirect fires its own
                # focus event on the restored item, which NVDA will announce.
                return
        # Preserve the built-in explorer handling (task-switcher quieting,
        # notification area, Start menu) by delegating up the MRO.
        base = getattr(super(), "event_gainFocus", None)
        if base is not None:
            base(obj, nextHandler)
        else:
            nextHandler()

    # -- simplified F6 navigation --
    def _in_file_browser(self):
        fg = api.getForegroundObject()
        return (getattr(fg, "windowClassName", "") or "") in EXPLORER_FRAME_CLASSES

    def _cycle(self, direction, gesture):
        if not self._in_file_browser():
            gesture.send()  # desktop / taskbar -> keep native F6
            return
        current = _zone_of(api.getFocusObject())
        if current in ZONE_ORDER:
            idx = (ZONE_ORDER.index(current) + direction) % len(ZONE_ORDER)
        else:
            idx = 0 if direction > 0 else len(ZONE_ORDER) - 1
        target = ZONE_ORDER[idx]
        if not _MOVERS[target]():
            fallback = ZONE_ORDER[(idx + direction) % len(ZONE_ORDER)]
            if not _MOVERS[fallback]():
                ui.message("Pane not found")

    @script(gesture="kb:f6", description="Move to the next Explorer pane")
    def script_nextPane(self, gesture):
        self._cycle(+1, gesture)

    @script(gesture="kb:shift+f6", description="Move to the previous Explorer pane")
    def script_prevPane(self, gesture):
        self._cycle(-1, gesture)
