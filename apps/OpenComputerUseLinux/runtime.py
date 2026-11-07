#!/usr/bin/env python3

import base64
import json
import math
import os
import sys
import time
import traceback
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

import gi

gi.require_version("Atspi", "2.0")

try:
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk
except (ImportError, ValueError):
    Gdk = None

from gi.repository import Atspi


MAX_ELEMENTS = 1200
MAX_DEPTH = 64
DEFAULT_TEXT_LIMIT = 500


def frame(x, y, width, height):
    if width is None or height is None or width < 0 or height < 0:
        return None
    return {
        "x": float(x),
        "y": float(y),
        "width": float(width),
        "height": float(height),
    }


def safe(call, default=None):
    try:
        value = call()
        if value is None:
            return default
        return value
    except Exception:
        return default


def supports_interface(node, interface_name):
    interfaces = safe(lambda: node.get_interfaces(), [])
    expected = str(interface_name).casefold()
    return any(str(interface).casefold() == expected for interface in interfaces)


def require_desktop_session():
    missing = []
    if not os.environ.get("XDG_RUNTIME_DIR"):
        missing.append("XDG_RUNTIME_DIR")
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        missing.append("DBUS_SESSION_BUS_ADDRESS")
    if missing:
        raise RuntimeError(
            "Linux runtime requires an active desktop session; missing "
            + ", ".join(missing)
        )


def desktop():
    return Atspi.get_desktop(0)


def child_count(node):
    return int(safe(node.get_child_count, 0) or 0)


def child_at(node, index):
    return safe(lambda: node.get_child_at_index(index))


def node_name(node):
    return str(safe(node.get_name, "") or "")


def limit_text(value, text_limit=DEFAULT_TEXT_LIMIT):
    text = str(value or "")
    if text_limit is None:
        return text
    if len(text) > text_limit:
        return text[:text_limit] + "..."
    return text


def node_role(node):
    return str(safe(node.get_role_name, "") or "")


def node_pid(node):
    value = safe(node.get_process_id, 0)
    try:
        return int(value or 0)
    except Exception:
        return 0


def state_contains(node, state):
    state_set = safe(node.get_state_set)
    if state_set is None:
        return False
    return bool(safe(lambda: state_set.contains(state), False))


def extents(node):
    component = safe(node.get_component_iface)
    if component is None:
        return None
    rect = safe(lambda: Atspi.Component.get_extents(component, Atspi.CoordType.SCREEN))
    if (
        rect is None
        or rect.width <= 0
        or rect.height <= 0
        or rect.width > 100000
        or rect.height > 100000
    ):
        return None
    return frame(rect.x, rect.y, rect.width, rect.height)


def relative_frame(node, window_bounds):
    bounds = extents(node)
    if bounds is None:
        return None
    if window_bounds is None:
        return bounds
    return frame(
        bounds["x"] - window_bounds["x"],
        bounds["y"] - window_bounds["y"],
        bounds["width"],
        bounds["height"],
    )


def iter_apps():
    root = desktop()
    apps = []
    for index in range(child_count(root)):
        app = child_at(root, index)
        if app is not None and node_name(app):
            apps.append(app)
    return apps


def app_windows(app):
    windows = []
    for index in range(child_count(app)):
        child = child_at(app, index)
        if child is None:
            continue
        role = node_role(child).lower()
        bounds = extents(child)
        if role in {"frame", "window", "dialog", "alert"} or bounds is not None:
            windows.append((index, child))
    return windows


def main_window(app):
    windows = app_windows(app)
    if not windows:
        raise RuntimeError(
            "No top-level AT-SPI window is available for " + node_name(app)
        )
    for index, window in windows:
        if state_contains(window, Atspi.StateType.ACTIVE):
            return index, window
    for index, window in windows:
        if state_contains(window, Atspi.StateType.SHOWING):
            return index, window
    return windows[0]


def matches_query(app, query):
    normalized = query.strip().lower()
    if not normalized:
        return False
    if normalized.isdigit() and node_pid(app) == int(normalized):
        return True
    app_name = node_name(app).lower()
    if app_name == normalized or normalized in app_name:
        return True
    for _, window in app_windows(app):
        title = node_name(window).lower()
        if title == normalized or normalized in title:
            return True
    return False


def resolve_app(query):
    for app in iter_apps():
        if matches_query(app, query):
            return app
    raise RuntimeError('appNotFound("{}")'.format(query))


def action_names(node):
    names = []
    count = int(safe(node.get_n_actions, 0) or 0)
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(
            safe(lambda i=index: node.get_action_description(i), "") or ""
        )
        label = name or description
        if label and label not in names:
            names.append(label)
    return names


def accessible_id(node):
    return str(safe(node.get_accessible_id, "") or "")


def text_value(node, text_limit=DEFAULT_TEXT_LIMIT):
    if not supports_interface(node, "Text"):
        return ""
    text_iface = safe(node.get_text_iface)
    if text_iface is None:
        return ""
    count = int(safe(lambda: Atspi.Text.get_character_count(text_iface), 0) or 0)
    if count <= 0:
        return ""
    end_offset = count if text_limit is None else min(count, text_limit + 1)
    value = str(safe(lambda: Atspi.Text.get_text(text_iface, 0, end_offset), "") or "")
    return limit_text(value, text_limit=text_limit)


def numeric_value(node):
    value_iface = safe(node.get_value_iface)
    if value_iface is None:
        return ""
    current = safe(lambda: Atspi.Value.get_current_value(value_iface))
    if current is None:
        return ""
    return str(current)


def element_value(node, text_limit=DEFAULT_TEXT_LIMIT):
    return text_value(node, text_limit=text_limit) or numeric_value(node)


def positive_int(value, fallback):
    if isinstance(value, bool):
        return fallback
    if isinstance(value, float) and not value.is_integer():
        return fallback
    try:
        integer = int(value)
    except (TypeError, ValueError):
        return fallback
    return integer if integer > 0 else fallback


def parse_text_limit(value, fallback=DEFAULT_TEXT_LIMIT):
    if isinstance(value, str) and value.lower() == "max":
        return None
    return positive_int(value, fallback)


def record_for(node, index, path, window_bounds, text_limit=DEFAULT_TEXT_LIMIT, lightweight_hidden=False):
    # Only an explicit non-SHOWING state qualifies. Errors/unknown state keep
    # full details; geometry alone cannot prove that a menu/control is hidden.
    showing = safe(lambda: node.get_state_set().contains(Atspi.StateType.SHOWING)) if lightweight_hidden else None
    omit_details = showing is not None and not bool(showing)
    bounds = None if omit_details else relative_frame(node, window_bounds)
    role = node_role(node)
    return {
        "index": index,
        "runtimeId": path[:],
        "automationId": "" if omit_details else accessible_id(node),
        "name": limit_text(node_name(node), text_limit=text_limit),
        "controlType": role,
        "localizedControlType": role,
        "className": "" if omit_details else str(safe(node.get_toolkit_name, "") or ""),
        "value": "" if omit_details else element_value(node, text_limit=text_limit),
        "nativeWindowHandle": 0,
        "frame": bounds,
        "actions": [] if omit_details else action_names(node),
        **({"detailsOmitted": True} if omit_details else {}),
    }


def prioritized_tree_nodes(root, root_path, max_nodes, max_depth, window_bounds=None):
    """Bound discovery separately; retain ancestors and original AT-SPI paths."""
    import heapq
    pending, selected, seen = [], [], set()
    scanned, sequence, truncated = 0, 0, False
    scan_limit = max(64, min(max_nodes, 2500) * 4)
    collections = {"table", "tree", "tree table", "list", "list box", "scroll pane"}
    controls = {"push button", "check box", "radio button", "toggle button", "entry",
                "password text", "combo box", "slider", "spin button"}

    def enqueue(node, depth, path, in_collection, viewport):
        nonlocal scanned, sequence, truncated
        if depth > max_depth or scanned >= scan_limit:
            truncated = True
            return
        scanned += 1
        if node is None or node in seen:
            return
        seen.add(node)
        role = node_role(node).lower()
        collection = in_collection or role in collections
        showing = safe(lambda: node.get_state_set().contains(Atspi.StateType.SHOWING))
        geometry = safe(lambda: extents(node)) if collection else None
        hidden = showing is not None and not showing
        if geometry is not None and viewport is not None:
            hidden = hidden or (geometry["x"] + geometry["width"] <= viewport["x"] or
                geometry["y"] + geometry["height"] <= viewport["y"] or
                geometry["x"] >= viewport["x"] + viewport["width"] or
                geometry["y"] >= viewport["y"] + viewport["height"])
        if role == "scroll pane" and geometry is not None:
            if viewport is None:
                viewport = geometry
            else:
                x, y = max(viewport["x"], geometry["x"]), max(viewport["y"], geometry["y"])
                viewport = frame(x, y, max(0, min(viewport["x"]+viewport["width"], geometry["x"]+geometry["width"])-x),
                                 max(0, min(viewport["y"]+viewport["height"], geometry["y"]+geometry["height"])-y))
        control = role in controls or (role == "text" and supports_interface(node, "EditableText"))
        rank = 4 if hidden else (2 if control else 3) if collection else 0 if control else 1
        sequence += 1
        heapq.heappush(pending, (rank, sequence, node, depth, path, collection, viewport))

    enqueue(root, 0, tuple(root_path), False, window_bounds)
    while pending and len(selected) < max_nodes:
        _, _, node, depth, path, collection, viewport = heapq.heappop(pending)
        selected.append((path, node, depth))
        count = child_count(node)
        if depth >= max_depth:
            truncated = truncated or count > 0
            continue
        for index in range(count):
            if scanned >= scan_limit:
                truncated = True
                break
            enqueue(child_at(node, index), depth + 1, path + (index,), collection, viewport)
    return sorted(selected, key=lambda item: item[0]), truncated or bool(pending)


def render_tree(root, window_bounds, root_path, text_limit=DEFAULT_TEXT_LIMIT, max_tree_nodes=MAX_ELEMENTS, max_tree_depth=MAX_DEPTH):
    records = []
    lines = []
    lightweight_hidden = os.environ.get("OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN", "").strip().lower() in {"1", "true", "yes", "on"}

    selected, truncated = prioritized_tree_nodes(root, root_path, max_tree_nodes, max_tree_depth, window_bounds)
    for path, node, depth in selected:
        index = len(records)
        record = record_for(node, index, list(path), window_bounds, text_limit=text_limit, lightweight_hidden=lightweight_hidden)
        records.append(record)

        role = record["localizedControlType"] or record["controlType"] or "element"
        title = record["name"] or record["automationId"] or ""
        if record.get("detailsOmitted"):
            title += " [hidden details omitted]"
        value_segment = ""
        if record["value"] and record["value"] != title:
            safe_value = record["value"].replace("\r", "\\r").replace("\n", "\\n")
            value_segment = " Value: " + safe_value
        actions_segment = ""
        if record["actions"]:
            actions_segment = " Secondary Actions: " + ", ".join(record["actions"])
        frame_segment = ""
        if record["frame"] is not None:
            f = record["frame"]
            frame_segment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}".format(
                round(f["x"]),
                round(f["y"]),
                round(f["width"]),
                round(f["height"]),
            )
        lines.append(
            ("\t" * (depth + 1))
            + "{} {} {}{}{}{}".format(
                index, role, title, value_segment, actions_segment, frame_segment
            ).rstrip()
        )

    if truncated:
        lines.append("[Accessibility tree truncated: prioritized visible controls; some nodes were omitted.]")
    return records, lines


def capture_window_png(bounds):
    if Gdk is None or bounds is None:
        return None
    try:
        screen = Gdk.Screen.get_default()
        if screen is None:
            return None
        root = screen.get_root_window()
        pixbuf = Gdk.pixbuf_get_from_window(
            root,
            int(round(bounds["x"])),
            int(round(bounds["y"])),
            max(1, int(round(bounds["width"]))),
            max(1, int(round(bounds["height"]))),
        )
        if pixbuf is None:
            return None
        if pixbuf_looks_black(pixbuf):
            return None
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        if not ok:
            return None
        return base64.b64encode(bytes(data)).decode("ascii")
    except Exception:
        return None


def pixbuf_looks_black(pixbuf):
    try:
        pixels = pixbuf.get_pixels()
        channels = pixbuf.get_n_channels()
        rowstride = pixbuf.get_rowstride()
        width = pixbuf.get_width()
        height = pixbuf.get_height()
        if width <= 0 or height <= 0 or channels < 3:
            return True
        step_x = max(1, width // 16)
        step_y = max(1, height // 16)
        checked = 0
        for y in range(0, height, step_y):
            row = y * rowstride
            for x in range(0, width, step_x):
                offset = row + (x * channels)
                if (
                    pixels[offset] > 3
                    or pixels[offset + 1] > 3
                    or pixels[offset + 2] > 3
                ):
                    return False
                checked += 1
        return checked > 0
    except Exception:
        return False


def focus_details(window, text_limit=DEFAULT_TEXT_LIMIT, max_nodes=MAX_ELEMENTS, max_depth=MAX_DEPTH):
    """Find focus once, within the same node/depth budget as the snapshot."""
    visited = 0
    truncated = False

    def visit(node, depth):
        nonlocal visited, truncated
        if visited >= max_nodes or depth > max_depth:
            truncated = True
            return None
        visited += 1
        if node is None:
            return None
        if state_contains(node, Atspi.StateType.FOCUSED):
            return node
        children = child_count(node)
        if depth >= max_depth:
            # Do not fetch children that cannot be visited. Otherwise a wide
            # node at the depth boundary can bypass the node budget entirely.
            truncated = truncated or children > 0
            return None
        for index in range(children):
            if visited >= max_nodes:
                truncated = True
                break
            found = visit(child_at(node, index), depth + 1)
            if found is not None:
                return found
        return None

    focused = visit(window, 0)
    if focused is None:
        return None, None, truncated
    summary = (node_role(focused) + " " + limit_text(node_name(focused), text_limit)).strip()
    selection = None
    if supports_interface(focused, "Text"):
        text_iface = safe(focused.get_text_iface)
        count = safe(lambda: Atspi.Text.get_n_selections(text_iface), 0)
        selected = safe(lambda: Atspi.Text.get_selection(text_iface, 0)) if count > 0 else None
        if selected is not None:
            end = selected.end_offset
            if text_limit is not None:
                end = min(end, selected.start_offset + text_limit + 1)
            selection = safe(lambda: Atspi.Text.get_text(text_iface, selected.start_offset, end))
            if selection is not None:
                selection = limit_text(selection, text_limit)
    return summary, selection, False


def build_snapshot(query, text_limit=DEFAULT_TEXT_LIMIT, max_tree_nodes=MAX_ELEMENTS, max_tree_depth=MAX_DEPTH, include_ax=True, include_screenshot=True):
    app = resolve_app(query)
    window_index, window = main_window(app)
    bounds = extents(window)
    records, lines = [], []
    focus, selection = None, None
    if include_ax:
        records, lines = render_tree(
            window,
            bounds,
            [window_index],
            text_limit=text_limit,
            max_tree_nodes=max_tree_nodes,
            max_tree_depth=max_tree_depth,
        )
        focus, selection, focus_truncated = focus_details(window, text_limit, max_tree_nodes, max_tree_depth)
        if focus_truncated:
            lines.append("[Focus search incomplete: node/depth budget reached.]")
    pid = node_pid(app)
    return {
        "app": {
            "name": node_name(app),
            "bundleIdentifier": node_name(app),
            "pid": pid,
        },
        "windowTitle": limit_text(node_name(window), text_limit=text_limit),
        "windowBounds": bounds,
        "screenshotPngBase64": capture_window_png(bounds) if include_screenshot else None,
        "treeLines": lines,
        "focusedSummary": focus,
        "selectedText": selection,
        "elements": records,
    }


def list_apps_text():
    lines = []
    for app in sorted(iter_apps(), key=lambda item: (node_name(item).lower(), node_pid(item))):
        windows = app_windows(app)
        if not windows:
            continue
        title = node_name(windows[0][1]) or "untitled"
        name = node_name(app)
        lines.append(
            "{} -- {} [running, pid={}, window={}]".format(
                name, name, node_pid(app), title
            )
        )
    return "\n".join(lines)


def find_first(root, predicate):
    if root is None:
        return None
    if predicate(root):
        return root
    for index in range(child_count(root)):
        found = find_first(child_at(root, index), predicate)
        if found is not None:
            return found
    return None


def iter_all(root):
    items = []

    def visit(node):
        if node is None or len(items) >= MAX_ELEMENTS:
            return
        items.append(node)
        for index in range(child_count(node)):
            visit(child_at(node, index))

    visit(root)
    return items


def resolve_path(app, path):
    if not path:
        return None
    node = app
    for index in path:
        node = child_at(node, int(index))
        if node is None:
            return None
    return node


def same_frame(record_frame, node_frame):
    if record_frame is None or node_frame is None:
        return False
    for key in ("x", "y", "width", "height"):
        if abs(float(record_frame.get(key, 0)) - float(node_frame.get(key, 0))) > 3:
            return False
    return True


def find_element(app, record):
    if not record:
        return None
    node = resolve_path(app, record.get("runtimeId") or [])
    if node is not None:
        return node

    _, window = main_window(app)
    target_name = str(record.get("name") or "")
    target_id = str(record.get("automationId") or "")
    target_role = str(record.get("controlType") or "")
    window_bounds = extents(window)
    for candidate in iter_all(window):
        if target_id and accessible_id(candidate) == target_id:
            return candidate
        if target_name and node_name(candidate) == target_name and node_role(candidate) == target_role:
            return candidate
        if target_role and node_role(candidate) == target_role:
            if same_frame(record.get("frame"), relative_frame(candidate, window_bounds)):
                return candidate
    return None


def preferred_action_index(node):
    preferred_exact = {
        "click",
        "press",
        "activate",
        "default.activate",
        "invoke",
        "select",
        "toggle",
        "open",
    }
    count = int(safe(node.get_n_actions, 0) or 0)
    fallback = None
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(safe(lambda i=index: node.get_action_description(i), "") or "")
        lower = (name or description).lower()
        if lower in preferred_exact:
            return index
        if fallback is None and (
            "activate" in lower or "click" in lower or "press" in lower
        ):
            fallback = index
    return fallback


def do_action_by_index(node, index):
    if index is None:
        return False
    return bool(safe(lambda: node.do_action(int(index)), False))


def screen_point(window_bounds, element=None, x=None, y=None):
    if element is not None:
        f = element.get("frame")
        if f is not None and window_bounds is not None:
            return (
                window_bounds["x"] + f["x"] + f["width"] / 2,
                window_bounds["y"] + f["y"] + f["height"] / 2,
            )
    if x is None or y is None or window_bounds is None:
        raise RuntimeError("coordinate action requires window bounds and x/y")
    return window_bounds["x"] + float(x), window_bounds["y"] + float(y)


def mouse_button_events(button):
    normalized = (button or "left").lower()
    if normalized == "right":
        return "b3p", "b3r"
    if normalized == "middle":
        return "b2p", "b2r"
    return "b1p", "b1r"


def send_mouse_click(x, y, button, count):
    down, up = mouse_button_events(button)
    repeat = max(1, int(count or 1))
    for _ in range(repeat):
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), "abs")
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), down)
        time.sleep(0.035)
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), up)
        time.sleep(0.05)


def send_drag(from_x, from_y, to_x, to_y):
    Atspi.generate_mouse_event(int(round(from_x)), int(round(from_y)), "abs")
    Atspi.generate_mouse_event(int(round(from_x)), int(round(from_y)), "b1p")
    steps = 12
    for step in range(1, steps + 1):
        x = from_x + ((to_x - from_x) * step / steps)
        y = from_y + ((to_y - from_y) * step / steps)
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), "abs")
        time.sleep(0.02)
    Atspi.generate_mouse_event(int(round(to_x)), int(round(to_y)), "b1r")


KEY_ALIASES = {
    "return": "Return",
    "enter": "Return",
    "tab": "Tab",
    "escape": "Escape",
    "esc": "Escape",
    "backspace": "BackSpace",
    "back_space": "BackSpace",
    "delete": "Delete",
    "space": "space",
    "left": "Left",
    "up": "Up",
    "right": "Right",
    "down": "Down",
    "home": "Home",
    "end": "End",
    "page_up": "Page_Up",
    "prior": "Page_Up",
    "page_down": "Page_Down",
    "next": "Page_Down",
}

# X11 modifier bits for LOCKMODIFIERS/UNLOCKMODIFIERS. Super is usually Mod4.
MODIFIER_BITS = {
    "ctrl": "CONTROL",
    "control": "CONTROL",
    "shift": "SHIFT",
    "alt": "ALT",
    "super": "META3",
    "win": "META3",
    "cmd": "META3",
}


# GDK returns VoidSymbol for names it doesn't know.
VOID_SYMBOL = 0xFFFFFF


def keyval(name):
    # Characters have no name lookup in GDK ("/" is "slash"), so map them
    # from Unicode instead.
    if len(name) == 1:
        if Gdk is not None:
            return int(Gdk.unicode_to_keyval(ord(name)))
        return ord(name)
    if Gdk is not None:
        value = int(Gdk.keyval_from_name(name))
        if value and value != VOID_SYMBOL:
            return value
    raise RuntimeError("Unsupported key: " + name)


def send_key(key):
    parts = [part for part in str(key).split("+") if part]
    if not parts:
        raise RuntimeError("Unsupported key: " + str(key))
    main = parts[-1]
    mask = 0
    for modifier in parts[:-1]:
        name = MODIFIER_BITS.get(modifier.lower())
        if name is None:
            raise RuntimeError("Unsupported modifier: " + modifier)
        mask |= 1 << int(getattr(Atspi.ModifierType, name))
    normalized = KEY_ALIASES.get(main.lower(), main)
    if mask:
        Atspi.generate_keyboard_event(mask, None, Atspi.KeySynthType.LOCKMODIFIERS)
    try:
        if len(normalized) == 1 and not mask:
            Atspi.generate_keyboard_event(0, normalized, Atspi.KeySynthType.STRING)
        else:
            # SYM takes a keysym. PRESS, RELEASE, and PRESSRELEASE take a
            # hardware keycode, so passing a keysym there sends another key.
            Atspi.generate_keyboard_event(
                keyval(normalized), None, Atspi.KeySynthType.SYM
            )
    finally:
        if mask:
            Atspi.generate_keyboard_event(
                mask, None, Atspi.KeySynthType.UNLOCKMODIFIERS
            )


def send_text(text):
    Atspi.generate_keyboard_event(0, str(text), Atspi.KeySynthType.STRING)


def find_editable_text(root):
    def is_editable(node):
        return supports_interface(node, "EditableText") and supports_interface(
            node, "Text"
        )

    return find_first(root, is_editable)


def insert_text(root, text):
    node = find_editable_text(root)
    if node is None:
        return False
    editable = safe(node.get_editable_text_iface)
    text_iface = safe(node.get_text_iface)
    if editable is None or text_iface is None:
        return False
    offset = int(safe(lambda: Atspi.Text.get_character_count(text_iface), 0) or 0)
    return bool(
        safe(
            lambda: Atspi.EditableText.insert_text(
                editable, offset, str(text), len(str(text))
            ),
            False,
        )
    )


def verify_set_value(requested, read, numeric=False):
    from decimal import Decimal, InvalidOperation
    import re
    def matches(actual):
        if not numeric:
            return isinstance(actual, str) and actual == requested
        try:
            if re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", requested) is None:
                return False
            expected, observed = Decimal(requested), Decimal(str(actual))
            return expected.is_finite() and observed.is_finite() and expected == observed
        except (InvalidOperation, ValueError):
            return False
    deadline = time.monotonic() + 0.6
    while True:
        if matches(safe(read)):
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("set_value could not verify the requested value. Read the current value before retrying; the write may have changed the control.")
        time.sleep(min(0.05, remaining))


def set_element_value(node, value):
    value = str(value)
    if node is not None and supports_interface(node, "EditableText"):
        editable = safe(node.get_editable_text_iface)
        if editable is not None:
            # A failed text write must not be retried through the numeric interface.
            if not Atspi.EditableText.set_text_contents(editable, value):
                raise RuntimeError("set_value was rejected; read the current value before retrying")
            text = safe(node.get_text_iface) if supports_interface(node, "Text") else None
            def read():
                if text is None:
                    return None
                count = Atspi.Text.get_character_count(text)
                return Atspi.Text.get_text(text, 0, count)
            verify_set_value(value, read)
            return True
    value_iface = safe(node.get_value_iface) if node is not None else None
    if value_iface is not None:
        import math
        number = float(value)
        if not math.isfinite(number):
            raise RuntimeError("set_value requires a finite numeric value")
        if not Atspi.Value.set_current_value(value_iface, number):
            raise RuntimeError("set_value was rejected; read the current value before retrying")
        verify_set_value(value, lambda: Atspi.Value.get_current_value(value_iface), numeric=True)
        return True
    return False


def invoke_secondary_action(node, action):
    if node is None:
        raise RuntimeError("unknown element_index")
    normalized = str(action).lower()
    count = int(safe(node.get_n_actions, 0) or 0)
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(safe(lambda i=index: node.get_action_description(i), "") or "")
        if normalized in {name.lower(), description.lower()}:
            if do_action_by_index(node, index):
                return
            break
    raise RuntimeError("{} is not a valid secondary action for element".format(action))


def scroll_element(direction, pages):
    key = "Page_Down"
    if direction == "up":
        key = "Page_Up"
    elif direction == "left":
        key = "Left"
    elif direction == "right":
        key = "Right"
    repeat = max(1, int(math.ceil(float(pages or 1))))
    for _ in range(repeat):
        send_key(key)
        time.sleep(0.04)


def perform_operation(operation):
    tool = operation.get("tool")
    if tool == "list_apps":
        return {"ok": True, "text": list_apps_text()}
    if tool == "get_app_state":
        for key in ("include_ax", "include_screenshot"):
            if key in operation and not isinstance(operation[key], bool):
                raise RuntimeError(key + " must be a boolean")
        if not operation.get("include_ax", True) and not operation.get("include_screenshot", True):
            raise RuntimeError("At least one of include_ax or include_screenshot must be true")
        return {
            "ok": True,
            "snapshot": build_snapshot(
                operation.get("app", ""),
                text_limit=parse_text_limit(operation.get("text_limit"), DEFAULT_TEXT_LIMIT),
                max_tree_nodes=positive_int(operation.get("max_tree_nodes"), MAX_ELEMENTS),
                max_tree_depth=positive_int(operation.get("max_tree_depth"), MAX_DEPTH),
                include_ax=operation.get("include_ax", True),
                include_screenshot=operation.get("include_screenshot", True),
            ),
        }

    app = resolve_app(operation.get("app", ""))
    _, window = main_window(app)
    bounds = operation.get("windowBounds") or extents(window)
    element_record = operation.get("element")
    element = find_element(app, element_record)

    if tool == "click":
        click_method = (operation.get("click_method") or "auto").lower()
        if click_method == "accessibility":
            if element is None:
                raise RuntimeError("click_method 'accessibility' requires element_index")
            if operation.get("mouse_button", "left") != "left":
                raise RuntimeError(
                    "click_method 'accessibility' only supports mouse_button 'left'"
                )
            if not do_action_by_index(element, preferred_action_index(element)):
                raise RuntimeError(
                    "click_method 'accessibility' could not click the requested element"
                )
        elif click_method == "app_post":
            raise RuntimeError("click_method 'app_post' is not supported on Linux")
        elif click_method == "sky_click":
            raise RuntimeError("click_method 'sky_click' is not supported on Linux")
        elif click_method == "global":
            x, y = screen_point(
                bounds,
                element_record,
                operation.get("x"),
                operation.get("y"),
            )
            send_mouse_click(
                x, y, operation.get("mouse_button", "left"), operation.get("click_count", 1)
            )
        elif click_method == "auto":
            handled = False
            if element is not None and operation.get("mouse_button", "left") == "left":
                handled = do_action_by_index(element, preferred_action_index(element))
            if not handled:
                x, y = screen_point(
                    bounds,
                    element_record,
                    operation.get("x"),
                    operation.get("y"),
                )
                send_mouse_click(
                    x,
                    y,
                    operation.get("mouse_button", "left"),
                    operation.get("click_count", 1),
                )
        else:
            raise RuntimeError("Invalid click_method '{}'".format(click_method))
    elif tool == "perform_secondary_action":
        invoke_secondary_action(element, operation.get("action", ""))
    elif tool == "scroll":
        scroll_element(operation.get("direction", "down"), operation.get("pages", 1))
    elif tool == "drag":
        from_x, from_y = screen_point(
            bounds, None, operation.get("from_x"), operation.get("from_y")
        )
        to_x, to_y = screen_point(bounds, None, operation.get("to_x"), operation.get("to_y"))
        send_drag(from_x, from_y, to_x, to_y)
    elif tool == "type_text":
        if not insert_text(window, operation.get("text", "")):
            send_text(operation.get("text", ""))
    elif tool == "press_key":
        send_key(operation.get("key", ""))
    elif tool == "set_value":
        if element is None:
            raise RuntimeError("unknown element_index")
        if not set_element_value(element, operation.get("value", "")):
            raise RuntimeError("Cannot set a value for an element that is not settable")
    else:
        raise RuntimeError('unsupportedTool("{}")'.format(tool))

    if operation.get("skip_read_back", False):
        return {"ok": True}

    time.sleep(0.12)
    return {"ok": True, "snapshot": build_snapshot(operation.get("app", ""))}


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("runtime.py requires an operation JSON path")
    require_desktop_session()
    Atspi.init()
    with open(sys.argv[1], "r", encoding="utf-8") as file:
        operation = json.load(file)
    try:
        response = perform_operation(operation)
    except Exception as exc:
        response = {"ok": False, "error": str(exc)}
    print(json.dumps(response, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(json.dumps({"ok": False, "error": traceback.format_exc()}))
