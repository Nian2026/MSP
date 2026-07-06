struct ProcessSubstitutionLifetime {
    var createdTemporaryDirectories: Set<String> = []

    mutating func recordCreatedTemporaryDirectory(_ path: String) {
        createdTemporaryDirectories.insert(path)
    }

    mutating func forgetCreatedTemporaryDirectory(_ path: String) {
        createdTemporaryDirectories.remove(path)
    }
}
