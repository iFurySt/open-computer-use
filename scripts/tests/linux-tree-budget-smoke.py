#!/usr/bin/env python3
"""Real GTK/AT-SPI large collection through the native MCP; run in private Xvfb/D-Bus."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def fixture(name, state_file):
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk, GLib
    GLib.set_prgname(name)
    window = Gtk.Window(title=name)
    window.set_default_size(600, 420)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    window.add(box)
    store = Gtk.ListStore(str)
    for i in range(2000): store.append([f'Budget item {i:04d}'])
    tree = Gtk.TreeView(model=store)
    tree.append_column(Gtk.TreeViewColumn('Files', Gtk.CellRendererText(), text=0))
    scroll = Gtk.ScrolledWindow()
    scroll.set_size_request(550, 300)
    scroll.add(tree)
    box.pack_start(scroll, True, True, 0)
    state = {'clicks': 0, 'scrolled': False}
    footer = Gtk.Box()
    button = Gtk.Button(label='Budget open')
    end = Gtk.Button(label='Budget scroll end')
    footer.pack_start(button, False, False, 0)
    footer.pack_start(end, False, False, 0)
    box.pack_start(footer, False, False, 0)
    def clicked(*_): state['clicks'] += 1
    def scrolled(*_):
        tree.scroll_to_cell(Gtk.TreePath.new_from_indices([1999]), None, True, 1.0, 0.0)
        state['scrolled'] = True
    button.connect('clicked', clicked)
    end.connect('clicked', scrolled)
    def publish():
        temporary = state_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(state))
        temporary.replace(state_file)
        return True
    GLib.timeout_add(50, publish)
    window.show_all()
    Gtk.main()


def smoke(native):
    spec = importlib.util.spec_from_file_location('helpers', Path(__file__).with_name('linux-read-back-smoke.py'))
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    with tempfile.TemporaryDirectory(prefix='ocu-tree-') as directory:
        root = Path(directory)
        state_file = root / 'state.json'
        name = 'OCUTreeFixture' + str(os.getpid())
        with (root / 'stderr.log').open('w+') as stderr:
            child = subprocess.Popen([sys.executable, __file__, '--fixture', name, '--state-file', str(state_file)], stderr=stderr)
            client = None
            try:
                helpers.wait_for(state_file.exists, 'GTK startup')
                client = helpers.MCP(native, '0', stderr)
                helpers.wait_for(lambda: not client.call('get_app_state', name, include_screenshot=False).get('isError'), 'AT-SPI registration')
                for budget in (1200, 40):
                    result = client.call('get_app_state', name, include_screenshot=False, max_tree_nodes=budget)
                    assert not result.get('isError'), result
                    import re
                    assert len(re.findall(r'^\s*\d+ ', helpers.text(result), re.M)) <= budget
                    index = helpers.element_index(result, 'Budget open')
                    before = json.loads(state_file.read_text())['clicks']
                    action = client.call('click', name, element_index=index)
                    assert not action.get('isError'), action
                    helpers.wait_for(lambda: json.loads(state_file.read_text())['clicks'] == before + 1, 'Actual footer click')
                    print(f'Budget {budget}: footer retained and receiver click verified.', flush=True)
                result = client.call('get_app_state', name, include_screenshot=False)
                action = client.call('click', name, element_index=helpers.element_index(result, 'Budget scroll end'))
                assert not action.get('isError'), action
                helpers.wait_for(lambda: json.loads(state_file.read_text())['scrolled'], 'Scroll end')
                time.sleep(0.5)
                result = client.call('get_app_state', name, include_screenshot=False)
                assert 'Budget item 1999' in helpers.text(result), helpers.text(result)[-1500:]
                print('Real GTK/AT-SPI: 2000 rows, strict budgets, footer actions and newly visible last row passed.', flush=True)
            finally:
                if client: client.close()
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native')
    parser.add_argument('--fixture')
    parser.add_argument('--state-file', type=Path)
    args = parser.parse_args()
    if args.fixture: fixture(args.fixture, args.state_file)
    else: smoke(args.native)
