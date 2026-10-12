#!/usr/bin/env python3
"""XAML checks the C# type-check cannot do (the WinUI XAML compiler only runs on Windows):

  * every .xaml is well-formed XML;
  * every {StaticResource X} / {ThemeResource X} names a key defined in Styles/Tokens.xaml,
    Styles/Controls.xaml, App.xaml, the file itself, or a known WinUI theme resource
    (a missing key compiles but crashes when the page loads);
  * x:Name is unique outside templates (each template is its own name scope).

Exit status 1 when anything is found. Usage: xamllint.py [path/to/AINotebook.App]
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET  # repository files only, no external input

HERE = os.path.dirname(os.path.abspath(__file__))
APP = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(os.path.join(HERE, '..', '..', '..', 'windows', 'src', 'AINotebook.App'))
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
TEMPLATES = {'DataTemplate', 'ControlTemplate', 'ItemsPanelTemplate'}

# WinUI / WinAppSDK resources the App may reference without defining them.
WINUI_RESOURCES = set('''BodyStrongTextBlockStyle CaptionTextBlockStyle SubtitleTextBlockStyle TitleTextBlockStyle
BaseTextBlockStyle BodyTextBlockStyle DefaultButtonStyle DateTimePickerFlyoutButtonStyle ContentDialogMinWidth
ContentDialogMaxWidth'''.split())


def keys_in(path):
    root = ET.parse(path).getroot()
    return {el.attrib[X + 'Key'] for el in root.iter() if X + 'Key' in el.attrib}


def main():
    shared = set()
    for name in ('Styles/Tokens.xaml', 'Styles/Controls.xaml', 'App.xaml'):
        shared |= keys_in(os.path.join(APP, name))
    problems = []
    for path in sorted(glob.glob(os.path.join(APP, '**', '*.xaml'), recursive=True)):
        rel = os.path.relpath(path, APP)
        if rel.split(os.sep)[0] in ('obj', 'bin'):
            continue
        raw = open(path, encoding='utf-8').read()
        try:
            root = ET.fromstring(raw)
        except ET.ParseError as error:
            problems.append(f'{rel}: not well-formed XML ({error})')
            continue
        own = {el.attrib[X + 'Key'] for el in root.iter() if X + 'Key' in el.attrib}
        for key in sorted(set(re.findall(r'\{(?:StaticResource|ThemeResource)\s+(\w+)\}', raw))):
            if key not in shared and key not in own and key not in WINUI_RESOURCES:
                problems.append(f'{rel}: unknown resource {key}')
        names = []

        def walk(el, in_template):
            if X + 'Name' in el.attrib and not in_template:
                names.append(el.attrib[X + 'Name'])
            nested = in_template or el.tag.split('}')[-1] in TEMPLATES
            for child in el:
                walk(child, nested)

        walk(root, False)
        for name in sorted({n for n in names if names.count(n) > 1}):
            problems.append(f'{rel}: duplicate x:Name {name}')
    if problems:
        print('\n'.join(problems))
        return 1
    print('xamllint: ok')
    return 0


if __name__ == '__main__':
    sys.exit(main())
