#if canImport(Darwin)
import Darwin
#endif
import Foundation

struct MSPCPythonSymbols: @unchecked Sendable {
    typealias PyInitializeEx = @convention(c) (Int32) -> Void
    typealias PyIsInitialized = @convention(c) () -> Int32
    typealias PyRunSimpleStringFlags = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Int32
    typealias PyGILStateEnsure = @convention(c) () -> Int32
    typealias PyGILStateRelease = @convention(c) (Int32) -> Void
    typealias PyEvalSaveThread = @convention(c) () -> UnsafeMutableRawPointer?
    typealias PyNewInterpreter = @convention(c) () -> UnsafeMutableRawPointer?
    typealias PyEndInterpreter = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias PyThreadStateGet = @convention(c) () -> UnsafeMutableRawPointer?
    typealias PyThreadStateSwap = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    var pyInitializeEx: PyInitializeEx
    var pyIsInitialized: PyIsInitialized
    var pyRunSimpleStringFlags: PyRunSimpleStringFlags
    var pyGILStateEnsure: PyGILStateEnsure
    var pyGILStateRelease: PyGILStateRelease
    var pyEvalSaveThread: PyEvalSaveThread
    var pyNewInterpreter: PyNewInterpreter
    var pyEndInterpreter: PyEndInterpreter
    var pyThreadStateGet: PyThreadStateGet
    var pyThreadStateSwap: PyThreadStateSwap

    init(library: MSPCPythonLibrary) throws {
        #if canImport(Darwin)
        let handle: UnsafeMutableRawPointer?
        switch library {
        case .currentProcess:
            handle = dlopen(nil, RTLD_NOW)
        case .path(let url):
            handle = dlopen(url.standardizedFileURL.path, RTLD_NOW | RTLD_GLOBAL)
        }
        guard let handle else {
            let message = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable(message)
        }
        self.pyInitializeEx = try Self.symbol("Py_InitializeEx", handle: handle)
        self.pyIsInitialized = try Self.symbol("Py_IsInitialized", handle: handle)
        self.pyRunSimpleStringFlags = try Self.symbol("PyRun_SimpleStringFlags", handle: handle)
        self.pyGILStateEnsure = try Self.symbol("PyGILState_Ensure", handle: handle)
        self.pyGILStateRelease = try Self.symbol("PyGILState_Release", handle: handle)
        self.pyEvalSaveThread = try Self.symbol("PyEval_SaveThread", handle: handle)
        self.pyNewInterpreter = try Self.symbol("Py_NewInterpreter", handle: handle)
        self.pyEndInterpreter = try Self.symbol("Py_EndInterpreter", handle: handle)
        self.pyThreadStateGet = try Self.symbol("PyThreadState_Get", handle: handle)
        self.pyThreadStateSwap = try Self.symbol("PyThreadState_Swap", handle: handle)
        #else
        throw MSPPythonEmbeddedRuntimeError.engineUnavailable("dynamic CPython loading is not available")
        #endif
    }

    #if canImport(Darwin)
    private static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw MSPPythonEmbeddedRuntimeError.engineUnavailable("missing CPython symbol \(name)")
        }
        return unsafeBitCast(pointer, to: T.self)
    }
    #endif
}
