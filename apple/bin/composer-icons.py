#!/usr/bin/env python3
"""Validate, natively render, or compile Made's Icon Composer documents."""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

APPLE = Path(__file__).resolve().parents[1]
REPO = APPLE.parent
BRAND = APPLE / 'Brand/Icons'
APPS = {
    'Cockpit': {'target': 'Pilot', 'platform': 'macosx', 'preview': 'macOS', 'device': 'mac'},
    'Kneeboard': {'target': 'Plotter', 'platform': 'iphoneos', 'preview': 'iOS', 'device': 'ipad'},
    'Walkie': {'target': 'Copilot', 'platform': 'iphoneos', 'preview': 'iOS', 'device': 'iphone'},
    'Drone': {'target': None, 'preview': 'macOS'},
}
APPEARANCES = ['Default', 'Dark', 'ClearLight', 'ClearDark', 'TintedLight', 'TintedDark']


def run(arguments):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
    return result.stdout


def renderer():
    developer = Path(run(['xcode-select', '-p']).strip())
    locations = [developer.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool',
                 Path('/Applications/Icon Composer.app/Contents/Executables/ictool')]
    for executable in locations:
        if executable.is_file():
            return executable
    raise RuntimeError('Icon Composer renderer was not found in the selected Xcode or /Applications')


def asset_names(layer):
    names = []
    if layer.get('image-name'):
        names.append(layer['image-name'])
    names.extend(value['value'] for value in layer.get('image-name-specializations', []) if value.get('value'))
    return names


def validate():
    run(['python3', APPLE / 'bin/build-icon-layers.py', '--check'])
    total = 0
    for name in APPS:
        bundle = BRAND / f'{name}.icon'
        document = json.loads((bundle / 'icon.json').read_text())
        groups = document.get('groups', [])
        if not 1 <= len(groups) <= 4:
            raise RuntimeError(f'{name}: expected 1–4 native depth groups')
        if not document.get('supported-platforms', {}).get('squares'):
            raise RuntimeError(f'{name}: square Apple platforms must be supported')
        appearance_keys = {x.get('appearance', 'default') for x in document.get('fill-specializations', [])}
        if not {'default', 'dark', 'tinted'} <= appearance_keys:
            raise RuntimeError(f'{name}: default, dark, and mono backgrounds are required')
        glass_count = 0
        for group in groups:
            for layer in group.get('layers', []):
                images = asset_names(layer)
                if not images:
                    raise RuntimeError(f'{name}: missing source image for {layer.get("name")}')
                glass_count += bool(layer.get('glass', True))
                for image in images:
                    if Path(image).name != image:
                        raise RuntimeError(f'{name}: source image must be inside Assets: {image}')
                    source = bundle / 'Assets' / image
                    root = ET.parse(source).getroot()
                    if (root.get('width'), root.get('height'), root.get('viewBox')) != ('1024', '1024', '0 0 1024 1024'):
                        raise RuntimeError(f'{name}: layer must have a 1024 px artboard: {image}')
                    if any(element.tag.rsplit('}', 1)[-1] in ('script', 'image', 'foreignObject') for element in root.iter()):
                        raise RuntimeError(f'{name}: expected standalone vector geometry: {image}')
                total += 1
        if not glass_count:
            raise RuntimeError(f'{name}: native glass must be enabled on at least one layer')

    project = json.loads(run(['plutil', '-convert', 'json', '-o', '-', APPLE / 'made.xcodeproj/project.pbxproj']))
    objects = project['objects']
    for name, metadata in APPS.items():
        if metadata['target'] is None:
            continue
        target = next(o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == metadata['target'])
        configs = objects[target['buildConfigurationList']]['buildConfigurations']
        for config_id in configs:
            config = objects[config_id]
            selected = config['buildSettings'].get('ASSETCATALOG_COMPILER_APPICON_NAME')
            if selected != name:
                raise RuntimeError(f'{metadata["target"]}/{config["name"]}: selected icon is {selected}, expected {name}')
        resources = [objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXResourcesBuildPhase']
        references = [objects[objects[f]['fileRef']] for phase in resources for f in phase['files'] if 'fileRef' in objects[f]]
        if not any(r.get('path') == f'{name}.icon' and r.get('lastKnownFileType') == 'wrapper.icon' for r in references):
            raise RuntimeError(f'{metadata["target"]}: native .icon resource membership is missing')
    print(f'Validated {len(APPS)} Icon Composer documents, {total} vector layers, and all 3 app target selections')


def render(output):
    executable = renderer()
    output.mkdir(parents=True, exist_ok=True)
    gallery = {}
    for name, metadata in APPS.items():
        document = json.loads((BRAND / f'{name}.icon/icon.json').read_text())
        gallery[name] = {'platform': metadata['preview'], 'target': metadata['target'], 'groups': document['groups']}
        for appearance in APPEARANCES:
            suffix = 'default' if appearance == 'Default' else appearance
            pixels = '1024' if appearance == 'Default' else '512'
            run([executable, BRAND / f'{name}.icon', '--export-image', '--output-file', output / f'{name}-{suffix}.png',
                 '--platform', metadata['preview'], '--rendition', appearance,
                 '--width', pixels, '--height', pixels, '--scale', '1'])
        run([executable, BRAND / f'{name}.icon', '--export-image', '--output-file', output / f'{name}-watch.png',
             '--platform', 'watchOS', '--rendition', 'Default', '--width', '272', '--height', '272', '--scale', '1'])
        print(f'Rendered {name}: 6 native appearances and a watchOS crop')
    (output / 'layers.js').write_text('window.MADE_ICON_LAYERS = ' + json.dumps(gallery, indent=2) + ';\n')


def compile_icons(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, metadata in APPS.items():
        if metadata['target'] is None:
            continue
        destination = output / name
        destination.mkdir(exist_ok=True)
        plist = destination / 'IconInfo.plist'
        catalog = APPLE / 'Sources' / metadata['target'] / 'Assets.xcassets'
        result = run(['xcrun', 'actool', catalog, BRAND / f'{name}.icon', '--compile', destination,
                      '--platform', metadata['platform'], '--minimum-deployment-target', '26.0',
                      '--app-icon', name, '--output-partial-info-plist', plist,
                      '--target-device', metadata['device'], '--output-format', 'human-readable-text', '--warnings', '--notices'])
        info = plistlib.loads(plist.read_bytes())
        names = []

        def collect(value):
            if isinstance(value, dict):
                if 'CFBundleIconName' in value:
                    names.append(value['CFBundleIconName'])
                for child in value.values():
                    collect(child)
            elif isinstance(value, list):
                for child in value:
                    collect(child)

        collect(info)
        if not names or any(icon != name for icon in names):
            raise RuntimeError(f'{name}: compiled Info.plist selected unexpected icons: {names}')
        if not (destination / 'Assets.car').is_file():
            raise RuntimeError(f'{name}: compiled Assets.car is missing')
        (destination / 'actool.log').write_text(result)
        print(f'Compiled {name} with its app asset catalog for {metadata["platform"]}/{metadata["device"]}; Info.plist selects {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'render', 'compile'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.command == 'validate':
        validate()
    elif args.command == 'render':
        render(args.output or REPO / 'icons/composer/previews')
    elif args.command == 'compile':
        validate()
        compile_icons(args.output or APPLE / '.build/icon-validation')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, StopIteration, ET.ParseError) as error:
        raise SystemExit(f'composer-icons: {error}') from error
