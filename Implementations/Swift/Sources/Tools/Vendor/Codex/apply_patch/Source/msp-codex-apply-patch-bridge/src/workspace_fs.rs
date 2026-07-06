use std::io;
use std::path::Component;
use std::path::Path;
use std::path::PathBuf;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use async_trait::async_trait;
use codex_exec_server::CopyOptions;
use codex_exec_server::CreateDirectoryOptions;
use codex_exec_server::ExecutorFileSystem;
use codex_exec_server::FileMetadata;
use codex_exec_server::FileSystemResult;
use codex_exec_server::FileSystemSandboxContext;
use codex_exec_server::ReadDirectoryEntry;
use codex_exec_server::RemoveOptions;
use codex_utils_absolute_path::AbsolutePathBuf;

pub(crate) struct MSPApplyPatchWorkspaceFileSystem {
    root: PathBuf,
}

impl MSPApplyPatchWorkspaceFileSystem {
    pub(crate) fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn physical_path(
        &self,
        virtual_path: &AbsolutePathBuf,
        missing_policy: MissingPathPolicy,
    ) -> io::Result<PathBuf> {
        self.safe_physical_path_from_virtual_path(virtual_path.as_path(), missing_policy)
    }

    fn safe_physical_path_from_virtual_path(
        &self,
        virtual_path: &Path,
        missing_policy: MissingPathPolicy,
    ) -> io::Result<PathBuf> {
        let mut components = Vec::new();
        for component in virtual_path.components() {
            match component {
                Component::RootDir | Component::CurDir => {}
                Component::Normal(segment) => components.push(segment.to_owned()),
                Component::ParentDir | Component::Prefix(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "invalid workspace path",
                    ));
                }
            }
        }
        self.safe_physical_path_from_components(components.iter(), missing_policy)
    }

    fn safe_existing_physical_path(&self, physical_path: &Path) -> io::Result<PathBuf> {
        let relative_path = physical_path
            .strip_prefix(&self.root)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path escapes workspace"))?;
        let mut components = Vec::new();
        for component in relative_path.components() {
            match component {
                Component::CurDir => {}
                Component::Normal(segment) => components.push(segment.to_owned()),
                Component::RootDir | Component::ParentDir | Component::Prefix(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "invalid workspace path",
                    ));
                }
            }
        }
        self.safe_physical_path_from_components(components.iter(), MissingPathPolicy::MustExist)
    }

    fn safe_physical_path_from_components<'a>(
        &self,
        components: impl IntoIterator<Item = &'a std::ffi::OsString>,
        missing_policy: MissingPathPolicy,
    ) -> io::Result<PathBuf> {
        let mut physical = self.root.clone();
        let mut missing_seen = false;
        for segment in components {
            physical.push(segment);
            if missing_seen {
                continue;
            }
            match std::fs::symlink_metadata(&physical) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "workspace symlinks are not supported by MSP apply_patch",
                    ));
                }
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => match missing_policy {
                    MissingPathPolicy::AllowMissing => missing_seen = true,
                    MissingPathPolicy::MustExist => return Err(error),
                },
                Err(error) => return Err(error),
            }
        }
        Ok(physical)
    }

    fn copy_directory_recursively(&self, source: &Path, destination: &Path) -> io::Result<()> {
        let destination = self.safe_physical_path_from_virtual_path(
            destination.strip_prefix(&self.root).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "path escapes workspace")
            })?,
            MissingPathPolicy::AllowMissing,
        )?;
        std::fs::create_dir_all(&destination)?;
        for entry in std::fs::read_dir(self.safe_existing_physical_path(source)?)? {
            let entry = entry?;
            let source_path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "workspace symlinks are not supported by MSP apply_patch",
                ));
            }
            let destination_path = destination.join(entry.file_name());
            let safe_destination_path = self.safe_physical_path_from_virtual_path(
                destination_path.strip_prefix(&self.root).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "path escapes workspace")
                })?,
                MissingPathPolicy::AllowMissing,
            )?;
            if file_type.is_dir() {
                self.copy_directory_recursively(&source_path, &safe_destination_path)?;
            } else {
                std::fs::copy(source_path, safe_destination_path)?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
enum MissingPathPolicy {
    AllowMissing,
    MustExist,
}

#[async_trait]
impl ExecutorFileSystem for MSPApplyPatchWorkspaceFileSystem {
    async fn canonicalize(
        &self,
        path: &AbsolutePathBuf,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<AbsolutePathBuf> {
        virtual_absolute_path(path.as_path())
    }

    async fn join(
        &self,
        base_path: &AbsolutePathBuf,
        path: &Path,
    ) -> FileSystemResult<AbsolutePathBuf> {
        Ok(base_path.join(path))
    }

    async fn parent(&self, path: &AbsolutePathBuf) -> FileSystemResult<Option<AbsolutePathBuf>> {
        Ok(path.parent())
    }

    async fn read_file(
        &self,
        path: &AbsolutePathBuf,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<Vec<u8>> {
        let physical = self.physical_path(path, MissingPathPolicy::MustExist)?;
        std::fs::read(physical)
    }

    async fn write_file(
        &self,
        path: &AbsolutePathBuf,
        contents: Vec<u8>,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<()> {
        let physical = self.physical_path(path, MissingPathPolicy::AllowMissing)?;
        if physical.try_exists()? && physical.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::IsADirectory,
                "path is a directory",
            ));
        }
        std::fs::write(physical, contents)
    }

    async fn create_directory(
        &self,
        path: &AbsolutePathBuf,
        options: CreateDirectoryOptions,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<()> {
        let physical = self.physical_path(path, MissingPathPolicy::AllowMissing)?;
        if options.recursive {
            std::fs::create_dir_all(physical)
        } else {
            std::fs::create_dir(physical)
        }
    }

    async fn get_metadata(
        &self,
        path: &AbsolutePathBuf,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<FileMetadata> {
        let physical = self.physical_path(path, MissingPathPolicy::MustExist)?;
        let symlink_metadata = std::fs::symlink_metadata(&physical)?;
        Ok(FileMetadata {
            is_directory: symlink_metadata.is_dir(),
            is_file: symlink_metadata.is_file(),
            is_symlink: symlink_metadata.file_type().is_symlink(),
            created_at_ms: symlink_metadata
                .created()
                .ok()
                .map_or(0, system_time_to_unix_ms),
            modified_at_ms: symlink_metadata
                .modified()
                .ok()
                .map_or(0, system_time_to_unix_ms),
        })
    }

    async fn read_directory(
        &self,
        path: &AbsolutePathBuf,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<Vec<ReadDirectoryEntry>> {
        let physical = self.physical_path(path, MissingPathPolicy::MustExist)?;
        let mut entries = Vec::new();
        for entry in std::fs::read_dir(physical)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            entries.push(ReadDirectoryEntry {
                file_name: entry.file_name().to_string_lossy().into_owned(),
                is_directory: file_type.is_dir(),
                is_file: file_type.is_file(),
            });
        }
        Ok(entries)
    }

    async fn remove(
        &self,
        path: &AbsolutePathBuf,
        options: RemoveOptions,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<()> {
        let physical = self.physical_path(path, MissingPathPolicy::AllowMissing)?;
        let metadata = match std::fs::symlink_metadata(&physical) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound && options.force => return Ok(()),
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_dir() {
            if options.recursive {
                std::fs::remove_dir_all(physical)
            } else {
                std::fs::remove_dir(physical)
            }
        } else {
            std::fs::remove_file(physical)
        }
    }

    async fn copy(
        &self,
        source_path: &AbsolutePathBuf,
        destination_path: &AbsolutePathBuf,
        options: CopyOptions,
        _sandbox: Option<&FileSystemSandboxContext>,
    ) -> FileSystemResult<()> {
        let source = self.physical_path(source_path, MissingPathPolicy::MustExist)?;
        let destination = self.physical_path(destination_path, MissingPathPolicy::AllowMissing)?;
        let metadata = std::fs::symlink_metadata(&source)?;
        if metadata.is_dir() {
            if !options.recursive {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "fs/copy requires recursive: true when sourcePath is a directory",
                ));
            }
            self.copy_directory_recursively(&source, &destination)
        } else {
            if let Some(parent) = destination.parent() {
                let safe_parent = self.safe_physical_path_from_virtual_path(
                    parent.strip_prefix(&self.root).map_err(|_| {
                        io::Error::new(io::ErrorKind::InvalidInput, "path escapes workspace")
                    })?,
                    MissingPathPolicy::AllowMissing,
                )?;
                std::fs::create_dir_all(safe_parent)?;
            }
            std::fs::copy(source, destination).map(|_| ())
        }
    }
}

pub(crate) fn virtual_absolute_path(path: impl AsRef<Path>) -> io::Result<AbsolutePathBuf> {
    let path = path.as_ref();
    let path = if path.as_os_str().is_empty() {
        Path::new("/")
    } else {
        path
    };
    if path.is_absolute() {
        AbsolutePathBuf::from_absolute_path_checked(path)
    } else {
        AbsolutePathBuf::from_absolute_path_checked(Path::new("/").join(path))
    }
}

pub(crate) fn virtual_path_string(path: &Path) -> String {
    AbsolutePathBuf::from_absolute_path_checked(path)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.display().to_string())
}

fn system_time_to_unix_ms(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().try_into().unwrap_or(i64::MAX))
        .unwrap_or(0)
}
