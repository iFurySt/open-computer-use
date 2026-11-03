import contextlib
import importlib.util
import pathlib
import sys
import types
import unittest
from unittest import mock


class FakeText:
    @staticmethod
    def get_character_count(_interface):
        return 5

    @staticmethod
    def get_text(_interface, _start, _end):
        return "hello"


class FakeEditableText:
    @staticmethod
    def insert_text(_interface, _offset, _text, _length):
        return True

    @staticmethod
    def set_text_contents(_interface, _text):
        return True


def load_runtime():
    gi = types.ModuleType("gi")
    gi.require_version = lambda *_args: None
    repository = types.ModuleType("gi.repository")
    repository.Atspi = types.SimpleNamespace(
        Text=FakeText,
        EditableText=FakeEditableText,
    )
    repository.Gdk = types.SimpleNamespace()
    gi.repository = repository

    runtime_path = pathlib.Path(__file__).with_name("runtime.py")
    spec = importlib.util.spec_from_file_location("open_computer_use_linux_runtime", runtime_path)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(
        sys.modules,
        {"gi": gi, "gi.repository": repository},
    ):
        spec.loader.exec_module(module)
    return module


class InterfaceOnlyAccessible:
    def __init__(self, interfaces):
        self.interfaces = interfaces

    def get_interfaces(self):
        return self.interfaces

    def get_text_iface(self):
        return self

    def get_editable_text_iface(self):
        return self

    def get_child_count(self):
        return 0


class RuntimeInterfaceDetectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = load_runtime()

    def test_text_value_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text"])

        self.assertEqual(self.runtime.text_value(node), "hello")

    def test_insert_text_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text", "EditableText"])

        self.assertTrue(self.runtime.insert_text(node, "hello"))

    def test_set_value_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text", "EditableText"])

        self.assertTrue(self.runtime.set_element_value(node, "hello"))


class SetValueVerificationTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.clock = 0.0
        def sleep(seconds): self.clock += seconds
        self.patch = mock.patch.multiple(self.runtime.time, monotonic=lambda: self.clock, sleep=sleep)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_literal_text_and_typed_numbers(self):
        for text in ["", " \t中文🙂\n", "0015", "e\u0301"]:
            self.runtime.verify_set_value(text, lambda: text)
        for requested, actual in [("0015", "15"), (" x ", "x"), ("e\u0301", "é"), ("true", "1"), ("x", None)]:
            with self.assertRaisesRegex(RuntimeError, "could not verify"):
                self.runtime.verify_set_value(requested, lambda: actual)
        self.runtime.verify_set_value("15.0", lambda: 15.0, numeric=True)
        with self.assertRaisesRegex(RuntimeError, "could not verify"):
            self.runtime.verify_set_value("9007199254740993", lambda: 9007199254740992.0, numeric=True)

    def test_delayed_success_and_unreadable_failure(self):
        self.runtime.verify_set_value("new", lambda: "new" if self.clock >= 0.15 else "old")
        self.assertLessEqual(self.clock, 0.6)
        with self.assertRaisesRegex(RuntimeError, "could not verify"):
            self.runtime.verify_set_value("new", lambda: (_ for _ in ()).throw(RuntimeError("gone")))

    def test_ignored_text_write_is_attempted_once_without_numeric_fallback(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text", "EditableText"])
        with mock.patch.object(self.runtime.Atspi.EditableText, "set_text_contents", return_value=True) as write:
            with self.assertRaisesRegex(RuntimeError, "could not verify"):
                self.runtime.set_element_value(node, "ignored")
            self.assertEqual(write.call_count, 1)


class FakeKeySynthType:
    PRESS = "PRESS"
    RELEASE = "RELEASE"
    PRESSRELEASE = "PRESSRELEASE"
    SYM = "SYM"
    STRING = "STRING"
    LOCKMODIFIERS = "LOCKMODIFIERS"
    UNLOCKMODIFIERS = "UNLOCKMODIFIERS"


class FakeModifierType:
    SHIFT = 0
    CONTROL = 2
    ALT = 3
    META3 = 6


KEYSYMS = {"Return": 0xFF0D, "Tab": 0xFF09, "Down": 0xFF54}


class RuntimeKeyTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.events = []
        self.runtime.Atspi = types.SimpleNamespace(
            KeySynthType=FakeKeySynthType,
            ModifierType=FakeModifierType,
            generate_keyboard_event=lambda value, text, synth: self.events.append(
                (value, text, synth)
            ),
        )
        self.runtime.Gdk = types.SimpleNamespace(
            # Like GDK, unknown names map to VoidSymbol rather than 0.
            keyval_from_name=lambda name: KEYSYMS.get(name, 0xFFFFFF),
            unicode_to_keyval=lambda codepoint: codepoint,
        )

    def test_named_key_is_sent_as_keysym(self):
        self.runtime.send_key("Enter")

        self.assertEqual(self.events, [(0xFF0D, None, "SYM")])

    def test_modifiers_are_held_around_the_key(self):
        self.runtime.send_key("ctrl+shift+Tab")

        mask = (1 << FakeModifierType.CONTROL) | (1 << FakeModifierType.SHIFT)
        self.assertEqual(
            self.events,
            [
                (mask, None, "LOCKMODIFIERS"),
                (0xFF09, None, "SYM"),
                (mask, None, "UNLOCKMODIFIERS"),
            ],
        )

    def test_modified_character_is_sent_as_keysym(self):
        self.runtime.send_key("ctrl+a")

        mask = 1 << FakeModifierType.CONTROL
        self.assertEqual(self.events[1], (ord("a"), None, "SYM"))
        self.assertEqual(self.events[0], (mask, None, "LOCKMODIFIERS"))

    def test_modified_punctuation_is_sent_as_keysym(self):
        self.runtime.send_key("ctrl+/")

        self.assertEqual(self.events[1], (ord("/"), None, "SYM"))

    def test_unknown_key_name_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.runtime.send_key("NoSuchKey")

        self.assertEqual(self.events, [])

    def test_plain_character_is_typed(self):
        self.runtime.send_key("a")

        self.assertEqual(self.events, [(0, "a", "STRING")])

    def test_unknown_modifier_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.runtime.send_key("hyper+a")

        self.assertEqual(self.events, [])


class RuntimeSelectiveObservationTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.app = object()
        self.window = object()
        self.patches = []
        for name, value in {
            "resolve_app": self.app,
            "main_window": (0, self.window),
            "extents": {"x": 1, "y": 2, "width": 300, "height": 200},
            "node_pid": 42,
            "node_name": "Editor",
            "render_tree": ([{"index": 7}], ["tree"]),
            "focus_details": ("focus", "selection", False),
            "capture_window_png": "png",
        }.items():
            patch = mock.patch.object(self.runtime, name, return_value=value)
            self.patches.append(patch)
            patch.start()
            self.addCleanup(patch.stop)

    def test_defaults_still_collect_full_state(self):
        state = self.runtime.build_snapshot("Editor")
        self.assertEqual(state["elements"], [{"index": 7}])
        self.assertEqual(state["screenshotPngBase64"], "png")
        self.runtime.focus_details.assert_called_once()

    def test_screenshot_only_skips_tree_focus_and_selection(self):
        state = self.runtime.build_snapshot("Editor", include_ax=False)
        self.assertEqual(state["screenshotPngBase64"], "png")
        self.assertEqual(state["elements"], [])
        self.assertEqual(state["treeLines"], [])
        self.assertIsNone(state["focusedSummary"])
        self.assertIsNone(state["selectedText"])
        for name in ("render_tree", "focus_details"):
            getattr(self.runtime, name).assert_not_called()

    def test_ax_only_skips_capture(self):
        state = self.runtime.build_snapshot("Editor", include_screenshot=False)
        self.assertEqual(state["treeLines"], ["tree"])
        self.assertIsNone(state["screenshotPngBase64"])
        self.runtime.capture_window_png.assert_not_called()

    def test_ax_only_preserves_bounded_focus_reporting(self):
        self.runtime.focus_details.return_value = (None, None, True)
        state = self.runtime.build_snapshot("Editor", text_limit=20, max_tree_nodes=2,
                                            max_tree_depth=1, include_screenshot=False)
        self.runtime.focus_details.assert_called_once_with(self.window, 20, 2, 1)
        self.assertIn("[Focus search incomplete: node/depth budget reached.]", state["treeLines"])
        self.runtime.capture_window_png.assert_not_called()

    def test_tool_forwards_explicit_observation_flags(self):
        state = self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", "include_ax": False})
        self.assertTrue(state["ok"])
        self.runtime.render_tree.assert_not_called()

    def test_invalid_or_empty_observations_are_rejected(self):
        for flags in ({"include_ax": "false"}, {"include_screenshot": None},
                      {"include_ax": 0}, {"include_ax": False, "include_screenshot": False}):
            with self.subTest(flags=flags):
                with self.assertRaises(RuntimeError):
                    self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", **flags})
        self.runtime.resolve_app.assert_not_called()


class HiddenDetailsTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.runtime.Atspi.StateType = types.SimpleNamespace(SHOWING="showing")

    def node(self, showing):
        node = mock.Mock()
        node.get_name.return_value = "Menu"
        node.get_role_name.return_value = "menu"
        node.get_child_count.return_value = 0
        node.get_state_set.return_value.contains.return_value = showing
        return node

    def test_hidden_record_retains_identity_and_skips_expensive_properties(self):
        node = self.node(False)
        with mock.patch.object(self.runtime, "relative_frame") as geometry, \
             mock.patch.object(self.runtime, "element_value") as value, \
             mock.patch.object(self.runtime, "action_names") as actions:
            record = self.runtime.record_for(node, 7, [0, 3], None, lightweight_hidden=True)
        self.assertEqual((record["index"], record["runtimeId"], record["name"]), (7, [0, 3], "Menu"))
        self.assertTrue(record["detailsOmitted"])
        for query in (geometry, value, actions):
            query.assert_not_called()
        node.get_toolkit_name.assert_not_called()
        node.get_accessible_id.assert_not_called()

    def test_default_and_unknown_or_showing_state_keep_full_details(self):
        for enabled, showing in ((False, False), (True, True), (True, None)):
            with self.subTest(enabled=enabled, showing=showing):
                node = self.node(showing)
                with mock.patch.object(self.runtime, "relative_frame", return_value=None), \
                     mock.patch.object(self.runtime, "accessible_id", return_value="id"), \
                     mock.patch.object(self.runtime, "element_value", return_value="value"), \
                     mock.patch.object(self.runtime, "action_names", return_value=["open"]):
                    record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=enabled)
                self.assertNotIn("detailsOmitted", record)
                self.assertEqual((record["value"], record["actions"]), ("value", ["open"]))
                if not enabled:
                    node.get_state_set.assert_not_called()

    def test_hidden_parent_does_not_prune_visible_menu_children_or_renumber(self):
        parent = self.node(False)
        child = self.node(True)
        parent.get_child_count.return_value = 1
        parent.get_child_at_index.return_value = child
        with mock.patch.dict(self.runtime.os.environ, {"OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN": "1"}), \
             mock.patch.object(self.runtime, "relative_frame", return_value=None), \
             mock.patch.object(self.runtime, "accessible_id", return_value="id"), \
             mock.patch.object(self.runtime, "element_value", return_value="value"), \
             mock.patch.object(self.runtime, "action_names", return_value=[]):
            records, lines = self.runtime.render_tree(parent, None, [0])
        self.assertEqual([r["index"] for r in records], [0, 1])
        self.assertTrue(records[0]["detailsOmitted"])
        self.assertNotIn("detailsOmitted", records[1])
        self.assertIn("hidden details omitted", lines[0])
        self.assertEqual(records[1]["runtimeId"], [0, 0])

    def test_failed_state_reads_keep_full_details(self):
        for failure in ("state-set", "missing-state-set", "contains"):
            with self.subTest(failure=failure):
                node = self.node(False)
                if failure == "state-set":
                    node.get_state_set.side_effect = RuntimeError("state unavailable")
                elif failure == "missing-state-set":
                    node.get_state_set.return_value = None
                else:
                    node.get_state_set.return_value.contains.side_effect = RuntimeError("state unavailable")
                with mock.patch.object(self.runtime, "relative_frame", return_value=None), \
                     mock.patch.object(self.runtime, "element_value", return_value="retained"), \
                     mock.patch.object(self.runtime, "action_names", return_value=["click"]):
                    record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=True)
                self.assertNotIn("detailsOmitted", record)
                self.assertEqual((record["value"], record["actions"]), ("retained", ["click"]))

    def test_showing_node_with_negative_geometry_keeps_details(self):
        node = self.node(True)
        bounds = {"x": -100, "y": -200, "width": 30, "height": 40}
        with mock.patch.object(self.runtime, "relative_frame", return_value=bounds), \
             mock.patch.object(self.runtime, "element_value", return_value="visible"), \
             mock.patch.object(self.runtime, "action_names", return_value=["click"]):
            record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=True)
        self.assertNotIn("detailsOmitted", record)
        self.assertEqual((record["frame"], record["value"], record["actions"]), (bounds, "visible", ["click"]))


class FocusDetailsTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.runtime.Atspi.StateType = types.SimpleNamespace(FOCUSED="focused")

    def node(self, children=(), focused=False):
        node = mock.Mock()
        node.get_child_count.return_value = len(children)
        node.get_child_at_index.side_effect = lambda i: children[i]
        node.get_state_set.return_value.contains.side_effect = lambda s: focused
        node.get_name.return_value = "Editor"
        node.get_role_name.return_value = "text"
        node.get_interfaces.return_value = ["Text"]
        return node

    def test_summary_and_selection_share_one_focus_lookup(self):
        focused = self.node(focused=True)
        root = self.node([focused])
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=lambda _iface, index: types.SimpleNamespace(start_offset=1, end_offset=8),
            get_text=lambda _iface, start, end: "hello"[start:end],
        )
        summary, selected, truncated = self.runtime.focus_details(root)
        self.assertEqual((summary, selected, truncated), ("text Editor", "ello", False))
        root.get_child_at_index.assert_called_once_with(0)
        focused.get_state_set.assert_called_once()

    def test_node_budget_reports_incomplete_instead_of_absent(self):
        children = [self.node() for _ in range(100)]
        root = self.node(children)
        self.assertEqual(self.runtime.focus_details(root, max_nodes=3), (None, None, True))
        self.assertEqual(root.get_child_at_index.call_count, 2)

    def test_depth_budget_and_complete_absence(self):
        root = self.node([self.node([self.node(focused=True)])])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), (None, None, True))
        self.assertEqual(self.runtime.focus_details(self.node()), (None, None, False))

    def test_depth_boundary_does_not_fetch_out_of_budget_children(self):
        boundary = self.node()
        boundary.get_child_count.return_value = 100
        boundary.get_child_at_index.side_effect = None
        boundary.get_child_at_index.return_value = None
        root = self.node([boundary])
        self.assertEqual(self.runtime.focus_details(root, max_nodes=3, max_depth=1), (None, None, True))
        boundary.get_child_at_index.assert_not_called()

    def test_depth_boundary_leaf_is_complete(self):
        root = self.node([self.node()])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), (None, None, False))

    def test_focus_after_a_pruned_branch_is_still_reported(self):
        pruned = self.node([self.node()])
        focused = self.node(focused=True)
        root = self.node([pruned, focused])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), ("text Editor", None, False))
        pruned.get_child_at_index.assert_not_called()

    def test_selection_uses_standard_atspi_api_and_character_offsets(self):
        focused = self.node(focused=True)
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=lambda _iface, index: types.SimpleNamespace(start_offset=1, end_offset=4),
            get_text=lambda _iface, start, end: "a中文🙂z"[start:end],
        )
        self.assertEqual(self.runtime.focus_details(focused), ("text Editor", "中文🙂", False))
        self.assertEqual(self.runtime.focus_details(focused, text_limit=2), ("text Ed...", "中文...", False))

    def test_no_selection_does_not_fetch_a_range(self):
        selection = mock.Mock()
        self.runtime.Atspi.Text = types.SimpleNamespace(get_n_selections=lambda _: 0, get_selection=selection)
        self.assertEqual(self.runtime.focus_details(self.node(focused=True)), ("text Editor", None, False))
        selection.assert_not_called()

    def test_selection_read_failure_keeps_the_focus_summary(self):
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=mock.Mock(side_effect=RuntimeError("element became unavailable")),
        )
        self.assertEqual(self.runtime.focus_details(self.node(focused=True)), ("text Editor", None, False))

    def test_snapshot_reports_focus_budget_exhaustion(self):
        with mock.patch.object(self.runtime, "resolve_app"), \
             mock.patch.object(self.runtime, "main_window", return_value=(0, self.node())), \
             mock.patch.object(self.runtime, "extents"), \
             mock.patch.object(self.runtime, "render_tree", return_value=([], [])), \
             mock.patch.object(self.runtime, "focus_details", return_value=(None, None, True)) as focus, \
             mock.patch.object(self.runtime, "node_pid", return_value=42), \
             mock.patch.object(self.runtime, "node_name", return_value="Editor"), \
             mock.patch.object(self.runtime, "capture_window_png"):
            state = self.runtime.build_snapshot("Editor", max_tree_nodes=5, max_tree_depth=2)
        self.assertIn("incomplete", state["treeLines"][0])
        self.assertEqual(focus.call_args.args[2:], (5, 2))


class RuntimeActionReadBackTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(self.runtime, "resolve_app"))
        self.stack.enter_context(mock.patch.object(self.runtime, "main_window", return_value=(0, object())))
        for name in ("extents", "find_element", "send_key", "send_drag", "send_mouse_click",
                     "invoke_secondary_action", "scroll_element", "insert_text", "set_element_value"):
            self.stack.enter_context(mock.patch.object(self.runtime, name))
        self.snapshot = self.stack.enter_context(mock.patch.object(self.runtime, "build_snapshot", return_value={"elements": []}))
        self.sleep = self.stack.enter_context(mock.patch.object(self.runtime.time, "sleep"))

    def test_all_actions_skip_snapshot_and_settle_when_requested(self):
        for tool, arguments in (
            ("click", {"x": 1, "y": 2}),
            ("drag", {"from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4}),
            ("press_key", {"key": "Return"}),
            ("type_text", {"text": "hello"}),
            ("set_value", {"value": "hello"}),
            ("perform_secondary_action", {"action": "activate"}),
            ("scroll", {"direction": "down", "pages": 1}),
        ):
            with self.subTest(tool=tool):
                with mock.patch.object(self.runtime, "screen_point", side_effect=[(1, 2), (3, 4)]):
                    result = self.runtime.perform_operation({"tool": tool, "app": "Editor", "skip_read_back": True, **arguments})
                self.assertEqual(result, {"ok": True})
                self.snapshot.assert_not_called()
                self.sleep.assert_not_called()
        self.runtime.send_key.assert_called_once_with("Return")
        self.runtime.send_drag.assert_called_once_with(1, 2, 3, 4)
        self.runtime.insert_text.assert_called_once()

    def test_default_action_still_waits_and_returns_snapshot(self):
        result = self.runtime.perform_operation({"tool": "press_key", "app": "Editor", "key": "Return"})
        self.assertEqual(result, {"ok": True, "snapshot": {"elements": []}})
        self.sleep.assert_called_once_with(0.12)
        self.snapshot.assert_called_once_with("Editor")

    def test_explicit_observation_is_not_suppressed(self):
        result = self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", "skip_read_back": True})
        self.assertIn("snapshot", result)
        self.snapshot.assert_called_once()

    def test_action_errors_are_not_suppressed(self):
        self.runtime.send_key.side_effect = RuntimeError("input failed")
        with self.assertRaisesRegex(RuntimeError, "input failed"):
            self.runtime.perform_operation({"tool": "press_key", "app": "Editor", "key": "Return", "skip_read_back": True})
        self.snapshot.assert_not_called()




class TreeBudgetTests(unittest.TestCase):
    class Node:
        def __init__(self, role, name, children=(), showing=True):
            self.role, self.name, self.children, self.showing = role, name, list(children), showing
            self.child_reads = 0
        def get_role_name(self): return self.role
        def get_name(self): return self.name
        def get_child_count(self): return len(self.children)
        def get_child_at_index(self, index):
            self.child_reads += 1
            return self.children[index]
        def get_state_set(self): return self
        def contains(self, state):
            if self.showing is None: raise RuntimeError("unknown")
            return self.showing
        def get_interfaces(self): return []

    def test_later_nested_buttons_survive_large_collection_with_original_paths(self):
        runtime = load_runtime()
        runtime.Atspi.StateType = types.SimpleNamespace(SHOWING=1)
        rows = [self.Node("table cell", str(i)) for i in range(2000)]
        collection = self.Node("table", "Files", rows)
        cancel = self.Node("push button", "Cancel")
        root = self.Node("dialog", "Open", [collection, self.Node("panel", "footer", [cancel])])
        selected, truncated = runtime.prioritized_tree_nodes(root, [4, 2], 20, 64)
        self.assertTrue(truncated)
        self.assertLessEqual(len(selected), 20)
        self.assertIn(((4, 2, 1, 0), cancel, 2), selected)
        self.assertLessEqual(collection.child_reads, 80)
        self.assertEqual([path for path, _, _ in selected], sorted(path for path, _, _ in selected))

    def test_hidden_unknown_visibility_depth_and_cycles(self):
        runtime = load_runtime()
        runtime.Atspi.StateType = types.SimpleNamespace(SHOWING=1)
        hidden = self.Node("push button", "Hidden", showing=False)
        unknown = self.Node("push button", "Unknown", showing=None)
        root = self.Node("dialog", "Root", [hidden, unknown])
        root.children.append(root)
        selected, truncated = runtime.prioritized_tree_nodes(root, [0], 2, 64)
        self.assertEqual([node for _, node, _ in selected], [root, unknown])
        self.assertTrue(truncated)
        selected, truncated = runtime.prioritized_tree_nodes(root, [0], 20, 0)
        self.assertEqual(len(selected), 1)
        self.assertTrue(truncated)

    def test_duplicate_and_invalid_children_still_consume_discovery_budget(self):
        runtime = load_runtime()
        runtime.Atspi.StateType = types.SimpleNamespace(SHOWING=1)
        for invalid in (False, True):
            root = self.Node("dialog", "Root")
            root.children = [None if invalid else root] * 10000
            selected, truncated = runtime.prioritized_tree_nodes(root, [0], 20, 64)
            self.assertEqual(len(selected), 1)
            self.assertTrue(truncated)
            self.assertLessEqual(root.child_reads, 79)
            root.child_reads = 0
            runtime.prioritized_tree_nodes(root, [0], 20, 0)
            self.assertEqual(root.child_reads, 0)

    def test_gtk_showing_flag_does_not_override_offscreen_cell_geometry(self):
        runtime = load_runtime()
        runtime.Atspi.StateType = types.SimpleNamespace(SHOWING=1)
        hidden = self.Node("table cell", "Old first", showing=True)
        visible = self.Node("table cell", "Visible last", showing=True)
        root = self.Node("table", "Files", [hidden, visible])
        bounds = dict(x=0, y=0, width=600, height=300)
        def geometry(node):
            return dict(x=-2147483648, y=-2147483648, width=600, height=20) if node is hidden else bounds
        with mock.patch.object(runtime, "extents", side_effect=geometry):
            selected, _ = runtime.prioritized_tree_nodes(root, [0], 2, 64, bounds)
        self.assertEqual([node for _, node, _ in selected], [root, visible])

if __name__ == "__main__":
    unittest.main()
