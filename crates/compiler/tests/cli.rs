use std::{fs, process::Command};
#[test]
fn cli_retains_history_and_does_not_overwrite_on_break() {
    let root = std::env::temp_dir().join(format!("otter-compiler-cli-{}", std::process::id()));
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
        Command::new(env!("CARGO_BIN_EXE_otter-sync"))
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
#[test]
fn cli_writes_backend_ts_with_the_requested_runtime_import() {
    let root = std::env::temp_dir().join(format!("otter-compiler-backend-{}", std::process::id()));
    let input = root.join("input");
    let out = root.join("out");
    fs::create_dir_all(&input).unwrap();
    fs::write(
        input.join("test.model"),
        "model A { id UUID title String @@id(id) } mutation Save { a A.create }",
    )
    .unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_otter-sync"))
        .arg("compile")
        .arg(&input)
        .arg(&out)
        .arg("--backend-runtime")
        .arg("../../packages/server/index.mts")
        .arg("--client-runtime")
        .arg("../../packages/client-js/index.mts")
        .status()
        .unwrap();
    assert!(status.success());
    let backend = fs::read_to_string(out.join("backend.ts")).unwrap();
    assert!(backend.contains("from \"../../packages/server/index.mts\""));
    assert!(backend.contains(" save(call: HandlerCall<Tx, SaveInput>)"));
    assert!(backend.contains(" a(call: LoaderCall<Tx, AIdentity>)"));
    let client = fs::read_to_string(out.join("client.ts")).unwrap();
    assert!(client.contains("from \"../../packages/client-js/index.mts\""));
    assert!(client.contains(" static async open(options: { path: string;"));
    assert!(!client.contains("owner"));
    fs::remove_dir_all(root).unwrap();
}
