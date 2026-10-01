#!/usr/bin/env python3
"""Chart GitLab Performance Tool's native aggregate JSON without merging endpoint percentiles."""
import argparse
import json
from datetime import datetime
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def render_resources(source, output):
    path = source / 'generator-resources.jsonl'
    if not path.exists():
        return
    samples = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    samples = [s for s in samples if s.get('phase') == 'benchmark' and 'cpu' in s and 'memory_bytes' in s]
    if len(samples) < 2:
        return
    times = [datetime.fromisoformat(s['time'].replace('Z', '+00:00')) for s in samples]
    counters = [dict(line.split() for line in s['cpu'].splitlines()) for s in samples]
    elapsed, cores, memory = [], [], []
    for i in range(1, len(samples)):
        seconds = (times[i]-times[i-1]).total_seconds()
        if seconds <= 0:
            continue
        elapsed.append((times[i]-times[0]).total_seconds()/60)
        cores.append((int(counters[i]['usage_usec'])-int(counters[i-1]['usage_usec']))/seconds/1e6)
        memory.append(int(samples[i]['memory_bytes'])/1024**3)
    if not cores:
        return
    fig, axes = plt.subplots(2, 1, figsize=(12, 6), sharex=True)
    axes[0].plot(elapsed, cores, color='#4d67c7', label='Sampled CPU usage')
    quota = samples[-1].get('cpu_limit', '').split()
    if len(quota) == 2 and quota[0] != 'max':
        axes[0].axhline(int(quota[0])/int(quota[1]), color='#ce4a50', linestyle='--', label='Container CPU limit')
    axes[0].set_ylabel('CPU cores')
    axes[1].plot(elapsed, memory, color='#23856d', label='Container memory')
    limit = samples[-1].get('memory_limit_bytes', 'max')
    if limit != 'max':
        axes[1].axhline(int(limit)/1024**3, color='#ce4a50', linestyle='--', label='Container memory limit')
    axes[1].set_ylabel('Memory (GiB)')
    axes[1].set_xlabel('Minutes since first benchmark resource sample')
    for ax in axes:
        ax.set_ylim(bottom=0)
        ax.grid(alpha=.2)
        ax.legend(loc='upper right')
    fig.suptitle('GitLab Performance Tool generator resources during the benchmark phase')
    fig.tight_layout()
    for extension in ('png', 'svg'):
        fig.savefig(output/f'generator-resources.{extension}', dpi=160)
    plt.close(fig)
    periods = int(counters[-1].get('nr_periods',0))-int(counters[0].get('nr_periods',0))
    throttled = int(counters[-1].get('nr_throttled',0))-int(counters[0].get('nr_throttled',0))
    (output/'generator-resources.json').write_text(json.dumps({
        'samples':len(samples), 'max_sampled_cpu_cores':max(cores), 'max_sampled_memory_gib':max(memory),
        'throttled_period_percent':100*throttled/periods if periods else None,
        'note':'Container cgroup samples, including GitLab Performance Tool benchmark setup; short peaks between samples may be missed.'
    },indent=2)+'\n')


def render(source, output):
    candidates = []
    for path in sorted(source.rglob('*_results.json')):
        if 'failed_test_results' in path.parts or 'test_results' in path.parts:
            continue
        data = json.loads(path.read_text())
        if isinstance(data, dict) and data.get('test_results'):
            candidates.append((path, data))
    if not candidates:
        raise ValueError('No GitLab Performance Tool aggregate results found; inspect generator.log and benchmark.log. No performance result can be reported.')
    output.mkdir(parents=True, exist_ok=True)
    summaries = []
    report_lines = ['# GitLab Performance Tool results', '',
                    'Each endpoint is tested separately. The upstream score is not the percentage of tests passed.', '']
    coverage_path = source / 'suite-coverage.json'
    coverage_complete = True
    if coverage_path.exists():
        coverage = json.loads(coverage_path.read_text())
        counts = {status: sum(t['status'] == status for t in coverage) for status in
                  ('passed', 'failed', 'blocked', 'not_reported', 'selected')}
        coverage_complete = not (counts['failed'] or counts['not_reported'] or counts['selected'])
        report_lines += ['## Full-suite coverage', '',
                         f"Inventory: **{len(coverage)}** tests · passed: **{counts['passed']}** · failed: **{counts['failed']}** · blocked: **{counts['blocked']}** · missing results: **{counts['not_reported'] + counts['selected']}**.", '',
                         'Blocked tests were not executed and are not counted as passes. A successful supported subset does not mean every test in the full inventory ran.', '',
                         '| Unexecuted test | Status | Reason |', '| --- | --- | --- |']
        for test in coverage:
            if test['status'] not in ('passed', 'failed'):
                report_lines.append(f"| {test['name']} | {test['status']} | {test.get('reason') or 'No native GitLab Performance Tool result was produced.'} |")
        report_lines.append('')
    plt.rcParams.update({'font.size': 9, 'axes.spines.top': False, 'axes.spines.right': False})
    for source_path, data in candidates:
        # k6 can fail before printing its script name or any metrics.
        rows = [dict(row, name=row.get('name') or f'unidentified_test_{index}')
                for index, row in enumerate(data['test_results'], 1)]
        passed = sum(r.get('result') is True for r in rows)
        summary = {k: data.get(k) for k in ('name', 'version', 'gpt_version', 'option', 'date', 'time', 'overall_result', 'overall_result_score')}
        summary.update(tests=len(rows), passed=passed, failed=len(rows)-passed, source=str(source_path), failed_tests=[r['name'] for r in rows if r.get('result') is not True])
        summaries.append(summary)
        score = f"{data['overall_result_score']}%" if data.get('overall_result_score') is not None else 'N/A'
        report_lines += [f"## {data.get('name', 'Environment')} — {data.get('date', '')}", '',
                         f"GitLab {data.get('version')} · GitLab Performance Tool {data.get('gpt_version')} · Profile `{data.get('option')}`", '',
                         f"**{'PASS' if data.get('overall_result') is True else 'FAIL'}** — {passed}/{len(rows)} tests passed; upstream score: {score}.", '',
                         '| Test | Result | P90 TTFB (ms) | P90 limit (ms) | RPS | RPS minimum | Success (%) |',
                         '| --- | --- | ---: | ---: | ---: | ---: | ---: |']
        for row in rows:
            metrics = [str(row.get(key) if row.get(key) is not None else 'N/A') for key in
                       ('ttfb_p90', 'ttfb_p90_threshold', 'rps_result', 'rps_threshold', 'success_rate')]
            report_lines.append('| ' + ' | '.join([row['name'], 'PASS' if row.get('result') is True else 'FAIL', *metrics]) + ' |')
        report_lines.append('')
        for page, start in enumerate(range(0, len(rows), 20), 1):
            batch = rows[start:start+20]
            fig, axes = plt.subplots(1, 3, figsize=(20, max(5, len(batch)*.38+2)), sharey=True, gridspec_kw={'width_ratios': [1.3, 1, 1]})
            y = list(range(len(batch)))
            colors = ['#23856d' if r.get('result') else '#ce4a50' for r in batch]
            for ax, metric, threshold, title in zip(axes, ['ttfb_p90', 'rps_result', 'success_rate'], ['ttfb_p90_threshold', 'rps_threshold', 'success_rate_threshold'], ['P90 time to first byte (ms) · lower is better', 'Requests/sec · higher is better', 'Successful requests (%) · higher is better']):
                values = [float(r[metric]) if r.get(metric) is not None else 0 for r in batch]
                ax.barh(y, values, color=colors, height=.6)
                for i, row in enumerate(batch):
                    if row.get(threshold) is not None:
                        ax.plot(float(row[threshold]), i, '|', color='#202a44', markersize=15, markeredgewidth=2)
                    if row.get(metric) is None:
                        ax.text(0, i, ' N/A', va='center')
                ax.set_title(title, fontsize=10)
                ax.grid(axis='x', alpha=.2)
                ax.set_axisbelow(True)
            axes[0].set_yticks(y, [r['name'].removesuffix('.js') for r in batch])
            axes[0].invert_yaxis()
            axes[2].set_xlim(0, 105)
            fig.suptitle(f"GitLab Performance Tool {data.get('gpt_version')} | GitLab {data.get('version')} | {data.get('option')}\n{passed}/{len(rows)} tests passed · upstream score: {score} · page {page}", fontsize=14)
            fig.text(.5, .015, 'Green: passed · Red: failed · Dark tick: upstream threshold. Each row is a separate test; percentiles are not combined.', ha='center')
            fig.tight_layout(rect=(0,.04,1,.93))
            for extension in ('png', 'svg'):
                fig.savefig(output / f'{source_path.stem}-{page:02d}.{extension}', dpi=160)
            plt.close(fig)
            report_lines.append(f"Charts, page {page}: [PNG]({source_path.stem}-{page:02d}.png) · [SVG]({source_path.stem}-{page:02d}.svg)")
        report_lines.append('')
    (output/'summary.json').write_text(json.dumps(summaries, indent=2)+'\n')
    render_resources(source, output)
    if (output/'generator-resources.json').exists():
        resources = json.loads((output/'generator-resources.json').read_text())
        report_lines += ['## Load generator resources', '',
                         '[PNG](generator-resources.png) · [SVG](generator-resources.svg)', '',
                         f"Peak sampled CPU: {resources['max_sampled_cpu_cores']:.2f} cores; peak sampled memory: {resources['max_sampled_memory_gib']:.2f} GiB.",
                         resources['note'], '']
    (output/'summary.md').write_text('\n'.join(report_lines)+'\n')
    print(json.dumps(summaries, indent=2))
    return coverage_complete and all(s['overall_result'] is True for s in summaries)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        ok = render(args.results, args.output)
    except (ValueError, KeyError, TypeError) as exc:
        parser.exit(2, f'{exc}\n')
    raise SystemExit(0 if ok else 1)
