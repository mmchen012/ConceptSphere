# conceptSphereQuiet.py - NVDA global plugin
#
# One plugin in place of four. Replaces, and you must DELETE:
#     globalPlugins\minitrayQuiet.py
#     globalPlugins\quietFocusAncestry.py
#     globalPlugins\startMenuContextMenuFix.py
#     globalPlugins\desktopChurnFix.py
#
# Leaving minitrayQuiet.py in place alongside this is actively harmful: both
# wrap speech.speak, so whichever loads second wraps the other's wrapper and
# the sentinel handling ends up doubled.
#
# WHAT IS IN HERE
#
#   1. QUIET WINDOWS (was minitrayQuiet)
#      An app "speaks" a sentinel through the controller client:
#          \x01MTQUIET:900\x01   open a 900 ms quiet window
#          \x01MTQUIET:0\x01     close it now
#          \x01MTQUIETSAFE:ms\x01 open/close quiet and cancel only when no
#                                  protected MiniTray result is in progress
#          \x01MTFINAL:text\x01 queue this protected result while staying quiet
#          \x01MTMENU:tail:text\x01
#                                  cancel competing speech inside NVDA, defer
#                                  the menu-opening phrase, and suppress late
#                                  focus chatter for tail milliseconds
#          \x01MTNAV\x01         immediately release protected MiniTray menu
#                                  speech before AHK changes the popup selection
#          \x01MTCLOSEMENU:hwnd:text\x01
#                                  speak the close result, then the first focused
#                                  item in the still-open MiniTray popup
#          \x01MTCLOSETRAY:hwnd:remove:text\x01
#                                  speak the close result, move focus to the
#                                  MiniTray notification icon, and optionally
#                                  advance once before asking AHK to remove it
#          \x01MTHIDEFINAL:tail:text\x01
#                                  defer the final-window hide result until
#                                  desktop focus chatter has settled
#          \x01MTFINALFOCUS:hwnd:token:text\x01
#                                  speak text, then tell MiniTray to activate the
#                                  window and restore focus
#          \x01MTREPLAYFOCUS:hwnd:pid\x01
#                                  reopen speech and report NVDA focused caret line for
#                                  the actual focused object
#          \x01MTSAVEFOCUS:hwnd:pid\x01
#                                  remember NVDA's current focused object before hide
#          \x01MTRESTORESAVEDFOCUS:hwnd:pid\x01
#                                  recover terminal monitoring or announce the focused
#                                  control in other restored applications
#      Everything else is dropped for the duration, before it is synthesised.
#      Used by MiniTray and by ConsoleSelectAll. The sentinel is never spoken,
#      and without this plugin the strings are harmless.
#
#      WHY NOT cancelSpeech: cancelling can only INTERRUPT. NVDA queues an
#      announcement the moment focus or a selection changes, and with a synth
#      that renders on a background thread (SAPI5 mixers, dual-voice add-ons)
#      the audio is already on its way out before the next cancel lands. The
#      result is a clipped fragment of every announcement rather than silence.
#
#   2. FOCUS ANCESTRY (was quietFocusAncestry)
#      Drops the "<title> window" / "<title> document" pair NVDA speaks as
#      focus passes through containers on its way to the control you actually
#      focused. Toggle with NVDA+Shift+Q; starts enabled, not remembered
#      across restarts.
#
#   3. START MENU (was startMenuContextMenuFix)
#      Stops "context menu list" being repeated before every item in a
#      Windows 11 Start context menu (a Chromium <ul> living in SearchHost,
#      not StartMenuExperienceHost), and shortens "<folder> expanded dialog
#      list" to just "expanded" when a Start folder opens.
#
#   4. DESKTOP CHURN (was desktopChurnFix)
#      Silences automatic Explorer desktop refresh events. Windows/OneDrive
#      can recreate the focused desktop LISTITEM and emit repeated gainFocus
#      plus selection events every few seconds. Event-only suppression was not
#      enough: the log showed the icon name had already reached speech before
#      event_selection ran. This version therefore uses two narrow guards:
#        - event guard: drops duplicate gainFocus for the same desktop icon;
#        - speech guard: drops a repeated name-only utterance for the currently
#          focused desktop icon unless a new user gesture or icon change occurs.
#      Arrowing to another icon remains spoken normally. Ctrl+Space explicitly
#      reports only "selected" or "not selected" after the state changes.
#
# INSTALL
#   1. NVDA -> Preferences -> Settings -> Advanced
#      Tick "Enable loading custom code from Developer Scratchpad Directory".
#   2. NVDA -> Tools -> Open developer scratchpad directory
#   3. Save as:  globalPlugins\conceptSphereQuiet.py
#      and delete the four files listed at the top.
#   4. Reload with NVDA+Ctrl+F3, or restart NVDA.
#
# GESTURES
#   NVDA+Shift+Q   toggle focus ancestry suppression
#   Quiet-window status remains available in Input Gestures, unassigned.
#
# SAFETY
#   External quiet-window requests are capped at MAX_QUIET_MS. Protected
#   MiniTray results may extend suppression only while their bounded queue is
#   active, preventing focus chatter from interrupting queued status speech.

import ctypes
import os
import time

import api
import core
import eventHandler
import textInfos
import treeInterceptorHandler
import globalPluginHandler
import globalVars
import inputCore
import keyboardHandler
import speech
import winUser
import ui
import controlTypes
from NVDAObjects import NVDAObject
from logHandler import log
from scriptHandler import script
from speech.commands import CallbackCommand

# ---------------------------------------------------------------- settings

# Hard ceiling on a quiet window, in milliseconds.
MAX_QUIET_MS = 1500

# Sentinel prefixes accepted. MTQUIET is what MiniTray and ConsoleSelectAll
# already send; CSQUIET is the neutral name for anything written later.
OPEN_PREFIXES = ("\x01MTQUIET:", "\x01CSQUIET:")
SAFE_QUIET_PREFIX = "\x01MTQUIETSAFE:"
FINAL_PREFIX = "\x01MTFINAL:"
MENU_PREFIX = "\x01MTMENU:"
POPUP_NAVIGATION_COMMAND = "\x01MTNAV\x01"
CLOSE_MENU_PREFIX = "\x01MTCLOSEMENU:"
CLOSE_TRAY_PREFIX = "\x01MTCLOSETRAY:"
HIDE_FINAL_PREFIX = "\x01MTHIDEFINAL:"
RESTORE_FINAL_PREFIX = "\x01MTRESTOREFINAL:"
FINAL_FOCUS_PREFIX = "\x01MTFINALFOCUS:"
REPLAY_FOCUS_PREFIX = "\x01MTREPLAYFOCUS:"  # accepted for backward compatibility
REPORT_LINE_PREFIX = "\x01MTREPORTLINE:"
SAVE_FOCUS_PREFIX = "\x01MTSAVEFOCUS:"
RESTORE_SAVED_FOCUS_PREFIX = "\x01MTRESTORESAVEDFOCUS:"
RESTORE_FOCUS_MESSAGE = 0x8154
TRAY_ICON_HIDE_MESSAGE = 0x8155
CLOSE_RESULT_FOCUS_GAP_MS = 80
CLOSE_RESULT_RETRY_MS = 70
CLOSE_RESULT_MAX_ATTEMPTS = 20
TRAY_FOCUS_INITIAL_DELAY_MS = 140
TRAY_FOCUS_STEP_DELAY_MS = 85
TRAY_FOCUS_MAX_STEPS = 48
REPLAY_FOCUS_RETRY_MS = 80
REPLAY_FOCUS_MAX_ATTEMPTS = 8
REPORT_LINE_RETRY_MS = 100
REPORT_LINE_MAX_ATTEMPTS = 20
SAVED_FOCUS_RETRY_MS = 80
SAVED_FOCUS_MAX_ATTEMPTS = 15
SAVED_FOCUS_QUIET_MS = 350
SAVED_FOCUS_CACHE_LIMIT = 64
GENERIC_FOCUS_ANNOUNCE_DELAY_MS = 850
GENERIC_FOCUS_RETRY_MS = 80
GENERIC_FOCUS_MAX_ATTEMPTS = 15
MENU_ANNOUNCE_DELAY_MS = 80
HIDE_FINAL_ANNOUNCE_DELAY_MS = 120
RESTORE_FINAL_PREPARE_DELAY_MS = 40
RESTORE_FINAL_ANNOUNCE_DELAY_MS = 120
RESTORE_TITLE_MIN_MS = 650
RESTORE_TITLE_MAX_MS = 3200
RESTORE_FOCUS_MIN_MS = 650
RESTORE_FOCUS_MAX_MS = 4500
RESTORE_FINAL_MAX_ATTEMPTS = 6

# Protected MiniTray speech is serialized without CallbackCommand. The user's
# dual-voice synthesizer does not reliably execute callbacks, so queue progress
# uses a conservative duration estimate instead. The estimate only controls
# when the next MiniTray result may start; ordinary user input can still cancel
# NVDA speech in the normal way.
MINITRAY_QUEUE_GAP_MS = 100
MINITRAY_QUEUE_MIN_SPEECH_MS = 1800
MINITRAY_QUEUE_MAX_SPEECH_MS = 9000
MINITRAY_QUEUE_WORD_MS = 220
MINITRAY_QUEUE_CHAR_MS = 32
MINITRAY_QUEUE_PUNCT_MS = 90
MINITRAY_QUEUE_LIMIT = 32

# Native Alt+Tab first reports the selected task-switcher item, usually as
# "<title>, row <n>, column <n>". When Alt is released, NVDA normally cancels
# that preview and starts a second foreground-window utterance. Replace the
# preview with "<full title>, window", make it independent of the task-switcher
# focus object, and suppress the release-time cancellation/duplicate.
ALT_TAB_PREVIEW_WAIT_MS = 1600
ALT_TAB_SESSION_MAX_MS = 12000
ALT_TAB_TITLE_FOCUS_DELAY_MS = 50
ALT_TAB_RELEASE_POLL_MS = 25
ALT_TAB_TITLE_MIN_MS = 650
ALT_TAB_TITLE_MAX_MS = 3200
ALT_TAB_FOCUS_RETRY_MS = 80
ALT_TAB_FOCUS_MAX_ATTEMPTS = 12
ALT_TAB_POST_FOCUS_GUARD_MS = 600

# Newly opened windows and windows revealed because the previous foreground
# window closed use the same deterministic sequence as Alt+Tab:
# plain title -> fixed 50 ms gap -> current focused control.
# Native transition chatter is suppressed during the sequence and briefly
# after the custom focus report.
NEW_FOREGROUND_WATCH_MS = 900
NEW_FOREGROUND_FOCUS_RETRY_MS = 60
NEW_FOREGROUND_FOCUS_MAX_ATTEMPTS = 12
FOREGROUND_POST_FOCUS_GUARD_MS = 600

CLOSE_REVEAL_PROBE_DELAY_MS = 70
CLOSE_REVEAL_PROBE_RETRY_MS = 60
CLOSE_REVEAL_PROBE_MAX_ATTEMPTS = 10
WIN_M_DESKTOP_INITIAL_DELAY_MS = 90
WIN_M_DESKTOP_RETRY_MS = 60
WIN_M_DESKTOP_MAX_ATTEMPTS = 12
WIN_M_DESKTOP_QUIET_MS = 1200
VK_MENU = 0x12
CLOSE_CHAR = "\x01"

# Roles whose focusEntered announcement is dropped. Trim this to taste --
# removing Role.WINDOW keeps "<app> window" while still dropping the duplicate
# "<title> document" that follows it in a browser.
SILENCED_ROLES = {
    controlTypes.Role.DOCUMENT,
}

# Set True to log the ancestor chain of focused Start menu items. Only needed
# if the context-menu match stops working and the container has to be
# identified again.
DEBUG_START_CHAIN = False

HOST_APPS = ("searchhost", "startmenuexperiencehost")

# Classic desktop icon view: SysListView32 below Progman or WorkerW.
_DESKTOP_TOP_CLASSES = ("Progman", "WorkerW")

# Set True only while diagnosing desktop events. Suppressed-event messages are
# debug-level by default so startup reconciliation cannot flood the NVDA log.
DEBUG_DESKTOP_CHURN = False

# Ctrl+Space toggles and plain Space selections are reported explicitly after
# Explorer has updated the focused desktop item's state. Native desktop
# selection events remain suppressed because refreshes emit the same events.
DESKTOP_SELECTION_REPORT_RETRY_MS = 40
DESKTOP_SELECTION_REPORT_MAX_ATTEMPTS = 5

try:
    from controlTypes import Role
    LIST_ROLE = Role.LIST
    LISTITEM_ROLE = Role.LIST_ITEM if hasattr(Role, "LIST_ITEM") else Role.LISTITEM
except Exception:  # older NVDA
    LIST_ROLE = controlTypes.ROLE_LIST
    LISTITEM_ROLE = controlTypes.ROLE_LISTITEM

# Used to gate the UIA automation-id read. Neither container we look for is a
# leaf, and leaves are most of what NVDA constructs. A blacklist rather than a
# whitelist on purpose: guessing the exact role of StartFolderModal wrongly
# would silently break the folder fix, whereas an unexpected role here simply
# falls through to the checks below.
def _roleSet(*names):
    out = set()
    enum = getattr(controlTypes, "Role", None)
    if enum is None:
        return out
    for n in names:
        r = getattr(enum, n, None)
        if r is not None:
            out.add(r)
    return out


LEAF_ROLES = _roleSet(
    "LISTITEM", "LIST_ITEM", "MENUITEM", "MENU_ITEM", "BUTTON", "STATICTEXT",
    "STATIC_TEXT", "EDITABLETEXT", "EDIT", "LINK", "GRAPHIC", "IMAGE",
    "CHECKBOX", "CHECK_BOX", "RADIOBUTTON", "RADIO_BUTTON", "TREEVIEWITEM",
    "TREE_VIEW_ITEM", "TAB", "SEPARATOR", "TOGGLEBUTTON",
)

# These surfaces keep NVDA's native speech. Their roles and focus ancestry carry
# important modal/menu state that a plain title + focused-control sequence loses.
NATIVE_SPEECH_ROLES = _roleSet(
    "DIALOG", "ALERT", "MENU", "POPUPMENU", "POPUP_MENU",
    "MENUBAR", "MENU_BAR", "TOOLTIP", "TOOL_TIP",
)

NATIVE_SPEECH_CLASSES = {
    "#32768",                         # native popup menu
    "#32770",                         # native dialog / message box
    "combobox",                       # transient system combo popup
    "combolbox",
    "dv2controlhost",                 # classic shell flyout/menu host
    "foregroundstaging",             # Windows shell staging surface
    "multitaskingviewframe",          # Alt+Tab / Task View
    "notifyiconoverflowwindow",       # notification-area overflow
    "progman",
    "shell_dialog",
    "shell_secondarytraywnd",
    "shell_traywnd",
    "sysshadow",
    "taskswitcherwnd",
    "tooltips_class32",
    "windows.ui.composition.desktopwindowcontentbridge",
    "xamlexplorerhostislandwindow",
    "workerw",
}

NATIVE_SPEECH_APPS = {
    "lockapp",
    "searchhost",
    "shellexperiencehost",
    "startmenuexperiencehost",
    "textinputhost",
    "widgets",
    "widgetservice",
}

NATIVE_SPEECH_TITLES = {
    "desktop",
    "notification center",
    "program manager",
    "quick settings",
    "search",
    "start",
    "task switching",
    "task view",
}

# Only genuine UIA objects can carry a UIAAutomationId. The Start context menu
# is Chromium/IAccessible and never does, so this import turns the fetch off
# for it entirely.
try:
    from NVDAObjects.UIA import UIA
except Exception:
    UIA = None

# ---------------------------------------------------------------- 1. quiet

_quiet_until = 0.0          # time.monotonic() value; 0 = not quiet
_menu_announcement_serial = 0
_hide_announcement_serial = 0
_restore_final_announcement_serial = 0
_orig_speak = None
_orig_cancel_speech = None

# Protected MiniTray announcements. A new hide/restore command is appended here
# instead of cancelling the sentence already being spoken.
_minitray_announcement_queue = []
_minitray_announcement_active = False
_minitray_announcement_scheduled = False
_minitray_announcement_generation = 0
_minitray_current_announcement = None

# The off-screen AutoHotkey focus bridge is an implementation detail. This
# independent guard prevents its dialog/edit/blank ancestry from leaking even
# during a temporary MiniTray/plugin version mismatch.
_minitray_bridge_chatter_until = 0.0

# This state is independent of MiniTray. A new Alt+Tab gesture deliberately
# cancels the previously selected title; releasing Alt does not.
_alt_tab_preview_wait_until = 0.0
_alt_tab_session_until = 0.0
_alt_tab_title_guard_until = 0.0
_alt_tab_release_seen_at = 0.0
_alt_tab_focus_generation = 0
_alt_tab_focus_pending = False
_alt_tab_post_focus_until = 0.0
_alt_tab_post_focus_hwnd = 0

_win_m_desktop_generation = 0
_win_m_desktop_active = False

_close_result_generation = 0
_close_result_active = False
_close_result_synthetic_input_until = 0.0

_known_foreground_hwnds = set()
_last_foreground_hwnd = 0
_new_foreground_generation = 0
_new_foreground_watch = None
_foreground_post_focus_until = 0.0
_foreground_post_focus_hwnd = 0
_close_reveal_probe_generation = 0
_close_reveal_probe_state = None
_last_close_gesture_hwnd = 0
_last_close_gesture_at = 0.0
_saved_focus_objects = {}
_recovered_terminal_objects = {}
_recovered_generic_focus_objects = {}

# explorerNav's dead-frame redirect is useful only when the corresponding
# Explorer CabinetWClass is actually foreground. A delayed Explorer gainFocus
# event must never be allowed to pull focus away from whatever window Windows
# has since made foreground (dialog or otherwise).
_explorer_stale_focus_guard_module = None
_explorer_stale_focus_guard_class = None
_explorer_stale_focus_guard_original = None
_explorer_stale_focus_guard_wrapper = None

# Desktop-churn state. A serial is used instead of a time threshold: one
# name-only announcement is allowed for each real user gesture, while any
# number of automatic refresh events generated from the same idle period are
# discarded. A changed icon key is always allowed, preserving arrow navigation.
_desktop_input_serial = 0
_desktop_last_focus_key = None
_desktop_last_focus_input_serial = -1
_desktop_last_spoken_key = None
_desktop_last_spoken_input_serial = -1


def _first_string(sequence):
    """The first plain string in a speech sequence, or None.

    A sequence is a mix of strings and command objects, so the text is not
    reliably at index 0.
    """
    try:
        for item in sequence:
            if isinstance(item, str):
                return item
    except TypeError:
        pass
    return None


def _plain_strings(sequence):
    """Return non-empty plain strings from a mixed NVDA speech sequence."""
    try:
        return [item.strip() for item in sequence
                if isinstance(item, str) and item.strip()]
    except TypeError:
        return []


def _isDesktopIconView(obj):
    """True if obj is, or is inside, the classic desktop SysListView32."""
    try:
        node = obj
        list_obj = None
        for _ in range(5):
            if node is None:
                break
            if getattr(node, "windowClassName", "") == "SysListView32":
                list_obj = node
                break
            node = node.parent
        if list_obj is None:
            return False

        # Prefer the Win32 parent chain; it is stable even when Explorer
        # recreates NVDAObject wrappers during a desktop refresh.
        hwnd = getattr(list_obj, "windowHandle", 0) or 0
        for _ in range(8):
            if not hwnd:
                break
            if winUser.getClassName(hwnd) in _DESKTOP_TOP_CLASSES:
                return True
            parent = winUser.getAncestor(hwnd, winUser.GA_PARENT)
            if not parent or parent == hwnd:
                break
            hwnd = parent

        # Fallback for NVDA/Windows builds where the native parent walk is
        # incomplete but the accessibility parent chain is available.
        top = list_obj
        for _ in range(8):
            if top is None:
                return False
            if getattr(top, "windowClassName", "") in _DESKTOP_TOP_CLASSES:
                return True
            top = top.parent
    except Exception:
        pass
    return False


def _isDesktopListItem(obj):
    """True only for an individual icon in the classic desktop list."""
    if obj is None:
        return False
    try:
        if obj.role != LISTITEM_ROLE:
            return False
        # Desktop items themselves use the SysListView32 window handle. This
        # cheap gate avoids parent walking for ordinary speech elsewhere.
        if getattr(obj, "windowClassName", "") != "SysListView32":
            return False
    except Exception:
        return False
    return _isDesktopIconView(obj)


def _find_desktop_list_windows():
    """Return (desktop top-level hwnd, SysListView32 hwnd), or (0, 0)."""
    user32 = ctypes.windll.user32

    def list_from_top(top_hwnd):
        if not top_hwnd:
            return (0, 0)
        def_view = user32.FindWindowExW(
            int(top_hwnd),
            0,
            "SHELLDLL_DefView",
            None,
        )
        if not def_view:
            return (0, 0)
        list_hwnd = user32.FindWindowExW(
            int(def_view),
            0,
            "SysListView32",
            "FolderView",
        )
        if not list_hwnd:
            list_hwnd = user32.FindWindowExW(
                int(def_view),
                0,
                "SysListView32",
                None,
            )
        if list_hwnd:
            return (int(top_hwnd), int(list_hwnd))
        return (0, 0)

    progman = user32.FindWindowW("Progman", None)
    found = list_from_top(progman)
    if found[1]:
        return found

    result = [0, 0]
    callback_type = ctypes.WINFUNCTYPE(
        ctypes.c_bool,
        ctypes.c_void_p,
        ctypes.c_void_p,
    )

    @callback_type
    def enum_window(hwnd, lparam):
        try:
            class_name = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, class_name, len(class_name))
            if class_name.value != "WorkerW":
                return True
            top_hwnd, list_hwnd = list_from_top(hwnd)
            if list_hwnd:
                result[0] = top_hwnd
                result[1] = list_hwnd
                return False
        except Exception:
            return True
        return True

    user32.EnumWindows(enum_window, 0)
    return (int(result[0]), int(result[1]))


def _set_system_focus_to_desktop_list():
    """Move real Windows focus to the Explorer desktop icon view."""
    top_hwnd, list_hwnd = _find_desktop_list_windows()
    if not top_hwnd or not list_hwnd:
        return False

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    current_thread = int(kernel32.GetCurrentThreadId() or 0)
    target_thread = int(
        user32.GetWindowThreadProcessId(int(list_hwnd), None) or 0
    )
    foreground_hwnd = int(user32.GetForegroundWindow() or 0)
    foreground_thread = int(
        user32.GetWindowThreadProcessId(foreground_hwnd, None) or 0
    )

    attached = []
    try:
        for thread_id in {target_thread, foreground_thread}:
            if (
                thread_id
                and current_thread
                and thread_id != current_thread
                and user32.AttachThreadInput(
                    current_thread,
                    thread_id,
                    True,
                )
            ):
                attached.append(thread_id)

        user32.ShowWindow(int(top_hwnd), 5)
        user32.BringWindowToTop(int(top_hwnd))
        user32.SetForegroundWindow(int(top_hwnd))
        previous_focus = int(user32.SetFocus(int(list_hwnd)) or 0)
        return bool(
            previous_focus
            or int(user32.GetForegroundWindow() or 0) == int(top_hwnd)
        )
    finally:
        for thread_id in reversed(attached):
            try:
                user32.AttachThreadInput(
                    current_thread,
                    thread_id,
                    False,
                )
            except Exception:
                pass


def _desktop_focus_sequence():
    """Return the exact Win+M/Win+D desktop announcement."""
    obj = api.getFocusObject()
    if obj is None or not _isDesktopIconView(obj):
        return None

    if _isDesktopListItem(obj):
        try:
            icon_name = (obj.name or "").strip()
        except Exception:
            icon_name = ""
        if icon_name:
            return [f"desktop list: {icon_name}"]

    return ["desktop list"]


def _complete_win_m_desktop_focus(generation, attempt=0):
    global _win_m_desktop_active
    global _quiet_until

    if (
        generation != _win_m_desktop_generation
        or not _win_m_desktop_active
    ):
        return

    sequence = _desktop_focus_sequence()
    if sequence is None:
        _set_system_focus_to_desktop_list()
        if attempt < WIN_M_DESKTOP_MAX_ATTEMPTS:
            core.callLater(
                WIN_M_DESKTOP_RETRY_MS,
                _complete_win_m_desktop_focus,
                generation,
                attempt + 1,
            )
            return
        sequence = ["Desktop", "list"]

    _win_m_desktop_active = False
    _quiet_until = 0.0

    try:
        if _orig_cancel_speech is not None:
            _orig_cancel_speech()
    except Exception:
        log.debugWarning(
            "Unable to cancel taskbar speech before desktop shortcut report",
            exc_info=True,
        )

    try:
        _orig_speak(sequence)
        log.info(
            "Desktop shortcut focus corrected: attempt=%s items=%s",
            attempt,
            len(sequence),
        )
    except Exception:
        log.exception("Unable to speak desktop shortcut focus")


def _finish_silent_desktop_shortcut(generation):
    global _quiet_until

    if generation != _win_m_desktop_generation:
        return
    _quiet_until = 0.0
    log.info("Desktop shortcut started on desktop; speech remained silent")


def _start_silent_desktop_shortcut():
    global _win_m_desktop_generation
    global _win_m_desktop_active
    global _quiet_until

    _win_m_desktop_generation += 1
    generation = _win_m_desktop_generation
    _win_m_desktop_active = False
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + WIN_M_DESKTOP_QUIET_MS / 1000.0,
    )
    core.callLater(
        WIN_M_DESKTOP_QUIET_MS,
        _finish_silent_desktop_shortcut,
        generation,
    )


def _start_win_m_desktop_focus():
    global _win_m_desktop_generation
    global _win_m_desktop_active
    global _quiet_until

    _win_m_desktop_generation += 1
    generation = _win_m_desktop_generation
    _win_m_desktop_active = True
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + WIN_M_DESKTOP_QUIET_MS / 1000.0,
    )
    core.callLater(
        WIN_M_DESKTOP_INITIAL_DELAY_MS,
        _complete_win_m_desktop_focus,
        generation,
        0,
    )


def _desktopObjectKey(obj):
    """Stable identity for a desktop icon across recreated NVDAObject wrappers."""
    try:
        name = (obj.name or "").strip()
    except Exception:
        name = ""
    return (getattr(obj, "windowHandle", 0) or 0, name.casefold())


def _debugDesktop(message, *args):
    if DEBUG_DESKTOP_CHURN:
        log.info("conceptSphereQuiet desktop: " + message, *args)
    else:
        log.debug("conceptSphereQuiet desktop: " + message, *args)


def _desktopSelectionGestureKind(gesture):
    """Return "toggle" for Ctrl+Space, "select" for Space, or None."""
    try:
        identifiers = getattr(gesture, "identifiers", ()) or ()
        for identifier in identifiers:
            normalized = str(identifier).casefold().replace("ctrl", "control")
            key_part = normalized.rsplit(":", 1)[-1].replace(" ", "")
            key_parts = set(key_part.split("+"))
            if key_parts == {"control", "space"}:
                return "toggle"
            if key_parts == {"space"}:
                return "select"
    except Exception:
        pass

    # Fallback for keyboard gesture implementations that do not expose
    # identifiers in the usual NVDA form.
    try:
        key_name = (getattr(gesture, "mainKeyName", "") or "").casefold()
        modifiers = {
            str(item).casefold().replace("ctrl", "control")
            for item in (getattr(gesture, "modifierNames", ()) or ())
        }
        if key_name != "space":
            return None
        if modifiers == {"control"}:
            return "toggle"
        if not modifiers:
            return "select"
    except Exception:
        pass
    return None


def _desktopItemIsSelected(obj):
    """Return the selected state of a desktop icon."""
    try:
        selected_state = getattr(controlTypes.State, "SELECTED", None)
        if selected_state is not None:
            return selected_state in obj.states
    except Exception:
        pass
    try:
        return controlTypes.STATE_SELECTED in obj.states
    except Exception:
        return False


def _reportDesktopSelectionGesture(
    item_key,
    was_selected,
    gesture_kind,
    attempt=0,
):
    """Report the result of Ctrl+Space or plain Space on a desktop icon.

    Explorer's automatic desktop refresh emits the same selection/state events
    as genuine keyboard selection, so those native events stay suppressed.
    Ctrl+Space reports either selected state after the toggle. Plain Space waits
    for the focused icon to become selected and reports only "selected".
    """
    try:
        obj = api.getFocusObject()
        if not _isDesktopListItem(obj):
            return
        if _desktopObjectKey(obj) != item_key:
            return

        is_selected = _desktopItemIsSelected(obj)
        waiting_for_result = (
            is_selected == was_selected
            if gesture_kind == "toggle"
            else not is_selected
        )
        if (
            waiting_for_result
            and attempt < DESKTOP_SELECTION_REPORT_MAX_ATTEMPTS
        ):
            core.callLater(
                DESKTOP_SELECTION_REPORT_RETRY_MS,
                _reportDesktopSelectionGesture,
                item_key,
                was_selected,
                gesture_kind,
                attempt + 1,
            )
            return

        # Plain Space is a select action, not a toggle. Do not claim success if
        # Explorer did not actually select the icon within the retry window.
        if gesture_kind == "select" and not is_selected:
            _debugDesktop(
                "plain Space did not select desktop icon %r",
                getattr(obj, "name", None),
            )
            return

        name = (obj.name or "").strip()
        if not name:
            return
        state_text = "selected" if is_selected else "not selected"
        # The icon name was already spoken when focus arrived. Both Ctrl+Space
        # and plain Space therefore report only the resulting selection state.
        ui.message(state_text)
        _debugDesktop(
            "reported %s desktop selection for %r: %s",
            "Ctrl+Space" if gesture_kind == "toggle" else "Space",
            name,
            state_text,
        )
    except Exception:
        log.exception("conceptSphereQuiet desktop selection report failed")


def _shouldSuppressDesktopSpeech(sequence):
    """Drop unsolicited repeated name-only speech for the focused desktop icon.

    The startup log shows the repeated icon name reaches speech before the
    selection handler is entered, so suppressing event_selection alone cannot
    stop it. This is intentionally narrow: the focused object must be a classic
    desktop LISTITEM and the complete textual speech payload must be exactly its
    name. Role/state-rich reports and all non-desktop speech pass unchanged.
    """
    global _desktop_last_spoken_key, _desktop_last_spoken_input_serial

    try:
        obj = api.getFocusObject()
        if not _isDesktopListItem(obj):
            return False
        name = (obj.name or "").strip()
        strings = _plain_strings(sequence)
        if not name or strings != [name]:
            return False

        key = _desktopObjectKey(obj)
        if key != _desktop_last_spoken_key:
            _desktop_last_spoken_key = key
            _desktop_last_spoken_input_serial = _desktop_input_serial
            return False

        if _desktop_input_serial != _desktop_last_spoken_input_serial:
            # A real gesture may legitimately request the same icon again.
            _desktop_last_spoken_input_serial = _desktop_input_serial
            return False

        _debugDesktop("silenced repeated speech for %r", name)
        return True
    except Exception:
        log.exception("conceptSphereQuiet desktop speech guard failed")
        return False


def _parse_sentinel(text):
    """Milliseconds requested, or None if this is not a sentinel."""
    if not text:
        return None
    for prefix in OPEN_PREFIXES:
        if text.startswith(prefix):
            body = text[len(prefix):]
            break
    else:
        return None
    if body.endswith(CLOSE_CHAR):
        body = body[:-1]
    try:
        return max(0, min(int(body), MAX_QUIET_MS))
    except ValueError:
        return None


def _parse_safe_quiet(text):
    """Milliseconds requested by MTQUIETSAFE, or None.

    This sentinel replaces controller-level cancelSpeech. It may cancel
    ordinary NVDA speech, but never a protected MiniTray announcement that is
    active or waiting in the queue.
    """
    if not text or not text.startswith(SAFE_QUIET_PREFIX):
        return None
    body = text[len(SAFE_QUIET_PREFIX):]
    if body.endswith(CLOSE_CHAR):
        body = body[:-1]
    try:
        return max(0, min(int(body), MAX_QUIET_MS))
    except ValueError:
        return None


def _parse_final(text):
    """Privileged announcement payload, or None when this is not MTFINAL."""
    if not text or not text.startswith(FINAL_PREFIX):
        return None
    payload = text[len(FINAL_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    return payload


def _parse_menu(text):
    """Return (quiet-tail milliseconds, spoken text), or None.

    MTMENU is intentionally distinct from MTFINAL. A tray popup moves focus
    before its opening phrase is requested. Handling cancellation and the
    delayed phrase inside NVDA guarantees that the cancellation is processed
    before—not after—the phrase reaches a background-threaded synthesizer.
    """
    if not text or not text.startswith(MENU_PREFIX):
        return None
    payload = text[len(MENU_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        tail_text, spoken_text = payload.split(":", 1)
        tail_ms = max(0, min(int(tail_text), MAX_QUIET_MS))
        return tail_ms, spoken_text
    except (TypeError, ValueError):
        return None



def _parse_close_menu(text):
    if not text or not text.startswith(CLOSE_MENU_PREFIX):
        return None
    payload = text[len(CLOSE_MENU_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, spoken_text = payload.split(":", 1)
        return int(hwnd_text), spoken_text
    except (TypeError, ValueError):
        return None


def _parse_close_tray(text):
    if not text or not text.startswith(CLOSE_TRAY_PREFIX):
        return None
    payload = text[len(CLOSE_TRAY_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, remove_text, spoken_text = payload.split(":", 2)
        return int(hwnd_text), bool(int(remove_text)), spoken_text
    except (TypeError, ValueError):
        return None


def _plain_focus_sequence(obj):
    if obj is None:
        return []
    try:
        sequence = list(
            speech.getObjectSpeech(
                obj,
                reason=controlTypes.OutputReason.FOCUS,
            )
        )
    except Exception:
        log.debugWarning(
            "Unable to build MiniTray destination focus speech",
            exc_info=True,
        )
        return []
    return [
        item for item in sequence
        if not isinstance(item, CallbackCommand)
    ]


def _begin_close_result(spoken_text):
    global _close_result_generation
    global _close_result_active
    global _quiet_until

    # Clear menu-opening speech and all close-time focus chatter first.
    _cancel_minitray_speech_for_user_input("MiniTray close result")
    _close_result_generation += 1
    generation = _close_result_generation
    _close_result_active = True
    try:
        if _orig_cancel_speech is not None:
            _orig_cancel_speech()
    except Exception:
        log.debugWarning(
            "Unable to cancel speech before MiniTray close result",
            exc_info=True,
        )

    close_ms = _estimate_title_speech_ms(spoken_text)
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + (close_ms + 6000) / 1000.0,
    )
    _orig_speak([spoken_text])
    due_at = time.monotonic() + (
        close_ms + CLOSE_RESULT_FOCUS_GAP_MS
    ) / 1000.0
    return generation, due_at


def _complete_close_result(generation):
    global _close_result_active
    global _quiet_until
    if generation != _close_result_generation:
        return
    _close_result_active = False
    _quiet_until = 0.0


def _finish_close_result(generation, focus_sequence):
    global _quiet_until
    if generation != _close_result_generation or not _close_result_active:
        return
    if focus_sequence:
        _orig_speak(focus_sequence)
        focus_ms = _estimate_focus_speech_ms(focus_sequence)
    else:
        focus_ms = 300
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + (focus_ms + 250) / 1000.0,
    )
    core.callLater(focus_ms + 250, _complete_close_result, generation)


def _deliver_close_menu_focus(generation, popup_hwnd, due_at, attempt=0):
    if generation != _close_result_generation or not _close_result_active:
        return
    now = time.monotonic()
    if now < due_at:
        core.callLater(
            max(1, int((due_at - now) * 1000)),
            _deliver_close_menu_focus,
            generation,
            popup_hwnd,
            due_at,
            attempt,
        )
        return
    prepared, focus_sequence, source = _build_current_focus_sequence(popup_hwnd)
    if not prepared and attempt < CLOSE_RESULT_MAX_ATTEMPTS:
        core.callLater(
            CLOSE_RESULT_RETRY_MS,
            _deliver_close_menu_focus,
            generation,
            popup_hwnd,
            due_at,
            attempt + 1,
        )
        return
    log.info(
        "MiniTray close retained popup focus: hwnd=%s source=%s items=%s",
        popup_hwnd,
        source,
        len(focus_sequence),
    )
    _finish_close_result(generation, focus_sequence)


def _send_keyboard_gesture(name):
    global _close_result_synthetic_input_until
    try:
        _close_result_synthetic_input_until = time.monotonic() + 0.35
        keyboardHandler.KeyboardInputGesture.fromName(name).send()
        return True
    except Exception:
        log.debugWarning(
            "Unable to send keyboard gesture %s",
            name,
            exc_info=True,
        )
        return False


def _tray_focus_identity(obj):
    if obj is None:
        return ("", "", "")
    try:
        name = (obj.name or "").strip()
    except Exception:
        name = ""
    try:
        role = str(obj.role)
    except Exception:
        role = ""
    try:
        location = str(obj.location)
    except Exception:
        location = ""
    return (name.casefold(), role, location)


def _focus_is_minitray_icon(obj):
    try:
        return "minitray" in (obj.name or "").casefold()
    except Exception:
        return False


def _post_tray_icon_hide(mini_tray_hwnd):
    try:
        ctypes.windll.user32.PostMessageW(
            int(mini_tray_hwnd),
            TRAY_ICON_HIDE_MESSAGE,
            0,
            0,
        )
    except Exception:
        log.exception("Unable to post MiniTray tray-icon hide callback")


def _speak_tray_destination(
    generation,
    mini_tray_hwnd,
    remove_icon,
    due_at,
    prior_identity=None,
    attempt=0,
):
    if generation != _close_result_generation or not _close_result_active:
        return
    obj = api.getFocusObject()
    identity = _tray_focus_identity(obj)

    if remove_icon:
        if identity == prior_identity and attempt < CLOSE_RESULT_MAX_ATTEMPTS:
            core.callLater(
                TRAY_FOCUS_STEP_DELAY_MS,
                _speak_tray_destination,
                generation,
                mini_tray_hwnd,
                True,
                due_at,
                prior_identity,
                attempt + 1,
            )
            return
        _post_tray_icon_hide(mini_tray_hwnd)

    now = time.monotonic()
    if now < due_at:
        core.callLater(
            max(1, int((due_at - now) * 1000)),
            _speak_tray_destination,
            generation,
            mini_tray_hwnd,
            False,
            due_at,
            None,
            0,
        )
        return

    focus_sequence = _plain_focus_sequence(obj)
    log.info(
        "MiniTray close moved focus to tray destination: "
        "removeIcon=%s identity=%r items=%s",
        remove_icon,
        identity,
        len(focus_sequence),
    )
    _finish_close_result(generation, focus_sequence)


def _find_minitray_icon(
    generation,
    mini_tray_hwnd,
    remove_icon,
    due_at,
    seen,
    attempt=0,
):
    if generation != _close_result_generation or not _close_result_active:
        return

    obj = api.getFocusObject()
    identity = _tray_focus_identity(obj)
    if _focus_is_minitray_icon(obj):
        if remove_icon:
            if _send_keyboard_gesture("rightArrow"):
                core.callLater(
                    TRAY_FOCUS_STEP_DELAY_MS,
                    _speak_tray_destination,
                    generation,
                    mini_tray_hwnd,
                    True,
                    due_at,
                    identity,
                    0,
                )
                return
            _post_tray_icon_hide(mini_tray_hwnd)
        _speak_tray_destination(
            generation,
            mini_tray_hwnd,
            False,
            due_at,
        )
        return

    if attempt >= TRAY_FOCUS_MAX_STEPS:
        log.warning(
            "MiniTray tray-icon search exhausted: attempt=%s identity=%r",
            attempt,
            identity,
        )
        if remove_icon:
            _post_tray_icon_hide(mini_tray_hwnd)
        _speak_tray_destination(
            generation,
            mini_tray_hwnd,
            False,
            due_at,
        )
        return

    seen.add(identity)
    if not _send_keyboard_gesture("rightArrow"):
        if remove_icon:
            _post_tray_icon_hide(mini_tray_hwnd)
        _speak_tray_destination(
            generation,
            mini_tray_hwnd,
            False,
            due_at,
        )
        return
    core.callLater(
        TRAY_FOCUS_STEP_DELAY_MS,
        _find_minitray_icon,
        generation,
        mini_tray_hwnd,
        remove_icon,
        due_at,
        seen,
        attempt + 1,
    )


def _start_close_tray_focus(mini_tray_hwnd, remove_icon, spoken_text):
    generation, due_at = _begin_close_result(spoken_text)
    if not _send_keyboard_gesture("windows+b"):
        if remove_icon:
            _post_tray_icon_hide(mini_tray_hwnd)
        core.callLater(
            max(1, int((due_at - time.monotonic()) * 1000)),
            _speak_tray_destination,
            generation,
            mini_tray_hwnd,
            False,
            due_at,
        )
        return
    core.callLater(
        TRAY_FOCUS_INITIAL_DELAY_MS,
        _find_minitray_icon,
        generation,
        mini_tray_hwnd,
        remove_icon,
        due_at,
        set(),
        0,
    )


def _minitray_queue_busy():
    return bool(
        _minitray_announcement_active
        or _minitray_announcement_scheduled
        or _minitray_announcement_queue
    )


def _is_alt_tab_gesture(gesture):
    """True for Alt+Tab and Alt+Shift+Tab keyboard gestures."""
    try:
        identifiers = getattr(gesture, "identifiers", ()) or ()
        for identifier in identifiers:
            normalized = str(identifier).casefold().replace(" ", "")
            if normalized.endswith(":alt+tab"):
                return True
            if normalized.endswith(":alt+shift+tab"):
                return True
            if normalized.endswith(":shift+alt+tab"):
                return True
    except Exception:
        pass

    try:
        key_name = (getattr(gesture, "mainKeyName", "") or "").casefold()
        modifiers = {
            str(item).casefold()
            for item in (getattr(gesture, "modifierNames", ()) or ())
        }
        return key_name == "tab" and "alt" in modifiers
    except Exception:
        return False


def _alt_tab_title_from_preview(sequence):
    """Extract the full window title from native task-switcher speech."""
    for text in _plain_strings(sequence):
        normalized = text.casefold().strip()
        if not normalized:
            continue
        if normalized == "row" or normalized.startswith("row "):
            continue
        if normalized == "column" or normalized.startswith("column "):
            continue
        if normalized in {"window", "application"}:
            continue
        return text.strip()
    return ""


def _estimate_title_speech_ms(text):
    """Estimate title completion without the queue's old 1.8 second floor."""
    text = (text or "").strip()
    if not text:
        return RESTORE_TITLE_MIN_MS
    words = len(text.split())
    punctuation = sum(text.count(ch) for ch in ".,;:!?-_")
    estimate = max(words * 185, len(text) * 22)
    estimate += punctuation * 60 + 120
    return max(RESTORE_TITLE_MIN_MS, min(estimate, RESTORE_TITLE_MAX_MS))


def _estimate_focus_speech_ms(sequence):
    text = " ".join(_plain_strings(sequence))
    if not text:
        return RESTORE_FOCUS_MIN_MS
    words = len(text.split())
    punctuation = sum(text.count(ch) for ch in ".,;:!?-_")
    estimate = max(words * 185, len(text) * 24)
    estimate += punctuation * 60 + 150
    return max(RESTORE_FOCUS_MIN_MS, min(estimate, RESTORE_FOCUS_MAX_MS))


def _alt_key_is_down():
    try:
        return bool(ctypes.windll.user32.GetAsyncKeyState(VK_MENU) & 0x8000)
    except Exception:
        return False


def _clear_alt_tab_state():
    global _alt_tab_preview_wait_until
    global _alt_tab_session_until
    global _alt_tab_title_guard_until
    global _alt_tab_release_seen_at
    global _alt_tab_focus_generation
    global _alt_tab_focus_pending
    global _alt_tab_post_focus_until
    global _alt_tab_post_focus_hwnd

    _alt_tab_preview_wait_until = 0.0
    _alt_tab_session_until = 0.0
    _alt_tab_title_guard_until = 0.0
    _alt_tab_release_seen_at = 0.0
    _alt_tab_focus_pending = False
    _alt_tab_post_focus_until = 0.0
    _alt_tab_post_focus_hwnd = 0
    _alt_tab_focus_generation += 1


def _build_current_focus_sequence(target_hwnd):
    """Return the current focused control/line without repeating the title."""
    try:
        obj = _get_fresh_operating_system_focus()
    except Exception:
        obj = None
    if obj is None or not _focus_belongs_to_window(obj, target_hwnd):
        return False, [], "unavailable"

    if _generic_focus_is_container_only(obj):
        return False, [], "container"

    if _is_terminal_object(obj) or _appName(obj) == "msedge":
        try:
            line_text, _text_obj, _position = _line_text_from_object(obj)
        except Exception:
            line_text = ""
        if line_text:
            return True, [line_text], "current line"

    try:
        sequence = list(
            speech.getObjectSpeech(
                obj,
                reason=controlTypes.OutputReason.FOCUS,
            )
        )
        sequence = [
            item for item in sequence
            if not isinstance(item, CallbackCommand)
        ]
    except Exception:
        log.debugWarning(
            "Could not build focused-control speech sequence",
            exc_info=True,
        )
        sequence = []

    return bool(sequence), sequence, _focus_object_summary(obj)


def _speak_alt_tab_focus(generation, attempt=0):
    global _alt_tab_preview_wait_until
    global _alt_tab_session_until
    global _alt_tab_title_guard_until
    global _alt_tab_focus_pending
    global _alt_tab_post_focus_until
    global _alt_tab_post_focus_hwnd

    if generation != _alt_tab_focus_generation:
        return

    target_hwnd = int(winUser.getForegroundWindow() or 0)
    prepared, focus_sequence, source = _build_current_focus_sequence(target_hwnd)
    if not prepared and attempt < ALT_TAB_FOCUS_MAX_ATTEMPTS:
        core.callLater(
            ALT_TAB_FOCUS_RETRY_MS,
            _speak_alt_tab_focus,
            generation,
            attempt + 1,
        )
        return

    _alt_tab_preview_wait_until = 0.0
    _alt_tab_session_until = 0.0
    _alt_tab_title_guard_until = 0.0
    _alt_tab_focus_pending = False
    _alt_tab_post_focus_hwnd = target_hwnd
    _alt_tab_post_focus_until = (
        time.monotonic() + ALT_TAB_POST_FOCUS_GUARD_MS / 1000.0
    )

    if focus_sequence:
        try:
            _orig_speak(focus_sequence)
            log.info(
                "Spoke Alt+Tab focused control; armed late-event guard: "
                "hwnd=%s source=%s items=%s guardMs=%s",
                target_hwnd,
                source,
                len(focus_sequence),
                ALT_TAB_POST_FOCUS_GUARD_MS,
            )
        except Exception:
            log.exception("Unable to speak Alt+Tab focused control")


def _poll_alt_release_for_focus(generation):
    """Run the complete post-title timer before deciding when focus speaks.

    Sequence:
      * Let the selected window title finish.
      * Run the full 50 ms post-title timer.
      * At timer expiry:
          - if Alt has already been released, speak focus;
          - if Alt is still held, remain silent until release, then speak focus
            immediately.
    """
    global _alt_tab_release_seen_at
    global _alt_tab_focus_pending

    if generation != _alt_tab_focus_generation or not _alt_tab_focus_pending:
        return

    now = time.monotonic()
    title_end = _alt_tab_title_guard_until
    timer_end = title_end + ALT_TAB_TITLE_FOCUS_DELAY_MS / 1000.0

    if not _alt_key_is_down() and not _alt_tab_release_seen_at:
        _alt_tab_release_seen_at = now
        log.info(
            "Observed Alt release during Alt+Tab title/timer sequence: "
            "beforeTimerExpiry=%s",
            now < timer_end,
        )

    # The title and the complete 50 ms timer always finish before focus can
    # speak, regardless of when Alt was released.
    if now < timer_end:
        core.callLater(
            min(
                ALT_TAB_RELEASE_POLL_MS,
                max(1, int((timer_end - now) * 1000)),
            ),
            _poll_alt_release_for_focus,
            generation,
        )
        return

    if not _alt_key_is_down():
        log.info(
            "Speaking Alt+Tab focus after full post-title timer: delayMs=%s",
            ALT_TAB_TITLE_FOCUS_DELAY_MS,
        )
        _speak_alt_tab_focus(generation, 0)
        return

    # The timer has expired while Alt remains held. Stay silent and speak the
    # focus on the first poll after Alt is released.
    core.callLater(
        ALT_TAB_RELEASE_POLL_MS,
        _poll_alt_release_for_focus,
        generation,
    )


def _release_minitray_speech_for_alt_tab():
    """Explicit user navigation takes priority over queued MiniTray results."""
    _cancel_minitray_speech_for_user_input("Alt+Tab")


def _handle_alt_tab_speech(sequence, args, kwargs):
    """Speak the selected title, then its focus after Alt is released."""
    global _alt_tab_preview_wait_until
    global _alt_tab_session_until
    global _alt_tab_title_guard_until
    global _alt_tab_release_seen_at
    global _alt_tab_focus_pending
    global _alt_tab_post_focus_until
    global _alt_tab_post_focus_hwnd
    global _quiet_until

    now = time.monotonic()

    if _alt_tab_post_focus_until:
        current_hwnd = int(winUser.getForegroundWindow() or 0)
        if (
            now < _alt_tab_post_focus_until
            and current_hwnd == _alt_tab_post_focus_hwnd
        ):
            log.info(
                "Suppressed late native Alt+Tab speech after custom focus: "
                "hwnd=%s speech=%r",
                current_hwnd,
                _plain_strings(sequence),
            )
            return True, None

        _alt_tab_post_focus_until = 0.0
        _alt_tab_post_focus_hwnd = 0

    if _alt_tab_session_until and now >= _alt_tab_session_until:
        _clear_alt_tab_state()
        return False, None

    if _alt_tab_preview_wait_until:
        if now >= _alt_tab_preview_wait_until:
            _alt_tab_preview_wait_until = 0.0
        else:
            title = _alt_tab_title_from_preview(sequence)
            if title:
                native_reason = _title_requires_native_speech(title)
                if native_reason:
                    log.info(
                        "Preserved native Alt+Tab speech: title=%r reason=%s",
                        title,
                        native_reason,
                    )
                    _clear_alt_tab_state()
                    return False, None

                _alt_tab_preview_wait_until = 0.0
                _quiet_until = 0.0
                title_ms = _estimate_title_speech_ms(title)
                _alt_tab_title_guard_until = now + title_ms / 1000.0
                _alt_tab_release_seen_at = 0.0
                _alt_tab_focus_pending = True
                generation = _alt_tab_focus_generation
                core.callLater(
                    ALT_TAB_RELEASE_POLL_MS,
                    _poll_alt_release_for_focus,
                    generation,
                )
                log.info(
                    "Speaking uninterrupted Alt+Tab title with fixed timer: "
                    "titleMs=%s timerMs=%s title=%r",
                    title_ms,
                    ALT_TAB_TITLE_FOCUS_DELAY_MS,
                    title,
                )
                return True, _orig_speak([title], *args, **kwargs)

    if _alt_tab_focus_pending:
        current_hwnd = int(winUser.getForegroundWindow() or 0)
        try:
            focus_obj = api.getFocusObject()
        except Exception:
            focus_obj = None
        native_reason = _window_requires_native_speech(
            current_hwnd,
            focus_obj,
        )
        if native_reason:
            log.info(
                "Released Alt+Tab target to native speech after foreground: "
                "hwnd=%s reason=%s",
                current_hwnd,
                native_reason,
            )
            _clear_alt_tab_state()
            return False, None

        # Drop the release-time duplicate title and focus burst. The focused
        # control is reported once by _speak_alt_tab_focus after a real pause.
        log.info(
            "Suppressed native Alt+Tab release speech before custom focus: %r",
            _plain_strings(sequence),
        )
        return True, None

    return False, None


def _cancel_speech(*args, **kwargs):
    """Protect synthesized title/focus sequences from transition cancellation."""
    global _alt_tab_post_focus_until
    global _alt_tab_post_focus_hwnd
    global _foreground_post_focus_until
    global _foreground_post_focus_hwnd

    probe = _close_reveal_probe_state
    if probe is not None:
        try:
            foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        except Exception:
            foreground_hwnd = 0
        if foreground_hwnd == probe.get("target_hwnd", 0):
            log.info(
                "Buffered native cancellation during tentative close reveal: "
                "previousHwnd=%s targetHwnd=%s",
                probe.get("previous_hwnd", 0),
                probe.get("target_hwnd", 0),
            )
            return

    watch = _new_foreground_watch
    if (
        watch is not None
        and watch.get("title_spoken")
        and time.monotonic() < watch.get("release_at", 0.0)
    ):
        log.info(
            "Blocked speech cancellation during new foreground title/focus sequence"
        )
        return

    if _alt_tab_focus_pending:
        log.info("Blocked speech cancellation during Alt+Tab title/focus sequence")
        return

    if (
        _foreground_post_focus_until
        and time.monotonic() < _foreground_post_focus_until
        and int(winUser.getForegroundWindow() or 0)
            == _foreground_post_focus_hwnd
    ):
        log.info(
            "Blocked late native cancellation after deterministic foreground focus"
        )
        return

    if (
        _alt_tab_post_focus_until
        and time.monotonic() < _alt_tab_post_focus_until
        and int(winUser.getForegroundWindow() or 0) == _alt_tab_post_focus_hwnd
    ):
        log.info("Blocked late native cancellation after Alt+Tab custom focus")
        return

    return _orig_cancel_speech(*args, **kwargs)


def _window_text(hwnd):
    """Return a top-level Win32 title without relying on one NVDA backend."""
    if not hwnd:
        return ""
    try:
        length = int(ctypes.windll.user32.GetWindowTextLengthW(hwnd))
        if length <= 0:
            return ""
        buffer = ctypes.create_unicode_buffer(length + 1)
        ctypes.windll.user32.GetWindowTextW(hwnd, buffer, length + 1)
        return buffer.value.strip()
    except Exception:
        return ""


def _window_exists(hwnd):
    if not hwnd:
        return False
    try:
        return bool(ctypes.windll.user32.IsWindow(int(hwnd)))
    except Exception:
        return False


def _window_is_visible(hwnd):
    if not hwnd:
        return False
    try:
        return bool(ctypes.windll.user32.IsWindowVisible(int(hwnd)))
    except Exception:
        return False


def _window_is_minimized(hwnd):
    if not hwnd:
        return False
    try:
        return bool(ctypes.windll.user32.IsIconic(int(hwnd)))
    except Exception:
        return False


def _window_class_name(hwnd):
    if not hwnd:
        return ""
    try:
        return (winUser.getClassName(int(hwnd)) or "").strip().casefold()
    except Exception:
        try:
            buffer = ctypes.create_unicode_buffer(256)
            ctypes.windll.user32.GetClassNameW(
                int(hwnd),
                buffer,
                len(buffer),
            )
            return buffer.value.strip().casefold()
        except Exception:
            return ""


def _window_process_name(hwnd):
    """Return a lowercase executable stem for a top-level HWND."""
    if not hwnd:
        return ""

    pid = ctypes.c_ulong(0)
    try:
        ctypes.windll.user32.GetWindowThreadProcessId(
            int(hwnd),
            ctypes.byref(pid),
        )
    except Exception:
        return ""
    if not pid.value:
        return ""

    process_query_limited_information = 0x1000
    handle = None
    try:
        open_process = ctypes.windll.kernel32.OpenProcess
        open_process.restype = ctypes.c_void_p
        handle = open_process(
            process_query_limited_information,
            False,
            int(pid.value),
        )
        if not handle:
            return ""

        buffer = ctypes.create_unicode_buffer(32768)
        size = ctypes.c_ulong(len(buffer))
        if not ctypes.windll.kernel32.QueryFullProcessImageNameW(
            ctypes.c_void_p(handle),
            0,
            buffer,
            ctypes.byref(size),
        ):
            return ""
        return os.path.splitext(os.path.basename(buffer.value))[0].casefold()
    except Exception:
        return ""
    finally:
        if handle:
            try:
                ctypes.windll.kernel32.CloseHandle(ctypes.c_void_p(handle))
            except Exception:
                pass


def _window_owner(hwnd):
    if not hwnd:
        return 0
    try:
        get_window = ctypes.windll.user32.GetWindow
        get_window.restype = ctypes.c_void_p
        return int(get_window(int(hwnd), 4) or 0)  # GW_OWNER
    except Exception:
        return 0


def _window_ex_style(hwnd):
    if not hwnd:
        return 0
    try:
        user32 = ctypes.windll.user32
        function = getattr(
            user32,
            "GetWindowLongPtrW",
            user32.GetWindowLongW,
        )
        function.restype = ctypes.c_ssize_t
        return int(function(int(hwnd), -20) or 0)  # GWL_EXSTYLE
    except Exception:
        return 0


def _visible_active_popup(hwnd):
    """Return an active visible owned popup, or zero."""
    if not hwnd:
        return 0
    try:
        get_popup = ctypes.windll.user32.GetLastActivePopup
        get_popup.restype = ctypes.c_void_p
        popup = int(get_popup(int(hwnd)) or 0)
        if (
            popup
            and popup != int(hwnd)
            and ctypes.windll.user32.IsWindowVisible(popup)
        ):
            return popup
    except Exception:
        pass
    return 0


def _object_has_native_speech_role(obj):
    node = obj
    for _ in range(12):
        if node is None:
            break
        try:
            if node.role in NATIVE_SPEECH_ROLES:
                return True
        except Exception:
            pass
        try:
            node = node.parent
        except Exception:
            break
    return False


def _window_requires_native_speech(hwnd, obj=None):
    """Return an exclusion reason, or an empty string for ordinary app windows."""
    hwnd = int(hwnd or 0)
    if not hwnd:
        return ""

    class_name = _window_class_name(hwnd)
    if class_name in NATIVE_SPEECH_CLASSES:
        return "special window class " + class_name

    app_name = ""
    if obj is not None:
        try:
            app_name = _appName(obj)
        except Exception:
            app_name = ""
    if not app_name:
        app_name = _window_process_name(hwnd)
    if app_name in NATIVE_SPEECH_APPS:
        return "special shell application " + app_name

    if obj is not None and _object_has_native_speech_role(obj):
        return "dialog, alert, menu, or tooltip role"

    # Owned and non-taskbar tool windows are dialogs, palettes, popups, or other
    # secondary surfaces. Their native announcement includes state that the
    # deterministic sequence deliberately omits.
    ws_ex_toolwindow = 0x00000080
    ws_ex_appwindow = 0x00040000
    ex_style = _window_ex_style(hwnd)
    if (
        ex_style & ws_ex_toolwindow
        and not ex_style & ws_ex_appwindow
    ):
        return "tool or popup window"
    if _window_owner(hwnd) and not ex_style & ws_ex_appwindow:
        return "owned dialog or secondary window"

    try:
        if not ctypes.windll.user32.IsWindowEnabled(hwnd):
            return "owner disabled by active dialog"
    except Exception:
        pass

    popup = _visible_active_popup(hwnd)
    if popup:
        return "application has active dialog or popup"

    return ""


def _title_requires_native_speech(title):
    """Match an Alt+Tab preview title to a currently open special window."""
    normalized = (title or "").strip().casefold()
    if not normalized:
        return ""
    if normalized in NATIVE_SPEECH_TITLES:
        return "special shell title " + normalized

    result = [""]
    callback_type = ctypes.WINFUNCTYPE(
        ctypes.c_bool,
        ctypes.c_void_p,
        ctypes.c_void_p,
    )

    @callback_type
    def enum_window(hwnd, lparam):
        try:
            hwnd = int(hwnd or 0)
            if not hwnd or not ctypes.windll.user32.IsWindowVisible(hwnd):
                return True
            if _window_text(hwnd).strip().casefold() != normalized:
                return True
            reason = _window_requires_native_speech(hwnd)
            if reason:
                result[0] = reason
                return False
        except Exception:
            return True
        return True

    try:
        ctypes.windll.user32.EnumWindows(enum_window, 0)
    except Exception:
        return ""
    return result[0]


def _clear_foreground_post_focus_guard():
    global _foreground_post_focus_until
    global _foreground_post_focus_hwnd

    _foreground_post_focus_until = 0.0
    _foreground_post_focus_hwnd = 0


def _handle_foreground_post_focus_speech(sequence):
    """Suppress late native speech after a custom foreground focus report."""
    global _foreground_post_focus_until
    global _foreground_post_focus_hwnd

    if not _foreground_post_focus_until:
        return False

    now = time.monotonic()
    current_hwnd = int(winUser.getForegroundWindow() or 0)
    if (
        now < _foreground_post_focus_until
        and current_hwnd == _foreground_post_focus_hwnd
    ):
        log.info(
            "Suppressed late native foreground speech after custom focus: "
            "hwnd=%s speech=%r",
            current_hwnd,
            _plain_strings(sequence),
        )
        return True

    _clear_foreground_post_focus_guard()
    return False


def _foreground_title_from_object(obj, hwnd):
    candidates = []
    for attribute in ("name", "windowText"):
        try:
            value = getattr(obj, attribute, "") or ""
        except Exception:
            value = ""
        if value:
            candidates.append(str(value).strip())

    win32_title = _window_text(hwnd)
    if win32_title:
        candidates.append(win32_title)

    rejected = {
        "",
        "desktop",
        "program manager",
        "minitray",
        "minitray focus bridge",
    }
    for candidate in candidates:
        normalized = candidate.casefold().strip()
        if normalized in rejected:
            continue
        return candidate
    return ""


def _sequence_without_callbacks(sequence):
    return [
        item
        for item in sequence
        if not isinstance(item, CallbackCommand)
    ]


def _sequence_mentions_title(sequence, title):
    normalized_title = title.casefold().strip()
    if not normalized_title:
        return False
    joined = " ".join(_plain_strings(sequence)).casefold().strip()
    return bool(joined) and (
        normalized_title in joined
        or joined in normalized_title
    )


def _clear_new_foreground_watch():
    global _new_foreground_generation
    global _new_foreground_watch

    _new_foreground_generation += 1
    _new_foreground_watch = None


def _deliver_new_foreground_followup(generation, attempt=0):
    global _new_foreground_watch
    global _foreground_post_focus_until
    global _foreground_post_focus_hwnd

    watch = _new_foreground_watch
    if (
        watch is None
        or generation != watch["generation"]
        or generation != _new_foreground_generation
    ):
        return

    now = time.monotonic()
    if now < watch["release_at"]:
        core.callLater(
            max(1, int((watch["release_at"] - now) * 1000)),
            _deliver_new_foreground_followup,
            generation,
            attempt,
        )
        return

    target_hwnd = watch["hwnd"]
    if int(winUser.getForegroundWindow() or 0) != target_hwnd:
        _clear_new_foreground_watch()
        return

    try:
        focus_obj = api.getFocusObject()
    except Exception:
        focus_obj = None
    native_reason = _window_requires_native_speech(
        target_hwnd,
        focus_obj,
    )
    if native_reason:
        _clear_new_foreground_watch()
        _clear_foreground_post_focus_guard()
        log.info(
            "Cancelled delayed custom focus for native special window: "
            "hwnd=%s reason=%s",
            target_hwnd,
            native_reason,
        )
        return

    prepared, followup, source = _build_current_focus_sequence(target_hwnd)
    if not prepared and attempt < NEW_FOREGROUND_FOCUS_MAX_ATTEMPTS:
        core.callLater(
            NEW_FOREGROUND_FOCUS_RETRY_MS,
            _deliver_new_foreground_followup,
            generation,
            attempt + 1,
        )
        return

    reason = watch.get("reason", "foreground transition")
    _clear_new_foreground_watch()
    _foreground_post_focus_hwnd = target_hwnd
    _foreground_post_focus_until = (
        time.monotonic() + FOREGROUND_POST_FOCUS_GUARD_MS / 1000.0
    )

    if followup:
        try:
            _orig_speak(followup)
            log.info(
                "Spoke foreground focus after title: reason=%s hwnd=%s "
                "source=%s items=%s guardMs=%s",
                reason,
                target_hwnd,
                source,
                len(followup),
                FOREGROUND_POST_FOCUS_GUARD_MS,
            )
        except Exception:
            log.exception("Unable to speak foreground focus after title")


def _start_new_foreground_title(watch):
    """Speak a plain title and arm the fixed-gap current-focus follow-up."""
    global _new_foreground_watch
    global _quiet_until

    if _new_foreground_watch is not watch:
        return None

    title = watch["title"]
    now = time.monotonic()
    title_ms = _estimate_title_speech_ms(title)
    watch["title_spoken"] = True
    watch["release_at"] = (
        now + (title_ms + ALT_TAB_TITLE_FOCUS_DELAY_MS) / 1000.0
    )
    _quiet_until = 0.0

    core.callLater(
        title_ms + ALT_TAB_TITLE_FOCUS_DELAY_MS,
        _deliver_new_foreground_followup,
        watch["generation"],
        0,
    )

    log.info(
        "Speaking deterministic foreground title: reason=%s hwnd=%s "
        "titleMs=%s delayMs=%s title=%r",
        watch.get("reason", "foreground transition"),
        watch["hwnd"],
        title_ms,
        ALT_TAB_TITLE_FOCUS_DELAY_MS,
        title,
    )
    return _orig_speak([title])


def _replay_close_reveal_buffer(probe, reason):
    buffered = list(probe.get("buffer", [])) if probe else []
    if not buffered:
        return
    log.info(
        "Replaying buffered native foreground speech: reason=%s items=%s "
        "previousHwnd=%s targetHwnd=%s",
        reason,
        len(buffered),
        probe.get("previous_hwnd", 0),
        probe.get("target_hwnd", 0),
    )
    for sequence, args, kwargs in buffered:
        try:
            _orig_speak(sequence, *args, **kwargs)
        except Exception:
            log.exception("Unable to replay buffered native foreground speech")


def _cancel_close_reveal_probe(replay=False, reason="cancelled"):
    global _close_reveal_probe_generation
    global _close_reveal_probe_state

    old_probe = _close_reveal_probe_state
    _close_reveal_probe_generation += 1
    _close_reveal_probe_state = None
    if replay and old_probe is not None:
        _replay_close_reveal_buffer(old_probe, reason)


def _handle_close_reveal_probe_speech(sequence, args, kwargs):
    """Hold native focus speech until we know whether the previous HWND closed."""
    probe = _close_reveal_probe_state
    if probe is None:
        return False, None

    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
    except Exception:
        foreground_hwnd = 0
    if foreground_hwnd != probe.get("target_hwnd", 0):
        _cancel_close_reveal_probe(False, "foreground changed again")
        return False, None

    try:
        saved_sequence = list(sequence)
    except Exception:
        saved_sequence = sequence

    probe["buffer"].append((saved_sequence, tuple(args), dict(kwargs)))
    if len(probe["buffer"]) > 20:
        probe["buffer"] = probe["buffer"][-20:]

    log.info(
        "Buffered native speech during tentative close reveal: "
        "previousHwnd=%s targetHwnd=%s speech=%r",
        probe.get("previous_hwnd", 0),
        probe.get("target_hwnd", 0),
        _text_items(sequence),
    )
    return True, None


def _probe_close_reveal(
    generation,
    previous_hwnd,
    target_hwnd,
    attempt=0,
):
    global _close_reveal_probe_state

    if generation != _close_reveal_probe_generation:
        return

    probe = _close_reveal_probe_state
    if probe is None or probe.get("generation") != generation:
        return

    if int(winUser.getForegroundWindow() or 0) != int(target_hwnd):
        _cancel_close_reveal_probe(False, "foreground moved before classification")
        return

    if not _window_exists(previous_hwnd):
        _close_reveal_probe_state = None

        try:
            obj = api.getForegroundObject()
        except Exception:
            obj = None
        if obj is None:
            try:
                obj = _get_fresh_operating_system_focus()
            except Exception:
                obj = None

        native_reason = _window_requires_native_speech(target_hwnd, obj)
        if native_reason:
            _watch_new_foreground_window(
                obj,
                target_hwnd,
                "revealed after previous window closed",
            )
            _replay_close_reveal_buffer(
                probe,
                "confirmed close revealed native/special window",
            )
            return

        try:
            if _orig_cancel_speech is not None:
                _orig_cancel_speech()
        except Exception:
            log.debugWarning(
                "Unable to cancel native speech before close-reveal sequence",
                exc_info=True,
            )

        log.info(
            "Confirmed deferred close reveal; discarded buffered chatter: "
            "previousHwnd=%s targetHwnd=%s attempt=%s buffered=%s",
            previous_hwnd,
            target_hwnd,
            attempt,
            len(probe.get("buffer", [])),
        )
        _watch_new_foreground_window(
            obj,
            target_hwnd,
            "revealed after previous window closed",
        )
        return

    # Ordinary foreground changes should not wait for the full close timeout.
    if (
        attempt == 0
        and not probe.get("close_expected")
        and (
            _window_is_visible(previous_hwnd)
            or _window_is_minimized(previous_hwnd)
        )
    ):
        _cancel_close_reveal_probe(True, "ordinary foreground switch")
        return

    if attempt >= CLOSE_REVEAL_PROBE_MAX_ATTEMPTS:
        _cancel_close_reveal_probe(
            True,
            "close probe expired with previous window still alive",
        )
        log.debug(
            "Close-reveal probe expired with previous window still alive: "
            "previousHwnd=%s targetHwnd=%s",
            previous_hwnd,
            target_hwnd,
        )
        return

    core.callLater(
        CLOSE_REVEAL_PROBE_RETRY_MS,
        _probe_close_reveal,
        generation,
        previous_hwnd,
        target_hwnd,
        attempt + 1,
    )


def _schedule_close_reveal_probe(previous_hwnd, target_hwnd):
    global _close_reveal_probe_generation
    global _close_reveal_probe_state

    now = time.monotonic()
    close_expected = bool(
        previous_hwnd
        and previous_hwnd == _last_close_gesture_hwnd
        and now - _last_close_gesture_at <= 1.5
    )
    if (
        previous_hwnd
        and not _window_is_visible(previous_hwnd)
        and not _window_is_minimized(previous_hwnd)
    ):
        close_expected = True

    _close_reveal_probe_generation += 1
    generation = _close_reveal_probe_generation
    _close_reveal_probe_state = {
        "generation": generation,
        "previous_hwnd": int(previous_hwnd or 0),
        "target_hwnd": int(target_hwnd or 0),
        "close_expected": close_expected,
        "buffer": [],
        "started_at": now,
    }

    core.callLater(
        CLOSE_REVEAL_PROBE_DELAY_MS,
        _probe_close_reveal,
        generation,
        previous_hwnd,
        target_hwnd,
        0,
    )



def _watch_new_foreground_window(obj, hwnd, reason):
    global _new_foreground_generation
    global _new_foreground_watch

    if not hwnd:
        return

    # Alt+Tab, MiniTray restore/close, and explicit quiet transactions already
    # own their speech. Do not layer a second title/focus sequence over them.
    if (
        _alt_tab_focus_pending
        or _alt_tab_session_until
        or _minitray_queue_busy()
        or _close_result_active
        or _win_m_desktop_active
        or (_quiet_until and time.monotonic() < _quiet_until)
    ):
        return

    native_reason = _window_requires_native_speech(hwnd, obj)
    if native_reason:
        # Native/special surfaces are a hard boundary: conceptSphereQuiet
        # clears any deterministic window sequence and then gets completely
        # out of NVDA's way. No custom focus repair or speech replacement.
        _clear_new_foreground_watch()
        _clear_foreground_post_focus_guard()
        log.info(
            "Preserved fully native foreground behavior: hwnd=%s reason=%s",
            hwnd,
            native_reason,
        )
        return

    title = _foreground_title_from_object(obj, hwnd)
    if not title:
        return

    # Win+B temporarily makes the taskbar foreground before Explorer places
    # focus on a notification icon. Leave that native focus transition alone.
    if title.casefold() == "taskbar":
        log.info(
            "Skipped deterministic foreground sequence for taskbar: hwnd=%s",
            hwnd,
        )
        return

    _clear_new_foreground_watch()
    _clear_foreground_post_focus_guard()

    _new_foreground_generation += 1
    generation = _new_foreground_generation
    _new_foreground_watch = {
        "generation": generation,
        "hwnd": hwnd,
        "title": title,
        "reason": reason,
        "deadline": time.monotonic() + NEW_FOREGROUND_WATCH_MS / 1000.0,
        "title_spoken": False,
        "release_at": 0.0,
    }

    log.info(
        "Starting deterministic foreground sequence: reason=%s hwnd=%s title=%r",
        reason,
        hwnd,
        title,
    )
    _start_new_foreground_title(_new_foreground_watch)


def _handle_new_foreground_speech(sequence, args, kwargs):
    """Suppress native speech while a deterministic transition is active."""
    watch = _new_foreground_watch
    if watch is None:
        return False, None

    now = time.monotonic()
    if now >= watch["deadline"]:
        _clear_new_foreground_watch()
        return False, None

    if int(winUser.getForegroundWindow() or 0) != watch["hwnd"]:
        _clear_new_foreground_watch()
        return False, None

    try:
        focus_obj = api.getFocusObject()
    except Exception:
        focus_obj = None
    native_reason = _window_requires_native_speech(
        watch["hwnd"],
        focus_obj,
    )
    if native_reason:
        _clear_new_foreground_watch()
        _clear_foreground_post_focus_guard()
        log.info(
            "Released deterministic foreground sequence to native speech: "
            "hwnd=%s reason=%s",
            watch["hwnd"],
            native_reason,
        )
        return False, None

    log.info(
        "Suppressed native speech during deterministic foreground sequence: "
        "reason=%s hwnd=%s speech=%r",
        watch.get("reason", "foreground transition"),
        watch["hwnd"],
        _plain_strings(sequence),
    )
    return True, None


def _should_suppress_minitray_bridge_speech(sequence):
    """Drop only the hidden MiniTray focus bridge and its tiny ancestry burst."""
    global _minitray_bridge_chatter_until

    texts = _plain_strings(sequence)
    if not texts:
        return False

    now = time.monotonic()
    lowered = [text.casefold().strip() for text in texts]
    joined = " ".join(lowered)

    if "minitray focus bridge" in joined:
        _minitray_bridge_chatter_until = now + 1.0
        log.info("Suppressed MiniTray focus bridge announcement")
        return True

    if now >= _minitray_bridge_chatter_until:
        return False

    bridge_tokens = {
        "dialog",
        "window",
        "edit",
        "editable text",
        "blank",
    }
    if all(text in bridge_tokens for text in lowered):
        log.info("Suppressed MiniTray focus bridge ancestry: %r", texts)
        return True

    return False


def _estimate_minitray_speech_ms(sequence):
    """Conservative callback-free duration estimate for one speech sequence."""
    text = " ".join(_plain_strings(sequence))
    if not text:
        return MINITRAY_QUEUE_MIN_SPEECH_MS
    words = len(text.split())
    punctuation = sum(text.count(ch) for ch in ".,;:!?")
    estimate = max(
        words * MINITRAY_QUEUE_WORD_MS,
        len(text) * MINITRAY_QUEUE_CHAR_MS,
    )
    estimate += punctuation * MINITRAY_QUEUE_PUNCT_MS + 450
    return max(
        MINITRAY_QUEUE_MIN_SPEECH_MS,
        min(estimate, MINITRAY_QUEUE_MAX_SPEECH_MS),
    )


def _extend_quiet_for_minitray(milliseconds):
    global _quiet_until
    if milliseconds <= 0:
        return
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + milliseconds / 1000.0,
    )


def _normalized_gesture_keys(gesture):
    try:
        identifiers = getattr(gesture, "identifiers", ()) or ()
        if identifiers:
            key_part = str(identifiers[0]).casefold().rsplit(":", 1)[-1]
            key_part = key_part.replace("ctrl", "control").replace(" ", "")
            return frozenset(part for part in key_part.split("+") if part)
    except Exception:
        pass
    try:
        keys = {
            str(item).casefold().replace("ctrl", "control")
            for item in (getattr(gesture, "modifierNames", ()) or ())
        }
        main_key = (getattr(gesture, "mainKeyName", "") or "").casefold()
        if main_key:
            keys.add(main_key)
        return frozenset(keys)
    except Exception:
        return frozenset()


def _is_window_close_gesture(gesture):
    """Return True for the ordinary Alt+F4 top-level close gesture."""
    keys = _normalized_gesture_keys(gesture)
    alt_names = {"alt", "leftalt", "rightalt"}
    return (
        "f4" in keys
        and bool(keys.intersection(alt_names))
        and not bool(
            keys.intersection(
                {
                    "control",
                    "leftcontrol",
                    "rightcontrol",
                    "ctrl",
                    "windows",
                    "leftwindows",
                    "rightwindows",
                    "win",
                    "leftwin",
                    "rightwin",
                }
            )
        )
    )


def _windows_desktop_gesture_name(gesture):
    """Return ``windows+m`` or ``windows+d`` for desktop shortcuts."""
    keys = _normalized_gesture_keys(gesture)
    windows_names = {
        "windows",
        "leftwindows",
        "rightwindows",
        "win",
        "leftwin",
        "rightwin",
    }
    if not keys.intersection(windows_names):
        return ""

    if keys.intersection(
        {
            "alt",
            "leftalt",
            "rightalt",
            "control",
            "leftcontrol",
            "rightcontrol",
            "ctrl",
        }
    ):
        return ""

    if "m" in keys:
        return "windows+m"
    if "d" in keys:
        return "windows+d"
    return ""


def _is_modifier_only_gesture(gesture):
    """True when NVDA reports only released/pressed modifier keys.

    AutoHotkey hotkeys such as Ctrl+Shift+L and Alt+Shift+Escape can be followed
    by a standalone rightControl, Shift or Alt gesture. Treating that as fresh
    user input clears the protected restore-all/hide-all summary before it
    starts speaking.
    """
    keys = _normalized_gesture_keys(gesture)
    if not keys:
        return False
    modifier_names = {
        "alt",
        "leftalt",
        "rightalt",
        "shift",
        "leftshift",
        "rightshift",
        "control",
        "leftcontrol",
        "rightcontrol",
        "ctrl",
        "windows",
        "leftwindows",
        "rightwindows",
        "win",
        "leftwin",
        "rightwin",
        "nvda",
    }
    return keys.issubset(modifier_names)


def _is_minitray_command_gesture(gesture):
    keys = _normalized_gesture_keys(gesture)
    return keys in {
        frozenset({"shift", "escape"}),
        frozenset({"control", "l"}),
        frozenset({"control", "shift", "l"}),
        frozenset({"alt", "shift", "escape"}),
        frozenset({"control", "alt", "m"}),
        frozenset({"control", "alt", "h"}),
        frozenset({"control", "alt", "4"}),
        frozenset({"control", "alt", "5"}),
        frozenset({"control", "alt", "z"}),
        frozenset({"control", "alt", "shift", "q"}),
    }


def _cancel_minitray_speech_for_user_input(reason="user input"):
    """Make navigation responsive without breaking MiniTray-to-MiniTray queueing."""
    global _quiet_until
    global _close_result_generation
    global _close_result_active
    global _menu_announcement_serial
    global _hide_announcement_serial
    global _restore_final_announcement_serial
    global _minitray_announcement_generation
    global _minitray_announcement_active
    global _minitray_announcement_scheduled
    global _minitray_current_announcement

    if (
        not _minitray_queue_busy()
        and not _quiet_until
        and not _close_result_active
    ):
        return False

    _close_result_generation += 1
    _close_result_active = False
    _quiet_until = 0.0
    _menu_announcement_serial += 1
    _hide_announcement_serial += 1
    _restore_final_announcement_serial += 1
    _minitray_announcement_generation += 1
    _minitray_announcement_queue.clear()
    _minitray_announcement_active = False
    _minitray_announcement_scheduled = False
    _minitray_current_announcement = None

    if _orig_cancel_speech is not None:
        try:
            _orig_cancel_speech()
        except Exception:
            log.debugWarning(
                "Unable to cancel MiniTray speech for user input",
                exc_info=True,
            )
    log.info("Released MiniTray speech suppression for %s", reason)
    return True


def _queue_minitray_announcement(
    kind,
    spoken_text,
    tail_ms=0,
    delay_ms=0,
    target_hwnd=0,
    target_pid=0,
):
    """Append a protected MiniTray result without interrupting an active one."""
    global _minitray_announcement_scheduled

    if len(_minitray_announcement_queue) >= MINITRAY_QUEUE_LIMIT:
        # Keep recent state transitions. Dropping the oldest *pending* result is
        # preferable to cancelling the sentence already in the synthesizer.
        dropped = _minitray_announcement_queue.pop(0)
        log.warning(
            "MiniTray announcement queue full; dropped oldest pending %s: %r",
            dropped.get("kind"),
            dropped.get("spoken_text"),
        )

    was_idle = not _minitray_queue_busy()
    item = {
        "kind": kind,
        "spoken_text": spoken_text,
        "tail_ms": max(0, int(tail_ms or 0)),
        "delay_ms": max(0, int(delay_ms or 0)),
        "target_hwnd": int(target_hwnd or 0),
        "target_pid": int(target_pid or 0),
        "attempt": 0,
    }
    # Restore entries may append a focused-control or terminal line. Reserve a
    # little extra protection until the actual sequence is built.
    item["estimate_ms"] = _estimate_minitray_speech_ms([spoken_text])
    if kind == "restore":
        item["estimate_ms"] = min(
            MINITRAY_QUEUE_MAX_SPEECH_MS,
            item["estimate_ms"] + 1200,
        )
    _minitray_announcement_queue.append(item)

    pending_ms = sum(
        queued.get("estimate_ms", MINITRAY_QUEUE_MIN_SPEECH_MS)
        + queued.get("tail_ms", 0)
        + MINITRAY_QUEUE_GAP_MS
        for queued in _minitray_announcement_queue
    )
    _extend_quiet_for_minitray(pending_ms)

    if was_idle:
        # Clear unrelated speech once, before the first protected item. Further
        # MiniTray commands are appended and never call cancelSpeech.
        try:
            speech.cancelSpeech()
        except Exception:
            log.debugWarning(
                "Unable to cancel ordinary speech before MiniTray queue",
                exc_info=True,
            )
        _schedule_next_minitray_announcement()

    log.info(
        "MiniTray announcement queued: kind=%s pending=%s active=%s text=%r",
        kind,
        len(_minitray_announcement_queue),
        _minitray_announcement_active,
        spoken_text,
    )


def _schedule_next_minitray_announcement():
    global _minitray_announcement_scheduled

    if (
        _minitray_announcement_active
        or _minitray_announcement_scheduled
        or not _minitray_announcement_queue
    ):
        return
    _minitray_announcement_scheduled = True
    item = _minitray_announcement_queue[0]
    generation = _minitray_announcement_generation
    core.callLater(
        item.get("delay_ms", 0),
        _start_next_minitray_announcement,
        generation,
    )


def _start_next_minitray_announcement(generation):
    global _minitray_announcement_active
    global _minitray_announcement_scheduled
    global _minitray_current_announcement
    global _quiet_until

    if generation != _minitray_announcement_generation:
        return
    _minitray_announcement_scheduled = False
    if _minitray_announcement_active or not _minitray_announcement_queue:
        return

    item = _minitray_announcement_queue[0]
    title_sequence = [item["spoken_text"]]
    focus_sequence = []

    if item["kind"] == "restore":
        target_hwnd = item["target_hwnd"]
        target_pid = item["target_pid"]
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        if foreground_hwnd != target_hwnd:
            if item["attempt"] < RESTORE_FINAL_MAX_ATTEMPTS:
                item["attempt"] += 1
                _minitray_announcement_scheduled = True
                core.callLater(
                    SAVED_FOCUS_RETRY_MS,
                    _start_next_minitray_announcement,
                    generation,
                )
                return
            log.warning(
                "MiniTray queued restore foreground mismatch: expected=%s actual=%s",
                target_hwnd,
                foreground_hwnd,
            )
        else:
            try:
                prepared, focus_sequence, focus_source = (
                    _prepare_restore_final_focus(target_hwnd, target_pid)
                )
            except Exception:
                prepared, focus_sequence, focus_source = False, [], "exception"
                log.exception(
                    "MiniTray queued restore focus preparation failed: hwnd=%s pid=%s",
                    target_hwnd,
                    target_pid,
                )
            if not prepared and item["attempt"] < RESTORE_FINAL_MAX_ATTEMPTS:
                item["attempt"] += 1
                _minitray_announcement_scheduled = True
                core.callLater(
                    SAVED_FOCUS_RETRY_MS,
                    _start_next_minitray_announcement,
                    generation,
                )
                return
            log.info(
                "MiniTray queued restore prepared: hwnd=%s pid=%s source=%s focusItems=%s",
                target_hwnd,
                target_pid,
                focus_source,
                len(focus_sequence),
            )

    _minitray_announcement_queue.pop(0)
    _minitray_announcement_active = True
    _minitray_current_announcement = item

    speech_sequence = title_sequence
    if item["kind"] == "restore" and focus_sequence:
        # Submit the complete restore result in ONE synthesizer utterance:
        #   "<restore message> <window title>: <focus>"
        # focus_sequence may contain language/state commands, so concatenate
        # sequences rather than flattening it to text.
        speech_sequence = [
            item["spoken_text"].rstrip(" :"),
            ": ",
        ] + focus_sequence

    duration_ms = _estimate_minitray_speech_ms(speech_sequence)

    item["actual_duration_ms"] = duration_ms
    _quiet_until = max(
        _quiet_until,
        time.monotonic() + (duration_ms + item["tail_ms"]) / 1000.0,
    )

    try:
        _orig_speak(speech_sequence)
        log.info(
            "MiniTray announcement started: kind=%s durationMs=%s remaining=%s "
            "text=%r focusItems=%s singleUtterance=%s",
            item["kind"],
            duration_ms,
            len(_minitray_announcement_queue),
            item["spoken_text"],
            len(focus_sequence),
            bool(item["kind"] == "restore" and focus_sequence),
        )
    except Exception:
        log.exception(
            "Unable to speak queued MiniTray announcement: %r",
            item["spoken_text"],
        )
        duration_ms = 1

    core.callLater(
        duration_ms,
        _finish_minitray_announcement,
        generation,
    )


def _finish_minitray_announcement(generation):
    global _minitray_announcement_active
    global _minitray_current_announcement

    if generation != _minitray_announcement_generation:
        return
    item = _minitray_current_announcement
    _minitray_current_announcement = None
    _minitray_announcement_active = False
    if item is not None:
        log.info(
            "MiniTray announcement slot completed: kind=%s pending=%s text=%r",
            item.get("kind"),
            len(_minitray_announcement_queue),
            item.get("spoken_text"),
        )
    if _minitray_announcement_queue:
        core.callLater(
            MINITRAY_QUEUE_GAP_MS,
            _schedule_next_minitray_announcement,
        )


def _deliver_menu_announcement(serial, spoken_text):
    """Speak a pending MiniTray opening phrase after NVDA finishes cancelling."""
    if serial != _menu_announcement_serial:
        return
    try:
        _orig_speak([spoken_text])
        log.info("MiniTray spoke deferred menu announcement: %r", spoken_text)
    except Exception:
        log.exception("Unable to speak deferred MiniTray menu announcement")


def _parse_hide_final(text):
    """Return (quiet-tail milliseconds, spoken text), or None."""
    if not text or not text.startswith(HIDE_FINAL_PREFIX):
        return None
    payload = text[len(HIDE_FINAL_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        tail_text, spoken_text = payload.split(":", 1)
        tail_ms = max(0, min(int(tail_text), MAX_QUIET_MS))
        return tail_ms, spoken_text
    except (TypeError, ValueError):
        return None


def _deliver_hide_final_announcement(serial, spoken_text):
    """Speak the final-window hide result after desktop focus chatter settles."""
    if serial != _hide_announcement_serial:
        return
    try:
        _orig_speak([spoken_text])
        log.info("MiniTray spoke deferred final-hide announcement: %r", spoken_text)
    except Exception:
        log.exception("Unable to speak deferred MiniTray final-hide announcement")


def _parse_restore_final(text):
    """Return (quiet tail, HWND, PID, spoken text), or None.

    Restore-all deliberately uses a plain speech sequence with no
    CallbackCommand. Some dual-voice synthesizers accept the callback command
    but never execute it, and can truncate the surrounding utterance.
    """
    if not text or not text.startswith(RESTORE_FINAL_PREFIX):
        return None
    payload = text[len(RESTORE_FINAL_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        tail_text, hwnd_text, pid_text, spoken_text = payload.split(":", 3)
        tail_ms = max(0, min(int(tail_text), MAX_QUIET_MS))
        return tail_ms, int(hwnd_text), int(pid_text), spoken_text
    except (TypeError, ValueError):
        return None


def _prepare_restore_final_focus(target_hwnd, target_pid):
    """Repair NVDA caches and return focus speech for the same utterance.

    The restore title and the focused control are submitted through one
    speech.speak call. This avoids both unsupported synth callbacks and a later
    focus report overtaking the title.
    """
    obj, source, is_terminal = _choose_generic_restored_focus(
        target_hwnd,
        target_pid,
    )
    if is_terminal:
        terminal_obj, score, visited = _find_terminal_text_object(target_hwnd)
        if terminal_obj is None or score < 300:
            return False, [], "terminal unavailable"
        if not _install_terminal_focus_object(
            target_hwnd,
            target_pid,
            terminal_obj,
            reason=(
                "restore-all combined speech preparation; "
                f"score={score}; visited={visited}"
            ),
            run_gain_focus=False,
        ):
            return False, [], "terminal installation failed"
        _saved_focus_objects.pop((target_hwnd, target_pid), None)
        try:
            line_text, _text_obj, _position = _line_text_from_object(terminal_obj)
        except Exception:
            line_text = ""
        return True, ([line_text] if line_text else []), "terminal line"

    if obj is None:
        return False, [], "no focus object"

    _set_nvda_foreground_from_focus(obj, target_hwnd)
    api.setFocusObject(obj)
    _saved_focus_objects.pop((target_hwnd, target_pid), None)

    focus_sequence = []
    if _appName(obj) == "msedge":
        try:
            line_text, _text_obj, _position = _line_text_from_object(obj)
        except Exception:
            line_text = ""
        if line_text:
            focus_sequence = [line_text]

    if not focus_sequence:
        try:
            focus_sequence = list(
                speech.getObjectSpeech(
                    obj,
                    reason=controlTypes.OutputReason.FOCUS,
                )
            )
            # The user's dual-voice synth mishandles CallbackCommand. Normal
            # focus speech does not require one, but strip any provider-added
            # callback defensively while retaining language and state commands.
            focus_sequence = [
                item for item in focus_sequence
                if not isinstance(item, CallbackCommand)
            ]
        except Exception:
            log.debugWarning(
                "MiniTray could not build combined restore focus speech",
                exc_info=True,
            )
            focus_sequence = []

    log.info(
        "MiniTray prepared restore-all title+focus sequence: hwnd=%s pid=%s "
        "source=%s object=%s sequenceItems=%s",
        target_hwnd,
        target_pid,
        source,
        _focus_object_summary(obj),
        len(focus_sequence),
    )
    return True, focus_sequence, source


def _deliver_restore_final_announcement(
    serial,
    tail_ms,
    target_hwnd,
    target_pid,
    spoken_text,
    attempt=0,
):
    """Repair focus quietly, then speak one callback-free restore-all result."""
    global _quiet_until

    if serial != _restore_final_announcement_serial:
        return

    if tail_ms:
        _quiet_until = time.monotonic() + tail_ms / 1000.0

    foreground_hwnd = int(winUser.getForegroundWindow() or 0)
    focus_sequence = []
    if foreground_hwnd != target_hwnd:
        if attempt < RESTORE_FINAL_MAX_ATTEMPTS:
            core.callLater(
                SAVED_FOCUS_RETRY_MS,
                _deliver_restore_final_announcement,
                serial,
                tail_ms,
                target_hwnd,
                target_pid,
                spoken_text,
                attempt + 1,
            )
            return
        log.warning(
            "MiniTray restore-all summary foreground mismatch: "
            "expected=%s actual=%s",
            target_hwnd,
            foreground_hwnd,
        )
    else:
        try:
            prepared, focus_sequence, focus_source = _prepare_restore_final_focus(
                target_hwnd,
                target_pid,
            )
        except Exception:
            prepared, focus_sequence, focus_source = False, [], "exception"
            log.exception(
                "MiniTray restore-all focus preparation failed: "
                "hwnd=%s pid=%s",
                target_hwnd,
                target_pid,
            )
        if not prepared and attempt < RESTORE_FINAL_MAX_ATTEMPTS:
            core.callLater(
                SAVED_FOCUS_RETRY_MS,
                _deliver_restore_final_announcement,
                serial,
                tail_ms,
                target_hwnd,
                target_pid,
                spoken_text,
                attempt + 1,
            )
            return

    core.callLater(
        RESTORE_FINAL_ANNOUNCE_DELAY_MS,
        _speak_restore_final_plain,
        serial,
        spoken_text,
        focus_sequence,
    )


def _speak_restore_final_plain(serial, spoken_text, focus_sequence):
    if serial != _restore_final_announcement_serial:
        return
    try:
        speech_sequence = [spoken_text]
        if focus_sequence:
            speech_sequence = [
                spoken_text.rstrip(" :"),
                ": ",
            ] + focus_sequence
        _orig_speak(speech_sequence)
        log.info(
            "MiniTray spoke restore result as one utterance: "
            "text=%r focusItems=%s",
            spoken_text,
            len(focus_sequence),
        )
    except Exception:
        log.exception("Unable to speak MiniTray restore result")


def _parse_final_focus(text):
    """Return (MiniTray HWND, token, spoken text), or None."""
    if not text or not text.startswith(FINAL_FOCUS_PREFIX):
        return None
    payload = text[len(FINAL_FOCUS_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, token_text, spoken_text = payload.split(":", 2)
        return int(hwnd_text), int(token_text), spoken_text
    except (TypeError, ValueError):
        return None


def _parse_replay_focus(text):
    """Return (target top-level HWND, process ID), or None."""
    if not text or not text.startswith(REPLAY_FOCUS_PREFIX):
        return None
    payload = text[len(REPLAY_FOCUS_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, pid_text = payload.split(":", 1)
        return int(hwnd_text), int(pid_text)
    except (TypeError, ValueError):
        return None


def _parse_report_line(text):
    """Return (target top-level HWND, process ID), or None."""
    if not text or not text.startswith(REPORT_LINE_PREFIX):
        return None
    payload = text[len(REPORT_LINE_PREFIX):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, pid_text = payload.split(":", 1)
        return int(hwnd_text), int(pid_text)
    except (TypeError, ValueError):
        return None


def _parse_focus_cache_command(text, prefix):
    """Return (target top-level HWND, process ID), or None."""
    if not text or not text.startswith(prefix):
        return None
    payload = text[len(prefix):]
    if payload.endswith(CLOSE_CHAR):
        payload = payload[:-1]
    try:
        hwnd_text, pid_text = payload.split(":", 1)
        return int(hwnd_text), int(pid_text)
    except (TypeError, ValueError):
        return None


def _remember_current_focus(target_hwnd, target_pid):
    """Cache NVDA's exact focused object before MiniTray hides its window."""
    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        obj = api.getFocusObject()
        if obj is None:
            log.warning(
                "MiniTray could not cache NVDA focus: no focused object; hwnd=%s pid=%s",
                target_hwnd,
                target_pid,
            )
            return
        if foreground_hwnd and foreground_hwnd != target_hwnd:
            log.warning(
                "MiniTray did not cache NVDA focus: foreground mismatch; "
                "expected=%s actual=%s object=%r",
                target_hwnd,
                foreground_hwnd,
                obj,
            )
            return

        key = (target_hwnd, target_pid)
        _recovered_terminal_objects.pop(target_hwnd, None)
        _recovered_generic_focus_objects.pop(target_hwnd, None)
        _saved_focus_objects[key] = obj
        while len(_saved_focus_objects) > SAVED_FOCUS_CACHE_LIMIT:
            oldest_key = next(iter(_saved_focus_objects))
            _saved_focus_objects.pop(oldest_key, None)

        log.info(
            "MiniTray cached NVDA focus before hide: hwnd=%s pid=%s "
            "objectPid=%s object=%s role=%s",
            target_hwnd,
            target_pid,
            _object_process_id(obj),
            type(obj).__name__,
            getattr(obj, "role", None),
        )
    except Exception:
        log.exception(
            "Unable to cache MiniTray NVDA focus: hwnd=%s pid=%s",
            target_hwnd,
            target_pid,
        )


def _focus_object_summary(obj):
    """Return compact diagnostics for a candidate focus object."""
    if obj is None:
        return "None"
    try:
        role = getattr(obj, "role", None)
        role_name = getattr(role, "name", str(role))
    except Exception:
        role_name = "?"
    try:
        hwnd = int(getattr(obj, "windowHandle", 0) or 0)
    except Exception:
        hwnd = 0
    try:
        class_name = getattr(obj, "windowClassName", "") or ""
    except Exception:
        class_name = ""
    try:
        name = (getattr(obj, "name", "") or "").replace("\r", " ").replace("\n", " ")
    except Exception:
        name = ""
    return (
        f"{type(obj).__name__}(role={role_name}, hwnd={hwnd}, "
        f"root={_root_window_handle(obj)}, pid={_object_process_id(obj)}, "
        f"class={class_name!r}, name={name[:80]!r})"
    )


def _descend_to_real_focus(obj):
    """Follow focusRedirect/activeChild to the deepest real focused object.

    Windows Terminal can initially expose its frame or hosting pane while the
    terminal TextArea is still becoming available. Descending here avoids
    teaching NVDA that the frame itself is the keyboard focus.
    """
    seen = set()
    current = obj
    for _ in range(12):
        if current is None or id(current) in seen:
            break
        seen.add(id(current))

        redirected = None
        try:
            redirected = getattr(current, "focusRedirect", None)
        except Exception:
            pass
        if redirected is not None and redirected is not current:
            current = redirected
            continue

        active = None
        try:
            active = getattr(current, "activeChild", None)
        except Exception:
            pass
        if active is not None and active is not current:
            current = active
            continue
        break
    return current


def _get_fresh_operating_system_focus():
    """Construct a fresh NVDA object for the current Windows keyboard focus."""
    desktop = api.getDesktopObject()
    if desktop is None:
        return None
    obj = desktop.objectWithFocus()
    return _descend_to_real_focus(obj)


def _is_terminal_object(obj):
    if obj is None:
        return False
    try:
        terminal_role = getattr(controlTypes.Role, "TERMINAL", None)
        if terminal_role is not None and obj.role == terminal_role:
            return True
    except Exception:
        pass
    # Compatibility fallback for old/new Windows Terminal provider classes.
    class_names = " ".join(
        cls.__name__.casefold() for cls in type(obj).__mro__
    )
    try:
        window_class = (getattr(obj, "windowClassName", "") or "").casefold()
    except Exception:
        window_class = ""
    return any(token in class_names or token in window_class for token in (
        "terminal",
        "winconsole",
        "cascadia",
        "termcontrol",
        "openconsole",
    ))


def _restart_terminal_monitoring(obj):
    """Force a clean LiveText baseline for a freshly reacquired terminal."""
    stop_monitoring = getattr(obj, "stopMonitoring", None)
    start_monitoring = getattr(obj, "startMonitoring", None)
    if callable(stop_monitoring):
        try:
            stop_monitoring()
        except Exception:
            log.debugWarning(
                "MiniTray could not stop old terminal monitor",
                exc_info=True,
            )
    if callable(start_monitoring):
        start_monitoring()
    return callable(start_monitoring)


def _safe_automation_id(obj):
    try:
        return (getattr(obj, "UIAAutomationId", "") or "").strip()
    except Exception:
        return ""


def _safe_children(obj):
    """Return child NVDA objects without trusting one accessibility API."""
    out = []
    try:
        children = getattr(obj, "children", None)
        if children:
            out.extend(children)
    except Exception:
        pass
    if out:
        return out

    # Some UIA objects do not expose .children efficiently, but do expose the
    # ordinary firstChild/next chain.
    try:
        child = getattr(obj, "firstChild", None)
        count = 0
        while child is not None and count < 100:
            out.append(child)
            count += 1
            child = getattr(child, "next", None)
    except Exception:
        pass
    return out


def _terminal_candidate_score(obj):
    """Score an object for use as the real Windows Terminal text control."""
    if obj is None:
        return -1
    score = 0
    automation_id = _safe_automation_id(obj).casefold()
    if automation_id == "text area":
        score += 1000
    elif "text area" in automation_id:
        score += 700

    try:
        if obj.role == controlTypes.Role.TERMINAL:
            score += 600
    except Exception:
        pass

    class_text = " ".join(cls.__name__.casefold() for cls in type(obj).__mro__)
    try:
        window_class = (getattr(obj, "windowClassName", "") or "").casefold()
    except Exception:
        window_class = ""
    for token, points in (
        ("winterminaluia", 500),
        ("winconsoleuia", 450),
        ("terminal", 260),
        ("termcontrol", 220),
        ("cascadia", 180),
        ("openconsole", 180),
    ):
        if token in class_text or token in window_class:
            score += points

    if callable(getattr(obj, "makeTextInfo", None)):
        score += 25
    if callable(getattr(obj, "startMonitoring", None)):
        score += 150
    return score


def _find_terminal_text_object(target_hwnd):
    """Find the terminal Text Area below the restored foreground window.

    objectWithFocus frequently returns Windows Terminal's outer pane after a
    hide/show cycle. That pane accepts keyboard input indirectly, but it is not
    NVDA's terminal overlay and therefore receives neither typedCharacter
    routing nor LiveText monitoring. Search the foreground accessibility tree
    explicitly for the UIA element named ``Text Area`` or the strongest
    terminal overlay candidate.
    """
    roots = []
    try:
        roots.append(_get_fresh_operating_system_focus())
    except Exception:
        pass
    try:
        roots.append(api.getForegroundObject())
    except Exception:
        pass
    try:
        desktop = api.getDesktopObject()
        if desktop is not None:
            roots.append(desktop.objectInForeground())
    except Exception:
        pass

    queue = [root for root in roots if root is not None]
    seen = set()
    best = None
    best_score = -1
    visited = 0
    while queue and visited < 350:
        obj = queue.pop(0)
        obj_id = id(obj)
        if obj_id in seen:
            continue
        seen.add(obj_id)
        visited += 1

        root_hwnd = _root_window_handle(obj)
        # Provider-only descendants can expose root=0. A positive mismatch is
        # rejected, but root=0 is allowed while the requested window is the
        # real foreground window.
        if not root_hwnd or root_hwnd == target_hwnd:
            score = _terminal_candidate_score(obj)
            if score > best_score:
                best = obj
                best_score = score
            if score >= 1000:
                return obj, score, visited
            queue.extend(_safe_children(obj))

    return best, best_score, visited


def _install_terminal_focus_object(
    target_hwnd,
    target_pid,
    obj,
    reason,
    run_gain_focus=True,
):
    """Make a terminal object authoritative for NVDA and restart its monitor."""
    if obj is None:
        return False
    try:
        # Set UIA focus when the provider permits it. Keyboard focus already
        # belongs to the window, so failure here is harmless; the important
        # operation is rebuilding NVDA's internal focus object below.
        element = getattr(obj, "UIAElement", None)
        if element is not None:
            try:
                element.setFocus()
            except Exception:
                log.debugWarning(
                    "MiniTray terminal UIA setFocus was unavailable",
                    exc_info=True,
                )

        # NVDA tracks foreground and focused objects separately. Repair the
        # top-level cache first so NVDA+T reports the restored window rather
        # than the desktop's Program Manager object.
        _set_nvda_foreground_from_focus(obj, target_hwnd)

        # api.setFocusObject performs the old object's loseFocus path. Calling
        # event_gainFocus directly afterward avoids duplicate-event filtering
        # while still running Terminal.event_gainFocus -> startMonitoring.
        api.setFocusObject(obj)
        if run_gain_focus:
            try:
                obj.event_gainFocus()
            except Exception:
                log.debugWarning(
                    "MiniTray terminal event_gainFocus failed; using monitor fallback",
                    exc_info=True,
                )

        try:
            obj._queuedChars = []
            obj._hasTab = False
        except Exception:
            pass
        monitoring = _restart_terminal_monitoring(obj)
        _recovered_terminal_objects[target_hwnd] = {
            "pid": target_pid,
            "obj": obj,
            "time": time.monotonic(),
        }
        log.info(
            "MiniTray installed terminal Text Area focus: hwnd=%s pid=%s "
            "reason=%s monitoring=%s object=%s",
            target_hwnd,
            target_pid,
            reason,
            monitoring,
            _focus_object_summary(obj),
        )
        return True
    except Exception:
        log.exception(
            "MiniTray could not install terminal focus object: hwnd=%s pid=%s reason=%s",
            target_hwnd,
            target_pid,
            reason,
        )
        return False


def _repair_terminal_text_area(target_hwnd, target_pid, attempt=0):
    """Locate and install the real terminal Text Area after restoration."""
    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        if foreground_hwnd != target_hwnd:
            if attempt < SAVED_FOCUS_MAX_ATTEMPTS:
                core.callLater(
                    SAVED_FOCUS_RETRY_MS,
                    _repair_terminal_text_area,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray terminal Text Area recovery timed out waiting for foreground: "
                    "expected=%s actual=%s",
                    target_hwnd,
                    foreground_hwnd,
                )
            return

        obj, score, visited = _find_terminal_text_object(target_hwnd)
        if obj is None or score < 300:
            if attempt < SAVED_FOCUS_MAX_ATTEMPTS:
                log.debug(
                    "MiniTray waiting for terminal Text Area: attempt=%s score=%s "
                    "visited=%s candidate=%s",
                    attempt,
                    score,
                    visited,
                    _focus_object_summary(obj),
                )
                core.callLater(
                    SAVED_FOCUS_RETRY_MS,
                    _repair_terminal_text_area,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray could not find terminal Text Area: hwnd=%s pid=%s "
                    "score=%s visited=%s candidate=%s",
                    target_hwnd,
                    target_pid,
                    score,
                    visited,
                    _focus_object_summary(obj),
                )
            return

        if _install_terminal_focus_object(
            target_hwnd,
            target_pid,
            obj,
            reason=f"restore attempt {attempt}; score={score}; visited={visited}",
        ):
            _saved_focus_objects.pop((target_hwnd, target_pid), None)
            core.callLater(
                850,
                _speak_recovered_terminal_line,
                target_hwnd,
                target_pid,
                0,
            )
    except Exception:
        log.exception(
            "MiniTray terminal Text Area recovery failed: hwnd=%s pid=%s attempt=%s",
            target_hwnd,
            target_pid,
            attempt,
        )


def _speak_recovered_terminal_line(target_hwnd, target_pid, attempt=0):
    """Speak the prompt/current line once terminal focus has been rebuilt."""
    try:
        if int(winUser.getForegroundWindow() or 0) != target_hwnd:
            return
        rec = _recovered_terminal_objects.get(target_hwnd)
        obj = rec.get("obj") if rec else None
        if obj is None:
            return
        text, _text_obj, _position = _line_text_from_object(obj)
        if text:
            _orig_speak([text])
            log.info(
                "MiniTray spoke recovered terminal prompt: hwnd=%s length=%s",
                target_hwnd,
                len(text),
            )
            return
        if attempt < 5:
            core.callLater(
                180,
                _speak_recovered_terminal_line,
                target_hwnd,
                target_pid,
                attempt + 1,
            )
    except Exception:
        if attempt < 5:
            core.callLater(
                180,
                _speak_recovered_terminal_line,
                target_hwnd,
                target_pid,
                attempt + 1,
            )
        else:
            log.exception(
                "MiniTray could not speak recovered terminal prompt: hwnd=%s pid=%s",
                target_hwnd,
                target_pid,
            )


def _ensure_terminal_focus_before_input():
    """Reassert the recovered terminal object before NVDA routes a key.

    Windows Terminal can emit a late focus event for its outer pane after the
    Text Area was repaired. Reasserting the Text Area in the input observer is
    cheap and guarantees that NVDA's keyboard hook dispatches typedCharacter
    to EnhancedTermTypedCharSupport rather than to the non-text pane.
    """
    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        rec = _recovered_terminal_objects.get(foreground_hwnd)
        if not rec:
            return
        obj = rec.get("obj")
        current = api.getFocusObject()
        if current is obj or (current is not None and current == obj):
            return
        if current is not None and _is_terminal_object(current):
            rec["obj"] = current
            return

        # Prefer a freshly discovered Text Area if the saved object has gone
        # stale; otherwise reinstall the saved terminal object immediately.
        fresh, score, _visited = _find_terminal_text_object(foreground_hwnd)
        if fresh is not None and score >= 300:
            obj = fresh
            rec["obj"] = fresh
        _install_terminal_focus_object(
            foreground_hwnd,
            rec.get("pid", 0),
            obj,
            reason="pre-input reassertion",
            run_gain_focus=False,
        )
    except Exception:
        log.exception("MiniTray terminal pre-input focus repair failed")


def _generic_focus_is_container_only(obj):
    """True for broad containers that are less useful than a saved child."""
    if obj is None:
        return True
    role = None
    try:
        role = obj.role
    except Exception:
        pass
    enum = getattr(controlTypes, "Role", None)
    if enum is None:
        return False
    container_roles = {
        getattr(enum, name, None)
        for name in ("WINDOW", "APPLICATION", "FRAME", "PANE")
    }
    container_roles.discard(None)
    return role in container_roles


def _focus_belongs_to_window(obj, target_hwnd):
    """Accept provider-only objects with root 0, reject positive mismatches."""
    if obj is None:
        return False
    root_hwnd = _root_window_handle(obj)
    return not root_hwnd or root_hwnd == target_hwnd


def _set_nvda_foreground_from_focus(obj, target_hwnd):
    """Update NVDA's foreground cache from a recovered focused object.

    NVDA tracks the focused child and the foreground top-level object
    separately. MiniTray previously repaired only the former, which allowed
    NVDA+T to keep reporting Program Manager after a restore-all operation.
    Walk upward while objects still belong to the target HWND and store the
    highest matching object as NVDA's foreground object.
    """
    if obj is None:
        return None
    candidate = None
    node = obj
    seen = set()
    try:
        desktop_obj = api.getDesktopObject()
    except Exception:
        desktop_obj = None
    for _ in range(40):
        if node is None or node is desktop_obj or id(node) in seen:
            break
        seen.add(id(node))
        root_hwnd = _root_window_handle(node)
        if root_hwnd and root_hwnd != target_hwnd:
            break
        candidate = node
        try:
            parent = getattr(node, "container", None) or getattr(node, "parent", None)
        except Exception:
            parent = None
        if parent is node:
            break
        node = parent

    if candidate is None:
        candidate = obj
    try:
        api.setForegroundObject(candidate)
        log.info(
            "MiniTray updated NVDA foreground cache: hwnd=%s object=%s",
            target_hwnd,
            _focus_object_summary(candidate),
        )
    except Exception:
        log.exception(
            "MiniTray could not update NVDA foreground cache: hwnd=%s",
            target_hwnd,
        )
    return candidate


def _choose_generic_restored_focus(target_hwnd, target_pid):
    """Choose the best non-terminal focus object after a restore.

    Prefer the fresh operating-system focus. If Windows exposes only a broad
    frame or pane, fall back to the exact NVDA object cached before hiding.
    Classic Win32 and most UIA controls survive hide/show and remain useful;
    stale objects are harmless because installation and reporting are guarded.
    """
    fresh = None
    try:
        fresh = _get_fresh_operating_system_focus()
    except Exception:
        log.debugWarning(
            "MiniTray could not obtain fresh generic focus",
            exc_info=True,
        )

    saved = _saved_focus_objects.get((target_hwnd, target_pid))
    candidates = []
    for obj, source in ((fresh, "operating-system"), (saved, "pre-hide cache")):
        if obj is None or not _focus_belongs_to_window(obj, target_hwnd):
            continue
        if _is_terminal_object(obj):
            return obj, source, True
        candidates.append((obj, source))

    for obj, source in candidates:
        if not _generic_focus_is_container_only(obj):
            return obj, source, False
    if candidates:
        return candidates[0][0], candidates[0][1], False
    return None, "none", False


def _install_generic_focus_object(target_hwnd, target_pid, obj, source):
    """Rebuild NVDA focus for a normal control while restore chatter is quiet."""
    if obj is None:
        return False
    try:
        # Rebuild both of NVDA's caches. The foreground object powers
        # NVDA+T, while the focus object powers control and caret reporting.
        _set_nvda_foreground_from_focus(obj, target_hwnd)
        api.setFocusObject(obj)
        try:
            obj.event_gainFocus()
        except Exception:
            log.debugWarning(
                "MiniTray generic event_gainFocus failed",
                exc_info=True,
            )

        _recovered_generic_focus_objects[target_hwnd] = {
            "pid": target_pid,
            "obj": obj,
            "source": source,
            "time": time.monotonic(),
        }
        _saved_focus_objects.pop((target_hwnd, target_pid), None)
        core.callLater(
            GENERIC_FOCUS_ANNOUNCE_DELAY_MS,
            _speak_recovered_generic_focus,
            target_hwnd,
            target_pid,
            0,
        )
        log.info(
            "MiniTray installed generic restored focus: hwnd=%s pid=%s "
            "source=%s object=%s",
            target_hwnd,
            target_pid,
            source,
            _focus_object_summary(obj),
        )
        return True
    except Exception:
        log.exception(
            "MiniTray could not install generic restored focus: "
            "hwnd=%s pid=%s source=%s",
            target_hwnd,
            target_pid,
            source,
        )
        return False


def _speak_recovered_generic_focus(target_hwnd, target_pid, attempt=0):
    """Speak NVDA's normal focused-control report after the restore title."""
    global _quiet_until
    try:
        if int(winUser.getForegroundWindow() or 0) != target_hwnd:
            return

        rec = _recovered_generic_focus_objects.get(target_hwnd)
        obj = rec.get("obj") if rec else None
        source = rec.get("source", "stored") if rec else "stored"

        # Prefer a newer real focus object if Windows has settled on a deeper
        # control since the initial restore pass.
        try:
            fresh = _get_fresh_operating_system_focus()
        except Exception:
            fresh = None
        if (
            fresh is not None
            and _focus_belongs_to_window(fresh, target_hwnd)
            and not _is_terminal_object(fresh)
            and (
                obj is None
                or (
                    _generic_focus_is_container_only(obj)
                    and not _generic_focus_is_container_only(fresh)
                )
            )
        ):
            obj = fresh
            source = "settled operating-system"

        if obj is None:
            if attempt < 4:
                core.callLater(
                    150,
                    _speak_recovered_generic_focus,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            return

        # A terminal provider may finish loading after the generic branch was
        # selected. Hand it to the proven terminal repair without speaking a
        # misleading ordinary-control report.
        if _is_terminal_object(obj):
            _recovered_generic_focus_objects.pop(target_hwnd, None)
            _repair_terminal_text_area(target_hwnd, target_pid, 0)
            return

        api.setFocusObject(obj)
        _quiet_until = 0.0

        # Earlier MiniTray builds read Edge's browse-mode caret line after a
        # restore. reportFocus() alone often reports only the Chromium document
        # or container, losing the item at the virtual cursor. Restore that
        # behavior specifically for Edge; terminals keep their separate proven
        # Text Area recovery path and other applications retain reportFocus().
        if _appName(obj) == "msedge":
            try:
                line_text, text_obj, position = _line_text_from_object(obj)
            except Exception:
                line_text, text_obj, position = "", obj, None
            if line_text:
                _orig_speak([line_text])
                log.info(
                    "MiniTray spoke restored Edge cursor item: hwnd=%s pid=%s "
                    "source=%s object=%s position=%s length=%s",
                    target_hwnd,
                    target_pid,
                    source,
                    type(text_obj).__name__,
                    position,
                    len(line_text),
                )
                return

        obj.reportFocus()
        log.info(
            "MiniTray spoke restored focused control: hwnd=%s pid=%s "
            "source=%s object=%s",
            target_hwnd,
            target_pid,
            source,
            _focus_object_summary(obj),
        )
    except Exception:
        if attempt < 4:
            core.callLater(
                150,
                _speak_recovered_generic_focus,
                target_hwnd,
                target_pid,
                attempt + 1,
            )
        else:
            log.exception(
                "MiniTray could not speak restored focused control: "
                "hwnd=%s pid=%s",
                target_hwnd,
                target_pid,
            )


def _restore_cached_focus(target_hwnd, target_pid, attempt=0):
    """Recover terminal monitoring or report a normal restored control."""
    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        if foreground_hwnd != target_hwnd:
            if attempt < GENERIC_FOCUS_MAX_ATTEMPTS:
                core.callLater(
                    GENERIC_FOCUS_RETRY_MS,
                    _restore_cached_focus,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray restored-focus recovery timed out waiting for "
                    "foreground: expected=%s actual=%s",
                    target_hwnd,
                    foreground_hwnd,
                )
            return

        obj, source, is_terminal = _choose_generic_restored_focus(
            target_hwnd,
            target_pid,
        )
        if is_terminal:
            _repair_terminal_text_area(target_hwnd, target_pid, attempt)
            return

        if obj is None:
            if attempt < GENERIC_FOCUS_MAX_ATTEMPTS:
                core.callLater(
                    GENERIC_FOCUS_RETRY_MS,
                    _restore_cached_focus,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray could not resolve restored focused control: "
                    "hwnd=%s pid=%s",
                    target_hwnd,
                    target_pid,
                )
            return

        _install_generic_focus_object(
            target_hwnd,
            target_pid,
            obj,
            source,
        )
    except Exception:
        log.exception(
            "MiniTray restored-focus recovery failed: hwnd=%s pid=%s attempt=%s",
            target_hwnd,
            target_pid,
            attempt,
        )


def _object_process_id(obj):
    app_module = getattr(obj, "appModule", None) if obj is not None else None
    return getattr(app_module, "processID", 0) if app_module is not None else 0


def _root_window_handle(obj):
    """Return the real top-level HWND containing an NVDA object, if known."""
    try:
        hwnd = int(getattr(obj, "windowHandle", 0) or 0)
    except (TypeError, ValueError):
        hwnd = 0
    if not hwnd:
        return 0
    try:
        # GA_ROOT = 2. Some UIA objects expose a child/provider HWND rather
        # than the foreground top-level window.
        return int(ctypes.windll.user32.GetAncestor(hwnd, 2) or hwnd)
    except Exception:
        return hwnd


def _get_real_focus_object():
    """Fetch the operating system focus instead of NVDA's possibly stale cache.

    api.getFocusObject() returns globalVars.focusObject, which is updated only
    after NVDA processes a focus event. Restoring a window can return to the
    same logical UIA object without producing a new event, leaving that cache
    on MiniTray's focus bridge. NVDAObject.objectWithFocus() resolves the real
    current OS focus directly.
    """
    try:
        desktop = api.getDesktopObject()
        obj = desktop.objectWithFocus() if desktop is not None else None
        if obj is not None:
            return obj, "operating-system"
    except Exception:
        log.debugWarning("Unable to resolve real OS focus for MiniTray", exc_info=True)
    return api.getFocusObject(), "NVDA-cache"


def _line_text_from_object(obj):
    """Return the caret line for an object, with terminal-oriented fallbacks."""
    tree_interceptor = getattr(obj, "treeInterceptor", None)
    text_obj = obj
    if (
        isinstance(tree_interceptor, treeInterceptorHandler.DocumentTreeInterceptor)
        and not tree_interceptor.passThrough
    ):
        text_obj = tree_interceptor

    positions = (textInfos.POSITION_CARET, textInfos.POSITION_FIRST)
    last_error = None
    for position in positions:
        try:
            info = text_obj.makeTextInfo(position)
            info.expand(textInfos.UNIT_LINE)
            text = getattr(info, "text", "") or ""
            # Remove line terminators only. Preserve leading spaces because
            # they can be meaningful in terminals and editors.
            text = text.rstrip("\r\n")
            if text and not text.isspace():
                return text, text_obj, position
        except (LookupError, NotImplementedError, RuntimeError) as error:
            last_error = error

    # Some terminal providers expose the screen buffer but not POSITION_CARET
    # immediately after reactivation. In that case use the last non-empty
    # visual line from the story as a prompt/current-line fallback.
    try:
        info = text_obj.makeTextInfo(textInfos.POSITION_ALL)
        story = (getattr(info, "text", "") or "").replace("\r\n", "\n")
        for line in reversed(story.split("\n")):
            candidate = line.rstrip("\r")
            if candidate and not candidate.isspace():
                return candidate, text_obj, textInfos.POSITION_ALL
    except (LookupError, NotImplementedError, RuntimeError) as error:
        last_error = error

    if last_error:
        raise last_error
    return "", text_obj, None


def _speak_focused_caret_line(target_hwnd, target_pid=0, attempt=0):
    """Speak the real OS-focused object's current line after a MiniTray restore.

    The controller DLL only carries the MTREPORTLINE command into NVDA. The
    object and text are resolved here. Crucially, this uses objectWithFocus()
    rather than api.getFocusObject(), because the latter is a cached value and
    may still identify MiniTray's temporary focus bridge when Windows does not
    emit a fresh focus event for the restored UIA object.
    """
    try:
        foreground_hwnd = int(winUser.getForegroundWindow() or 0)
        if foreground_hwnd != target_hwnd:
            if attempt < REPORT_LINE_MAX_ATTEMPTS:
                core.callLater(
                    REPORT_LINE_RETRY_MS,
                    _speak_focused_caret_line,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray line report foreground timeout: expected=%s actual=%s",
                    target_hwnd,
                    foreground_hwnd,
                )
            return

        obj, focus_source = _get_real_focus_object()
        if obj is None:
            if attempt < REPORT_LINE_MAX_ATTEMPTS:
                core.callLater(
                    REPORT_LINE_RETRY_MS,
                    _speak_focused_caret_line,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning("MiniTray line report found no focused object")
            return

        root_hwnd = _root_window_handle(obj)
        # Do not reject solely because appModule.processID differs. Windows
        # Terminal, console hosts, and remote UIA providers can legitimately
        # expose the focused object from a different process than the top-level
        # application window.
        if root_hwnd and root_hwnd != target_hwnd:
            if attempt < REPORT_LINE_MAX_ATTEMPTS:
                core.callLater(
                    REPORT_LINE_RETRY_MS,
                    _speak_focused_caret_line,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray line report focus timeout: expectedRoot=%s actualRoot=%s "
                    "source=%s object=%r",
                    target_hwnd,
                    root_hwnd,
                    focus_source,
                    obj,
                )
            return

        text, text_obj, position = _line_text_from_object(obj)
        if text:
            # Bypass our own quiet wrapper for this one requested line. The
            # quiet floor was reopened when MTREPORTLINE was parsed, but using
            # the original function also prevents this line from being mistaken
            # for another private controller command.
            _orig_speak([text])
            log.info(
                "MiniTray spoke restored line: source=%s root=%s pid=%s "
                "object=%s textInfoPosition=%s length=%s",
                focus_source,
                root_hwnd,
                _object_process_id(obj),
                type(text_obj).__name__,
                position,
                len(text),
            )
            return

        # A non-text focus (button, list item, etc.) should still be announced.
        obj.reportFocus()
        log.info(
            "MiniTray restored object had no line; reported focus: source=%s "
            "root=%s pid=%s object=%r",
            focus_source,
            root_hwnd,
            _object_process_id(obj),
            obj,
        )
    except Exception:
        log.exception(
            "Unable to speak MiniTray restored line: hwnd=%s pid=%s attempt=%s",
            target_hwnd,
            target_pid,
            attempt,
        )

def _replay_current_focus(target_hwnd, target_pid, attempt=0):
    """Replay NVDA's normal gainFocus chain after MiniTray restores focus.

    Windows/UIA often returns to the same logical object without emitting a
    fresh event that NVDA will report. By the time this runs, MiniTray has
    already restored the physical focus and reopened speech. We wait until
    NVDA's cached focus belongs to the requested foreground process, then queue
    gainFocus for that exact object. The object's ordinary event_gainFocus path
    calls reportFocus; navigable text controls therefore include the current
    line, and Terminal starts monitoring as it normally would.
    """
    try:
        if winUser.getForegroundWindow() != target_hwnd:
            return

        obj = api.getFocusObject()
        app_module = getattr(obj, "appModule", None) if obj is not None else None
        obj_pid = getattr(app_module, "processID", 0) if app_module is not None else 0

        if obj is None or (target_pid and obj_pid != target_pid):
            if attempt < REPLAY_FOCUS_MAX_ATTEMPTS:
                core.callLater(
                    REPLAY_FOCUS_RETRY_MS,
                    _replay_current_focus,
                    target_hwnd,
                    target_pid,
                    attempt + 1,
                )
            else:
                log.warning(
                    "MiniTray focus replay timed out: hwnd=%s pid=%s cachedPid=%s",
                    target_hwnd,
                    target_pid,
                    obj_pid,
                )
            return

        eventHandler.queueEvent("gainFocus", obj)
        log.debug(
            "MiniTray replayed gainFocus for %r (hwnd=%s pid=%s)",
            obj,
            target_hwnd,
            target_pid,
        )
    except Exception:
        log.exception("Unable to replay MiniTray restored focus")


def _finish_restore_title(mini_tray_hwnd, token):
    """Tell MiniTray the app/title utterance reached its end marker.

    Keep the quiet gate closed. MiniTray first activates the restored window
    and moves focus away from its saved child, then sends MTQUIET:0 immediately
    before applying the final ControlFocus. That ordinary Windows gainFocus
    event is what NVDA should announce.
    """
    try:
        ctypes.windll.user32.PostMessageW(
            mini_tray_hwnd,
            RESTORE_FOCUS_MESSAGE,
            token,
            0,
        )
    except Exception:
        log.exception("Unable to post MiniTray restore-focus callback")


def _speak(sequence, *args, **kwargs):
    global _quiet_until, _menu_announcement_serial, _hide_announcement_serial
    global _restore_final_announcement_serial

    first_text = _first_string(sequence)

    if _should_suppress_minitray_bridge_speech(sequence):
        return

    if first_text == POPUP_NAVIGATION_COMMAND:
        # AutoHotkey owns the popup's AppsKey, arrow, Left and Right gestures,
        # so NVDA's input observer never sees them. Explicitly release the
        # protected menu-opening phrase before AHK changes the ListBox
        # selection, allowing the resulting item announcement through at once.
        _cancel_minitray_speech_for_user_input(
            "MiniTray popup navigation"
        )
        return

    close_menu = _parse_close_menu(first_text)
    if close_menu is not None:
        popup_hwnd, spoken_text = close_menu
        generation, due_at = _begin_close_result(spoken_text)
        core.callLater(
            CLOSE_RESULT_RETRY_MS,
            _deliver_close_menu_focus,
            generation,
            popup_hwnd,
            due_at,
            0,
        )
        return

    close_tray = _parse_close_tray(first_text)
    if close_tray is not None:
        mini_tray_hwnd, remove_icon, spoken_text = close_tray
        _start_close_tray_focus(mini_tray_hwnd, remove_icon, spoken_text)
        return

    safe_quiet_ms = _parse_safe_quiet(first_text)
    if safe_quiet_ms is not None:
        if safe_quiet_ms:
            _quiet_until = max(
                _quiet_until,
                time.monotonic() + safe_quiet_ms / 1000.0,
            )
        elif not _minitray_queue_busy():
            _quiet_until = 0.0

        if not _minitray_queue_busy():
            try:
                speech.cancelSpeech()
            except Exception:
                log.debugWarning(
                    "Unable to perform safe MiniTray speech cancellation",
                    exc_info=True,
                )
        else:
            log.info(
                "MiniTray safe cancel preserved active/queued announcement: "
                "active=%s pending=%s",
                _minitray_announcement_active,
                len(_minitray_announcement_queue),
            )
        return

    menu_announcement = _parse_menu(first_text)
    if menu_announcement is not None:
        tail_ms, spoken_text = menu_announcement
        _queue_minitray_announcement(
            "menu",
            spoken_text,
            tail_ms=tail_ms,
            delay_ms=MENU_ANNOUNCE_DELAY_MS,
        )
        return

    hide_announcement = _parse_hide_final(first_text)
    if hide_announcement is not None:
        tail_ms, spoken_text = hide_announcement
        _queue_minitray_announcement(
            "hide",
            spoken_text,
            tail_ms=tail_ms,
            delay_ms=HIDE_FINAL_ANNOUNCE_DELAY_MS,
        )
        return

    restore_final = _parse_restore_final(first_text)
    if restore_final is not None:
        tail_ms, target_hwnd, target_pid, spoken_text = restore_final
        _queue_minitray_announcement(
            "restore",
            spoken_text,
            tail_ms=tail_ms,
            delay_ms=RESTORE_FINAL_PREPARE_DELAY_MS,
            target_hwnd=target_hwnd,
            target_pid=target_pid,
        )
        return

    save_focus = _parse_focus_cache_command(first_text, SAVE_FOCUS_PREFIX)
    if save_focus is not None:
        target_hwnd, target_pid = save_focus
        _remember_current_focus(target_hwnd, target_pid)
        return

    restore_saved_focus = _parse_focus_cache_command(
        first_text,
        RESTORE_SAVED_FOCUS_PREFIX,
    )
    if restore_saved_focus is not None:
        target_hwnd, target_pid = restore_saved_focus
        core.callLater(
            SAVED_FOCUS_RETRY_MS,
            _restore_cached_focus,
            target_hwnd,
            target_pid,
            0,
        )
        return

    report_line = _parse_report_line(first_text)
    if report_line is not None:
        # Reopen the speech floor, then let NVDA read the caret line from its
        # own focused object/TextInfo. The controller DLL is only the transport.
        _quiet_until = 0.0
        target_hwnd, target_pid = report_line
        core.callLater(
            REPORT_LINE_RETRY_MS,
            _speak_focused_caret_line,
            target_hwnd,
            target_pid,
            0,
        )
        return

    replay_focus = _parse_replay_focus(first_text)
    if replay_focus is not None:
        # Native focus events occurred while the quiet gate was closed. Reopen
        # speech first, then replay the event after NVDA's cached focus catches
        # up with the physical Windows focus.
        _quiet_until = 0.0
        target_hwnd, target_pid = replay_focus
        core.callLater(
            REPLAY_FOCUS_RETRY_MS,
            _replay_current_focus,
            target_hwnd,
            target_pid,
            0,
        )
        return

    final_focus = _parse_final_focus(first_text)
    if final_focus is not None:
        mini_tray_hwnd, token, spoken_text = final_focus
        replacement = list(sequence)
        for index, item in enumerate(replacement):
            if isinstance(item, str):
                replacement[index] = spoken_text
                break
        replacement.append(
            CallbackCommand(
                lambda hwnd=mini_tray_hwnd, value=token: _finish_restore_title(hwnd, value),
                name="MiniTray native focus handoff",
            )
        )
        return _orig_speak(replacement, *args, **kwargs)

    final_text = _parse_final(first_text)
    if final_text is not None:
        _queue_minitray_announcement(
            "final",
            final_text,
            tail_ms=350,
        )
        return

    ms = _parse_sentinel(first_text)
    if ms is not None:
        if ms:
            _quiet_until = max(
                _quiet_until,
                time.monotonic() + ms / 1000.0,
            )
        elif not _minitray_queue_busy():
            _quiet_until = 0.0
            _menu_announcement_serial += 1
            _hide_announcement_serial += 1
            _restore_final_announcement_serial += 1
        return                                  # never voice the sentinel

    alt_tab_handled, alt_tab_result = _handle_alt_tab_speech(
        sequence,
        args,
        kwargs,
    )
    if alt_tab_handled:
        return alt_tab_result

    close_probe_handled, close_probe_result = _handle_close_reveal_probe_speech(
        sequence,
        args,
        kwargs,
    )
    if close_probe_handled:
        return close_probe_result

    # MiniTray arms MTQUIET before it activates and closes a hidden window.
    # Honor that gate before the generic new-window watcher. Otherwise the
    # temporarily activated target (especially PowerShell), MiniTray popup
    # refocus events, and the next foreground application are announced before
    # MTCLOSEMENU/MTCLOSETRAY can deliver the protected close result.
    if _quiet_until:
        if time.monotonic() < _quiet_until:
            return                              # suppressed
        _quiet_until = 0.0                      # window expired

    if _handle_foreground_post_focus_speech(sequence):
        return

    new_window_handled, new_window_result = _handle_new_foreground_speech(
        sequence,
        args,
        kwargs,
    )
    if new_window_handled:
        return new_window_result

    if _shouldSuppressDesktopSpeech(sequence):
        return

    return _orig_speak(sequence, *args, **kwargs)


_speak._conceptSphereQuiet = True               # marker, see _install_speak_hook


def _install_cancel_speech_hook():
    global _orig_cancel_speech

    current = speech.cancelSpeech
    if getattr(current, "_conceptSphereQuietCancel", False):
        current = getattr(current, "_conceptSphereOrigCancel", None) or current
    if _orig_cancel_speech is None:
        _orig_cancel_speech = current

    _cancel_speech._conceptSphereOrigCancel = _orig_cancel_speech
    speech.cancelSpeech = _cancel_speech
    try:
        speech.speech.cancelSpeech = _cancel_speech
    except AttributeError:
        pass


def _remove_cancel_speech_hook():
    if _orig_cancel_speech is None:
        return

    speech.cancelSpeech = _orig_cancel_speech
    try:
        speech.speech.cancelSpeech = _orig_cancel_speech
    except AttributeError:
        pass


def _install_speak_hook():
    """Wrap speech.speak, without ever wrapping our own wrapper.

    A plugin reload gives this module a fresh namespace, so _orig_speak starts
    out None again. If terminate() did not run first, the naive version would
    capture the previous _speak and recurse.
    """
    global _orig_speak
    current = speech.speak
    if getattr(current, "_conceptSphereQuiet", False):
        current = getattr(current, "_conceptSphereOrig", None) or current
    if _orig_speak is None:
        _orig_speak = current
    _speak._conceptSphereOrig = _orig_speak
    # Patch both names: modules that did "from speech import speak" hold a
    # reference to the package attribute, others reach speech.speech.speak.
    speech.speak = _speak
    try:
        speech.speech.speak = _speak
    except AttributeError:
        pass


def _remove_speak_hook():
    if _orig_speak is None:
        return
    speech.speak = _orig_speak
    try:
        speech.speech.speak = _orig_speak
    except AttributeError:
        pass


# ------------------------------------------------------------- 2. ancestry

# Checked at speak time rather than baked into the overlay class, so the
# toggle takes effect immediately instead of only for objects created after.
_ancestryQuiet = True


class QuietAncestor:
    """Overlay class: says nothing when focus merely passes through."""

    def event_focusEntered(self):
        if _ancestryQuiet:
            return      # returning without calling super() is the suppression
        super().event_focusEntered()


# ----------------------------------------------------------- 3. Start menu

def _appName(obj):
    return (getattr(getattr(obj, "appModule", None), "appName", "") or "").lower()


def _ia2class(obj):
    # Reading IA2Attributes on these Chromium nodes can raise COMError -- the
    # log shows exactly that on every arrow press. Never let it escape, or the
    # match below is abandoned before the (reliable) name check runs.
    try:
        attrs = obj.IA2Attributes or {}
    except Exception:
        return ""
    try:
        return (attrs.get("class") or "").lower()
    except Exception:
        return ""


def _roleName(obj):
    try:
        r = obj.role
        return r.name if hasattr(r, "name") else str(r)
    except Exception:
        return "?"


def _uiaAutomationId(obj):
    # UIA objects expose UIAAutomationId; IAccessible/Chromium ones do not.
    try:
        return getattr(obj, "UIAAutomationId", "") or ""
    except Exception:
        return ""


class QuietFolderModal(NVDAObject):
    """The expanded-folder modal: announce just "expanded".

    Start names this container "<folder> expanded" and NVDA then adds its role
    ("dialog"), while the grid inside it adds "list" -- so opening a folder
    says "<folder> expanded dialog list". The folder name is redundant (you
    just pressed Enter on it), so the name is reduced to "expanded" and the
    role text is blanked.
    """

    def _get_name(self):
        return "expanded"

    def _get_roleText(self):
        return ""


class SilentContainer(NVDAObject):
    """A container NVDA neither names nor announces as a focus ancestor."""

    def _get_isPresentableFocusAncestor(self):
        return False

    def _get_name(self):
        return ""


def _is_stale_explorer_dead_frame_focus(obj):
    """True only for a delayed Explorer CabinetWClass event that is no longer foreground."""
    try:
        if (
            getattr(obj, "windowClassName", "") or ""
        ).casefold() != "cabinetwclass":
            return False

        obj_root = _root_window_handle(obj)
        if not obj_root:
            obj_root = int(getattr(obj, "windowHandle", 0) or 0)

        foreground = int(winUser.getForegroundWindow() or 0)

        # If this Explorer root really is foreground, explorerNav may perform
        # its normal dead-frame repair. Otherwise the event is stale and must
        # not redirect keyboard/NVDA focus back into Explorer.
        return bool(
            foreground
            and obj_root
            and foreground != obj_root
        )
    except Exception:
        return False


def _install_explorer_stale_focus_guard():
    """Prevent explorerNav from redirecting stale CabinetWClass focus events."""
    global _explorer_stale_focus_guard_module
    global _explorer_stale_focus_guard_class
    global _explorer_stale_focus_guard_original
    global _explorer_stale_focus_guard_wrapper

    try:
        import importlib

        explorer_module = importlib.import_module("appModules.explorer")
        app_module_class = getattr(explorer_module, "AppModule", None)
        if app_module_class is None:
            log.warning(
                "Explorer stale-focus guard: AppModule class unavailable"
            )
            return False

        current = getattr(app_module_class, "event_gainFocus", None)
        if current is None:
            log.warning(
                "Explorer stale-focus guard: event_gainFocus unavailable"
            )
            return False

        if getattr(
            current,
            "_conceptSphereStaleExplorerFocusGuard",
            False,
        ):
            _explorer_stale_focus_guard_module = explorer_module
            _explorer_stale_focus_guard_class = app_module_class
            _explorer_stale_focus_guard_wrapper = current
            _explorer_stale_focus_guard_original = getattr(
                current,
                "_conceptSphereOriginalEventGainFocus",
                None,
            )
            return True

        original = current

        def guarded_event_gainFocus(self, obj, nextHandler):
            if _is_stale_explorer_dead_frame_focus(obj):
                try:
                    foreground = int(
                        winUser.getForegroundWindow() or 0
                    )
                except Exception:
                    foreground = 0

                log.info(
                    "Blocked stale Explorer dead-frame focus before redirect: "
                    "explorerHwnd=%s foregroundHwnd=%s foregroundClass=%r",
                    _root_window_handle(obj),
                    foreground,
                    _window_class_name(foreground),
                )

                # Crucially, do not call explorerNav's original handler.
                # That handler's _ensure_item_focused redirect is what can
                # pull focus back into Explorer after another window has
                # already become foreground.
                return

            return original(self, obj, nextHandler)

        guarded_event_gainFocus._conceptSphereStaleExplorerFocusGuard = True
        guarded_event_gainFocus._conceptSphereOriginalEventGainFocus = original
        app_module_class.event_gainFocus = guarded_event_gainFocus

        _explorer_stale_focus_guard_module = explorer_module
        _explorer_stale_focus_guard_class = app_module_class
        _explorer_stale_focus_guard_original = original
        _explorer_stale_focus_guard_wrapper = guarded_event_gainFocus

        log.info("Installed Explorer stale dead-frame focus guard")
        return True
    except Exception:
        log.exception(
            "Unable to install Explorer stale dead-frame focus guard"
        )
        return False


def _remove_explorer_stale_focus_guard():
    """Restore explorerNav's original event_gainFocus method on plugin unload."""
    global _explorer_stale_focus_guard_module
    global _explorer_stale_focus_guard_class
    global _explorer_stale_focus_guard_original
    global _explorer_stale_focus_guard_wrapper

    try:
        app_module_class = _explorer_stale_focus_guard_class
        original = _explorer_stale_focus_guard_original
        wrapper = _explorer_stale_focus_guard_wrapper

        if (
            app_module_class is not None
            and original is not None
            and getattr(
                app_module_class,
                "event_gainFocus",
                None,
            ) is wrapper
        ):
            app_module_class.event_gainFocus = original
    except Exception:
        log.debugWarning(
            "Unable to remove Explorer stale dead-frame focus guard",
            exc_info=True,
        )
    finally:
        _explorer_stale_focus_guard_module = None
        _explorer_stale_focus_guard_class = None
        _explorer_stale_focus_guard_original = None
        _explorer_stale_focus_guard_wrapper = None


# ------------------------------------------------------------ the plugin

class GlobalPlugin(globalPluginHandler.GlobalPlugin):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._inputGestureObserver = self._recordInputGesture
        inputCore.decide_executeGesture.register(self._inputGestureObserver)
        _install_speak_hook()
        _install_cancel_speech_hook()
        _install_explorer_stale_focus_guard()
        global _last_foreground_hwnd
        try:
            current_foreground = int(winUser.getForegroundWindow() or 0)
            if current_foreground:
                _known_foreground_hwnds.add(current_foreground)
                _last_foreground_hwnd = current_foreground
        except Exception:
            log.debugWarning(
                "Unable to seed known foreground window set",
                exc_info=True,
            )
        log.info(
            "conceptSphereQuiet loaded - build=2026.08.07-native-dialogs-stale-explorer-guard; "
            "quiet windows, focus ancestry, Start menu, and desktop churn suppression active"
        )

    def terminate(self):
        global _quiet_until, _menu_announcement_serial, _hide_announcement_serial
        global _restore_final_announcement_serial
        global _minitray_announcement_active
        global _minitray_announcement_scheduled
        global _minitray_announcement_generation
        global _minitray_current_announcement
        global _minitray_bridge_chatter_until
        global _alt_tab_preview_wait_until
        global _alt_tab_session_until
        global _alt_tab_title_guard_until
        global _alt_tab_release_seen_at
        global _alt_tab_focus_generation
        global _alt_tab_focus_pending
        global _alt_tab_post_focus_until
        global _alt_tab_post_focus_hwnd
        global _win_m_desktop_generation
        global _win_m_desktop_active
        global _close_result_generation
        global _close_result_active
        global _close_result_synthetic_input_until
        global _last_foreground_hwnd
        global _new_foreground_generation
        global _new_foreground_watch
        global _foreground_post_focus_until
        global _foreground_post_focus_hwnd
        _quiet_until = 0.0
        _menu_announcement_serial += 1
        _hide_announcement_serial += 1
        _restore_final_announcement_serial += 1
        _minitray_announcement_generation += 1
        _minitray_announcement_queue.clear()
        _minitray_announcement_active = False
        _minitray_announcement_scheduled = False
        _minitray_current_announcement = None
        _minitray_bridge_chatter_until = 0.0
        _clear_alt_tab_state()
        _close_result_generation += 1
        _close_result_active = False
        _close_result_synthetic_input_until = 0.0
        _win_m_desktop_generation += 1
        _win_m_desktop_active = False
        _cancel_close_reveal_probe()
        _clear_new_foreground_watch()
        _clear_foreground_post_focus_guard()
        _last_foreground_hwnd = 0
        _known_foreground_hwnds.clear()
        _saved_focus_objects.clear()
        _recovered_terminal_objects.clear()
        _recovered_generic_focus_objects.clear()
        try:
            inputCore.decide_executeGesture.unregister(self._inputGestureObserver)
        except Exception:
            log.debugWarning(
                "Unable to unregister conceptSphereQuiet input observer",
                exc_info=True,
            )
        _remove_explorer_stale_focus_guard()
        _remove_cancel_speech_hook()
        _remove_speak_hook()
        super().terminate()

    def _recordInputGesture(self, gesture):
        """Mark every real NVDA input gesture and never block it."""
        global _desktop_input_serial
        global _alt_tab_preview_wait_until
        global _alt_tab_session_until
        global _alt_tab_title_guard_until
        global _alt_tab_release_seen_at
        global _alt_tab_focus_generation
        global _alt_tab_focus_pending
        global _alt_tab_post_focus_until
        global _alt_tab_post_focus_hwnd
        global _win_m_desktop_generation
        global _win_m_desktop_active
        global _last_close_gesture_hwnd
        global _last_close_gesture_at
        global _close_result_synthetic_input_until

        if _is_window_close_gesture(gesture):
            try:
                _last_close_gesture_hwnd = int(
                    winUser.getForegroundWindow() or 0
                )
            except Exception:
                _last_close_gesture_hwnd = 0
            _last_close_gesture_at = time.monotonic()
            log.debug(
                "Armed close-reveal speech buffer for Alt+F4: hwnd=%s",
                _last_close_gesture_hwnd,
            )

        if _is_alt_tab_gesture(gesture):
            _cancel_close_reveal_probe()
            _clear_new_foreground_watch()
            _clear_foreground_post_focus_guard()
            now = time.monotonic()

            had_alt_tab_speech = bool(
                _alt_tab_focus_pending or _alt_tab_post_focus_until
            )
            if had_alt_tab_speech:
                _clear_alt_tab_state()
            if had_alt_tab_speech and _orig_cancel_speech is not None:
                try:
                    _orig_cancel_speech()
                except Exception:
                    log.debugWarning(
                        "Unable to cancel previous Alt+Tab title while cycling",
                        exc_info=True,
                    )

            _release_minitray_speech_for_alt_tab()
            _alt_tab_preview_wait_until = (
                now + ALT_TAB_PREVIEW_WAIT_MS / 1000.0
            )
            _alt_tab_session_until = (
                now + ALT_TAB_SESSION_MAX_MS / 1000.0
            )
            _desktop_input_serial += 1
            return True

        desktop_shortcut = _windows_desktop_gesture_name(gesture)
        if desktop_shortcut:
            _cancel_close_reveal_probe()
            try:
                already_on_desktop = _isDesktopIconView(api.getFocusObject())
            except Exception:
                already_on_desktop = False

            _clear_new_foreground_watch()
            _clear_foreground_post_focus_guard()
            _clear_alt_tab_state()
            _cancel_minitray_speech_for_user_input(desktop_shortcut)

            if already_on_desktop:
                _start_silent_desktop_shortcut()
            else:
                _start_win_m_desktop_focus()

            _desktop_input_serial += 1
            return True

        if _is_modifier_only_gesture(gesture):
            # A reported Alt release must not reopen the late native title
            # window. The physical key state is handled by the timer poller.
            _desktop_input_serial += 1
            return True

        if (
            _close_result_active
            and time.monotonic() < _close_result_synthetic_input_until
        ):
            # Win+B and Right Arrow are injected by the close-focus transaction
            # itself. Do not treat them as user navigation that cancels it.
            _desktop_input_serial += 1
            return True

        _cancel_close_reveal_probe()
        _win_m_desktop_generation += 1
        _win_m_desktop_active = False
        _clear_new_foreground_watch()
        _clear_foreground_post_focus_guard()
        _clear_alt_tab_state()

        if _is_minitray_command_gesture(gesture):
            # A second MiniTray action remains queueable and does not cancel the
            # currently speaking MiniTray result.
            _desktop_input_serial += 1
            return True

        # Arrow keys, menu navigation, application shortcuts and NVDA commands
        # take immediate ownership of speech.
        _cancel_minitray_speech_for_user_input(
            "+".join(sorted(_normalized_gesture_keys(gesture))) or "user input"
        )
        _ensure_terminal_focus_before_input()
        _desktop_input_serial += 1

        # Native desktop selection events stay suppressed because refresh churn
        # produces indistinguishable events. Explicitly report Ctrl+Space
        # toggles and plain Space selection after Explorer updates the item.
        gesture_kind = _desktopSelectionGestureKind(gesture)
        if gesture_kind is not None:
            try:
                obj = api.getFocusObject()
                if _isDesktopListItem(obj):
                    was_selected = _desktopItemIsSelected(obj)
                    # Plain Space is only meaningful when it changes an
                    # unselected icon to selected. If the icon is already
                    # selected, do not schedule a redundant "<icon> selected"
                    # announcement. Ctrl+Space remains a toggle and is always
                    # reported after Explorer updates the state.
                    if gesture_kind == "select" and was_selected:
                        return True
                    core.callLater(
                        DESKTOP_SELECTION_REPORT_RETRY_MS,
                        _reportDesktopSelectionGesture,
                        _desktopObjectKey(obj),
                        was_selected,
                        gesture_kind,
                        0,
                    )
            except Exception:
                log.exception(
                    "conceptSphereQuiet could not schedule desktop selection report"
                )
        return True

    # -- overlay classes: Start menu first (it returns early), then ancestry

    def chooseNVDAObjectOverlayClasses(self, obj, clsList):
        # Never touch NVDA's own secure screens -- losing announcements inside
        # them would be its own problem.
        if globalVars.appArgs.secure:
            return
        try:
            role = obj.role
        except Exception:
            return
        if self._startMenuOverlay(obj, clsList, role):
            return
        if role in SILENCED_ROLES:
            clsList.insert(0, QuietAncestor)

    def _startMenuOverlay(self, obj, clsList, role):
        """True if an overlay was inserted for a Start menu container.

        COST GATE. This method runs for every object NVDA constructs, so the
        expensive checks are ordered behind cheap ones:

          1. appModule.appName is a plain attribute already on the object --
             no cross-process traffic. Anything not in the Start/Search hosts
             returns here, which is every Explorer object, every context menu,
             everything you actually spend the day in.
          2. Leaf roles are dropped: neither container we are looking for is a
             list item, button or menu item, and leaves are the bulk of the
             objects inside the Start menu itself.
          3. UIAAutomationId is read only for genuine UIA objects. It is a
             cross-process UIA fetch, and IAccessible/Chromium nodes (which is
             what the Start context menu is made of) never carry one -- the
             old code paid for that fetch on every object anyway.
        """
        if _appName(obj) not in HOST_APPS:
            return False
        if role in LEAF_ROLES:
            return False
        try:
            # --- expanded folder in the app list (UIA, StartMenuExperienceHost)
            if UIA is not None and isinstance(obj, UIA):
                aid = _uiaAutomationId(obj)
                if aid == "StartFolderModal":
                    clsList.insert(0, QuietFolderModal)
                    return True
                if aid == "LevelOneGridView":
                    clsList.insert(0, SilentContainer)
                    return True

            # --- Start context menu (Chromium, SearchHost) ---
            if role != LIST_ROLE:
                return False
            # Name first: the container is literally named "Context Menu", and
            # the name is readable when the IA2 attributes are not.
            try:
                name = (obj.name or "").strip().lower()
            except Exception:
                name = ""
            if "context menu" in name or "menu" in _ia2class(obj):
                clsList.insert(0, SilentContainer)
                return True
        except Exception:
            pass
        return False

    # -- desktop refresh churn

    def event_nameChange(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced nameChange for %r", getattr(obj, "name", None))
            return
        nextHandler()

    def event_reorder(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced reorder")
            return
        nextHandler()

    def event_show(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced show")
            return
        nextHandler()

    def event_stateChange(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced stateChange for %r", getattr(obj, "name", None))
            return
        nextHandler()

    def event_selection(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced selection for %r", getattr(obj, "name", None))
            return
        nextHandler()

    def event_selectionAdd(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced selectionAdd for %r", getattr(obj, "name", None))
            return
        nextHandler()

    def event_selectionRemove(self, obj, nextHandler):
        if _isDesktopIconView(obj):
            _debugDesktop("silenced selectionRemove for %r", getattr(obj, "name", None))
            return
        nextHandler()

    def event_foreground(self, obj, nextHandler):
        global _last_foreground_hwnd

        try:
            hwnd = _root_window_handle(obj)
            if not hwnd:
                hwnd = int(getattr(obj, "windowHandle", 0) or 0)
            if not hwnd:
                hwnd = int(winUser.getForegroundWindow() or 0)

            previous_hwnd = _last_foreground_hwnd
            was_known = hwnd in _known_foreground_hwnds
            changed_window = bool(
                previous_hwnd
                and hwnd
                and previous_hwnd != hwnd
            )

            # A newer foreground event supersedes an older delayed probe.
            _cancel_close_reveal_probe()

            if hwnd:
                _known_foreground_hwnds.add(hwnd)
                _last_foreground_hwnd = hwnd

            native_reason = _window_requires_native_speech(hwnd, obj)
            if native_reason:
                # Dialogs, menus, Start/Search, shell flyouts and other
                # special surfaces remain entirely under NVDA's native event
                # and speech handling. In particular, do NOT start the
                # close-reveal speech buffer for these windows.
                _clear_new_foreground_watch()
                _clear_foreground_post_focus_guard()
                log.info(
                    "Preserved fully native foreground behavior: "
                    "hwnd=%s reason=%s",
                    hwnd,
                    native_reason,
                )
            elif not was_known:
                _watch_new_foreground_window(
                    obj,
                    hwnd,
                    "new window or application",
                )
            elif changed_window:
                if not _window_exists(previous_hwnd):
                    _watch_new_foreground_window(
                        obj,
                        hwnd,
                        "revealed after previous window closed",
                    )
                else:
                    # Ordinary application windows still use the deferred
                    # close-reveal transaction so Explorer close chatter can
                    # be suppressed deterministically.
                    _schedule_close_reveal_probe(
                        previous_hwnd,
                        hwnd,
                    )
        except Exception:
            log.exception("Unable to watch deterministic foreground transition")
        nextHandler()

    def event_gainFocus(self, obj, nextHandler):
        global _desktop_last_focus_key, _desktop_last_focus_input_serial
        global _desktop_last_spoken_key, _desktop_last_spoken_input_serial

        try:
            foreground_hwnd = int(winUser.getForegroundWindow() or 0)
            rec = _recovered_terminal_objects.get(foreground_hwnd)
            if rec and not _is_terminal_object(obj):
                root_hwnd = _root_window_handle(obj)
                if not root_hwnd or root_hwnd == foreground_hwnd:
                    core.callLater(
                        0,
                        _repair_terminal_text_area,
                        foreground_hwnd,
                        rec.get("pid", 0),
                        0,
                    )
                    log.debug(
                        "MiniTray redirected late pane focus to terminal Text Area: %s",
                        _focus_object_summary(obj),
                    )
                    return
        except Exception:
            log.exception("MiniTray terminal focus redirection failed")

        try:
            if _isDesktopIconView(obj):
                role = obj.role
                if role == LISTITEM_ROLE:
                    key = _desktopObjectKey(obj)
                    if (
                        key == _desktop_last_focus_key
                        and _desktop_input_serial == _desktop_last_focus_input_serial
                    ):
                        _debugDesktop(
                            "silenced duplicate gainFocus for %r",
                            getattr(obj, "name", None),
                        )
                        return
                    _desktop_last_focus_key = key
                    _desktop_last_focus_input_serial = _desktop_input_serial
                elif role == LIST_ROLE:
                    # Allow the desktop list container itself to be announced.
                    # Only duplicate desktop-icon LISTITEM focus events are
                    # suppressed by this guard.
                    _debugDesktop(
                        "allowed list-container gainFocus for %r",
                        getattr(obj, "name", None),
                    )
            else:
                # Leaving the desktop resets both guards, so returning to the
                # same icon later is announced as a fresh focus transition.
                _desktop_last_focus_key = None
                _desktop_last_focus_input_serial = -1
                _desktop_last_spoken_key = None
                _desktop_last_spoken_input_serial = -1
        except Exception:
            log.exception("conceptSphereQuiet desktop gainFocus guard failed")

        # Existing Start-menu diagnostic support.
        if DEBUG_START_CHAIN:
            try:
                interesting = (
                    _appName(obj) in HOST_APPS
                    and (obj.role == LISTITEM_ROLE or _uiaAutomationId(obj))
                )
                if interesting:
                    parts = []
                    cur = obj
                    depth = 0
                    while cur is not None and depth < 6:
                        parts.append(
                            "%d: role=%s name=%r aid=%r class=%r"
                            % (depth, _roleName(cur), cur.name,
                               _uiaAutomationId(cur), _ia2class(cur))
                        )
                        try:
                            cur = cur.parent
                        except Exception:
                            cur = None
                        depth += 1
                    log.info("conceptSphereQuiet chain -> " + " | ".join(parts))
            except Exception:
                pass
        nextHandler()

    # -- scripts

    @script(
        description="Report quiet-window status",
    )
    def script_quietStatus(self, gesture):
        global _quiet_until
        remaining = _quiet_until - time.monotonic() if _quiet_until else 0
        if remaining > 0:
            _quiet_until = 0.0                  # also an escape hatch
            ui.message("Quiet window cleared, had %d milliseconds left"
                       % int(remaining * 1000))
        else:
            ui.message("ConceptSphere quiet plugin loaded, not currently quiet")

    @script(
        description="Toggle suppression of focus ancestry announcements",
        gesture="kb:NVDA+shift+q",
    )
    def script_toggleQuietAncestry(self, gesture):
        global _ancestryQuiet
        _ancestryQuiet = not _ancestryQuiet
        ui.message(
            "Focus ancestry announcements off" if _ancestryQuiet
            else "Focus ancestry announcements on"
        )
