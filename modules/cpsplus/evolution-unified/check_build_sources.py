#!/usr/bin/env python3
"""Check the real JTFRAME synthesis list before starting Quartus.

Rebuilds the pinned Go tool in an explicit disposable directory. Runs the
same file-list command as jtcore, plus an explicit-macro control. No source
files are changed and no existing scratch input is required.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

LOADER = 'modules/jtframe/target/mister/hdl/jtframe_cps2_load.v'
MACROS = 'CPS2_UNIFIED,CPSPLUS,CPSPLUS_EXTENT,CPS2_NATIVE128,CPS2_QSND32'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(text, core):
    expected = 'set_global_assignment -name VERILOG_FILE ' + str(core / LOADER)
    lines = text.splitlines()
    mentions = [line for line in lines if 'jtframe_cps2_load.v' in line]
    if mentions != [expected]:
        raise ValueError('synthesis list must contain exactly one correct loader source assignment')
    if not (core / LOADER).is_file():
        raise ValueError('listed loader source is missing')


def identity(core):
    files = subprocess.check_output(['git', '-c', 'safe.directory=' + str(core),
                                     '-C', str(core), 'ls-files', '-z']).decode().split('\0')
    # Pin all possible parser/config inputs, including recursive YAML aliases.
    return {rel: sha(core / rel) for rel in sorted(files)
            if rel and Path(rel).suffix in ('.go', '.mod', '.sum', '.yaml', '.def')
            and (core / rel).is_file()}


def self_test(core):
    expected = 'set_global_assignment -name VERILOG_FILE ' + str(core / LOADER)
    validate(expected + '\n', core)
    for bad in ('', expected + '\n' + expected, expected.replace('VERILOG_FILE', 'VHDL_FILE')):
        try:
            validate(bad, core)
        except ValueError:
            continue
        raise AssertionError('invalid loader assignment passed')
    print('PASS build-source negative controls: omitted, duplicated and wrong file type rejected', flush=True)


def check(core, work):
    if work.exists():
        raise ValueError('build-source output must be a fresh empty directory')
    work.mkdir(parents=True)
    inputs = identity(core)
    recipe = sha(Path(__file__))
    go = Path(shutil.which('go') or '')
    if not go.is_file():
        raise ValueError('Go is required to rebuild the pinned JTFRAME generator')
    go_sha = sha(go)
    tool = work / 'jtframe'
    env = dict(os.environ, JTROOT=str(core), JTFRAME=str(core / 'modules/jtframe'),
               MODULES=str(core / 'modules'), CORES=str(core / 'cores'), JTBIN=str(work / 'release'))
    subprocess.run([str(go), 'build', '-buildvcs=false', '-o', str(tool), '.'],
                   cwd=core / 'modules/jtframe/src/jtframe', env=env, check=True)
    tool_sha = sha(tool)
    observations = []
    outputs = {}
    for name, extra in (('jtcore-default', []), ('explicit-unified', ['--macro', MACROS])):
        out = work / name
        out.mkdir()
        subprocess.run([str(tool), 'files', 'syn', 'cps2', '--target=mister', *extra],
                       cwd=out, env=env, check=True)
        text = (out / 'files.qip').read_text()
        validate(text, core)
        # Portable receipt: the real output retains its paths in disposable work.
        outputs[name] = hashlib.sha256(text.replace(str(core), '<core>').encode()).hexdigest()
        observations.append('PASS actual JTFRAME synthesis list: ' + name + ' includes loader once')
    self_test(core)
    if inputs != identity(core) or recipe != sha(Path(__file__)) or go_sha != sha(go) or tool_sha != sha(tool):
        raise ValueError('build-source inputs or executable changed during check')
    record = dict(schema_version=1, status='pass', scope='actual synthesis source listing; no FPGA fit',
                  recipe_sha256=recipe, inputs=inputs, executable_sha256=tool_sha,
                  go_sha256=go_sha, output_sha256=outputs, observations=observations)
    (work / 'receipt.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for observation in observations:
        print(observation, flush=True)
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    check(args.root.resolve(), args.work.resolve())
