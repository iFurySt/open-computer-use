#!/usr/bin/env python3
"""Real GTK editable controls; run in an isolated Xvfb/D-Bus desktop."""
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
    import gi
    gi.require_version('Gtk','3.0')
    from gi.repository import Gtk, GLib
    GLib.set_prgname(name)
    window=Gtk.Window(title=name);window.set_default_size(500,300)
    box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL);window.add(box)
    entries={}
    for mode in ['normal','ignore','limited','delay']:
        entry=Gtk.Entry(text='old');entry.get_accessible().set_name('Value '+mode)
        entries[mode]=entry;box.pack_start(entry,False,False,5)
        if mode=='limited': entry.set_max_length(4)
        if mode=='ignore':
            entry.connect('insert-text',lambda e,*_:e.stop_emission_by_name('insert-text'))
            entry.connect('delete-text',lambda e,*_:e.stop_emission_by_name('delete-text'))
        if mode=='delay':
            guard={'applying':False}
            def insert(e,text,length,position):
                if guard['applying']: return
                e.stop_emission_by_name('insert-text')
                def apply():
                    guard['applying']=True;e.set_text(text);guard['applying']=False;return False
                GLib.timeout_add(200,apply)
            entry.connect('insert-text',insert)
    scale=Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL,0,100,1)
    scale.get_accessible().set_name('Value number');box.pack_start(scale,False,False,5)
    def publish():
        state={mode:e.get_text() for mode,e in entries.items()};state['number']=scale.get_value()
        temp=state_file.with_suffix('.tmp');temp.write_text(json.dumps(state));temp.replace(state_file);return True
    GLib.timeout_add(30,publish);window.show_all();Gtk.main()

def smoke(native):
    spec=importlib.util.spec_from_file_location('helpers',Path(__file__).with_name('linux-read-back-smoke.py'))
    h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
    with tempfile.TemporaryDirectory(prefix='ocu-set-value-') as directory:
        root=Path(directory);state_file=root/'state.json';name='OCUValueFixture'+str(os.getpid())
        with (root/'stderr.log').open('w+') as stderr:
            child=subprocess.Popen([sys.executable,__file__,'--fixture',name,'--state-file',str(state_file)],stderr=stderr)
            client=None
            try:
                h.wait_for(state_file.exists,'GTK startup')
                for read_back in ['0','1']:
                    client=h.MCP(native,read_back,stderr)
                    for mode,value,error in [('normal',' \t中文🙂\n',False),('normal','',False),('normal','same',False),('normal','same',False),('delay','delayed',False),('number','15.0',False),('ignore','new',True),('limited','too long',True)]:
                        tree=client.call('get_app_state',name,include_screenshot=False)
                        assert not tree.get('isError'),h.text(tree)
                        match=re.search(r'^\s*(\d+) .*Value '+mode+r'\b',h.text(tree),re.M)
                        assert match,h.text(tree)
                        result=client.call('set_value',name,element_index=match[1],value=value)
                        assert bool(result.get('isError'))==error,h.text(result)
                        if error: assert 'could not verify' in h.text(result),h.text(result)
                        else: h.wait_for(lambda:json.loads(state_file.read_text())[mode]==(float(value) if mode=='number' else value),'Exact receiver value')
                        print(f'Real GTK read-back={read_back}, mode={mode}, expectedError={error}: passed.',flush=True)
                    client.close();client=None
            finally:
                if client:client.close()
                child.terminate();child.wait(timeout=5)
                stderr.seek(0);print(stderr.read()[-3000:])
    print('Real GTK/native MCP set_value verification passed.')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--fixture');p.add_argument('--state-file',type=Path);p.add_argument('--native');a=p.parse_args()
    if a.fixture: fixture(a.fixture,a.state_file)
    else: smoke(a.native)
