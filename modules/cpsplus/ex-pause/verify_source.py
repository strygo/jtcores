#!/usr/bin/env python3
"""Standalone full-tree verifier for the EX pause FPGA candidate."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASE = '9886018dac2c0de37474b9d924765db3aa75da09'
MANIFEST = 'modules/cpsplus/ex-pause/source.json'
FILES = {'modules/cpsplus/hdl/cpsplus_top.v', '.github/workflows/build_cores.yml',
         'modules/cpsplus/ex-pause/verify_source.py'}


def git(root,*args):
    return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()


def contract(m):
    if m['base_revision'] != BASE or set(m['files']) != FILES:
        raise ValueError('unknown base or incomplete source contract')
    required={'modules/fx68k','modules/jtdsp16','modules/jteeprom'}
    if set(m['submodules']) != required:
        raise ValueError('missing or unexpected FPGA submodule')


def verify(root):
    root=Path(root).resolve()
    m=json.loads((root/MANIFEST).read_text())
    contract(m)
    if set(git(root,'diff','--name-only',BASE,'HEAD').splitlines()) != FILES|{MANIFEST}:
        raise ValueError('changes outside the declared pause bridge and build provenance')
    if git(root,'status','--porcelain','--untracked-files=all'):
        raise ValueError('dirty FPGA source checkout')
    for name,digest in m['files'].items():
        if hashlib.sha256((root/name).read_bytes()).hexdigest() != digest:
            raise ValueError('candidate source changed: '+name)
    for name,digest in m['submodules'].items():
        if git(root/name,'rev-parse','HEAD') != digest or git(root/name,'status','--porcelain'):
            raise ValueError('FPGA submodule changed: '+name)
    print('PASS approved full-tree baseline plus declared EX pause bridge; clean pinned source')
    return m


def self_test():
    m=dict(base_revision=BASE,files=dict.fromkeys(FILES,'0'*64),submodules=dict.fromkeys(
        ('modules/fx68k','modules/jtdsp16','modules/jteeprom'),'0'*40))
    contract(m)
    for key,value in [('base_revision','0'*40),('files',{}),('submodules',{})]:
        try:contract(dict(m,**{key:value}))
        except ValueError:pass
        else:raise AssertionError('incomplete provenance accepted')
    print('PASS exact base, complete file scope and mandatory submodule negative controls')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path)
    p.add_argument('--self-test',action='store_true');a=p.parse_args()
    if a.self_test:self_test()
    if a.root:verify(a.root)
    if not (a.self_test or a.root):p.error('select --root or --self-test')
