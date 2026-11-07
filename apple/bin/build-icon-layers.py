#!/usr/bin/env python3
"""Build the Made symmetry icon's editable SVG layers; preserve Composer tuning.

The geometry is a vector reconstruction of the latest Fighter Flight / Symmetry
study. Source coordinates use its 1254 px canvas; every exported layer has the same
1024 px artboard and a shared inset. No raster image, baked shadow, or platform mask
is embedded. icon.json is initialized only when absent so Composer edits survive.
"""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Brand/Icons"
INK = "#101744"
BLUE = "#224AFF"
CYAN = "#49EAFF"
CORAL = "#FF668E"
GOLD = "#FFD25D"


def polygon(color, points):
    return f'<polygon fill="{color}" points="{points}"/>'


def path(color, data):
    return f'<path fill="{color}" d="{data}"/>'


def mirrored(color, points):
    return '<g transform="translate(1254 0) scale(-1 1)">' + polygon(color, points) + '</g>'


def svg(parts):
    # 94% of the original composition, centered on a 1024 px canvas.
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">\n'
            '  <g transform="translate(30.72 30.72) scale(0.767591707)">\n'
            + '\n'.join('    ' + part for part in parts) + '\n  </g>\n</svg>\n')


def layer(name, parts, *, glass=True, mono="#DFE6F4", opacity=1):
    return {"name": name, "parts": parts, "glass": glass, "mono": mono, "opacity": opacity}


def group(name, layers, *, translucency=0, shadow=.12, specular=True):
    # Authoring order is back to front; Composer serializes front to back.
    return {"name": name, "layers": layers, "translucency": translucency,
            "shadow": shadow, "specular": specular}


def cockpit():
    shell = [polygon(INK, '478,111 776,111 995,230 1158,675 976,1017 627,1178 279,1017 96,675 258,230')]
    sky = [polygon('#164CC8', '492,191 762,191 937,305 1112,645 142,645 317,305'),
           polygon('#177FDC', '317,305 492,191 627,191 627,645 142,645'),
           polygon('#3B54DC', '627,191 762,191 937,305 1112,645 627,645')]
    frame = [
        polygon(CYAN, '96,675 103,541 258,230 318,294'),
        polygon('#26D7F5', '258,230 478,111 492,191 318,294'),
        polygon('#259BEF', '478,111 776,111 762,191 492,191'),
        polygon('#A86AF2', '776,111 995,230 937,305 762,191'),
        polygon(CORAL, '995,230 1151,541 1158,675 937,305'),
        polygon('#1761CD', '318,294 492,191 762,191 937,305 919,321 753,235 501,235 337,321'),
        polygon('#3ADCF5', '96,675 226,801 279,1017 156,883'),
        polygon('#1377E8', '226,801 470,944 627,1178 279,1017'),
        polygon('#24BAEF', '470,944 554,913 627,913 627,1178'),
        polygon('#9A5DE7', '627,913 700,913 784,944 627,1178'),
        polygon('#9C3ED3', '784,944 1028,801 976,1017 627,1178'),
        polygon('#FF889A', '1028,801 1158,675 1098,883 976,1017'),
    ]
    instruments = [polygon('#1ABFE9', '342,692 524,692 508,846 267,846 226,801'),
                   polygon('#2366EE', '267,846 508,846 516,739 226,801'),
                   polygon('#5965F1', '730,692 912,692 1028,801 987,846 746,846'),
                   polygon('#D76DDC', '738,739 1028,801 987,846 746,846')]
    hud = [polygon('#3EE4F0', '465,300 789,300 873,384 922,630 331,630 381,384'),
           polygon('#188EDA', '476,324 778,324 849,393 894,606 359,606 405,393')]
    heading = [polygon(CYAN, '528,435 627,371 726,435 726,479 627,417 528,479')]
    horizon = [polygon(GOLD, '365,533 889,533 895,559 359,559')]
    stick = [polygon('#243DA4', '579,779 675,779 657,913 709,961 545,961 597,913'),
             polygon('#34BDE8', '579,779 627,804 627,961 545,961 597,913'),
             polygon('#8153CC', '627,804 675,779 657,913 709,961 627,961'),
             polygon('#FFAA32', '559,751 591,705 663,705 695,751 675,779 579,779'),
             polygon(GOLD, '591,705 663,705 680,732 574,732')]
    return [group('01 Structure', [layer('01 Cockpit shell', shell, glass=False, mono='#343B50'),
                                   layer('02 Canopy field', sky, glass=False, mono='#727F98')], specular=False, shadow=.08),
            group('02 Faceted airframe', [layer('03 Canopy and frame facets', frame, mono='#BECBDD')], shadow=.1),
            group('03 Flight glass', [layer('04 Instrument glass', instruments, mono='#E9EEF7'),
                                     layer('05 HUD glass', hud, mono='#C6D6E9', opacity=.84)], translucency=.34, shadow=.16),
            group('04 Flight signals', [layer('06 Horizon', horizon, glass=False, mono='#FFFFFF'),
                                       layer('07 Heading chevron', heading, glass=False, mono='#FFFFFF'),
                                       layer('08 Control stick', stick, mono='#F3F5F9')], translucency=.08, shadow=.1)]


def kneeboard():
    body = [polygon(INK, '318,167 936,167 1031,263 1031,1034 929,1138 321,1138 221,1034 221,263')]
    frame = [polygon('#248FE9', '318,167 936,167 936,245 318,245'),
             polygon('#38E5F4', '221,263 318,167 318,285 267,336 267,990 221,1034'),
             polygon('#1868E5', '267,336 309,318 309,1034 267,990'),
             polygon('#A657D6', '936,167 1031,263 985,336 936,285'),
             polygon(CORAL, '1031,263 1031,1034 985,990 985,336'),
             polygon('#6A32D0', '985,336 944,318 944,1034 985,990'),
             polygon('#277CF1', '221,1034 309,1034 361,1077 321,1138'),
             polygon('#1538C9', '361,1077 892,1077 929,1138 321,1138'),
             polygon('#5654E4', '944,1034 1031,1034 929,1138 892,1077')]
    chart = [polygon('#20CEF0', '309,318 944,318 944,1034 309,1034'),
             polygon('#63E9F3', '309,318 580,318 309,542'),
             polygon('#29B3E5', '944,579 944,1034 510,1034')]
    buckles = [polygon('#18357E', '183,543 304,543 325,563 325,727 304,749 183,749 161,727 161,563'),
               polygon('#195DCC', '161,563 183,543 304,543 325,563'),
               polygon(CYAN, '161,563 182,563 182,727 161,727'),
               polygon('#143176', '950,543 1071,543 1093,563 1093,727 1071,749 950,749 929,727 929,563'),
               polygon('#8460C7', '929,563 950,543 1071,543 1093,563'),
               polygon(CORAL, '1071,563 1093,563 1093,727 1071,727')]
    clip = [polygon('#FF8E33', '457,71 797,71 850,166 864,246 864,295 390,295 390,246 404,166'),
            polygon(GOLD, '457,71 797,71 765,130 489,130'),
            polygon('#FFB148', '457,71 489,130 432,245 390,246 404,166'),
            polygon('#FFAA43', '797,71 850,166 864,246 822,245 765,130'),
            polygon('#F77B2D', '390,246 864,246 864,295 390,295')]
    heading = [polygon(GOLD, '627,486 627,705 419,793'),
               polygon('#FFA934', '627,486 835,793 627,705')]
    route = [path(CORAL, 'M365 479 Q627 303 889 479 L858 518 Q627 362 396 518 Z'),
             path(CORAL, 'M360 865 L392 829 Q627 992 862 829 L894 865 Q627 1050 360 865 Z')]
    return [group('01 Kneeboard structure', [layer('01 Board shell', body, glass=False, mono='#40495C')], specular=False),
            group('02 Frame facets', [layer('02 Cobalt frame', frame, mono='#B7C5DD')], shadow=.1),
            group('03 Navigation glass', [layer('03 Chart glass', chart, mono='#CEDAE8', opacity=.88)], translucency=.28, shadow=.12),
            group('04 Navigation and hardware', [layer('04 Harness buckles', buckles, mono='#62718A'),
                                                layer('05 Retaining clip', clip, mono='#F0F3F8'),
                                                layer('06 Navigation arcs', route, glass=False, mono='#525D72'),
                                                layer('07 Heading marker', heading, mono='#FFFFFF')], translucency=.06, shadow=.14)]


def walkie():
    shell = [polygon(INK, '558,96 590,72 664,72 696,96 716,283 748,318 835,318 941,422 941,540 918,582 918,1063 826,1166 428,1166 335,1063 335,582 312,540 312,422 419,318 506,318 538,283')]
    facets = [polygon('#208FED', '590,72 664,72 664,114 590,114'),
              polygon('#40E9F2', '558,96 590,72 590,114 568,284 538,284'),
              polygon('#154FC5', '590,114 627,114 627,284 568,284'),
              polygon('#7753C7', '627,114 664,114 686,284 627,284'),
              polygon('#F273B0', '664,72 696,96 716,284 686,284 664,114'),
              polygon('#216DE0', '538,284 716,284 748,342 506,342'),
              polygon('#4F70EE', '419,318 506,318 506,342 748,342 748,318 835,318 805,383 449,383'),
              polygon('#44E9F4', '419,318 449,383 360,473 312,422'),
              polygon(CORAL, '835,318 941,422 894,473 805,383'),
              polygon('#259FE8', '312,422 360,473 360,1044 335,1063 335,582 312,540'),
              polygon('#FD759D', '941,422 941,540 918,582 918,1063 894,1044 894,473'),
              polygon('#2748E8', '360,473 449,383 805,383 894,473 894,1044 801,1124 452,1124 360,1044'),
              polygon('#2784E7', '335,1063 360,1044 452,1124 428,1166'),
              polygon('#2542CA', '452,1124 801,1124 826,1166 428,1166'),
              polygon('#9652D7', '894,1044 918,1063 826,1166 801,1124'),
              polygon(INK, '449,421 805,421 864,480 864,630 805,690 449,690 390,630 390,480')]
    display = [polygon('#1FE4E8', '452,452 802,452 834,485 834,624 801,657 452,657 420,624 420,485'),
               polygon('#6AEFF0', '452,452 802,452 818,469 420,624 420,485')]
    button = [polygon('#FFAD31', '538,715 715,715 742,742 742,771 714,797 538,797 512,771 512,742'),
              polygon(GOLD, '538,715 715,715 729,741 525,741'),
              polygon('#FA8C22', '512,771 742,771 714,797 538,797')]
    grille = [polygon('#080F34', f'449,{y} 805,{y} 834,{y+28} 805,{y+57} 449,{y+57} 420,{y+28}') for y in (823,911,999)]
    return [group('01 Radio structure', [layer('01 Chassis and antenna', shell, glass=False, mono='#414B61')], specular=False),
            group('02 Radio facets', [layer('02 Cobalt housing', facets, mono='#C2CEE2')], shadow=.1),
            group('03 Radio glass', [layer('03 Display glass', display, mono='#F3F6FC', opacity=.9)], translucency=.36, shadow=.16),
            group('04 Communications details', [layer('04 Speaker grille', grille, glass=False, mono='#182238'),
                                                layer('05 Communication key', button, mono='#FFFFFF')], translucency=.08, shadow=.12)]


def drone():
    outline = '627,78 770,432 1182,802 1182,844 773,929 845,1034 840,1141 627,1040 414,1141 409,1034 481,929 68,844 72,802 484,432'
    structure = [polygon('#133394', outline)]
    wings = [polygon('#31D9ED', '484,432 72,802 68,844 520,512'),
             polygon('#167FEA', '72,802 520,512 520,681 68,844'),
             polygon('#0E48D8', '68,844 520,681 481,929'),
             mirrored('#49E9F5', '484,432 72,802 68,844 520,512'),
             mirrored('#2264EC', '72,802 520,512 520,681 68,844'),
             mirrored('#163BD1', '68,844 520,681 481,929'),
             polygon('#45D8ED', '481,881 520,958 414,1141 409,1034'),
             polygon('#2165D7', '520,958 627,1040 414,1141'),
             mirrored('#F176B4', '481,881 520,958 414,1141 409,1034'),
             mirrored('#6848D5', '520,958 627,1040 414,1141')]
    fuselage = [polygon('#34DDEA', '627,78 573,298 484,432 484,485 627,344'),
                polygon('#F8759E', '627,78 770,432 770,485 627,344 681,298'),
                polygon('#23AFE9', '573,298 627,344 627,1040 484,485'),
                polygon('#6149E9', '627,344 681,298 770,485 627,1040'),
                polygon('#194BD0', '484,485 522,681 481,929 627,1040'),
                polygon('#3537D0', '770,485 732,681 773,929 627,1040')]
    sensor = [polygon('#B36222', '627,78 681,298 627,344 573,298'),
              polygon(GOLD, '615,167 639,167 665,292 627,308 589,292')]
    return [group('01 Wingman structure', [layer('01 Aircraft silhouette', structure, glass=False, mono='#60718B')], specular=False),
            group('02 Swept wings', [layer('02 Wing and tail facets', wings, mono='#C5D2E6')], shadow=.12),
            group('03 Airframe glass', [layer('03 Fuselage facets', fuselage, mono='#EDF2FA')], translucency=.12, shadow=.18),
            group('04 Nose sensor', [layer('04 Amber sensor', sensor, mono='#FFFFFF')], translucency=.22, shadow=.1)]


DESIGNS = {"Cockpit": cockpit, "Kneeboard": kneeboard, "Walkie": walkie, "Drone": drone}


def color_value(hex_color):
    rgb = [int(hex_color[i:i+2], 16) / 255 for i in (1, 3, 5)]
    return 'srgb:' + ','.join(f'{v:.5f}' for v in [*rgb, 1])


def composer_document(groups):
    result = []
    for definition in reversed(groups):
        layers = []
        for item in reversed(definition['layers']):
            layers.append({"name": item['name'], "image-name": item['name'] + '.svg',
                           "fill": "none", "glass": item['glass'], "opacity": item['opacity'],
                           "fill-specializations": [{"appearance": "tinted", "value": {"solid": color_value(item['mono'])}}]})
        result.append({"name": definition['name'], "layers": layers, "specular": definition['specular'],
                       "shadow": {"kind": "neutral", "opacity": definition['shadow']},
                       "translucency": {"enabled": definition['translucency'] > 0, "value": definition['translucency']}})
    return {"fill-specializations": [
                {"value": {"linear-gradient": [color_value('#090D35'), color_value('#191C9B')],
                           "orientation": {"start": {"x": .5, "y": 0}, "stop": {"x": .5, "y": 1}}}},
                {"appearance": "dark", "value": {"linear-gradient": [color_value('#04081E'), color_value('#101746')],
                                                  "orientation": {"start": {"x": .5, "y": 0}, "stop": {"x": .5, "y": 1}}}},
                {"appearance": "tinted", "value": {"solid": color_value('#232A3B')}}],
            "groups": result, "supported-platforms": {"squares": "shared", "circles": ["watchOS"]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check generated SVGs without modifying files')
    args = parser.parse_args()
    count = 0
    for name, factory in DESIGNS.items():
        bundle = DESTINATION / f'{name}.icon'
        groups = factory()
        for definition in groups:
            for item in definition['layers']:
                output = bundle / 'Assets' / (item['name'] + '.svg')
                expected = svg(item['parts'])
                if args.check:
                    if not output.is_file() or output.read_text() != expected:
                        raise SystemExit(f'Generated layer differs: {output.relative_to(ROOT)}')
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text(expected)
                count += 1
        configuration = bundle / 'icon.json'
        if not configuration.exists():
            if args.check:
                raise SystemExit(f'Missing Composer document: {configuration}')
            configuration.write_text(json.dumps(composer_document(groups), indent=2) + '\n')
        document = json.loads(configuration.read_text())
        if not 1 <= len(document['groups']) <= 4:
            raise SystemExit(f'Composer requires 1–4 groups: {configuration}')
        expected_names = {item['name'] + '.svg' for group in groups for item in group['layers']}
        actual_names = set()
        for definition in document['groups']:
            for item in definition['layers']:
                if item.get('image-name'):
                    actual_names.add(item['image-name'])
                actual_names.update(value['value'] for value in item.get('image-name-specializations', [])
                                    if value.get('value'))
        if actual_names != expected_names:
            raise SystemExit(f'Composer layer references differ: {configuration}')
        for image_name in actual_names:
            if Path(image_name).name != image_name or not (bundle / 'Assets' / image_name).is_file():
                raise SystemExit(f'Invalid Composer image reference: {image_name}')
    print(f'{"Checked" if args.check else "Generated"} {count} SVG layers in {len(DESIGNS)} Icon Composer documents')


if __name__ == '__main__':
    main()
