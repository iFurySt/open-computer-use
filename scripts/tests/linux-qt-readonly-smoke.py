#!/usr/bin/env python3
"""Real Qt 6 read-only/writable controls through native MCP in private Xvfb/D-Bus."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def fixture(name, state_file):
    from PyQt6.QtCore import QTimer
    from PyQt6.QtWidgets import QApplication, QWidget, QVBoxLayout, QLineEdit, QSpinBox
    app = QApplication([name]); app.setApplicationName(name)
    window = QWidget(); window.setWindowTitle(name)
    layout = QVBoxLayout(window)
    readonly = QLineEdit('fixed'); readonly.setReadOnly(True); readonly.setAccessibleName('Readonly probe')
    writable = QLineEdit('old'); writable.setAccessibleName('Writable probe')
    spin = QSpinBox(); spin.setAccessibleName('Spin probe')
    for control in (readonly, writable, spin): layout.addWidget(control)
    def publish():
        tmp = state_file.with_suffix('.tmp')
        tmp.write_text(json.dumps({'readonly': readonly.text(), 'writable': writable.text(), 'spin': spin.value()}))
        tmp.replace(state_file)
    timer = QTimer(); timer.timeout.connect(publish); timer.start(30)
    window.show(); publish(); app.exec()


def smoke(native, expect_baseline):
    spec = importlib.util.spec_from_file_location('helpers', Path(__file__).with_name('linux-read-back-smoke.py'))
    h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
    with tempfile.TemporaryDirectory(prefix='ocu-qt-readonly-') as directory:
        state_file = Path(directory) / 'state.json'; name = 'OCUQtReadonly' + str(os.getpid())
        with tempfile.TemporaryFile(mode='w+') as errors:
            child = subprocess.Popen([sys.executable, __file__, '--fixture', name, '--state-file', str(state_file)], stderr=errors)
            client = None
            try:
                h.wait_for(state_file.exists, 'Qt fixture startup')
                client = h.MCP(native, '0', errors)
                name = str(child.pid)
                h.wait_for(lambda: not client.call('get_app_state', name, include_screenshot=False).get('isError'), 'Qt accessibility registration')
                for label, key, value in [('Readonly probe', 'readonly', 'changed'), ('Writable probe', 'writable', 'hello'), ('Spin probe', 'spin', '7')]:
                    tree = client.call('get_app_state', name, include_screenshot=False)
                    assert not tree.get('isError'), h.text(tree)
                    match = re.search(r'^\s*(\d+) .*' + label, h.text(tree), re.M)
                    assert match, h.text(tree)
                    result = client.call('set_value', name, element_index=match[1], value=value)
                    if key == 'readonly' and not expect_baseline:
                        assert result.get('isError') and 'read-only' in h.text(result), result
                        assert json.loads(state_file.read_text())[key] == 'fixed', state_file.read_text()
                    else:
                        assert not result.get('isError'), result
                        h.wait_for(lambda: json.loads(state_file.read_text())[key] == (int(value) if key == 'spin' else value), 'actual Qt receiver value')
                    print(f'Qt {key}: {state_file.read_text()}; expected baseline={expect_baseline}', flush=True)
            finally:
                if client: client.close()
                child.terminate(); child.wait(timeout=5)
                errors.seek(0); print(errors.read()[-1200:])


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--native'); p.add_argument('--expect-baseline-write', action='store_true')
    p.add_argument('--fixture'); p.add_argument('--state-file', type=Path); args = p.parse_args()
    if args.fixture: fixture(args.fixture, args.state_file)
    else: smoke(args.native, args.expect_baseline_write)
