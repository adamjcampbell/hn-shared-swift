#!/usr/bin/env python3
"""Generate the app bridge and build the pinned official Swift–Java runtime."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

here = Path(__file__).resolve().parent
root = here.parent.parent
package = root / 'HackerNewsReader'
out = here.parent / 'build/swift'
android = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
ndk = android / 'ndk/27.3.13750724/toolchains/llvm/prebuilt/darwin-x86_64'
sdk = Path(os.environ.get('SWIFT_ANDROID_SDK', Path.home() / '.swiftpm/swift-sdks/swift-6.3.1-RELEASE_android.artifactbundle/swift-android'))
env = dict(os.environ, ANDROID_HOME=str(android))

def run(*args, cwd=root):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

version = subprocess.check_output(['swiftc', '--version'], text=True)
if 'Swift version 6.3.1 ' not in version:
    raise RuntimeError('The Looper integration requires the tested Swift 6.3.1 toolchain')
metadata = json.loads((sdk.parent / 'info.json').read_text())
if 'swift-6.3.1-RELEASE_android' not in metadata['artifacts']:
    raise RuntimeError('The Looper integration requires Swift Android SDK 6.3.1-RELEASE')

out.mkdir(parents=True, exist_ok=True)
root_lock = package / 'Package.resolved'
locked = root_lock.read_bytes()
try:
    run('swift', 'package', '--package-path', package, '--force-resolved-versions', 'resolve')
    if json.loads(root_lock.read_bytes())['pins'] != json.loads(locked)['pins']:
        raise RuntimeError('Root dependency graph changed; update Package.resolved explicitly')
finally:
    root_lock.write_bytes(locked)
checkouts = package / '.build/checkouts'
upstream = checkouts / 'swift-java'
env['SWIFT_JAVA_JNI_CORE_PATH'] = str(checkouts / 'swift-java-jni-core')
# Version 2 locks omit originHash, which depends on absolute local dependency paths.
shutil.copy2(here / 'swift-java.Package.resolved', upstream / 'Package.resolved')
host = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parent.parent / 'lib/swift/host'
run('swiftc', '-I', host, '-L', host, '-Xlinker', '-rpath', '-Xlinker', host,
    root / 'scripts/generate-android.swift', '-o', out / 'generate-android')
run(out / 'generate-android', root, out / 'kotlin')

tool = os.environ.get('SWIFT_JAVA_TOOL')
if not tool:
    run('swift', 'build', '--package-path', upstream, '--force-resolved-versions', '--product', 'swift-java')
    tool = upstream / '.build/debug/swift-java'

extraction = out / 'extraction'
if extraction.exists(): shutil.rmtree(extraction)
extraction.mkdir()
for name in ['AndroidReader', 'AndroidReader.generated', 'Message', 'Command', 'Strings']:
    shutil.copy2(package / 'Sources/HackerNewsReader' / (name + '.swift'), extraction)
for folder in ['java', 'thunks']:
    path = out / folder
    if path.exists(): shutil.rmtree(path)
run(tool, 'jextract', '--mode', 'jni', '--swift-module', 'HackerNewsReader',
    '--java-package', 'com.example.hackernewsreader.swift', '--input-swift', extraction,
    '--output-swift', out / 'thunks', '--output-java', out / 'java')

native_package = out / 'package'
sources = native_package / 'Sources'
sources.mkdir(parents=True, exist_ok=True)
for module in ['PlatformSupport', 'HackerNews', 'HackerNewsReader', 'JNIThunks']:
    destination = sources / module
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir()
    origin = out / 'thunks' if module == 'JNIThunks' else package / 'Sources' / module
    for source in origin.glob('*.swift'):
        shutil.copy2(source, destination / source.name)
(native_package / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"), .unsafeFlags(["-Osize"])]
let package = Package(name: "AndroidRuntime", products: [
    .library(name: "HackerNewsReader", type: .dynamic, targets: ["JNIThunks"])
], dependencies: [.package(path: "''' + str(upstream) + '''")], targets: [
    .target(name: "PlatformSupport", dependencies: [.product(name: "SwiftJava", package: "swift-java")], swiftSettings: strict),
    .target(name: "HackerNews", dependencies: ["PlatformSupport"], swiftSettings: strict),
    .target(name: "HackerNewsReader", dependencies: ["HackerNews", "PlatformSupport"], swiftSettings: strict),
    .target(name: "JNIThunks", dependencies: ["HackerNewsReader",
        .product(name: "SwiftJava", package: "swift-java"),
        .product(name: "SwiftRuntimeFunctions", package: "swift-java")],
        swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"]),
            .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "HackerNewsReader"])],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-z", "-Xlinker", "max-page-size=16384"], .when(platforms: [.android]))])
])
''')
shutil.copy2(here / 'android.Package.resolved', native_package / 'Package.resolved')
run('swift', 'build', '--package-path', native_package, '--force-resolved-versions', '--swift-sdk', 'aarch64-unknown-linux-android28',
    '-c', 'release', '--product', 'HackerNewsReader')
build = native_package / '.build/aarch64-unknown-linux-android28/release'
run(ndk / 'bin/aarch64-linux-android28-clang', '-shared', '-fPIC', here / 'main-looper.c',
    '-L' + str(sdk / 'swift-resources/usr/lib/swift-aarch64/android'), '-ldispatch', '-landroid',
    '-Wl,--no-undefined', '-Wl,-z,max-page-size=16384', '-o', build / 'libMainLooper.so')

available = {p.name: p for p in (sdk / 'swift-resources/usr/lib/swift-aarch64/android').rglob('*.so')}
available.update({p.name: p for p in build.glob('*.so')})
available['libc++_shared.so'] = ndk / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so'
system = {'libc.so', 'libdl.so', 'libm.so', 'liblog.so', 'libandroid.so', 'libz.so'}
queue = ['libHackerNewsReader.so', 'libMainLooper.so', 'libSwiftJava.so', 'libSwiftRuntimeFunctions.so']
edges = {}
while queue:
    name = queue.pop()
    if name in edges: continue
    if re.search(r'Foundation(?!Essentials)|ICU|libicu|Skip|SwiftJNI', name):
        raise RuntimeError(f'Forbidden dependency: {name}')
    output = subprocess.check_output([ndk / 'bin/llvm-readelf', '-d', available[name]], text=True)
    edges[name] = re.findall(r'\(NEEDED\).*?\[(.*?)\]', output)
    queue.extend(dependency for dependency in edges[name] if dependency not in system)
native = out / 'jniLibs/arm64-v8a'
if native.exists(): shutil.rmtree(native)
native.mkdir(parents=True)
sizes = {}
for name in sorted(edges):
    shutil.copy2(available[name], native / name)
    run(ndk / 'bin/llvm-strip', '--strip-unneeded', native / name)
    sizes[name] = (native / name).stat().st_size
(out / 'native-sizes.json').write_text(json.dumps(dict(native_bytes=sum(sizes.values()), sizes=sizes, edges=edges), indent=2) + '\n')

classes = out / 'classes'
libs = out / 'libs'
for path in [classes, libs]:
    if path.exists(): shutil.rmtree(path)
    path.mkdir()
java_home = Path(env['JAVA_HOME'])
java_sources = [*sorted((upstream / 'SwiftKitCore/src/main/java').rglob('*.java')), *sorted((out / 'java').rglob('*.java'))]
arguments = out / 'javac.args'
arguments.write_text('\n'.join('"' + str(p) + '"' for p in java_sources))
run(java_home / 'bin/javac', '--release', '17', '-d', classes, '@' + str(arguments))
run(java_home / 'bin/jar', 'cf', libs / 'SwiftJava.jar', '-C', classes, '.')

notices = out / 'assets/third-party'
if notices.exists(): shutil.rmtree(notices)
notices.mkdir(parents=True)
for dependency in ['swift-java', 'swift-java-jni-core']:
    origin = checkouts / dependency
    for name in ['LICENSE.txt', 'NOTICE.txt', 'CONTRIBUTORS.txt']:
        if (origin / name).exists(): shutil.copy2(origin / name, notices / (dependency + '-' + name))
shutil.copy2(package / 'Package.resolved', notices / 'Package.resolved')
shutil.copy2(upstream / 'Package.resolved', notices / 'swift-java.Package.resolved')
shutil.copy2(native_package / 'Package.resolved', notices / 'android.Package.resolved')
shutil.copy2(sdk / 'swift-resources/usr/share/swift/LICENSE.txt', notices / 'Swift-LICENSE.txt')
for name in ['NOTICE', 'NOTICE.toolchain']:
    shutil.copy2(android / 'ndk/27.3.13750724' / name, notices / ('NDK-' + name + '.txt'))
shutil.copy2(here / 'NOTICE.txt', notices / 'NOTICE.txt')
print(f'Official Swift–Java native closure: {sum(sizes.values()):,} bytes')
