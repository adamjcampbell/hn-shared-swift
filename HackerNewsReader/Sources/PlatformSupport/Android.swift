#if os(Android)
import FoundationEssentials
import SwiftJava
import Synchronization

private let services = Mutex<Int?>(nil)

@_cdecl("Java_com_example_hackernewsreader_PlatformServices_initialize")
public func initialize(_ env: JNIEnvironment, _ target: jobject, _ type: jclass) {
    services.withLock {
        precondition($0 == nil)
        $0 = Int(bitPattern: env.interface.NewGlobalRef(env, type)!)
    }
}

private func withServices<Result>(_ body: (JavaClass<JavaObject>) throws -> Result) throws -> Result {
    let address = services.withLock { $0! }
    let environment = try JavaVirtualMachine.shared().environment()
    // Only the class reference is global; JNIEnv and its wrappers belong to this thread.
    let local = environment.interface.NewLocalRef(environment, jobject(bitPattern: address)!)!
    return try body(JavaClass<JavaObject>(javaThis: local, environment: environment))
}

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
                    try withServices {
                        try $0.dynamicJavaStaticMethodCall(methodName: "start", arguments: id, url.absoluteString)
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
            try! withServices {
                try $0.dynamicJavaStaticMethodCall(methodName: "cancel", arguments: id)
            }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

@_cdecl("Java_com_example_hackernewsreader_PlatformServices_complete")
public func complete(_ env: JNIEnvironment, _ target: jobject, _ id: Int64,
                     _ status: Int32, _ bytes: jbyteArray?, _ error: jstring?) {
    guard let continuation = pending.withLock({ $0.continuations.removeValue(forKey: id) }) else { return }
    if let error {
        continuation.resume(throwing: HTTPError.transport(String(fromJNI: error, in: env)))
    } else if let bytes {
        let body = Data([UInt8](fromJNI: bytes, in: env))
        continuation.resume(returning: HTTPResponse(body: body, statusCode: Int(status)))
    } else {
        continuation.resume(throwing: HTTPError.transport("Missing HTTP response body"))
    }
}

public func preferredLanguages() -> [String] {
    try! withServices {
        let result = try $0.dynamicJavaStaticMethodCall(methodName: "languages", resultType: String.self)
        return result.split(separator: ",").map(String.init)
    }
}

public func formatTime(_ date: Date) -> String {
    try! withServices {
        try $0.dynamicJavaStaticMethodCall(methodName: "formatTime", arguments: date.timeIntervalSince1970,
                                          resultType: String.self)
    }
}
#endif
