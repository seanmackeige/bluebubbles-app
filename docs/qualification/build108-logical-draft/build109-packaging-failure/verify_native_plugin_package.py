"""Read-only native plugin registration APK gate. Does not build/install/run apps.

This gate proves class definitions are packaged, not runtime registration success.
Requires Python standard library only. --registrant-source should be freshly
Flutter-generated from the candidate's locked dependency set before assembly.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import zipfile


def dex_classes(data):
    if len(data) < 112 or not data.startswith(b'dex\n'):
        raise ValueError('Unsupported or truncated DEX header')
    string_count, string_offset, type_count, type_offset = struct.unpack_from('<4I', data, 56)
    class_count, class_offset = struct.unpack_from('<2I', data, 96)

    def string_at(index):
        if not 0 <= index < string_count:
            raise ValueError('DEX string index out of range')
        cursor = struct.unpack_from('<I', data, string_offset + index * 4)[0]
        for _ in range(5):
            value = data[cursor]
            cursor += 1
            if not value & 128:
                break
        else:
            raise ValueError('Invalid DEX string length')
        return data[cursor:data.index(b'\x00', cursor)].decode('utf-8', 'replace')

    def type_at(index):
        if not 0 <= index < type_count:
            raise ValueError('DEX type index out of range')
        return string_at(struct.unpack_from('<I', data, type_offset + index * 4)[0])

    return {
        type_at(struct.unpack_from('<I', data, class_offset + index * 32)[0])
        for index in range(class_count)
    }


def inspect_apk(apk, registrant_source, expected_count):
    apk = Path(apk)
    registrant_source = Path(registrant_source)
    errors = []
    source = registrant_source.read_bytes() if registrant_source.is_file() else b''
    implementations = re.findall(
        rb'flutterEngine\.getPlugins\(\)\.add\(new ([\w.]+)\(', source
    )
    plugins = sorted({value.decode('ascii') for value in implementations})
    if not source:
        errors.append('GENERATED_REGISTRANT_SOURCE_MISSING')
    if b'package io.flutter.plugins;' not in source or b'public static void registerWith' not in source:
        errors.append('GENERATED_REGISTRANT_ENTRYPOINT_INVALID')
    if len(implementations) != expected_count or len(plugins) != expected_count:
        errors.append('LOCKED_PLUGIN_REGISTRATION_COUNT_MISMATCH')
    classes = set()
    with zipfile.ZipFile(apk) as archive:
        dex_names = [name for name in archive.namelist() if re.fullmatch(r'classes\d*\.dex', name)]
        if not dex_names:
            errors.append('APK_HAS_NO_DEX')
        for name in dex_names:
            classes.update(dex_classes(archive.read(name)))
    registrant_defined = 'Lio/flutter/plugins/GeneratedPluginRegistrant;' in classes
    missing = [name for name in plugins if 'L' + name.replace('.', '/') + ';' not in classes]
    if not registrant_defined:
        errors.append('GENERATED_REGISTRANT_CLASS_NOT_PACKAGED')
    if missing:
        errors.append('REGISTERED_PLUGIN_IMPLEMENTATION_NOT_PACKAGED')
    return {
        'gate': 'NATIVE_PLUGIN_REGISTRATION_PACKAGE_V1',
        'status': 'PASS' if not errors else 'FAIL',
        'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'registrant_source_sha256': hashlib.sha256(source).hexdigest() if source else None,
        'dex_files': len(dex_names),
        'class_definition_count': len(classes),
        'generated_registrant_defined': registrant_defined,
        'expected_registration_count': expected_count,
        'source_registration_count': len(implementations),
        'unique_registered_plugins': len(plugins),
        'registered_plugin_classes_present': len(plugins) - len(missing),
        'missing_plugin_implementations': missing,
        'path_provider_defined': 'Lio/flutter/plugins/pathprovider/PathProviderPlugin;' in classes,
        'errors': errors,
        'runtime_registration_proven': False,
        'device_mutations': 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True)
    parser.add_argument('--registrant-source', required=True)
    parser.add_argument('--expected-count', required=True, type=int)
    args = parser.parse_args()
    report = inspect_apk(args.apk, args.registrant_source, args.expected_count)
    print(json.dumps(report, sort_keys=True))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
