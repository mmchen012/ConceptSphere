# conceptSphereQuiet.py - NVDA global plugin
#
# One plugin in place of three. Replaces, and you must DELETE:
#     globalPlugins\minitrayQuiet.py
#     globalPlugins\quietFocusAncestry.py
#     globalPlugins\startMenuContextMenuFix.py
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
# INSTALL
#   1. NVDA -> Preferences -> Settings -> Advanced
#      Tick "Enable loading custom code from Developer Scratchpad Directory".
#   2. NVDA -> Tools -> Open developer scratchpad directory
#   3. Save as:  globalPlugins\conceptSphereQuiet.py
#      and delete the three files listed at the top.
#   4. Reload with NVDA+Ctrl+F3, or restart NVDA.
#
# GESTURES
#   NVDA+Shift+Q   toggle focus ancestry suppression
#   Quiet-window status remains available in Input Gestures, unassigned.
#
# SAFETY
#   A quiet window is capped at MAX_QUIET_MS however long is requested, so a
#   caller crashing between "open" and "close" cannot mute NVDA for more than
#   a second and a half.

import time

import globalPluginHandler
import globalVars
import speech
import ui
import controlTypes
from NVDAObjects import NVDAObject
from logHandler import log
from scriptHandler import script

# ---------------------------------------------------------------- settings

# Hard ceiling on a quiet window, in milliseconds.
MAX_QUIET_MS = 1500

# Sentinel prefixes accepted. MTQUIET is what MiniTray and ConsoleSelectAll
# already send; CSQUIET is the neutral name for anything written later.
OPEN_PREFIXES = ("\x01MTQUIET:", "\x01CSQUIET:")
CLOSE_CHAR = "\x01"

# Roles whose focusEntered announcement is dropped. Trim this to taste --
# removing Role.WINDOW keeps "<app> window" while still dropping the duplicate
# "<title> document" that follows it in a browser.
SILENCED_ROLES = {
    controlTypes.Role.WINDOW,
    controlTypes.Role.DOCUMENT,
}

# Set True to log the ancestor chain of focused Start menu items. Only needed
# if the context-menu match stops working and the container has to be
# identified again.
DEBUG_START_CHAIN = False

HOST_APPS = ("searchhost", "startmenuexperiencehost")

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

# Only genuine UIA objects can carry a UIAAutomationId. The Start context menu
# is Chromium/IAccessible and never does, so this import turns the fetch off
# for it entirely.
try:
    from NVDAObjects.UIA import UIA
except Exception:
    UIA = None

# ---------------------------------------------------------------- 1. quiet

_quiet_until = 0.0          # time.monotonic() value; 0 = not quiet
_orig_speak = None


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


def _speak(sequence, *args, **kwargs):
    global _quiet_until

    ms = _parse_sentinel(_first_string(sequence))
    if ms is not None:
        _quiet_until = (time.monotonic() + ms / 1000.0) if ms else 0.0
        return                                  # never voice the sentinel

    if _quiet_until:
        if time.monotonic() < _quiet_until:
            return                              # suppressed
        _quiet_until = 0.0                      # window expired

    return _orig_speak(sequence, *args, **kwargs)


_speak._conceptSphereQuiet = True               # marker, see _install_speak_hook


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


# ------------------------------------------------------------ the plugin

class GlobalPlugin(globalPluginHandler.GlobalPlugin):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        _install_speak_hook()
        log.info(
            "conceptSphereQuiet loaded - NVDA+shift+q ancestry toggle; "
            "quiet status gesture unassigned"
        )

    def terminate(self):
        global _quiet_until
        _quiet_until = 0.0
        _remove_speak_hook()
        super().terminate()

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

    # -- diagnostic only

    def event_gainFocus(self, obj, nextHandler):
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
