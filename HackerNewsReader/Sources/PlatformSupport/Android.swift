#if os(Android)
import FoundationEssentials
import SwiftJNI
import Synchronization

private let services = try! JClass(name: "com/example/hackernewsreader/PlatformServices")
private let startMethod = services.getStaticMethodID(name: "start", sig: "(JLjava/lang/String;)V")!
private let cancelMethod = services.getStaticMethodID(name: "cancel", sig: "(J)V")!
private let languagesMethod = services.getStaticMethodID(name: "languages", sig: "()Ljava/lang/String;")!
private let timeMethod = services.getStaticMethodID(name: "formatTime", sig: "(D)Ljava/lang/String;")!

private struct Pending {
    var next: Int64 = 0
    var continuations: [Int64: CheckedContinuation<HTTPResponse, any Error>] = [:]
}
private let pending = Mutex(Pending())

public func fetch(_ url: URL) async throws -> HTTPResponse {
    let id = pending.withLock { $0.next += 1; return $0.next }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            // Register/start and cancellation are ordered across the JNI boundary.
            let failure: (any Error)? = pending.withLock { state in
                if Task.isCancelled { return CancellationError() }
                state.continuations[id] = continuation
                do {
                    try jniContext {
                        let address = url.absoluteString.toJavaObject(options: [])!
                        defer { JNI.jni.deleteLocalRef(address) }
                        try services.callStatic(method: startMethod, options: [], args: [
                            id.toJavaParameter(options: []), address.toJavaParameter(options: [])
                        ])
                    }
                    return nil
                } catch {
                    state.continuations.removeValue(forKey: id)
                    return HTTPError.transport(String(describing: error))
                }
            }
            if let failure { continuation.resume(throwing: failure) }
        }
    } onCancel: {
        let continuation = pending.withLock { state in
            guard let continuation = state.continuations.removeValue(forKey: id) else { return nil as CheckedContinuation<HTTPResponse, any Error>? }
            jniContext {
                try! services.callStatic(method: cancelMethod, options: [], args: [id.toJavaParameter(options: [])])
            }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

@_cdecl("Java_com_example_hackernewsreader_PlatformServices_complete")
public func complete(_ env: JNIEnvPointer, _ target: JavaObjectPointer, _ id: Int64,
                     _ status: Int32, _ bytes: JavaByteArray?, _ error: JavaString?) {
    guard let continuation = pending.withLock({ $0.continuations.removeValue(forKey: id) }) else { return }
    if let error {
        continuation.resume(throwing: HTTPError.transport(String.fromJavaObject(error, options: [])))
    } else if let bytes {
        let (pointer, count) = JNI.jni.getByteArrayElements(bytes)
        let body = pointer.map { Data(bytes: $0, count: Int(count)) } ?? Data()
        JNI.jni.releaseByteArrayElements(bytes, elements: pointer, mode: .abort)
        continuation.resume(returning: HTTPResponse(body: body, statusCode: Int(status)))
    } else {
        continuation.resume(throwing: HTTPError.transport("Missing HTTP response body"))
    }
}

public func preferredLanguages() -> [String] {
    jniContext {
        let result: JavaString? = try! services.callStatic(method: languagesMethod, options: [], args: [])
        defer { if let result { JNI.jni.deleteLocalRef(result) } }
        return String.fromJavaObject(result, options: []).split(separator: ",").map(String.init)
    }
}

public func formatTime(_ date: Date) -> String {
    jniContext {
        let result: JavaString? = try! services.callStatic(method: timeMethod, options: [], args: [date.timeIntervalSince1970.toJavaParameter(options: [])])
        defer { if let result { JNI.jni.deleteLocalRef(result) } }
        return String.fromJavaObject(result, options: [])
    }
}
#endif
