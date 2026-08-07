# VAIO phantom-window focus guard for NVDA
#
# Suppresses focus/foreground announcements from known VAIO service windows
# and returns Windows focus to the desktop with Win+D.
#
# Install this file in an NVDA add-on's globalPlugins directory, then restart
# NVDA or choose NVDA menu > Tools > Reload plugins.

from __future__ import annotations

from typing import Any

import core
import globalPluginHandler
import keyboardHandler
from logHandler import log
import winUser


# These strings are checked case-insensitively against:
# - NVDA object names
# - NVDA window class/text properties
# - native Win32 window titles and class names
_TARGET_WINDOW_IDENTIFIERS = frozenset(
	identifier.casefold()
	for identifier in (
		"VESKeyboardBacklightObjectWnd",
		"VAIOControlCenterStartupFormWindow",
		"VVCCStartupFormWindow",
	)
)

# The first attempt is delayed slightly so the foreground transition can settle.
# A second guarded attempt handles a window that immediately steals focus again.
_RECOVERY_DELAYS_MS = (75, 350)


def _normalise(value: Any) -> str:
	if not isinstance(value, str):
		return ""
	return value.strip().casefold()


def _safeObjectProperty(obj: Any, propertyName: str) -> str:
	try:
		return _normalise(getattr(obj, propertyName, ""))
	except Exception:
		return ""


def _windowIdentifiers(hwnd: int) -> set[str]:
	if not hwnd:
		return set()

	identifiers: set[str] = set()
	try:
		identifiers.add(_normalise(winUser.getWindowText(hwnd)))
	except Exception:
		pass
	try:
		identifiers.add(_normalise(winUser.getClassName(hwnd)))
	except Exception:
		pass

	identifiers.discard("")
	return identifiers


def _relatedWindowHandles(hwnd: int) -> set[int]:
	if not hwnd:
		return set()

	handles = {hwnd}
	for relation in (winUser.GA_ROOT, winUser.GA_ROOTOWNER):
		try:
			relatedHwnd = winUser.getAncestor(hwnd, relation)
		except Exception:
			continue
		if relatedHwnd:
			handles.add(relatedHwnd)
	return handles


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	"""Suppress known VAIO phantom windows and restore focus to the desktop."""

	def __init__(self, *args, **kwargs):
		super().__init__(*args, **kwargs)
		self._recoveryPending = False
		self._recoveryTimer = None
		self._initialCheckTimer = None
		try:
			# Also handle the case where the phantom window became foreground
			# just before NVDA finished loading this plugin.
			self._initialCheckTimer = core.callLater(
				1000,
				self._checkInitialForeground,
			)
		except Exception:
			log.exception(
				"VAIO phantom-window guard could not schedule its startup check"
			)

	def terminate(self):
		timers = (self._recoveryTimer, self._initialCheckTimer)
		self._recoveryTimer = None
		self._initialCheckTimer = None
		self._recoveryPending = False
		for timer in timers:
			if timer is not None:
				try:
					timer.Stop()
				except Exception:
					pass
		super().terminate()

	def _checkInitialForeground(self) -> None:
		self._initialCheckTimer = None
		if self._foregroundMatchesTarget():
			self._scheduleDesktopRecovery()

	def _objectMatchesTarget(self, obj: Any) -> bool:
		identifiers = {
			_safeObjectProperty(obj, "name"),
			_safeObjectProperty(obj, "windowText"),
			_safeObjectProperty(obj, "windowClassName"),
		}
		identifiers.discard("")

		try:
			hwnd = int(getattr(obj, "windowHandle", 0) or 0)
		except Exception:
			hwnd = 0

		for relatedHwnd in _relatedWindowHandles(hwnd):
			identifiers.update(_windowIdentifiers(relatedHwnd))

		return not identifiers.isdisjoint(_TARGET_WINDOW_IDENTIFIERS)

	def _foregroundMatchesTarget(self) -> bool:
		try:
			foregroundHwnd = winUser.getForegroundWindow()
		except Exception:
			return False

		for relatedHwnd in _relatedWindowHandles(foregroundHwnd):
			if not _windowIdentifiers(relatedHwnd).isdisjoint(
				_TARGET_WINDOW_IDENTIFIERS
			):
				return True
		return False

	def _scheduleDesktopRecovery(self) -> None:
		if self._recoveryPending:
			return

		self._recoveryPending = True
		try:
			self._recoveryTimer = core.callLater(
				_RECOVERY_DELAYS_MS[0],
				self._recoverDesktopFocus,
				0,
			)
		except Exception:
			self._recoveryPending = False
			self._recoveryTimer = None
			log.exception(
				"VAIO phantom-window guard could not schedule focus recovery"
			)

	def _recoverDesktopFocus(self, attemptIndex: int) -> None:
		self._recoveryTimer = None

		# Never send Win+D after the user or Windows has already moved focus
		# somewhere legitimate.
		if not self._foregroundMatchesTarget():
			self._recoveryPending = False
			return

		try:
			keyboardHandler.KeyboardInputGesture.fromName("windows+d").send()
			log.debug(
				"VAIO phantom-window guard sent Win+D "
				f"(attempt {attemptIndex + 1})"
			)
		except Exception:
			self._recoveryPending = False
			log.exception(
				"VAIO phantom-window guard could not send Win+D"
			)
			return

		nextAttemptIndex = attemptIndex + 1
		if nextAttemptIndex >= len(_RECOVERY_DELAYS_MS):
			self._recoveryPending = False
			return

		try:
			self._recoveryTimer = core.callLater(
				_RECOVERY_DELAYS_MS[nextAttemptIndex],
				self._recoverDesktopFocus,
				nextAttemptIndex,
			)
		except Exception:
			self._recoveryPending = False
			self._recoveryTimer = None
			log.exception(
				"VAIO phantom-window guard could not schedule its retry"
			)

	def _handleFocusEvent(self, obj: Any, nextHandler) -> None:
		if not self._objectMatchesTarget(obj):
			nextHandler()
			return

		# Intentionally do not call nextHandler. This prevents NVDA's normal
		# foreground/focus presentation from announcing the phantom window.
		self._scheduleDesktopRecovery()

	def event_foreground(self, obj, nextHandler):
		self._handleFocusEvent(obj, nextHandler)

	def event_gainFocus(self, obj, nextHandler):
		self._handleFocusEvent(obj, nextHandler)

	def event_nameChange(self, obj, nextHandler):
		# Cover late title changes, but only while the phantom window is
		# genuinely foreground so unrelated background events are untouched.
		if self._objectMatchesTarget(obj) and self._foregroundMatchesTarget():
			self._scheduleDesktopRecovery()
			return
		nextHandler()
