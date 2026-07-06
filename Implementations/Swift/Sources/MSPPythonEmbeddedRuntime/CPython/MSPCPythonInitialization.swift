#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import MSPPythonRuntime

extension MSPCPythonEngine {
    static func configureUTF8Environment() {
        #if canImport(Darwin) || canImport(Glibc)
        for (key, value) in MSPPythonUTF8Environment.defaults {
            setenv(key, value, 1)
        }
        #endif
    }

    static func temporarilySetPythonHome(_ url: URL?) -> () -> Void {
        #if canImport(Darwin) || canImport(Glibc)
        guard let url else {
            return {}
        }
        let previous = getenv("PYTHONHOME").map { String(cString: $0) }
        setenv("PYTHONHOME", url.path, 1)
        return {
            if let previous {
                setenv("PYTHONHOME", previous, 1)
            } else {
                unsetenv("PYTHONHOME")
            }
        }
        #else
        return {}
        #endif
    }
}
