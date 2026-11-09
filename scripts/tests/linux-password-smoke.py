#!/usr/bin/env python3
"""Real GTK password observations on a private Xvfb/D-Bus desktop; fake secrets only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile

SECRET = "ocu-password-probe"
PUBLIC = "ocu-public-probe"


def fixture(version):
    import gi
    gi.require_version("Gtk", version + ".0")
    from gi.repository import Gtk, GLib, Gdk
    GLib.set_prgname("ocu-password-gtk" + version)
    if version == "3":
        win = Gtk.Window(title="OCU password probe")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        win.add(box)
        password = Gtk.Entry()
        password.set_visibility(False)
        ordinary = Gtk.Entry()
        for child in (password, ordinary):
            box.pack_start(child, False, False, 0)
        password.set_text(SECRET)
        ordinary.set_text(PUBLIC)
        win.show_all()
        window_handle = win.get_window()
        window_handle.focus(Gdk.CURRENT_TIME)
        password.grab_focus()
        password.select_region(0, -1)
        Gtk.main()
    else:
        app = Gtk.Application(application_id="dev.opencomputeruse.PasswordProbe")
        def activate(app):
            win = Gtk.ApplicationWindow(application=app, title="OCU password probe")
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            win.set_child(box)
            password = Gtk.PasswordEntry()
            ordinary = Gtk.Entry()
            password.set_text(SECRET)
            ordinary.set_text(PUBLIC)
            box.append(password)
            box.append(ordinary)
            win.present()
            password.grab_focus()
            password.select_region(0, -1)
        app.connect("activate", activate)
        app.run([])


def main(args):
    spec = importlib.util.spec_from_file_location("runtime", args.runtime)
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    for version in ("3", "4"):
        process = subprocess.Popen([sys.executable, __file__, "--fixture", version])
        try:
            deadline = time.monotonic() + 20
            while True:
                try:
                    snapshot = runtime.build_snapshot(str(process.pid), include_screenshot=False, text_limit=None)
                    encoded = json.dumps(snapshot)
                    assert PUBLIC in encoded, "ordinary field missing"
                    assert "password" in encoded.lower(), "password field missing"
                    break
                except Exception:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(.1)
            if args.native:
                response = subprocess.run([args.native, "call", "get_app_state", "--args",
                    json.dumps({"app": str(process.pid), "include_screenshot": False, "text_limit": "max"})],
                    capture_output=True, text=True, timeout=40)
                assert response.returncode == 0, response.stderr + response.stdout
                assert SECRET not in response.stdout and PUBLIC in response.stdout, "native output filter failed"
                print("GTK%s native CLI response: ordinary text present, password withheld" % version)
            leaked = SECRET in encoded
            if args.expect_leak and version == "4":
                assert leaked, "baseline did not reproduce GTK4 leak on this toolkit version"
            else:
                assert not leaked, "password entered snapshot"
            print("GTK%s complete snapshot: ordinary text present, password %s" % (version, "LEAK reproduced" if leaked else "withheld"))
            app = runtime.resolve_app(str(process.pid))
            _, window = runtime.main_window(app)
            secret_node = runtime.find_first(window, runtime.is_password) if hasattr(runtime, "is_password") else None
            if secret_node is not None:
                with_interface = runtime.supports_interface(secret_node, "Text")
                assert with_interface, "password fixture has no Text interface"
                # Check selected text directly as well: GTK versions differ in whether focus is exposed.
                details = runtime.focus_details(window)
                assert SECRET not in json.dumps(details)
                print("GTK%s focus summary: %s" % (version, details[0]))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", choices=("3", "4"))
    parser.add_argument("--runtime", default="apps/OpenComputerUseLinux/runtime.py")
    parser.add_argument("--native")
    parser.add_argument("--expect-leak", action="store_true")
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture)
    else:
        with tempfile.TemporaryDirectory(prefix="ocu-password-runtime-") as directory:
            os.environ.setdefault("XDG_RUNTIME_DIR", directory)
            main(args)
