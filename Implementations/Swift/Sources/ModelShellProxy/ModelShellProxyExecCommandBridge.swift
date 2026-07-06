import MSPAgentBridge
import MSPCore

public extension ModelShellProxy {
    func execCommandBridge() -> MSPExecCommandBridge {
        MSPExecCommandBridge(sessionCoordinator: MSPExecCommandSessionCoordinator(
            transport: ModelShellProxyExecSessionTransport(shell: self)
        ))
    }

    private static func execCommandOutputStream(
        stream: MSPExecCommandOutputStreamName,
        outputHandler: MSPExecCommandOutputHandler?
    ) -> (any MSPCommandOutputStream)? {
        guard let outputHandler else {
            return nil
        }
        return MSPClosureOutputStream { data in
            guard !data.isEmpty else {
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else {
                return
            }
            await outputHandler(MSPExecCommandOutputEvent(stream: stream, text: text))
        }
    }
}
