#!/usr/bin/env python3
"""
scripts/olm-dependencies.py - OLM dependencies of a pinned operator version,
read from the operator catalog (File-Based Catalog metadata).

For every component the approver must know which other CSVs OLM puts in the
same InstallPlan. They are declared by the operator bundle itself:

    olm.package.required   {packageName, versionRange}
    olm.gvk.required       {group, version, kind}   (provided by another bundle's olm.gvk)
    olm.constraint         {package: ...} / {gvk: ...} / {all: {constraints: [...]}}

This script resolves them (transitively) for the exact version in the versions
files and writes the exact dependency CSV names to versions.<component>.dependencies
in the file that defines that version. Run it after every version change: the
--check mode lists added and removed dependencies.

The catalog is read the same way olm-upgrade-analyzer does, one package at a time:

    oc image extract <catalog-image> --filter-by-os=linux/amd64 [-a <authfile>] \\
        --path /configs/<package>/:<cache>/<package>

Usage:
  scripts/olm-dependencies.py --catalog <index-image> odf                 # print
  scripts/olm-dependencies.py --catalog <index-image> odf --group group-a --check
  scripts/olm-dependencies.py --catalog <index-image> odf --group group-a --write
  scripts/olm-dependencies.py --catalog <index-image> odf \\
      --versions-file clusters/<cluster>/main-values.yaml --write          # a cluster
  scripts/olm-dependencies.py --configs <dir-with-/configs-layout> odf    # offline

Options:
  --catalog IMAGE     catalog index image (the mirrored one in airgapped setups),
                      e.g. registry.example.com/CHANGE-ME/redhat-operator-index:v4.18
  --authfile FILE     registry credentials for oc image extract
  --configs DIR       use an already extracted /configs tree instead of pulling
  --cache DIR         where pulled packages are kept (default: $TMPDIR/olm-dependencies)
  --full              pull the whole /configs (needed to find olm.gvk.required
                      providers that are not already in the cache)
  --group G           read the version from group-values/G/versions.yaml (+ defaults)
  --versions-file F   read the version from F (+ group, + defaults); --write targets F
  --check             compare with versions.<component>.dependencies; exit 1 on drift
  --write             write versions.<component>.dependencies into the defining file

Needs: python3 (stdlib only), yq v4, oc (unless --configs).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OS_FILTER = 'linux/amd64'


class Error(RuntimeError):
    pass


# --------------------------------------------------------------------------
# semver (OLM uses blang/semver ranges)
# --------------------------------------------------------------------------

SEMVER = re.compile(r'^v?(\d+)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')


def parse_version(text):
    m = SEMVER.match(text.strip())
    if not m:
        raise Error(f"not a semver version: {text!r}")
    nums = [m.group(1), m.group(2) or '0', m.group(3) or '0']
    pre = m.group(4)
    return tuple(int(n) if n.isdigit() else 0 for n in nums), \
        tuple(pre.split('.')) if pre else ()


def cmp_version(a, b):
    (na, pa), (nb, pb) = parse_version(a), parse_version(b)
    if na != nb:
        return -1 if na < nb else 1
    if pa == pb:
        return 0
    if not pa:          # release > pre-release
        return 1
    if not pb:
        return -1
    for x, y in zip(pa, pb):
        if x == y:
            continue
        if x.isdigit() and y.isdigit():
            return -1 if int(x) < int(y) else 1
        if x.isdigit() != y.isdigit():
            return -1 if x.isdigit() else 1
        return -1 if x < y else 1
    return -1 if len(pa) < len(pb) else (1 if len(pa) > len(pb) else 0)


def _wildcard_range(text):
    """'4.18.x' -> ('>=4.18.0', '<4.19.0')"""
    m = SEMVER.match(text)
    parts = [m.group(1), m.group(2), m.group(3)]
    if parts[1] in (None, 'x', 'X', '*'):
        return [('>=', f"{parts[0]}.0.0"), ('<', f"{int(parts[0]) + 1}.0.0")]
    return [('>=', f"{parts[0]}.{parts[1]}.0"), ('<', f"{parts[0]}.{int(parts[1]) + 1}.0")]


def in_range(version, rng):
    """blang/semver range: OR of '||', each an AND of space/comma separated comparators."""
    if not rng or not rng.strip():
        return True
    for alt in rng.split('||'):
        ok = True
        for tok in re.split(r'[\s,]+', alt.strip()):
            if not tok:
                continue
            m = re.match(r'^(>=|<=|!=|==|=|>|<)?\s*(.+)$', tok)
            op, ver = m.group(1) or '=', m.group(2)
            comparators = _wildcard_range(ver) if re.search(r'\.(x|X|\*)', ver) and op == '=' \
                else [(op, ver)]
            for op2, v2 in comparators:
                c = cmp_version(version, v2)
                if not {'>': c > 0, '>=': c >= 0, '<': c < 0, '<=': c <= 0,
                        '=': c == 0, '==': c == 0, '!=': c != 0}[op2]:
                    ok = False
        if ok:
            return True
    return False


# --------------------------------------------------------------------------
# catalog access
# --------------------------------------------------------------------------

def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise Error(f"{' '.join(cmd)} failed:\n{p.stderr.strip()}")
    return p.stdout


def yq_json(path_or_text, expr='.', is_text=False):
    if is_text:
        out = run(['yq', '-o=json', '-I=0', expr, '-'], input=path_or_text)
    else:
        out = run(['yq', '-o=json', '-I=0', expr, str(path_or_text)])
    return json.loads(out) if out.strip() else None


def json_stream(text):
    dec, i, n = json.JSONDecoder(), 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        obj, i = dec.raw_decode(text, i)
        if isinstance(obj, dict):
            yield obj


class Catalog:
    """Bundles per package from a /configs tree, pulled lazily from an image."""

    def __init__(self, image, authfile, configs, cache, full):
        self.image, self.authfile, self.full = image, authfile, full
        if configs:
            self.root = Path(configs)
        else:
            if not image:
                raise Error("--catalog IMAGE or --configs DIR is required")
            slug = re.sub(r'[^A-Za-z0-9._-]+', '_', image)
            self.root = Path(cache) / slug
        self.offline = bool(configs)
        self.bundles = {}
        self.channels = {}

    def _pull(self, src, dest):
        dest.mkdir(parents=True, exist_ok=True)
        cmd = ['oc', 'image', 'extract', self.image, f'--filter-by-os={OS_FILTER}',
               '--path', f'{src}:{dest}', '--confirm']
        if self.authfile:
            cmd[3:3] = ['-a', self.authfile]
        print(f"  pulling {src} from {self.image}", file=sys.stderr)
        try:
            run(cmd)
        except Error:
            shutil.rmtree(dest, ignore_errors=True)   # never cache a failed pull
            raise

    def pull_all(self):
        marker = self.root / '.complete'
        if not self.offline and not marker.exists():
            self._pull('/configs/', self.root)
            marker.touch()

    def package(self, name):
        if name in self.bundles:
            return self.bundles[name]
        pdir = self.root / name
        if not pdir.exists() and not self.offline:
            self._pull(f'/configs/{name}/', pdir)
        if not pdir.exists():
            raise Error(f"package {name} not found in {self.root}")
        bundles = []
        for f in sorted(pdir.rglob('*')):
            if not f.is_file():
                continue
            if f.suffix == '.json':
                objs = json_stream(f.read_text())
            elif f.suffix in ('.yaml', '.yml'):
                out = run(['yq', 'eval-all', '-o=json', '-I=0', '[.]', str(f)])
                objs = json.loads(out) if out.strip() else []
            else:
                continue
            objs = list(objs)
            bundles += [o for o in objs if o.get('schema') == 'olm.bundle']
            for o in objs:
                if o.get('schema') == 'olm.channel':
                    self.channels.setdefault(name, {})[o.get('name')] = \
                        {e.get('name') for e in o.get('entries') or []}
        self.bundles[name] = bundles
        return bundles

    def known_packages(self):
        return sorted(p.name for p in self.root.iterdir() if p.is_dir()) if self.root.exists() else []


def props(bundle, ptype):
    return [p.get('value') or {} for p in bundle.get('properties') or [] if p.get('type') == ptype]


def bundle_version(bundle):
    for v in props(bundle, 'olm.package'):
        return str(v.get('version'))
    return None


def pick(catalog, package, rng):
    """Highest version of package satisfying rng - what OLM resolves when the
    catalog holds several candidates (with exact mirrors there is only one)."""
    cands = [b for b in catalog.package(package) if bundle_version(b) and in_range(bundle_version(b), rng)]
    if not cands:
        raise Error(f"no bundle of {package} satisfies {rng!r}")
    best = cands[0]
    for b in cands[1:]:
        if cmp_version(bundle_version(b), bundle_version(best)) > 0:
            best = b
    return best


def gvk_provider(catalog, gvk):
    want = (gvk.get('group'), gvk.get('version'), gvk.get('kind'))
    found = []
    for pkg in catalog.known_packages():
        for b in catalog.package(pkg):
            if any((g.get('group'), g.get('version'), g.get('kind')) == want for g in props(b, 'olm.gvk')):
                found.append(b)
    if not found:
        return None
    best = found[0]
    for b in found[1:]:
        if cmp_version(bundle_version(b), bundle_version(best)) > 0:
            best = b
    return best


def requirements(bundle, warnings):
    """Yield ('package', name, range) / ('gvk', dict) from all dependency property types."""
    for v in props(bundle, 'olm.package.required'):
        yield 'package', v.get('packageName'), v.get('versionRange', '')
    for v in props(bundle, 'olm.gvk.required'):
        yield 'gvk', v

    def walk(c):
        if 'package' in c:
            yield 'package', c['package'].get('packageName'), c['package'].get('versionRange', '')
        elif 'gvk' in c:
            yield 'gvk', c['gvk']
        elif 'all' in c:
            for sub in c['all'].get('constraints') or []:
                yield from walk(sub)
        else:
            warnings.append(f"{bundle['name']}: olm.constraint {list(c)} not evaluated - check by hand")
    for v in props(bundle, 'olm.constraint'):
        yield from walk(v)


def resolve(catalog, root_bundle, warnings):
    """Transitive dependency bundles of root_bundle (excluding itself)."""
    seen, out, queue = {root_bundle['name']}, {}, [root_bundle]
    while queue:
        b = queue.pop(0)
        for req in requirements(b, warnings):
            if req[0] == 'package':
                dep = pick(catalog, req[1], req[2])
            else:
                gvk = req[1]
                dep = gvk_provider(catalog, gvk)
                if dep is None and catalog.full and not catalog.offline:
                    catalog.pull_all()
                    dep = gvk_provider(catalog, gvk)
                if dep is None:
                    raise Error(f"{b['name']} requires {gvk.get('group')}/{gvk.get('version')} "
                                f"{gvk.get('kind')}, and no package in {catalog.root} provides it. "
                                "Re-run with --full to search the whole catalog.")
            if dep['name'] not in seen:
                seen.add(dep['name'])
                out[dep['name']] = dep
                queue.append(dep)
    return [out[k] for k in sorted(out)]


# --------------------------------------------------------------------------
# repo values
# --------------------------------------------------------------------------

def merged_versions(component, files):
    merged = {}
    for f in files:
        if f and Path(f).is_file():
            v = yq_json(f, f'.versions."{component}" // {{}}') or {}
            merged.update(v)
    return merged


def defining_file(component, files):
    for f in reversed(files):
        if f and Path(f).is_file() and yq_json(f, f'.versions."{component}".version // null'):
            return f
    return None


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('component')
    ap.add_argument('--catalog')
    ap.add_argument('--authfile')
    ap.add_argument('--configs')
    ap.add_argument('--cache', default=str(Path(os.environ.get('TMPDIR', tempfile.gettempdir())) / 'olm-dependencies'))
    ap.add_argument('--full', action='store_true')
    ap.add_argument('--group')
    ap.add_argument('--versions-file')
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--write', action='store_true')
    a = ap.parse_args()

    os.chdir(ROOT)
    comp = a.component
    files = ['components/versions.yaml']
    if a.group:
        files.append(f'group-values/{a.group}/versions.yaml')
    if a.versions_file:
        files.append(a.versions_file)
    v = merged_versions(comp, files)
    if not v.get('version') and not v.get('csv'):
        raise Error(f"versions.{comp}.version not set in {files}")
    values = yq_json(f'components/{comp}/values.yaml', '.subscription // {}') or {}
    package = values.get('name')
    if not package:
        raise Error(f"components/{comp}/values.yaml: subscription.name not set")
    target = a.versions_file or defining_file(comp, files)

    expected_csv = v.get('csv') or (values.get('csvFormat') or f"{package}.v%s") % v['version']
    catalog = Catalog(a.catalog, a.authfile, a.configs, a.cache, a.full)
    bundles = catalog.package(package)
    # same CSV name the chart computes; fall back to the bundle version
    # (Red Hat bundles may carry suffixes, e.g. version 4.18.3-rhodf)
    root = next((b for b in bundles if b['name'] == expected_csv), None) or \
        next((b for b in bundles if v.get('version') and bundle_version(b) == str(v['version'])), None)
    if root is None:
        have = ', '.join(sorted(b['name'] for b in bundles))
        raise Error(f"{expected_csv} ({package} {v.get('version')}) is not in the catalog. Bundles: {have}")

    warnings = []
    # main Subscription -> versions.<component>.dependencies
    results = {'dependencies': [d['name'] for d in resolve(catalog, root, warnings)]}
    print(f"{comp}: {root['name']}  (package {package}, version {v.get('version')}, from {target})")
    chans = catalog.channels.get(package, {})
    if v.get('channel') and chans and root['name'] not in chans.get(v['channel'], set()):
        holding = sorted(c for c, e in chans.items() if root['name'] in e)
        print(f"  WARNING: {root['name']} is not in channel {v['channel']} "
              f"(it is in: {', '.join(holding) or 'none'}) - OLM cannot install it from there",
              file=sys.stderr)
    if root['name'] != expected_csv:
        print(f"  WARNING: the chart would expect CSV {expected_csv} - fix subscription.csvFormat "
              f"in components/{comp}/values.yaml or set versions.{comp}.csv", file=sys.stderr)

    # Subscriptions the operator creates at runtime (approver.extra) whose
    # dependency list is generated: dependenciesKey
    extras = yq_json(f'components/{comp}/values.yaml', '.approver.extra // []') or []
    for e in extras:
        key = e.get('dependenciesKey')
        if not key:
            continue
        pkg = e.get('package') or e['subscription']
        if e.get('csvFromMain'):
            csv = f"{e['csvFromMain']}.v" + re.sub(r'^.*?\.v(?=[0-9])', '', root['name'], count=1)
        elif e.get('csv'):
            csv = e['csv']
        else:
            csv = e['csvFormat'] % v[e['versionKey']]
        ebundle = next((b for b in catalog.package(pkg) if b['name'] == csv), None)
        if ebundle is None:
            raise Error(f"approver.extra {pkg}: {csv} is not in the catalog")
        edeps = [d['name'] for d in resolve(catalog, ebundle, warnings)]
        print(f"  runtime Subscription {pkg}: {csv} -> {key}")
        results[key] = sorted(set(results.get(key, [])) | set(edeps))

    for w in warnings:
        print(f"  WARNING: {w}", file=sys.stderr)
    drift = False
    for key, deps in results.items():
        print(f"  {key} ({len(deps)}):" + ''.join(f"\n    - {d}" for d in deps) if deps else f"  {key}: none")
        current = (yq_json(target, f'.versions."{comp}"."{key}" // []') if target else []) or []
        added, removed = sorted(set(deps) - set(current)), sorted(set(current) - set(deps))
        if a.check or a.write:
            for d in added:
                print(f"  + {d}")
            for d in removed:
                print(f"  - {d}")
            if not added and not removed:
                print(f"  {target} {key}: up to date")
        drift |= bool(added or removed)
        if a.write and (added or removed):
            expr = (f'.versions."{comp}"."{key}" = {json.dumps(deps)} | '
                    f'.versions."{comp}" style="" | .versions."{comp}"."{key}" style=""')
            if not deps:
                expr = f'del(.versions."{comp}"."{key}")'
            run(['yq', '-i', expr, target])
            print(f"  wrote versions.{comp}.{key} to {target}")
    if a.check and drift:
        print(f"  drift: run with --write to update {target}", file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Error as e:
        print(f"olm-dependencies: {e}", file=sys.stderr)
        sys.exit(2)
