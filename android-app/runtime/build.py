#!/usr/bin/env python3
"""Build stock generated peers with a Foundation-light native runtime."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

here = Path(__file__).resolve().parent
root = here.parent.parent
package = root / 'HackerNewsReader'
out = here.parent / 'build/swift'
checkouts = package / '.build/checkouts'
android = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
ndk = android / 'ndk/27.3.13750724/toolchains/llvm/prebuilt/darwin-x86_64'
sdk = Path(os.environ.get('SWIFT_ANDROID_SDK', Path.home() / '.swiftpm/swift-sdks/swift-6.3.1-RELEASE_android.artifactbundle/swift-android'))
env = dict(os.environ)
env['ANDROID_HOME'] = str(android)

def run(*args, cwd=root):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)

version = subprocess.check_output(['swiftc', '--version'], text=True)
if 'Swift version 6.3.1 ' not in version:
    raise RuntimeError('The Looper integration requires the tested Swift 6.3.1 toolchain')
metadata = json.loads((sdk.parent / 'info.json').read_text())
if 'swift-6.3.1-RELEASE_android' not in metadata['artifacts']:
    raise RuntimeError('The Looper integration requires Swift Android SDK 6.3.1-RELEASE')

out.mkdir(parents=True, exist_ok=True)
run('swift', 'build', '--force-resolved-versions', '--package-path', package)
skip = package / '.build/artifacts/skip/skip/skip.artifactbundle/macos/skip'
modules = {'SkipBridge': 'skip-bridge', 'SkipAndroidBridge': 'skip-android-bridge',
           'SkipFuse': 'skip-fuse', 'SkipLib': 'skip-lib', 'SkipModel': 'skip-model',
           'SkipUnit': 'skip-unit', 'SkipFoundation': 'skip-foundation'}
dependencies = []
for module, dependency in modules.items():
    dependencies += ['--dependency', f'{module}:{dependency}:{checkouts / dependency}',
                     '--module', f'{module}:{checkouts / dependency / "Sources" / module}']
    link = package / '.build/plugins/outputs' / dependency / module / 'destination/skipstone' / module
    if link.exists(): dependencies += ['--link', f'{module}:{link}']
for module in ['HackerNews', 'HackerNewsReader']:
    source = package / 'Sources' / module
    generated = out / 'generated' / module
    if generated.exists(): shutil.rmtree(generated)
    generated.mkdir(parents=True, exist_ok=True)
    relative_dependencies = []
    for index, value in enumerate(dependencies):
        if index > 0 and dependencies[index - 1] == '--link':
            name, path = value.split(':', 1)
            value = f'{name}:{os.path.relpath(path, generated)}'
        relative_dependencies.append(value)
    args = [skip, 'skipstone', '--project', source, '--skip-folder', source / 'Skip',
            '--module', f'{module}:{source}', '--module', f'PlatformSupport:{package / "Sources/PlatformSupport"}', *relative_dependencies]
    if module == 'HackerNewsReader':
        args += ['--dependency', f'HackerNews:hackernewsreader:{package}',
                 '--module', f'HackerNews:{package / "Sources/HackerNews"}',
                 '--link', 'HackerNews:../HackerNews/swift-project']
    run(*args, '--sourcehash', generated / '.swift.hash', '--output-folder', generated / 'swift-project/src/main',
        '--module-root', generated / 'swift-project', '--skip-bridge-output', generated / 'bridge')
    run(*args, '--sourcehash', generated / '.kotlin.hash', '--output-folder', generated / 'kotlin/src/main',
        '--module-root', generated / 'kotlin')

runtime = out / 'runtime'
if runtime.exists(): shutil.rmtree(runtime)
for module, dependency in [('SwiftJNI', 'swift-jni'), ('CJNI', 'swift-jni'),
                           ('SkipBridge', 'skip-bridge')]:
    shutil.copytree(checkouts / dependency / 'Sources' / module, runtime / module)
(runtime / 'SkipBridge/BridgedJob.swift').unlink()
(runtime / 'SkipAndroidBridge').mkdir()
for name in ['Observation.swift', 'ObservationModule.swift']:
    shutil.copy2(checkouts / 'skip-android-bridge/Sources/SkipAndroidBridge' / name, runtime / 'SkipAndroidBridge' / name)
run('patch', '--batch', '--fuzz=0', '-p0', '-i', here / 'foundation-light.patch', cwd=runtime)

flags = ['-target', 'aarch64-unknown-linux-android28', '-sdk', sdk / 'ndk-sysroot',
         '-resource-dir', sdk / 'swift-resources/usr/lib/swift-aarch64', '-tools-directory', ndk / 'bin',
         '-Xclang-linker', '-fuse-ld=lld', '-module-cache-path', out / 'cache', '-Osize', '-g',
         '-emit-library', '-emit-module', '-I', out, '-L', out, '-I', runtime / 'CJNI/include',
         '-D', 'SKIP_BRIDGE', '-Xlinker', '-z', '-Xlinker', 'max-page-size=16384', '-Xlinker', '--no-undefined']
env['PATH'] = str(ndk / 'bin') + os.pathsep + os.environ['PATH']

def compile(module, sources, links=(), strict=False):
    run('swiftc', *flags, *(['-swift-version', '6', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault'] if strict else []),
        '-module-name', module, *sources, *['-l' + link for link in links],
        '-o', out / f'lib{module}.so', '-emit-module-path', out / f'{module}.swiftmodule')

compile('SwiftJNI', sorted((runtime / 'SwiftJNI').glob('*.swift')))
compile('SkipBridge', sorted((runtime / 'SkipBridge').glob('*.swift')), ['SwiftJNI'])
compile('SkipAndroidBridge', sorted((runtime / 'SkipAndroidBridge').glob('*.swift')), ['SwiftJNI'])
compile('SkipFuse', [here / 'SkipFuse.swift'], ['SkipBridge', 'SkipAndroidBridge'])
compile('PlatformSupport', sorted((package / 'Sources/PlatformSupport').glob('*.swift')), ['SwiftJNI'], strict=True)
for module in ['HackerNews', 'HackerNewsReader']:
    peers = out / 'generated' / module / 'bridge'
    compile(module, [*sorted((package / 'Sources' / module).glob('*.swift')),
                     *sorted(peers.glob('*_Bridge.swift')), peers / 'AnyDynamicObject_Support.swift'],
            ['SkipFuse', 'SkipBridge', 'SkipAndroidBridge', 'SwiftJNI', 'PlatformSupport'] +
            (['HackerNews'] if module == 'HackerNewsReader' else []), strict=True)
run(ndk / 'bin/aarch64-linux-android28-clang', '-shared', '-fPIC', here / 'main-looper.c',
    '-L' + str(sdk / 'swift-resources/usr/lib/swift-aarch64/android'), '-ldispatch', '-landroid',
    '-Wl,--no-undefined', '-Wl,-z,max-page-size=16384', '-o', out / 'libMainLooper.so')

available = {p.name: p for p in (sdk / 'swift-resources/usr/lib/swift-aarch64/android').rglob('*.so')}
available.update({p.name: p for p in out.glob('*.so')})
available['libc++_shared.so'] = ndk / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so'
system = {'libc.so', 'libdl.so', 'libm.so', 'liblog.so', 'libandroid.so', 'libz.so'}
queue = ['libHackerNewsReader.so', 'libMainLooper.so']
edges = {}
while queue:
    name = queue.pop()
    if name in edges: continue
    if re.search(r'Foundation(?!Essentials)|ICU', name): raise RuntimeError(f'Forbidden dependency: {name}')
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

# Build only JVM jars: never invoke Skip's native merge/build tasks.
gradle = package / '.build/plugins/outputs/hackernewsreader/HackerNewsReader/destination/skipstone'
env['PATH'] = os.environ['PATH']
jvm_modules = ['SkipBridge', 'SkipLib', 'SkipModel', 'SkipFoundation']
run(here.parent / 'gradlew', '-p', gradle, *[f':{m}:bundleLibCompileToJarRelease' for m in jvm_modules], '--console=plain')
libs = out / 'libs'
if libs.exists(): shutil.rmtree(libs)
libs.mkdir(exist_ok=True)
for module in jvm_modules:
    jar = gradle / module / 'build/intermediates/compile_library_classes_jar/release/bundleLibCompileToJarRelease/classes.jar'
    shutil.copy2(jar, libs / f'{module}.jar')

notices = out / 'assets/third-party'
if notices.exists(): shutil.rmtree(notices)
notices.mkdir(parents=True)
covered = ['skip-bridge', 'skip-android-bridge', 'skip-lib', 'skip-model', 'skip-foundation', 'swift-jni']
pins = json.loads((package / 'Package.resolved').read_text())['pins']
sources = {pin['identity']: dict(url=pin['location'], **pin['state']) for pin in pins if pin['identity'] in covered}
(notices / 'sources.json').write_text(json.dumps(sources, indent=2) + '\n')
for dependency in covered:
    shutil.copy2(checkouts / dependency / 'LICENSE.txt', notices / f'{dependency}-LICENSE.txt')
shutil.copy2(sdk / 'swift-resources/usr/share/swift/LICENSE.txt', notices / 'Swift-LICENSE.txt')
shutil.copy2(android / 'ndk/27.3.13750724/NOTICE', notices / 'NDK-NOTICE.txt')
shutil.copy2(android / 'ndk/27.3.13750724/NOTICE.toolchain', notices / 'NDK-toolchain-NOTICE.txt')
with zipfile.ZipFile(notices / 'runtime-sources.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for source in sorted(runtime.rglob('*')):
        if source.is_file(): archive.write(source, 'native/' + str(source.relative_to(runtime)))
    for dependency in covered:
        for source in sorted((checkouts / dependency / 'Sources').rglob('*')):
            if source.is_file(): archive.write(source, dependency + '/' + str(source.relative_to(checkouts / dependency)))
    for name in ['build.py', 'foundation-light.patch', 'main-looper.c', 'SkipFuse.swift']:
        archive.write(here / name, 'build/' + name)
    archive.write(package / 'Package.resolved', 'build/Package.resolved')
shutil.copy2(here / 'NOTICE.txt', notices / 'NOTICE.txt')
print(f'Foundation-light native closure: {sum(sizes.values()):,} bytes')
