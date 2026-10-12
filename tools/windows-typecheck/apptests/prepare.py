#!/usr/bin/env python3
"""Prepare the macOS App.Tests build:
  * <work>/apptests-exclude.props: App sources outside code-behind that need real WinUI types
    (template selectors, converters, renderers, dialog service) are excluded automatically;
  * <work>/apptests-extracted/: pure types that live at the top of a code-behind file (before the
    WinUI partial class) are copied out so tests can use them."""
import os, re, sys, glob

repo, work = sys.argv[1], sys.argv[2]
app = os.path.join(repo, 'windows', 'src', 'AINotebook.App')
WINUI = re.compile(r'using Microsoft\.UI\.Xaml\.(Controls|Documents|Data|Media|Input)\b|:\s*(DataTemplateSelector|UserControl|IValueConverter)\b')
CODE_BEHIND_WITH_PURE_TYPES = ['Views/FolderRulesDialog.xaml.cs']

os.makedirs(work, exist_ok=True)
excluded = []
for path in sorted(glob.glob(os.path.join(app, '**', '*.cs'), recursive=True)):
    rel = os.path.relpath(path, app)
    if rel.endswith('.xaml.cs') or rel.split(os.sep)[0] in ('obj', 'bin'):
        continue
    if WINUI.search(open(path, encoding='utf-8').read()):
        excluded.append(path)
with open(os.path.join(work, 'apptests-exclude.props'), 'w', encoding='utf-8') as f:
    f.write('<Project>\n  <ItemGroup>\n')
    f.writelines(f'    <WtcExclude Include="{p}" />\n' for p in excluded)
    f.write('  </ItemGroup>\n</Project>\n')

out = os.path.join(work, 'apptests-extracted')
os.makedirs(out, exist_ok=True)
for old in glob.glob(os.path.join(out, '*.cs')):
    os.remove(old)
for rel in CODE_BEHIND_WITH_PURE_TYPES:
    src = os.path.join(app, rel)
    if not os.path.exists(src):
        continue
    kept = []
    for line in open(src, encoding='utf-8'):
        if re.match(r'^(public|internal) (sealed )?partial class ', line):
            break
        if re.match(r'^using (Microsoft\.UI|Windows\.|WinRT)', line):
            continue
        kept.append(line)
    with open(os.path.join(out, os.path.basename(rel).replace('.xaml.cs', '.Extracted.cs')), 'w', encoding='utf-8') as f:
        f.writelines(kept)
print(f'apptests: {len(excluded)} WinUI-bound sources excluded')
