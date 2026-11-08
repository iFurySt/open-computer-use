#!/usr/bin/env python3
"""Exercise native Linux MCP observation and actions against an isolated GTK fixture."""

import argparse
import base64
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import struct
import sys
import tempfile
import time
from unittest import mock


def fixture(name, state_file, focus_checks=False, hidden_checks=False):
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GLib, Gtk

    GLib.set_prgname(name)
    GLib.set_application_name(name)
    window = Gtk.Window(title=name)
    window.set_default_size(500, 240)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=20)
    notebook = None
    if hidden_checks:
        notebook = Gtk.Notebook()
        window.add(notebook)
        notebook.append_page(box, Gtk.Label(label="Main page"))
        hidden_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=20)
        hidden_entry = Gtk.Entry(text="hidden-value-中文🙂")
        hidden_entry.get_accessible().set_name("Hidden input")
        hidden_button = Gtk.Button(label="Return page")
        hidden_box.pack_start(hidden_entry, False, False, 0)
        hidden_box.pack_start(hidden_button, False, False, 0)
        notebook.append_page(hidden_box, Gtk.Label(label="Other page"))
        reveal = Gtk.Button(label="Reveal page")
        box.pack_start(reveal, False, False, 0)
    else:
        window.add(box)
    entry = Gtk.Entry()
    entry.get_accessible().set_name("Read-back input")
    button = Gtk.Button(label="Increment")
    label = Gtk.Label(label="Counter: 0")
    for widget in (entry, button, label):
        box.pack_start(widget, False, False, 0)
    state = {"count": 0, "text": "", "activated": 0}

    def publish(*_args):
        state["text"] = entry.get_text()
        state["focused"] = entry.has_focus()
        bounds = entry.get_selection_bounds()
        state["selected"] = entry.get_text()[bounds[0]:bounds[1]] if bounds else ""
        if notebook is not None:
            state["page"] = notebook.get_current_page()
        temporary = state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(state))
        temporary.replace(state_file)

    def increment(*_args):
        state["count"] += 1
        label.set_text("Counter: " + str(state["count"]))
        entry.grab_focus()
        window.get_window().focus(Gdk.CURRENT_TIME)
        publish()

    def activate(*_args):
        state["activated"] += 1
        publish()

    button.connect("clicked", increment)
    entry.connect("changed", publish)
    entry.connect("activate", activate)
    entry.connect("notify::selection-bound", publish)
    entry.connect("notify::cursor-position", publish)
    entry.connect("notify::has-focus", publish)
    if notebook is not None:
        reveal.connect("clicked", lambda *_: notebook.set_current_page(1))
        hidden_button.connect("clicked", lambda *_: notebook.set_current_page(0))
        notebook.connect("switch-page", lambda *_: GLib.idle_add(publish))
    window.connect("destroy", Gtk.main_quit)
    window.show_all()
    entry.grab_focus()
    window.get_window().focus(Gdk.CURRENT_TIME)
    if focus_checks:
        def initialize_selection():
            entry.grab_focus()
            window.get_window().focus(Gdk.CURRENT_TIME)
            if not entry.has_focus():
                return True
            entry.set_text("prefix-中文🙂-suffix")
            entry.select_region(7, 10)
            publish()
            return False
        GLib.timeout_add(20, initialize_selection)
    publish()
    Gtk.main()


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("Timed out: " + description)


class MCP:
    def __init__(self, native, read_back, stderr, env_overrides=None):
        env = dict(os.environ)
        env.update(env_overrides or {})
        env.pop("OPEN_COMPUTER_USE_ACTION_READ_BACK", None)
        if read_back is not None:
            env["OPEN_COMPUTER_USE_ACTION_READ_BACK"] = read_back
        self.process = subprocess.Popen(
            [native, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, env=env, text=True,
        )
        self.next_id = 0
        try:
            self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                        "clientInfo": {"name": "linux-read-back-smoke", "version": "1"}})
            self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            self.process.stdin.flush()
        except Exception:
            self.close()
            raise

    def request(self, method, params):
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id,
                                            "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        ready, _, _ = select.select([self.process.stdout], [], [], 40)
        if not ready:
            raise AssertionError("MCP response timed out: " + method)
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("Native MCP exited before responding: " + method)
        response = json.loads(line)
        assert response.get("id") == self.next_id, response
        assert "error" not in response, response
        return response["result"]

    def call(self, tool, app, **arguments):
        return self.request("tools/call", {"name": tool, "arguments": {"app": app, **arguments}})

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def text(result):
    return "\n".join(item["text"] for item in result["content"] if item["type"] == "text")


def expect_snapshot(result):
    assert not result.get("isError"), result
    assert "Window:" in text(result) and "Read-back input" in text(result), text(result)


def element_index(result, name):
    matches = re.findall(r"^\s*(\d+)\s+[^\n]*" + re.escape(name) + r"(?:\s|$)", text(result), re.MULTILINE)
    assert len(matches) == 1, (name, text(result))
    return matches[0]


def check_focus(client, name, state_file):
    wait_for(lambda: json.loads(state_file.read_text())["focused"] and
             json.loads(state_file.read_text())["selected"] == "中文🙂", "fixture focus and selection")
    marker = "[Focus search incomplete: node/depth budget reached.]"
    for limits in ({"max_tree_depth": 1}, {"max_tree_nodes": 2}):
        result = client.call("get_app_state", name, **limits)
        assert not result.get("isError"), result
        assert marker in text(result), text(result)
        assert "Selected text:" not in text(result), text(result)
        assert "The focused UI element" not in text(result), text(result)
    observed = client.call("get_app_state", name, max_tree_depth=10)
    expect_snapshot(observed)
    actual = json.loads(state_file.read_text())
    assert actual["focused"] and actual["selected"] == "中文🙂", actual
    assert "Selected text: [中文🙂]" in text(observed), text(observed)
    assert marker not in text(observed), text(observed)
    limited = client.call("get_app_state", name, text_limit=2)
    assert not limited.get("isError"), limited
    assert "Selected text: [中文...]" in text(limited), text(limited)
    result = client.call("press_key", name, key="Right")
    assert not result.get("isError"), result
    wait_for(lambda: json.loads(state_file.read_text())["selected"] == "", "selection cleared by real key")
    observed = client.call("get_app_state", name)
    expect_snapshot(observed)
    assert "Selected text:" not in text(observed), text(observed)
    assert "The focused UI element is text Read-back input." in text(observed), text(observed)
    print("Focus smoke: node/depth limits, Unicode selection, text limit and focus summary passed.")


def check_hidden(client, native, name, state_file, stderr):
    # Import the production bridge and wrap its real property helpers. All
    # objects below are remote GTK/AT-SPI accessibles, not synthetic records.
    runtime_path = Path(__file__).resolve().parents[2] / "apps/OpenComputerUseLinux/runtime.py"
    spec = importlib.util.spec_from_file_location("gtk_smoke_runtime", runtime_path)
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    app = runtime.resolve_app(name)
    window_index, window = runtime.main_window(app)
    bounds = runtime.extents(window)
    flag = "OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN"
    helpers = ("relative_frame", "accessible_id", "element_value", "action_names")

    def render(enabled):
        with ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, {flag: "1" if enabled else "0"}))
            calls = [stack.enter_context(mock.patch.object(runtime, key, wraps=getattr(runtime, key)))
                     for key in helpers]
            records, lines = runtime.render_tree(window, bounds, [window_index])
            return records, lines, [query.call_count for query in calls]

    full, _, full_calls = render(False)
    light, _, light_calls = render(True)
    identity = ("index", "runtimeId", "name", "controlType", "localizedControlType")
    assert [[row[key] for key in identity] for row in full] == [
        [row[key] for key in identity] for row in light], (full, light)
    omitted = [row for row in light if row.get("detailsOmitted")]
    assert any(row["name"] == "Hidden input" for row in omitted), light
    assert next(row for row in full if row["name"] == "Hidden input")["value"] == "hidden-value-中文🙂", full
    for original, row in zip(full, light):
        node = runtime.resolve_path(app, row["runtimeId"])
        showing = node.get_state_set().contains(runtime.Atspi.StateType.SHOWING)
        assert bool(row.get("detailsOmitted")) == (not showing), row
        if row.get("detailsOmitted"):
            assert row["frame"] is None and row["value"] == "" and row["actions"] == [], row
            assert row["className"] == "" and row["automationId"] == "", row
        else:
            assert row == original, (original, row)
    assert full_calls == [len(full)] * len(helpers), full_calls
    assert light_calls == [len(full) - len(omitted)] * len(helpers), light_calls
    print(f"Real AT-SPI tree: {len(full)} stable nodes, {len(omitted)} hidden; "
          f"property helpers {sum(full_calls)} → {sum(light_calls)} (not a latency benchmark).")

    baseline = MCP(native, "0", stderr, {flag: "0"})
    try:
        default = baseline.call("get_app_state", name)
        optimized = client.call("get_app_state", name)
        expect_snapshot(default)
        expect_snapshot(optimized)
        assert "[hidden details omitted]" not in text(default), text(default)
        assert "hidden-value-中文🙂" in text(default), text(default)
        assert "hidden-value-中文🙂" not in text(optimized), text(optimized)
        assert "[hidden details omitted]" in text(optimized), text(optimized)
        for title in ("Read-back input", "Increment", "Hidden input", "Return page", "Reveal page"):
            assert element_index(default, title) == element_index(optimized, title), title
    finally:
        baseline.close()

    def page_is(number):
        return json.loads(state_file.read_text())["page"] == number

    result = client.call("click", name, element_index=element_index(optimized, "Reveal page"),
                         click_method="accessibility")
    assert not result.get("isError"), result
    wait_for(lambda: page_is(1), "real notebook reveal")
    shown = client.call("get_app_state", name)
    expect_snapshot(shown)
    row = next(line for line in text(shown).splitlines()
               if re.match(r"\s*\d+\s", line) and "Hidden input" in line)
    assert "hidden-value-中文🙂" in row and "[hidden details omitted]" not in row and "Frame:" in row, row
    result = client.call("click", name, element_index=element_index(shown, "Return page"),
                         click_method="accessibility")
    assert not result.get("isError"), result
    wait_for(lambda: page_is(0), "real notebook return")
    print("Native MCP: default/opt-in output, stable indexes, page changes and full detail restoration passed.")


def check_observation(client, native, name, state_file, stderr):
    wait_for(lambda: json.loads(state_file.read_text())["selected"] == "中文🙂", "fixture selection")
    runtime_path = Path(__file__).resolve().parents[2] / "apps/OpenComputerUseLinux/runtime.py"
    spec = importlib.util.spec_from_file_location("observation_smoke_runtime", runtime_path)
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)

    def png(data):
        raw = base64.b64decode(data, validate=True)
        assert raw[:8] == b"\x89PNG\r\n\x1a\n" and raw[12:16] == b"IHDR", raw[:24]
        width, height = struct.unpack(">II", raw[16:24])
        assert width > 0 and height > 0, (width, height)

    def snapshot(**flags):
        with ExitStack() as stack:
            calls = {key: stack.enter_context(mock.patch.object(runtime, key, wraps=getattr(runtime, key)))
                     for key in ("render_tree", "focus_details", "capture_window_png")}
            result = runtime.build_snapshot(name, **flags)
            return result, {key: query.call_count for key, query in calls.items()}

    full, counts = snapshot()
    assert counts == {"render_tree": 1, "focus_details": 1, "capture_window_png": 1}, counts
    png(full["screenshotPngBase64"])
    assert full["selectedText"] == "中文🙂", full
    ax, counts = snapshot(include_screenshot=False)
    assert counts == {"render_tree": 1, "focus_details": 1, "capture_window_png": 0}, counts
    assert ax["screenshotPngBase64"] is None and ax["elements"] == full["elements"], ax
    assert ax["selectedText"] == "中文🙂", ax
    image, counts = snapshot(include_ax=False)
    assert counts == {"render_tree": 0, "focus_details": 0, "capture_window_png": 1}, counts
    png(image["screenshotPngBase64"])
    assert image["elements"] == [] and image["treeLines"] == [], image
    assert image["focusedSummary"] is None and image["selectedText"] is None, image
    assert image["windowBounds"] == full["windowBounds"], image
    print("Real GTK collection: full, AX-only (no capture), image-only (no tree/focus) passed.")

    ax = client.call("get_app_state", name, include_screenshot=False)
    expect_snapshot(ax)
    assert all(item["type"] != "image" for item in ax["content"]), ax
    assert "Selected text: [中文🙂]" in text(ax), text(ax)
    refused = client.call("click", name, x=10, y=10)
    assert refused.get("isError") and "include_screenshot=false" in text(refused), refused
    # The standalone snapshot and JSON call entry points must preserve flags.
    cli = subprocess.run([native, "snapshot", "--include-screenshot", "false", name],
                         check=True, capture_output=True, text=True, timeout=40)
    assert "Read-back input" in cli.stdout and "include_screenshot=false" in cli.stdout, cli.stdout
    cli = subprocess.run([native, "call", "get_app_state", "--args",
                          json.dumps({"app": name, "include_screenshot": False})],
                         check=True, capture_output=True, text=True, timeout=40)
    assert all(item["type"] != "image" for item in json.loads(cli.stdout)["content"]), cli.stdout
    old_index = element_index(ax, "Read-back input")
    invalid = client.call("get_app_state", name, include_ax=False, include_screenshot=False)
    assert invalid.get("isError"), invalid
    image = client.call("get_app_state", name, include_ax=False)
    assert not image.get("isError"), image
    images = [item for item in image["content"] if item["type"] == "image"]
    assert len(images) == 1, image
    png(images[0]["data"])
    assert "indexes invalidated" in text(image), text(image)
    for omitted in ("Read-back input", "The focused UI element", "Selected text:"):
        assert omitted not in text(image), text(image)
    for alias in (name, str(full["app"]["pid"])):
        result = client.call("set_value", alias, element_index=old_index, value="must-not-write")
        assert result.get("isError"), result
    assert json.loads(state_file.read_text())["text"] == "prefix-中文🙂-suffix"

    button = next(row for row in full["elements"] if row["name"] == "Increment")
    bounds = button["frame"]
    result = client.call("click", name, x=bounds["x"] + bounds["width"] / 2,
                         y=bounds["y"] + bounds["height"] / 2)
    assert not result.get("isError"), result
    wait_for(lambda: json.loads(state_file.read_text())["count"] == 1, "coordinate click after image-only read")
    refreshed = client.call("get_app_state", name, include_screenshot=False)
    expect_snapshot(refreshed)
    result = client.call("set_value", name, element_index=element_index(refreshed, "Read-back input"),
                         value="selective-中文🙂")
    assert not result.get("isError"), result
    wait_for(lambda: json.loads(state_file.read_text())["text"] == "selective-中文🙂", "AX index recovery")
    print("Native MCP: valid PNG, omitted channels, stale name/PID indexes refused, coordinate action and AX recovery passed.")

    subprocess.run(["node", str(Path(__file__).with_name("linux-observation-js-smoke.mjs")),
                    native, name, str(state_file)], check=True, timeout=30)


def smoke(native, focus_checks=False, hidden_checks=False, observation_checks=False):
    with tempfile.TemporaryDirectory(prefix="ocu-read-back-smoke-") as directory:
        directory = Path(directory)
        state_file = directory / "state.json"
        name = "OCUReadBackFixture" + str(os.getpid())
        with (directory / "stderr.log").open("w+") as stderr:
            arguments = [sys.executable, __file__, "--fixture", name, "--state-file", str(state_file)]
            if focus_checks or observation_checks:
                arguments.append("--focus-checks")
            if hidden_checks:
                arguments.append("--hidden-checks")
            process = subprocess.Popen(arguments, stderr=stderr)
            clients = []
            try:
                wait_for(state_file.exists, "GTK fixture startup")
                overrides = {"OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN": "1"} if hidden_checks else None
                client = MCP(native, " OFF ", stderr, overrides)
                clients.append(client)
                # AT-SPI registration follows GTK startup asynchronously.
                wait_for(lambda: not client.call("get_app_state", name).get("isError"), "AT-SPI registration")
                if focus_checks:
                    check_focus(client, name, state_file)
                    return
                if observation_checks:
                    check_observation(client, native, name, state_file, stderr)
                    return
                if hidden_checks:
                    check_hidden(client, native, name, state_file, stderr)
                observed = client.call("get_app_state", name)
                expect_snapshot(observed)
                input_index = element_index(observed, "Read-back input")
                button_index = element_index(observed, "Increment")

                def state_is(**expected):
                    actual = json.loads(state_file.read_text())
                    return all(actual[key] == value for key, value in expected.items())

                def acknowledged(tool, **arguments):
                    result = client.call(tool, name, **arguments)
                    assert not result.get("isError"), result
                    assert result["content"] == [{"type": "text", "text": "ok"}], result

                acknowledged("set_value", element_index=input_index, value="hello-中文-🙂")
                wait_for(lambda: state_is(text="hello-中文-🙂"), "real entry set_value")
                for count in (1, 2):
                    acknowledged("click", element_index=button_index, click_method="accessibility")
                    wait_for(lambda: state_is(count=count), "cached-index button click")
                acknowledged("perform_secondary_action", element_index=button_index, action="click")
                wait_for(lambda: state_is(count=3), "real secondary action")
                acknowledged("click", element_index=input_index)
                wait_for(lambda: state_is(focused=True), "entry click focuses the entry")
                assert state_is(activated=0), "entry click ran the entry's Enter action: " + state_file.read_text()
                acknowledged("type_text", text="-typed")
                wait_for(lambda: state_is(text="hello-中文-🙂-typed"), "real entry insertion")
                acknowledged("press_key", key="Return")
                wait_for(lambda: state_is(activated=1), "real Return delivery")
                for tool, arguments in (
                    ("set_value", {"element_index": button_index, "value": "invalid"}),
                    ("perform_secondary_action", {"element_index": button_index, "action": "not-an-action"}),
                ):
                    result = client.call(tool, name, **arguments)
                    assert result.get("isError") and text(result) != "ok", result
                refreshed = client.call("get_app_state", name)
                expect_snapshot(refreshed)
                assert "hello-中文-🙂-typed" in text(refreshed), text(refreshed)
                assert "Counter: 3" in text(refreshed), text(refreshed)
                print("Disabled read-back: real actions, preserved indexes, errors and explicit observation passed.")

                default = MCP(native, None, stderr)
                clients.append(default)
                observed = default.call("get_app_state", name)
                expect_snapshot(observed)
                result = default.call("set_value", name, element_index=element_index(observed, "Read-back input"), value="default-read-back")
                expect_snapshot(result)
                assert "default-read-back" in text(result), text(result)
                wait_for(lambda: state_is(text="default-read-back"), "default action state")
                print("Default read-back: real action returns an updated snapshot.")
            except Exception:
                if state_file.exists():
                    print("Fixture state:", state_file.read_text(), file=sys.stderr)
                stderr.flush()
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)
                raise
            finally:
                for client in clients:
                    client.close()
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native")
    parser.add_argument("--fixture")
    checks = parser.add_mutually_exclusive_group()
    checks.add_argument("--focus-checks", action="store_true")
    checks.add_argument("--hidden-checks", action="store_true")
    checks.add_argument("--observation-checks", action="store_true")
    parser.add_argument("--state-file", type=Path)
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture, args.state_file, args.focus_checks, args.hidden_checks)
    else:
        if not args.native:
            parser.error("--native is required")
        smoke(str(Path(args.native).resolve()), args.focus_checks, args.hidden_checks, args.observation_checks)
