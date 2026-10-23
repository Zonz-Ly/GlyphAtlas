#!/usr/bin/env python3
"""Check complete catalogs, regional overrides, and the README Help contract."""
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'Resources'
declared = plistlib.loads((RESOURCES / 'Info.plist').read_bytes())['CFBundleLocalizations']
folders = {path.stem: path for path in RESOURCES.glob('*.lproj')}
assert set(declared) == set(folders), 'Declared and packaged languages differ'

def strings(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))

catalogs = {locale: strings(folder / 'Localizable.strings') for locale, folder in folders.items()}
english = catalogs['en']
for locale, catalog in catalogs.items():
    assert catalog.keys() == english.keys(), f'{locale}: missing/extra translations'
    assert all(isinstance(value, str) and value for value in catalog.values()), locale
    info = strings(folders[locale] / 'InfoPlist.strings')
    assert info['Font File'] == catalog['Font File'], f'{locale}: document type name differs'
    assert '© 2026 Zonz.' in info['NSHumanReadableCopyright'], f'{locale}: copyright metadata missing'
    assert set(info) == {'Font File', 'NSHumanReadableCopyright'}, f'{locale}: localized metadata keys differ'
    plural = plistlib.loads((folders[locale] / 'Localizable.stringsdict').read_bytes())
    entry = plural['“%@” contains %lu fonts. Choose a style to inspect.']
    assert '%1$@' in entry['NSStringLocalizedFormatKey'], f'{locale}: filename argument missing'
    assert '%2$#@fonts@' in entry['NSStringLocalizedFormatKey'], f'{locale}: font count argument missing'
    assert entry['fonts']['NSStringFormatValueTypeKey'] == 'lu', locale
    assert 'other' in entry['fonts'], f'{locale}: plural fallback missing'

references = set()
for source in (ROOT / 'Sources').glob('*.m'):
    references.update(re.findall(r'NSLocalizedString\(@"([^"\n]+)"', source.read_text()))
plural_keys = {'“%@” contains %lu fonts. Choose a style to inspect.'}
assert references <= english.keys() | plural_keys, f'Unknown localization keys: {references - english.keys() - plural_keys}'

section = (ROOT / 'README.md').read_text().split('## 使用\n', 1)[1].split('\n## ', 1)[0]
usage = [re.sub(r'`([^`]+)`', r'\1', line[2:]) for line in section.splitlines() if line.startswith('- ')]
assert len(usage) == 12
for locale in ['zh-Hant', 'zh-HK']:
    assert [catalogs[locale][f'Help.{i:02}'] for i in range(1, 13)] == usage, f'{locale}: Help no longer matches README 使用'
for locale in ['zh-Hant', 'zh-HK', 'zh-Hans']:
    assert catalogs[locale]['All Glyphs'] == '全部字', locale
for key, value in {'Left': '靠左', 'Right': '靠右', 'Top': '靠上', 'Bottom': '靠下', 'Justified': '兩端'}.items():
    assert catalogs['zh-HK'][key] == value, f'Lost Hong Kong wording: {key}'
assert catalogs['zh-Hant']['Open Recent'] == '打開最近使用過的檔案'
assert catalogs['zh-HK']['Open Recent'] == '開啟最近項目'
assert catalogs['zh-Hans']['Open Recent'] == '打开最近使用'
for locale in ['zh-Hant', 'zh-HK']:
    assert strings(folders[locale] / 'InfoPlist.strings')['NSHumanReadableCopyright'] == 'Copyright © 2026 Zonz. 保留一切權利。'
assert '\u2066⌘C\u2069' in catalogs['ar']['Help.05'], 'Arabic copy shortcut must stay in a single LTR isolate'
for key in ['Left', 'Right', 'Center', 'Top', 'Bottom']:
    assert '합니다' not in catalogs['ko'][key], f'Korean {key} uses a tooltip sentence instead of a command title'
print(f'OK: {len(catalogs)} complete catalogs; {len(english)} strings and one plural entry each; README Help and regional wording preserved.')
