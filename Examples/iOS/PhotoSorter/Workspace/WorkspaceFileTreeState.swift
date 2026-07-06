enum WorkspaceFileTreeState: Equatable {
    case loading
    case loaded([WorkspaceFileNode])
    case failed(String)
}
