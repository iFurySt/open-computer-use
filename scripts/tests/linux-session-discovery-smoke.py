#!/usr/bin/env python3
"""Reproduce #66 through real /proc discovery and native GTK observations.
Run on a private D-Bus/Xvfb session; the sandbox process is a controlled stand-in,
not a full Flatpak installation or a GNOME/Wayland desktop.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main(args):
    os.environ.pop('AT_SPI_BUS_ADDRESS', None)
    with tempfile.TemporaryDirectory(prefix='ocu-session-probe-') as directory:
        os.environ.setdefault('XDG_RUNTIME_DIR', directory)
        spec = importlib.util.spec_from_file_location('smoke', Path(__file__).with_name('linux-read-back-smoke.py'))
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        name = 'OCU Session Discovery Probe'
        state_file = Path(directory) / 'state.json'
        processes = []
        clients = []
        try:
            fixture = subprocess.Popen([sys.executable, str(Path(__file__).with_name('linux-read-back-smoke.py')),
                                        '--fixture', name, '--state-file', str(state_file)])
            processes.append(fixture)
            smoke.wait_for(state_file.exists, 'GTK fixture')
            with tempfile.TemporaryFile(mode='w+') as errors:
                # First establish that the baseline can observe this actual GTK window.
                before = smoke.MCP(args.baseline, None, errors)
                clients.append(before)
                def ready():
                    result = before.call('get_app_state', name, include_screenshot=False)
                    return not result.get('isError') and 'Read-back input' in smoke.text(result)
                smoke.wait_for(ready, 'baseline GTK observation before poisoning')
                print('Baseline without sandbox candidate: real GTK observation passed.')
                poison_env = dict(os.environ, FLATPAK_ID='org.example.OCUProbe',
                    AT_SPI_BUS_ADDRESS='unix:path=/run/flatpak/at-spi-bus',
                    XAUTHORITY='/run/user/1000/.mutter-Xwaylandauth.ocu-probe')
                poison = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(180)',
                    '--env=XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.ocu-probe'], env=poison_env)
                processes.append(poison)
                time.sleep(.1)
                broken = before.call('get_app_state', name, include_screenshot=False)
                assert broken.get('isError'), 'baseline did not reproduce environment poisoning'
                errors.flush(); errors.seek(0)
                evidence = smoke.text(broken) + errors.read()
                assert '/run/flatpak/at-spi-bus' in evidence, 'failure was not the sandbox bus path'
                print('Baseline with sandbox candidate: missing Flatpak a11y socket failure reproduced.')
                fixed = smoke.MCP(args.native, None, errors)
                clients.append(fixed)
                observed = fixed.call('get_app_state', name, include_screenshot=False)
                assert not observed.get('isError'), smoke.text(observed)
                index = smoke.element_index(observed, 'Read-back input')
                result = fixed.call('set_value', name, element_index=index, value='session-bus-fallback-ok')
                assert not result.get('isError'), smoke.text(result)
                smoke.wait_for(lambda: json.loads(state_file.read_text())['text']=='session-bus-fallback-ok', 'actual GTK write')
                print('Patched with same sandbox candidate: snapshot, actual GTK write and action read-back passed.')
                # The explicit override remains usable, including addresses carrying a GUID.
                from gi.repository import Gio, GLib
                bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
                address = bus.call_sync('org.a11y.Bus', '/org/a11y/bus', 'org.a11y.Bus', 'GetAddress',
                    None, GLib.VariantType.new('(s)'), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
                explicit = smoke.MCP(args.native, None, errors, {'AT_SPI_BUS_ADDRESS':address})
                clients.append(explicit)
                result=explicit.call('get_app_state', name, include_screenshot=False)
                assert not result.get('isError') and 'session-bus-fallback-ok' in smoke.text(result)
                print('Explicit caller a11y bus override still works.')
        finally:
            for client in clients:
                client.close()
            for process in reversed(processes):
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--native',required=True)
    parser.add_argument('--baseline',required=True)
    main(parser.parse_args())
