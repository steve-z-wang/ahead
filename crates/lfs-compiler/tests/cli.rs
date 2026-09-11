use std::{fs, process::Command};
#[test]
fn cli_retains_history_and_does_not_overwrite_on_break() {
    let root = std::env::temp_dir().join(format!("lfs-compiler-cli-{}", std::process::id()));
    let input = root.join("input");
    let out = root.join("out");
    fs::create_dir_all(&input).unwrap();
    let model = input.join("test.model");
    fs::write(
        &model,
        "model A { id UUID title String @@id(id) } mutation Save { a A.create }",
    )
    .unwrap();
    let compile = || {
        Command::new(env!("CARGO_BIN_EXE_local-first-state"))
            .arg("compile")
            .arg(&input)
            .arg(&out)
            .output()
            .unwrap()
    };
    assert!(compile().status.success());
    let previous = fs::read(out.join("schema.json")).unwrap();
    fs::write(
        &model,
        "model A { id UUID @@id(id) } mutation Save { a A.create }",
    )
    .unwrap();
    let rejected = compile();
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("schema fence"));
    assert_eq!(fs::read(out.join("schema.json")).unwrap(), previous);
    fs::write(&model,"model A { id UUID title String count Int @@id(id) } mutation Save { a A.create @@version(2) }").unwrap();
    assert!(compile().status.success());
    let backend: serde_json::Value =
        serde_json::from_slice(&fs::read(out.join("backend.json")).unwrap()).unwrap();
    assert_eq!(backend["mutations"].as_array().unwrap().len(), 2);
    assert_eq!(
        backend["schema"]["clientPolicies"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    fs::remove_dir_all(root).unwrap();
}
