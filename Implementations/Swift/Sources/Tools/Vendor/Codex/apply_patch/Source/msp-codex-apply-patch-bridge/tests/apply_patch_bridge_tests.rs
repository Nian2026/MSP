use msp_codex_apply_patch_bridge::MSPCodexApplyPatchBridgeRequest;
use msp_codex_apply_patch_bridge::MSPCodexApplyPatchBridgeResponse;
use msp_codex_apply_patch_bridge::apply_patch_json_async;
use msp_codex_apply_patch_bridge::apply_patch_to_workspace;
use serde_json::json;
use std::path::Path;

fn request_json(root: &Path, patch: &str) -> String {
    json!({
        "patch": patch,
        "cwd": "/",
        "workspaceRoot": root,
        "hostPathRedactions": [root.to_string_lossy()]
    })
    .to_string()
}

#[tokio::test]
async fn applies_add_update_delete_move_with_codex_engine() {
    let workspace = tempfile::tempdir().unwrap();
    std::fs::write(workspace.path().join("existing.txt"), "old\nsecond\n").unwrap();
    std::fs::write(workspace.path().join("delete.txt"), "gone\n").unwrap();
    let patch = r#"*** Begin Patch
*** Add File: /added.txt
+hello
*** Update File: /existing.txt
*** Move to: /moved.txt
@@
-old
+new
*** Delete File: /delete.txt
*** End Patch"#;

    let output = apply_patch_json_async(&request_json(workspace.path(), patch))
        .await
        .unwrap();
    let response: MSPCodexApplyPatchBridgeResponse = serde_json::from_str(&output).unwrap();

    assert_eq!(response.exit_code, 0);
    assert_eq!(
        std::fs::read_to_string(workspace.path().join("added.txt")).unwrap(),
        "hello\n"
    );
    assert_eq!(
        std::fs::read_to_string(workspace.path().join("moved.txt")).unwrap(),
        "new\nsecond\n"
    );
    assert!(!workspace.path().join("existing.txt").exists());
    assert!(!workspace.path().join("delete.txt").exists());
    assert!(response.changed_paths.contains(&"/added.txt".to_string()));
    assert!(
        response
            .changed_paths
            .contains(&"/existing.txt".to_string())
    );
    assert!(response.changed_paths.contains(&"/moved.txt".to_string()));
    assert!(response.changed_paths.contains(&"/delete.txt".to_string()));
    let turn_diff = response.turn_diff.as_ref().unwrap();
    assert!(turn_diff.contains("diff --git a/added.txt b/added.txt"));
    assert!(turn_diff.contains("diff --git a/existing.txt b/moved.txt"));
    assert!(turn_diff.contains("diff --git a/delete.txt b/delete.txt"));
    assert_eq!(response.lines_added, Some(2));
    assert_eq!(response.lines_removed, Some(2));
    assert_eq!(response.changes.len(), 3);
    assert!(response.changes.iter().any(|change| {
        change.path == "/existing.txt"
            && change.kind == "update"
            && change.move_path.as_deref() == Some("/moved.txt")
    }));
    assert!(response.file_snapshots.iter().any(|snapshot| {
        snapshot.path == "/added.txt"
            && !snapshot.existed_before
            && snapshot.exists_after
            && snapshot.before_text.is_none()
            && snapshot.after_text.as_deref() == Some("hello\n")
    }));
    assert!(response.file_snapshots.iter().any(|snapshot| {
        snapshot.path == "/existing.txt"
            && snapshot.existed_before
            && !snapshot.exists_after
            && snapshot.before_text.as_deref() == Some("old\nsecond\n")
            && snapshot.after_text.is_none()
    }));
    assert!(response.file_snapshots.iter().any(|snapshot| {
        snapshot.path == "/moved.txt"
            && !snapshot.existed_before
            && snapshot.exists_after
            && snapshot.before_text.is_none()
            && snapshot.after_text.as_deref() == Some("new\nsecond\n")
    }));
    assert!(response.file_snapshots.iter().any(|snapshot| {
        snapshot.path == "/delete.txt"
            && snapshot.existed_before
            && !snapshot.exists_after
            && snapshot.before_text.as_deref() == Some("gone\n")
            && snapshot.after_text.is_none()
    }));
    assert!(
        !response
            .output
            .contains(&workspace.path().to_string_lossy().to_string())
    );
}

#[tokio::test]
async fn preserves_codex_context_mismatch_failure() {
    let workspace = tempfile::tempdir().unwrap();
    std::fs::write(workspace.path().join("existing.txt"), "old\n").unwrap();
    let patch = r#"*** Begin Patch
*** Update File: /existing.txt
@@
-missing
+new
*** End Patch"#;

    let response = apply_patch_to_workspace(MSPCodexApplyPatchBridgeRequest {
        patch: patch.to_string(),
        cwd: "/".to_string(),
        workspace_root: workspace.path().to_path_buf(),
        host_path_redactions: vec![workspace.path().to_string_lossy().into_owned()],
    })
    .await
    .unwrap();

    assert_eq!(response.exit_code, 1);
    assert!(response.output.contains("Failed to find expected lines"));
    assert_eq!(
        std::fs::read_to_string(workspace.path().join("existing.txt")).unwrap(),
        "old\n"
    );
}

#[tokio::test]
async fn rejects_empty_and_invalid_patch_without_touching_workspace() {
    let workspace = tempfile::tempdir().unwrap();
    std::fs::write(workspace.path().join("existing.txt"), "old\n").unwrap();

    let empty_output = apply_patch_json_async(&request_json(workspace.path(), "   "))
        .await
        .unwrap();
    let empty_response: MSPCodexApplyPatchBridgeResponse =
        serde_json::from_str(&empty_output).unwrap();
    assert_eq!(empty_response.exit_code, 1);
    assert!(empty_response.output.contains("patch is required"));

    let bad_output = apply_patch_json_async(&request_json(workspace.path(), "*** Begin Patch"))
        .await
        .unwrap();
    let bad_response: MSPCodexApplyPatchBridgeResponse = serde_json::from_str(&bad_output).unwrap();
    assert_eq!(bad_response.exit_code, 1);
    assert!(bad_response.output.contains("Invalid patch"));
    assert_eq!(
        std::fs::read_to_string(workspace.path().join("existing.txt")).unwrap(),
        "old\n"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn rejects_symlink_parent_without_leaking_host_path() {
    let workspace = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), workspace.path().join("linkdir")).unwrap();
    let patch = r#"*** Begin Patch
*** Add File: /linkdir/created.txt
+created outside
*** End Patch"#;

    let output = apply_patch_json_async(&request_json(workspace.path(), patch))
        .await
        .unwrap();
    let response: MSPCodexApplyPatchBridgeResponse = serde_json::from_str(&output).unwrap();

    assert_eq!(response.exit_code, 1);
    assert!(!outside.path().join("created.txt").exists());
    let outside_path = outside.path().to_string_lossy().to_string();
    assert!(!response.stdout.contains(&outside_path));
    assert!(!response.stderr.contains(&outside_path));
    assert!(!response.output.contains(&outside_path));
    assert!(!response.error.unwrap_or_default().contains(&outside_path));
}
