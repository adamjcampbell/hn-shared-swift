#!/usr/bin/env python3
"""Host-only bridge contract test. Requires pinned swift-java, JDK 17+, and kotlinc
or cached Kotlin 2.2.21 compiler jars. Never writes into the real source tree.
GENERATOR_SOURCE can point at an older generator for a fail-before check.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
upstream = root / 'HackerNewsReader/.build/checkouts/swift-java'
java_home = Path(os.environ.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='android-generator-') as temp:
    temp = Path(temp)
    sources = temp / 'HackerNewsReader/Sources/HackerNewsReader'
    sources.mkdir(parents=True)
    host = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parent.parent / 'lib/swift/host'
    run('swiftc', '-I', host, '-L', host, '-Xlinker', '-rpath', '-Xlinker', host,
        os.environ.get('GENERATOR_SOURCE', root / 'scripts/generate-android.swift'), '-o', temp / 'generate')
    fields = '''
    public var isEnabled: Bool = false
    public var active: Bool = false
    public var island: Bool = false
    public var query: String = "" { didSet {} }
    public var count: Int = 0 { willSet {} }
    public var identifier: Int64 = 0
    public var fraction: Double = 0
    public var explicit: String { get { query } }
    public var implicit: String { query }
    public var computed: String { get { query } set { query = newValue } }
    public private(set) var restricted: String = ""
    public let constant: String = ""
    public internal(set) var text: String? = nil
    public internal(set) var strings: [String] = []
    public internal(set) var date: Date = Date()
'''
    for value in ['StoryRow', 'LoadedStories', 'LoadStatus']:
        fields += f'    public internal(set) var one{value}: {value} = {value}()\n'
        fields += f'    public internal(set) var maybe{value}: {value}? = nil\n'
        fields += f'    public internal(set) var many{value}: [{value}] = []\n'
        nested = '''    public let status: LoadStatus = LoadStatus()
    public let maybeStatus: LoadStatus? = nil
    public let statuses: [LoadStatus] = []
''' if value == 'StoryRow' else ''
        (sources / f'{value}.swift').write_text(f'''import Foundation
public struct {value}: Sendable {{
    public let title: String = ""
    public let url: String? = nil
    public let ids: [String] = []
    public let isRead: Bool = false
    public let count: Int = 0
    public let date: Date = Date()
{nested}\
}}
''')
    model = 'import Foundation\npublic final class Model {\n' + fields + '}\n'
    (sources / 'Model.swift').write_text(model)
    run(temp / 'generate', temp, temp / 'kotlin')
    extraction = temp / 'extraction'
    extraction.mkdir()
    generated = sources / 'AndroidReader.generated.swift'
    shutil.copy2(generated, extraction)
    (extraction / 'AndroidReader.swift').write_text('''public final class AndroidReader {
    let storage = Storage()
    public func cancel(_ token: Int64) {}
}
''')
    (sources / 'Storage.swift').write_text('''final class Storage {
    let model = Model()
    func observe(read: () -> Void, callback: sending @escaping () -> Void) -> Int64 { 0 }
}
''')
    run('swiftc', '-typecheck', '-swift-version', '6', *sources.glob('*.swift'), extraction / 'AndroidReader.swift')
    run(upstream / '.build/debug/swift-java', 'jextract', '--mode', 'jni',
        '--swift-module', 'HackerNewsReader', '--java-package', 'com.example.hackernewsreader.swift',
        '--input-swift', extraction, '--output-swift', temp / 'thunks', '--output-java', temp / 'java')
    classes = temp / 'classes'
    classes.mkdir()
    java_sources = [*(upstream / 'SwiftKitCore/src/main/java').rglob('*.java'), *(temp / 'java').rglob('*.java')]
    args = temp / 'java.args'
    args.write_text('\n'.join('"' + str(path) + '"' for path in java_sources))
    run(java_home / 'bin/javac', '--release', '17', '-d', classes, '@' + str(args))
    compose = temp / 'Compose.kt'
    compose.write_text('''package androidx.compose.runtime
class MutableLongState(var longValue: Long)
fun mutableLongStateOf(value: Long) = MutableLongState(value)
''')
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    stdlib = next((cache / 'org.jetbrains.kotlin/kotlin-stdlib/2.2.21').glob('*/*.jar'))
    compiler = shutil.which('kotlinc')
    if compiler:
        command = [compiler]
    else:
        jars = [* (cache / 'org.jetbrains.kotlin/kotlin-compiler-embeddable/2.2.21').glob('*/*.jar'),
                stdlib, *(cache / 'org.jetbrains.kotlin/kotlin-script-runtime/2.2.21').glob('*/*.jar'),
                *(cache / 'org.jetbrains.kotlin/kotlin-reflect/1.6.10').glob('*/*.jar'),
                *(cache / 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0').glob('*/*.jar'),
                *(cache / 'org.jetbrains/annotations').glob('*/*/*.jar')]
        command = [java_home / 'bin/java', '-cp', os.pathsep.join(map(str, jars)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler']
    run(*command, '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath',
        os.pathsep.join(map(str, [classes, stdlib])), '-d', temp / 'kotlin-classes',
        compose, temp / 'kotlin/Model.kt')
    kotlin = (temp / 'kotlin/Model.kt').read_text()
    broken = temp / 'OldSetter.kt'
    broken.write_text(kotlin.replace('native.setEnabled(value)', 'native.setIsEnabled(value)'))
    result = subprocess.run([*map(str, command), '-no-stdlib', '-no-reflect', '-jvm-target', '17',
                             '-classpath', os.pathsep.join(map(str, [classes, stdlib])),
                             '-d', str(temp / 'negative-control'), str(compose), str(broken)],
                            capture_output=True, text=True)
    assert result.returncode != 0 and 'setIsEnabled' in result.stderr, result.stderr
    for name in ['explicit', 'implicit', 'restricted', 'constant']:
        assert f'val {name}: String' in kotlin, name
    for name in ['query', 'count', 'computed']:
        assert f'var {name}:' in kotlin, name
    rejected = ['public internal(set) var bad: Int? = nil', 'public var bad: String? = nil',
                'public var bad: [String] = []', 'public var bad: Date = Date()',
                'public var bad: StoryRow = StoryRow()', 'public var bad: Bool? = nil',
                'public var bad: Double? = nil', 'public var bad: [[String]] = []']
    for declaration in rejected:
        (sources / 'Model.swift').write_text(model.replace('\n}', '\n' + declaration + '\n}'))
        before = generated.read_bytes(), (temp / 'kotlin/Model.kt').read_bytes()
        result = subprocess.run([str(temp / 'generate'), str(temp), str(temp / 'kotlin')], capture_output=True, text=True)
        assert result.returncode != 0 and 'Unsupported' in result.stderr and 'Model.bad' in result.stderr, declaration
        assert before == (generated.read_bytes(), (temp / 'kotlin/Model.kt').read_bytes()), declaration
    for name in ['Model', 'StoryRow', 'LoadedStories', 'LoadStatus']:
        shutil.copy2(root / f'HackerNewsReader/Sources/HackerNewsReader/{name}.swift', sources)
    run(temp / 'generate', temp, temp / 'kotlin')
    print(f'PASS: 24 properties, Swift 6 typecheck, official Java + Kotlin compilation, old Boolean setter rejected by Kotlin, {len(rejected)} fail-before-write cases')
