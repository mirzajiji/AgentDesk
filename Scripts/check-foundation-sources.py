#!/usr/bin/env python3
"""Supplementary compiler/XCTest checks; not an Xcode build or Simulator run."""

import json
from pathlib import Path
import platform
import plistlib
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'TestResults/p1-01/source-checks'


def query(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def run(arguments):
    with (OUTPUT / 'commands.log').open('a') as log:
        log.write(shlex.join(str(a) for a in arguments) + '\n')
    subprocess.run([str(a) for a in arguments], cwd=ROOT, check=True)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # A failed rerun must never leave a previous success looking current.
    (OUTPUT / 'result.json').unlink(missing_ok=True)
    (OUTPUT / 'host-unit-tests.log').unlink(missing_ok=True)
    (OUTPUT / 'commands.log').write_text('')
    developer = Path(query('xcode-select', '-p'))
    host_arch = platform.machine()
    if host_arch not in ('arm64', 'x86_64'):
        raise RuntimeError(f'Unsupported test host: {host_arch}')

    core_sources = sorted((ROOT / 'Packages/AgentDeskCore/Sources/AgentDeskCore').glob('*.swift'))
    design_sources = sorted((ROOT / 'Packages/AgentDeskDesign/Sources/AgentDeskDesign').glob('*.swift'))
    unit_sources = sorted((ROOT / 'Packages/AgentDeskCore/Tests/AgentDeskCoreTests').glob('*.swift'))
    app_sources = sorted((ROOT / 'AgentDesk').glob('*.swift'))
    app_tests = sorted((ROOT / 'AgentDeskTests').glob('*.swift'))
    ui_tests = sorted((ROOT / 'AgentDeskUITests').glob('*.swift'))

    host_context = None
    for label, sdk_name, triple, platform_name in [
        ('mac-arm64', 'macosx', 'arm64-apple-macosx15.0', 'MacOSX'),
        ('mac-intel', 'macosx', 'x86_64-apple-macosx15.0', 'MacOSX'),
        ('iphone-simulator', 'iphonesimulator', 'arm64-apple-ios18.0-simulator', 'iPhoneSimulator'),
        ('iphone-device', 'iphoneos', 'arm64-apple-ios18.0', 'iPhoneOS'),
    ]:
        destination = OUTPUT / label
        destination.mkdir(exist_ok=True)
        sdk = query('xcrun', '--sdk', sdk_name, '--show-sdk-path')
        base = ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                '-target', triple, '-sdk', sdk, '-module-cache-path', destination / 'ModuleCache']
        frameworks = developer / f'Platforms/{platform_name}.platform/Developer/Library/Frameworks'
        libraries = developer / f'Platforms/{platform_name}.platform/Developer/usr/lib'
        testing = ['-F', frameworks, '-I', libraries]

        run(base + ['-parse-as-library', '-emit-library', '-static', '-emit-module', '-enable-testing',
                    '-module-name', 'AgentDeskCore', '-emit-module-path', destination / 'AgentDeskCore.swiftmodule',
                    '-o', destination / 'libAgentDeskCore.a'] + core_sources)
        run(base + ['-emit-module', '-module-name', 'AgentDeskDesign',
                    '-emit-module-path', destination / 'AgentDeskDesign.swiftmodule'] + design_sources)
        run(base + ['-typecheck', '-default-isolation', 'MainActor', '-I', destination] + app_sources)
        run(base + testing + ['-typecheck', '-I', destination] + unit_sources + app_tests)
        run(base + testing + ['-typecheck'] + ui_tests)
        print(f'PASS: {label} source compilation/type checks (not an app build)', flush=True)
        if label == f'mac-{host_arch}' or (host_arch == 'x86_64' and label == 'mac-intel'):
            host_context = (base, testing, destination, frameworks, libraries)

    base, testing, destination, frameworks, libraries = host_context
    bundle = destination / 'AgentDeskCoreTests.xctest'
    binary = bundle / 'Contents/MacOS/AgentDeskCoreTests'
    binary.parent.mkdir(parents=True, exist_ok=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'AgentDeskCoreTests',
        'CFBundleIdentifier': 'com.mirza.AgentDeskCoreTests',
        'CFBundlePackageType': 'BNDL',
    }))
    run(base + testing + ['-emit-library', '-module-name', 'AgentDeskCoreTests', '-I', destination,
                         '-L', destination, '-lAgentDeskCore', '-Xlinker', '-rpath', '-Xlinker', frameworks,
                         '-L', libraries, '-Xlinker', '-rpath', '-Xlinker', libraries,
                         '-o', binary] + unit_sources)

    # XCTest can dump the process environment on launcher errors. Persist only test-result lines.
    command = ['xcrun', 'xctest', str(bundle)]
    with (OUTPUT / 'commands.log').open('a') as log:
        log.write(shlex.join(command) + '\n')
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    lines = [line for line in (result.stdout + result.stderr).splitlines()
             if line.startswith(('Test Suite ', 'Test Case ', '\t Executed ', 'Executed '))]
    report = '\n'.join(lines) + '\n'
    (OUTPUT / 'host-unit-tests.log').write_text(report)
    print(report, end='')
    if result.returncode or not any('Executed 5 tests' in line for line in lines):
        raise RuntimeError(f'Host XCTest verification failed: exit {result.returncode}')
    (OUTPUT / 'result.json').write_text(json.dumps({
        'sourceChecks': ['mac-arm64', 'mac-intel', 'iphone-simulator', 'iphone-device'],
        'hostUnitTests': 5,
        'hostArchitecture': host_arch,
        'xcodeBuild': 'not covered',
        'simulatorExecution': 'not covered',
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
