import Foundation

extension MSPChatValidationRun {
    mutating func validateManifest() {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            error("missing-manifest", "manifest.json is required.", path: relativePath(manifestURL))
            return
        }

        guard let object = parseJSONObject(at: manifestURL) else {
            return
        }

        manifest = object
        checkProductPrivateKeys(in: object, path: relativePath(manifestURL), line: nil)

        guard string(object["format"]) == "msp.chat" else {
            error("manifest-format", "manifest.format must be \"msp.chat\".", path: relativePath(manifestURL))
            return
        }

        if int(object["version"]) == nil {
            error("manifest-version", "manifest.version must be an integer.", path: relativePath(manifestURL))
        }

        profiles = stringArray(object["profiles"]) ?? []
        capabilities = stringArray(object["capabilities"]) ?? []

        if profiles.isEmpty {
            error("manifest-profiles", "manifest.profiles must include at least core-timeline.", path: relativePath(manifestURL))
        }

        if !profiles.contains("core-timeline") {
            error("manifest-core-profile", "manifest.profiles must include core-timeline.", path: relativePath(manifestURL))
        }

        for profile in profiles where !knownProfiles.contains(profile) {
            error("unknown-profile", "Unknown profile \"\(profile)\".", path: relativePath(manifestURL))
        }

        for capability in capabilities where !knownCapabilities.contains(capability) {
            error("unknown-capability", "Unknown capability \"\(capability)\".", path: relativePath(manifestURL))
        }

        if let timeline = dictionary(object["timeline"]) {
            if string(timeline["path"]) == nil {
                error("manifest-timeline-path", "manifest.timeline.path is required.", path: relativePath(manifestURL))
            }
            if let recordFormat = string(timeline["record_format"]), recordFormat != "ndjson" {
                error("manifest-timeline-format", "manifest.timeline.record_format must be ndjson.", path: relativePath(manifestURL))
            }
        } else {
            error("manifest-timeline", "manifest.timeline object is required.", path: relativePath(manifestURL))
        }

        if capabilities.contains("execute_msp_commands"), !profiles.contains("command-timeline") {
            warning(
                "execution-without-command-profile",
                "execute_msp_commands should be declared together with command-timeline data.",
                path: relativePath(manifestURL)
            )
        }

        if bool(object["lossy"]) == true {
            if object["loss_matrix"] == nil || string(object["loss_reason"]) == nil {
                error("lossy-marker-detail", "Lossy packages must include loss_reason and loss_matrix.", path: relativePath(manifestURL))
            }
        }
    }
}
