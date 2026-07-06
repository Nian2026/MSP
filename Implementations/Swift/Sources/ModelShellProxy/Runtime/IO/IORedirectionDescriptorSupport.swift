import Foundation

extension IORuntimeState {
    static func descriptorNumber(from target: String) -> Int? {
        let raw = target.hasPrefix("&") ? String(target.dropFirst()) : target
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(raw)
    }

    func standardInputForFileDescriptor(
        _ fd: Int,
        fallback: Data,
        fallbackClosed: Bool = false,
        inputFileDescriptors: [Int: Int],
        closedInputFileDescriptors: Set<Int>,
        environment: IORedirectionEnvironment
    ) throws -> IORedirectionInputResolution {
        if let descriptionID = inputFileDescriptors[fd] {
            return IORedirectionInputResolution(
                data: try remainingInputData(for: descriptionID, environment: environment),
                descriptionID: descriptionID,
                isClosed: false
            )
        }
        if closedInputFileDescriptors.contains(fd) {
            if fd == 0 {
                return IORedirectionInputResolution(data: Data(), descriptionID: nil, isClosed: true)
            }
            throw environment.redirectionFailure("\(fd): Bad file descriptor")
        }
        if fd == 0 {
            return IORedirectionInputResolution(data: fallback, descriptionID: nil, isClosed: fallbackClosed)
        }
        throw environment.redirectionFailure("\(fd): Bad file descriptor")
    }
}
