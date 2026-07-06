import Foundation

extension IORuntimeState {
    func remainingInputData(
        for descriptionID: Int,
        environment: IORedirectionEnvironment
    ) throws -> Data {
        do {
            return try remainingInputData(for: descriptionID, readVirtualPath: environment.readVirtualPath)
        } catch IORuntimeFailure.badFileDescriptor(let message) {
            throw environment.redirectionFailure(message)
        }
    }

    mutating func writeOpenFileDescriptionOutput(
        _ incoming: Data,
        to descriptionID: Int,
        environment: IORedirectionEnvironment
    ) throws {
        guard var description = inputOpenFileDescriptions[descriptionID],
              let virtualPath = description.virtualPath else {
            throw environment.redirectionFailure("\(descriptionID): Bad file descriptor")
        }
        do {
            var data = try environment.readVirtualPath(virtualPath)
            let offset = max(0, description.offset)
            if offset > data.count {
                data.append(Data(count: offset - data.count))
            }
            let end = min(offset + incoming.count, data.count)
            data.replaceSubrange(offset..<end, with: incoming)
            try environment.writeVirtualPath(virtualPath, data)
            description.data = data
            description.offset = offset + incoming.count
            inputOpenFileDescriptions[descriptionID] = description
        } catch {
            throw environment.redirectionFailure("\(virtualPath): \(environment.diagnosticReason(error))")
        }
    }
}
