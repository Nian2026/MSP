mod turn_diff;
mod workspace_fs;

use std::io::Read;
use std::path::PathBuf;

use codex_utils_absolute_path::AbsolutePathBuf;
use serde::Deserialize;
use serde::Serialize;
use turn_diff::turn_diff_for_delta;
use workspace_fs::MSPApplyPatchWorkspaceFileSystem;
use workspace_fs::virtual_absolute_path;
use workspace_fs::virtual_path_string;

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MSPCodexApplyPatchBridgeRequest {
    /// Complete Codex apply_patch body. This remains raw/freeform model input.
    pub patch: String,
    /// Virtual cwd exposed to the model, for example "/" or "/src".
    #[serde(default = "default_virtual_cwd")]
    pub cwd: String,
    /// Physical workspace root controlled by the embedding SDK/application.
    pub workspace_root: PathBuf,
    /// Host path prefixes that must never appear in model-visible output.
    #[serde(default)]
    pub host_path_redactions: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MSPCodexApplyPatchBridgeResponse {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub output: String,
    pub changed_paths: Vec<String>,
    pub exact_delta: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_diff: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_added: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_removed: Option<usize>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changes: Vec<MSPApplyPatchChangeRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub file_snapshots: Vec<MSPApplyPatchFileSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MSPApplyPatchChangeRecord {
    pub path: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub move_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MSPApplyPatchFileSnapshot {
    pub path: String,
    pub existed_before: bool,
    pub exists_after: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub before_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub after_text: Option<String>,
}

#[repr(C)]
pub struct MSPCodexApplyPatchBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

fn default_virtual_cwd() -> String {
    "/".to_string()
}

pub async fn apply_patch_json_async(input_json: &str) -> Result<String, serde_json::Error> {
    let request: MSPCodexApplyPatchBridgeRequest = serde_json::from_str(input_json)?;
    let response = apply_patch_to_workspace(request)
        .await
        .unwrap_or_else(MSPCodexApplyPatchBridgeResponse::from_error);
    serde_json::to_string(&response)
}

pub fn apply_patch_json(input_json: &str) -> Result<String, serde_json::Error> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(serde_json::Error::io)?;
    runtime.block_on(apply_patch_json_async(input_json))
}

pub async fn apply_patch_to_workspace(
    request: MSPCodexApplyPatchBridgeRequest,
) -> Result<MSPCodexApplyPatchBridgeResponse, String> {
    if request.patch.trim().is_empty() {
        return Err("patch is required".to_string());
    }

    let workspace_root = std::fs::canonicalize(&request.workspace_root)
        .map_err(|_| "workspace root is unavailable".to_string())?;
    let fs = MSPApplyPatchWorkspaceFileSystem::new(workspace_root.clone());
    let cwd =
        virtual_absolute_path(&request.cwd).map_err(|err| format!("invalid virtual cwd: {err}"))?;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let apply_result = codex_apply_patch::apply_patch(
        &request.patch,
        &cwd,
        &mut stdout,
        &mut stderr,
        &fs,
        /*sandbox*/ None,
    )
    .await;
    let stdout = String::from_utf8_lossy(&stdout).into_owned();
    let stderr = String::from_utf8_lossy(&stderr).into_owned();

    let mut response = match apply_result {
        Ok(delta) => response_from_delta(0, stdout, stderr, delta, None),
        Err(failure) => {
            let error = failure.to_string();
            let delta = failure.delta().clone();
            response_from_delta(1, stdout, stderr, delta, Some(error))
        }
    };
    response.output = format!("{}{}", response.stdout, response.stderr);
    response.redact_host_paths(
        std::iter::once(workspace_root.to_string_lossy().into_owned())
            .chain(request.host_path_redactions.into_iter())
            .collect(),
    );
    Ok(response)
}

fn response_from_delta(
    exit_code: i32,
    stdout: String,
    stderr: String,
    delta: codex_apply_patch::AppliedPatchDelta,
    error: Option<String>,
) -> MSPCodexApplyPatchBridgeResponse {
    let turn_diff = turn_diff_for_delta(&delta);
    let (lines_added, lines_removed) = turn_diff
        .as_deref()
        .map(unified_diff_line_stats)
        .map_or((None, None), |(added, removed)| {
            (Some(added), Some(removed))
        });
    MSPCodexApplyPatchBridgeResponse {
        exit_code,
        stdout,
        stderr,
        output: String::new(),
        changed_paths: changed_virtual_paths(delta.changes()),
        exact_delta: delta.is_exact(),
        turn_diff,
        lines_added,
        lines_removed,
        changes: change_records(delta.changes()),
        file_snapshots: file_snapshots(delta.changes()),
        error,
    }
}

fn changed_virtual_paths(changes: &[codex_apply_patch::AppliedPatchChange]) -> Vec<String> {
    let mut paths = Vec::new();
    for change in changes {
        paths.push(virtual_path_string(&change.path));
        if let codex_apply_patch::AppliedPatchFileChange::Update {
            move_path: Some(move_path),
            ..
        } = &change.change
        {
            paths.push(virtual_path_string(move_path));
        }
    }
    paths.sort();
    paths.dedup();
    paths
}

fn change_records(
    changes: &[codex_apply_patch::AppliedPatchChange],
) -> Vec<MSPApplyPatchChangeRecord> {
    changes
        .iter()
        .map(|change| match &change.change {
            codex_apply_patch::AppliedPatchFileChange::Add { .. } => MSPApplyPatchChangeRecord {
                path: virtual_path_string(&change.path),
                kind: "add".to_string(),
                move_path: None,
            },
            codex_apply_patch::AppliedPatchFileChange::Delete { .. } => MSPApplyPatchChangeRecord {
                path: virtual_path_string(&change.path),
                kind: "delete".to_string(),
                move_path: None,
            },
            codex_apply_patch::AppliedPatchFileChange::Update { move_path, .. } => {
                MSPApplyPatchChangeRecord {
                    path: virtual_path_string(&change.path),
                    kind: "update".to_string(),
                    move_path: move_path.as_ref().map(|path| virtual_path_string(path)),
                }
            }
        })
        .collect()
}

fn file_snapshots(
    changes: &[codex_apply_patch::AppliedPatchChange],
) -> Vec<MSPApplyPatchFileSnapshot> {
    let mut snapshots = Vec::new();
    for change in changes {
        match &change.change {
            codex_apply_patch::AppliedPatchFileChange::Add {
                content,
                overwritten_content,
            } => snapshots.push(MSPApplyPatchFileSnapshot {
                path: virtual_path_string(&change.path),
                existed_before: overwritten_content.is_some(),
                exists_after: true,
                before_text: overwritten_content.clone(),
                after_text: Some(content.clone()),
            }),
            codex_apply_patch::AppliedPatchFileChange::Delete { content } => {
                snapshots.push(MSPApplyPatchFileSnapshot {
                    path: virtual_path_string(&change.path),
                    existed_before: true,
                    exists_after: false,
                    before_text: Some(content.clone()),
                    after_text: None,
                });
            }
            codex_apply_patch::AppliedPatchFileChange::Update {
                move_path,
                old_content,
                overwritten_move_content,
                new_content,
            } => {
                if let Some(move_path) = move_path {
                    snapshots.push(MSPApplyPatchFileSnapshot {
                        path: virtual_path_string(&change.path),
                        existed_before: true,
                        exists_after: false,
                        before_text: Some(old_content.clone()),
                        after_text: None,
                    });
                    snapshots.push(MSPApplyPatchFileSnapshot {
                        path: virtual_path_string(move_path),
                        existed_before: overwritten_move_content.is_some(),
                        exists_after: true,
                        before_text: overwritten_move_content.clone(),
                        after_text: Some(new_content.clone()),
                    });
                } else {
                    snapshots.push(MSPApplyPatchFileSnapshot {
                        path: virtual_path_string(&change.path),
                        existed_before: true,
                        exists_after: true,
                        before_text: Some(old_content.clone()),
                        after_text: Some(new_content.clone()),
                    });
                }
            }
        }
    }
    snapshots
}

fn unified_diff_line_stats(diff: &str) -> (usize, usize) {
    let mut added = 0;
    let mut removed = 0;
    for line in diff.lines() {
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        if line.starts_with('+') {
            added += 1;
        } else if line.starts_with('-') {
            removed += 1;
        }
    }
    (added, removed)
}

impl MSPCodexApplyPatchBridgeResponse {
    fn from_error(message: String) -> Self {
        Self {
            exit_code: 1,
            stdout: String::new(),
            stderr: message.clone(),
            output: message.clone(),
            changed_paths: Vec::new(),
            exact_delta: true,
            turn_diff: None,
            lines_added: None,
            lines_removed: None,
            changes: Vec::new(),
            file_snapshots: Vec::new(),
            error: Some(message),
        }
    }

    fn redact_host_paths(&mut self, mut roots: Vec<String>) {
        roots.sort_by_key(|root| std::cmp::Reverse(root.len()));
        roots.dedup();
        for root in roots.into_iter().filter(|root| !root.is_empty()) {
            self.stdout = self.stdout.replace(&root, "[MSP workspace]");
            self.stderr = self.stderr.replace(&root, "[MSP workspace]");
            self.output = self.output.replace(&root, "[MSP workspace]");
            if let Some(error) = &mut self.error {
                *error = error.replace(&root, "[MSP workspace]");
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn msp_codex_apply_patch_json(
    input_ptr: *const u8,
    input_len: usize,
    output_ptr: *mut *mut u8,
    output_len: *mut usize,
) -> i32 {
    let buffer = if input_ptr.is_null() {
        response_buffer(MSPCodexApplyPatchBridgeResponse::from_error(
            "request pointer is null".to_string(),
        ))
    } else {
        let input = unsafe { std::slice::from_raw_parts(input_ptr, input_len) };
        let input = match std::str::from_utf8(input) {
            Ok(input) => input,
            Err(error) => {
                return write_output_buffer(
                    response_buffer(MSPCodexApplyPatchBridgeResponse::from_error(format!(
                        "request is not valid UTF-8: {error}"
                    ))),
                    output_ptr,
                    output_len,
                );
            }
        };
        match apply_patch_json(input) {
            Ok(output) => owned_buffer(output.into_bytes()),
            Err(error) => response_buffer(MSPCodexApplyPatchBridgeResponse::from_error(format!(
                "request JSON is invalid: {error}"
            ))),
        }
    };
    write_output_buffer(buffer, output_ptr, output_len)
}

#[unsafe(no_mangle)]
pub extern "C" fn msp_codex_apply_patch_stdin_json(
    output_ptr: *mut *mut u8,
    output_len: *mut usize,
) -> i32 {
    let mut input = String::new();
    let buffer = match std::io::stdin().read_to_string(&mut input) {
        Ok(_) => match apply_patch_json(&input) {
            Ok(output) => owned_buffer(output.into_bytes()),
            Err(error) => response_buffer(MSPCodexApplyPatchBridgeResponse::from_error(format!(
                "request JSON is invalid: {error}"
            ))),
        },
        Err(error) => response_buffer(MSPCodexApplyPatchBridgeResponse::from_error(format!(
            "failed to read stdin: {error}"
        ))),
    };
    write_output_buffer(buffer, output_ptr, output_len)
}

#[unsafe(no_mangle)]
pub extern "C" fn msp_codex_apply_patch_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

fn response_buffer(response: MSPCodexApplyPatchBridgeResponse) -> MSPCodexApplyPatchBuffer {
    let output = serde_json::to_vec(&response).unwrap_or_else(|_| {
        br#"{"exitCode":1,"stdout":"","stderr":"failed to encode response","output":"failed to encode response","changedPaths":[],"exactDelta":true,"error":"failed to encode response"}"#.to_vec()
    });
    owned_buffer(output)
}

fn owned_buffer(mut bytes: Vec<u8>) -> MSPCodexApplyPatchBuffer {
    bytes.shrink_to_fit();
    let buffer = MSPCodexApplyPatchBuffer {
        ptr: bytes.as_mut_ptr(),
        len: bytes.len(),
    };
    std::mem::forget(bytes);
    buffer
}

fn write_output_buffer(
    buffer: MSPCodexApplyPatchBuffer,
    output_ptr: *mut *mut u8,
    output_len: *mut usize,
) -> i32 {
    if output_ptr.is_null() || output_len.is_null() {
        msp_codex_apply_patch_free(buffer.ptr, buffer.len);
        return -1;
    }
    unsafe {
        *output_ptr = buffer.ptr;
        *output_len = buffer.len;
    }
    0
}

#[allow(dead_code)]
fn _assert_absolute_path_is_send_sync(_: AbsolutePathBuf) {}
