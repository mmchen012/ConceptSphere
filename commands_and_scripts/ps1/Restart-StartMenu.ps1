# Restart-StartMenu.ps1
# Restarts the Windows Start menu host to clear glitches (pins that don't render,
# tab order that has drifted, etc.). Windows relaunches it automatically.
# Your EnhancedStartMenu AHK script does NOT need restarting -- it re-attaches to
# the new Start window on its own.

Stop-Process -Name 'StartMenuExperienceHost' -Force -ErrorAction SilentlyContinue

# Optional: also refresh the search host, which the search box can live in.
Stop-Process -Name 'SearchHost' -Force -ErrorAction SilentlyContinue
