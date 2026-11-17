#!/usr/bin/env python3
"""Compare two release resource harnesses using identical fixtures and alternating order."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--before', required=True)
parser.add_argument('--after', required=True)
parser.add_argument('--fixtures', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--runs', type=int, default=5)
args = parser.parse_args()
scenarios = {'live-history': 10, 'annotations': 120, 'static-scroll': 12, 'stitch': 50}
records = []
checksums = {}
for repetition in range(args.runs):
    order = ['before', 'after'] if repetition % 2 == 0 else ['after', 'before']
    for scenario, expected_work in scenarios.items():
        for side in order:
            process = subprocess.run([getattr(args, side), scenario, args.fixtures],
                                     capture_output=True, text=True, timeout=120)
            phases = [json.loads(line[9:]) for line in process.stdout.splitlines() if line.startswith('RESOURCE ')]
            if process.returncode or not phases or phases[-1].get('errors') != 0:
                raise RuntimeError(f'{side}/{scenario} failed\n{process.stdout}\n{process.stderr}')
            done = phases[-1]
            if done['completed'] != expected_work or done['memoryStatus'] != 0:
                raise RuntimeError(f'{side}/{scenario} did not complete the expected work')
            expected_checksum = checksums.setdefault(scenario, done['checksum'])
            if done['checksum'] != expected_checksum:
                raise RuntimeError(f'{side}/{scenario} output differs')
            for phase in phases:
                records.append(dict(phase, side=side, repetition=repetition + 1))
            print(f'{repetition + 1}/{args.runs} {side} {scenario} completed={expected_work}', flush=True)

metrics = [('live-history', 'recorded', 'footprintBytes'),
           ('live-history', 'recorded', 'peakFootprintBytes'),
           ('live-history', 'recordingReturned', 'operationMs'),
           ('annotations', 'dragged', 'operationMs'),
           ('annotations', 'dragged', 'notifications'),
           ('static-scroll', 'estimated', 'operationMs'),
           ('stitch', 'stitched', 'operationMs'),
           ('stitch', 'stitched', 'peakFootprintBytes')]
summary = []
for scenario, phase, metric in metrics:
    entry = {'scenario': scenario, 'phase': phase, 'metric': metric}
    for side in ['before', 'after']:
        values = [row[metric] for row in records if row['scenario'] == scenario and row['phase'] == phase and row['side'] == side]
        entry[side] = {'median': statistics.median(values), 'min': min(values), 'max': max(values), 'runs': len(values)}
    summary.append(entry)
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({'logicalCPUs': os.cpu_count(), 'runsPerSide': args.runs,
    'records': records, 'summary': summary}, indent=2) + '\n')
print(json.dumps(summary, indent=2))
