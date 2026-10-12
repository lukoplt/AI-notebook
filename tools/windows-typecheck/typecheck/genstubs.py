#!/usr/bin/env python3
"""Generate C# stand-ins for what the WinUI XAML compiler would emit, so the App's code-behind
type-checks on macOS. Per .xaml with an x:Class: a partial class with one field per x:Name outside
templates (typed by its element), InitializeComponent(), a Bindings.Update() stub, and a never-called
method that (a) subscribes every XAML event attribute to its handler, so handler signatures are
checked, and (b) evaluates the first positional path / function call of every {x:Bind}, against the
page or the template's x:DataType. Usage: genstubs.py <AINotebook.App dir> <output dir>"""
import re, os, sys, glob
import xml.etree.ElementTree as ET  # repository files only, no external input

APP = sys.argv[1]
OUT = sys.argv[2]
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
DEFAULT = '{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
EVENTS = {'Click', 'ItemClick', 'RightTapped', 'DoubleTapped', 'Tapped', 'KeyDown', 'PreviewKeyDown', 'LostFocus', 'GotFocus',
          'SelectionChanged', 'ManipulationDelta', 'Invoked', 'Loaded', 'Unloaded', 'Toggled', 'TextChanged', 'Closed',
          'PrimaryButtonClick', 'SecondaryButtonClick', 'CloseButtonClick', 'Opened', 'PointerEntered', 'PointerExited',
          'DragOver', 'Drop', 'Closing', 'QuerySubmitted', 'SizeChanged', 'ValueChanged', 'Checked', 'Unchecked', 'Opening',
          'CitationTapped', 'ActionRequested'}
SKIP_TAGS = {'ResourceDictionary', 'ThemeDictionaries', 'MergedDictionaries'}
USINGS = ['Microsoft.UI.Xaml', 'Microsoft.UI.Xaml.Controls', 'Microsoft.UI.Xaml.Controls.Primitives', 'Microsoft.UI.Xaml.Documents',
          'Microsoft.UI.Xaml.Media', 'Microsoft.UI.Xaml.Input', 'Microsoft.UI.Xaml.Shapes']
BOOL_PROPS = {'IsChecked': 'bool?', 'IsOn': 'bool', 'IsEnabled': 'bool', 'IsActive': 'bool', 'IsExpanded': 'bool'}

os.makedirs(OUT, exist_ok=True)
for f in glob.glob(os.path.join(OUT, '*.cs')):
    os.remove(f)

def prefixes(raw):
    return {m.group(1): m.group(2) for m in re.finditer(r'xmlns:(\w+)="using:([\w.]+)"', raw)}

def ctype(tag, pmap):
    ns, _, local = tag[1:].partition('}') if tag.startswith('{') else ('', '', tag)
    if '.' in local:
        return None  # property element
    if ns == DEFAULT[1:-1] or ns == '':
        return local
    if ns.startswith('using:'):
        return 'global::' + ns[6:] + '.' + local
    if ns == X[1:-1]:
        return {'String': 'string', 'Double': 'double', 'Int32': 'int', 'Boolean': 'bool'}.get(local)
    return None

def bind_paths(val):
    """First positional argument of each {x:Bind ...} (commas inside parentheses kept)."""
    out = []
    for m in re.finditer(r'\{x:Bind\b', val):
        i, depth, buf = m.end(), 0, ''
        while i < len(val):
            ch = val[i]
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif depth == 0 and ch in ',}':
                break
            buf += ch
            i += 1
        buf = buf.strip()
        if buf and '=' not in buf:
            out.append(buf)
    return out

def translate(expr, ctx, pmap):
    """x:Bind path or function call -> C# expression over `ctx`."""
    expr = expr.strip()
    m = re.match(r'^(?:(\w+):)?([\w.]+)\((.*)\)$', expr)
    if m:
        prefix, fn, args = m.groups()
        target = ('global::' + pmap[prefix] + '.' + fn) if prefix else (ctx + '.' + fn)
        parts = [translate(a, ctx, pmap) for a in args.split(',')] if args.strip() else []
        return f'{target}({", ".join(parts)})'
    return ctx + '.' + expr

for xaml in sorted(glob.glob(os.path.join(APP, '**', '*.xaml'), recursive=True)):
    if '/obj/' in xaml or '/bin/' in xaml:
        continue
    raw = open(xaml, encoding='utf-8').read()
    root = ET.fromstring(raw)
    cls = root.attrib.get(X + 'Class')
    if not cls:
        continue
    pmap = prefixes(raw)
    ns, _, name = cls.rpartition('.')
    fields, checks = [], []
    counter = [0]

    def walk(el, in_template, dtype):
        tag = el.tag
        local = tag.split('}')[-1]
        if local in ('DataTemplate', 'ControlTemplate', 'ItemsPanelTemplate'):
            dt = el.attrib.get(X + 'DataType')
            t = None
            if dt:
                p, _, l = dt.partition(':')
                t = ('global::' + pmap[p] + '.' + l) if l and p in pmap else ({'String': 'string'}.get(l) if p == 'x' else None)
            for c in el:
                walk(c, True, t)
            return
        if local in SKIP_TAGS and el is not root:
            for c in el:
                walk(c, in_template, dtype)
            return
        t = ctype(tag, pmap)
        if t and X + 'Name' in el.attrib and not in_template and el is not root and X + 'Key' not in el.attrib:
            fields.append(f'    internal {t} {el.attrib[X + "Name"]} = null!;')
        if t:
            for attr, val in el.attrib.items():
                a = attr.split('}')[-1]
                if a in EVENTS and not val.startswith('{'):
                    counter[0] += 1
                    target = 'this' if el is root else f'(({t})null!)'
                    checks.append(f'        {target}.{a} += {val};')
                for path in bind_paths(val):
                    if not path or path.startswith('Mode') or path.startswith('Converter'):
                        continue
                    ctx = f'default({dtype})!' if dtype else 'this'
                    if dtype == 'string':
                        continue
                    if in_template and not dtype:
                        continue
                    expr = translate(path, ctx, pmap)
                    has_conv = 'Converter=' in val
                    kind = 'object' if has_conv else BOOL_PROPS.get(a, 'object')
                    counter[0] += 1
                    checks.append(f'        {{ {kind} __b{counter[0]} = {expr}; }}')
        for c in el:
            walk(c, in_template, dtype)

    walk(root, False, None)
    base = ctype(root.tag, pmap)
    body = '\n'.join(fields)
    out = f'''// <auto-generated> stub for {os.path.relpath(xaml, APP)} </auto-generated>
#nullable disable warnings
{chr(10).join("using " + u + ";" for u in USINGS)}
namespace {ns};
partial class {name}
{{
{body}
    internal void InitializeComponent() {{ }}
    internal BindingsStub Bindings = new();
    internal sealed class BindingsStub {{ public void Update() {{ }} }}
    private void __XamlChecks()
    {{
{chr(10).join(checks)}
    }}
}}
'''
    open(os.path.join(OUT, name + '.g.cs'), 'w', encoding='utf-8').write(out)
print('stubs generated')
