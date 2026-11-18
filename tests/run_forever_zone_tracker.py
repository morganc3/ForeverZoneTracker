"""Install requirements-test.txt, then run this file to test under Lua 5.1."""
from pathlib import Path
from lupa.lua51 import LuaRuntime

root = Path(__file__).resolve().parent.parent
runtime = LuaRuntime()
runtime.globals().ADDON_DIR = str(root / "ForeverZoneTracker")
runtime.execute((root / "tests" / "test_forever_zone_tracker.lua").read_text(encoding="utf-8"))
