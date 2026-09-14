use serde_json::Value;
use std::{
    env, fs,
    path::{Path, PathBuf},
};
fn read_json(path: &Path) -> Result<Value, String> {
    serde_json::from_str(&fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?)
        .map_err(|e| format!("{}: {e}", path.display()))
}
fn run() -> Result<(), String> {
    let args: Vec<_> = env::args().collect();
    if args.len() < 4 || args[1] != "compile" {
        return Err("usage: ahead compile INPUT_DIR OUTPUT_DIR [--mutation-history FILE] [--initialize-mutation-history] [--schema-fence FILE] [--backend-runtime SPEC] [--client-runtime SPEC]".into());
    }
    let out = Path::new(&args[3]);
    let mut history_path = out.join("mutation-history.json");
    let mut fence_path = out.join("schema.json");
    let mut backend_runtime = String::from("@ahead/server");
    let mut client_runtime = String::from("@ahead/client");
    let mut initialize = false;
    let mut explicit_history = false;
    let mut index = 4;
    while index < args.len() {
        match args[index].as_str() {
            "--initialize-mutation-history" => initialize = true,
            "--mutation-history" | "--schema-fence" | "--backend-runtime" | "--client-runtime" => {
                let value = args.get(index + 1).ok_or("missing option value")?;
                match args[index].as_str() {
                    "--mutation-history" => {
                        history_path = PathBuf::from(value);
                        explicit_history = true;
                    }
                    "--schema-fence" => fence_path = PathBuf::from(value),
                    "--backend-runtime" => backend_runtime = value.clone(),
                    _ => client_runtime = value.clone(),
                }
                index += 1;
            }
            other => return Err(format!("unsupported option {other}")),
        }
        index += 1;
    }
    if initialize && history_path.exists() {
        return Err("mutation history already exists; initialization refused".into());
    }
    if explicit_history && !history_path.exists() && !initialize {
        return Err("missing mutation history; restore it or initialize explicitly".into());
    }
    let mut paths = fs::read_dir(&args[2])
        .map_err(|e| e.to_string())?
        .map(|e| e.map(|e| e.path()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    paths.retain(|p| p.extension().is_some_and(|e| e == "model"));
    paths.sort();
    if paths.is_empty() {
        return Err("input directory has no .model files".into());
    }
    let mut source = String::new();
    let mut origins = vec![];
    for path in paths {
        let contents = fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let start = source.chars().filter(|c| *c == '\n').count() + 1;
        source.push_str(&contents);
        source.push('\n');
        origins.push((start, path));
    }
    let mut config = ahead_compiler::compile(&source).map_err(|e| {
        let line = e
            .split(':')
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(1);
        let (start, path) = origins
            .iter()
            .rev()
            .find(|(start, _)| *start <= line)
            .unwrap();
        format!(
            "{}:{}:{}",
            path.display(),
            line - start + 1,
            e.split_once(':').map(|(_, rest)| rest).unwrap_or(&e)
        )
    })?;
    if initialize
        && config["mutations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["version"] != 1)
    {
        return Err("initial mutation history must begin at version 1".into());
    }
    if fence_path.exists() {
        ahead_compiler::check_fence(&read_json(&fence_path)?, &config["schema"])?;
    }
    let previous = if history_path.exists() {
        Some(read_json(&history_path)?)
    } else {
        None
    };
    let history = ahead_compiler::reconcile_history(&config, previous.as_ref())?;
    let historical: Vec<_> = history["mutations"]
        .as_object()
        .unwrap()
        .values()
        .flat_map(|v| v.as_object().unwrap().values().cloned())
        .collect();
    config["backendMutations"] = serde_json::json!(historical);
    config["schema"]["clientPolicies"] = serde_json::json!(historical);
    let mut backend = config.clone();
    backend["mutations"] = serde_json::json!(historical);
    backend.as_object_mut().unwrap().remove("backendMutations");
    let files = [
        (
            out.join("schema.json"),
            serde_json::to_string_pretty(&config["schema"]).unwrap(),
        ),
        (
            out.join("backend.json"),
            serde_json::to_string_pretty(&backend).unwrap(),
        ),
        (
            out.join("generated.ts"),
            ahead_compiler::typescript(&config),
        ),
        (
            out.join("backend.ts"),
            ahead_compiler::backend_typescript(&config, &backend_runtime),
        ),
        (
            out.join("client.ts"),
            ahead_compiler::client_typescript(&client_runtime),
        ),
        (out.join("generated.dart"), ahead_compiler::dart(&config)),
        (
            history_path,
            serde_json::to_string_pretty(&history).unwrap(),
        ),
    ];
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    for (path, contents) in files {
        let temp = path.with_extension(format!("{}.tmp", std::process::id()));
        fs::write(&temp, contents).map_err(|e| format!("{}: {e}", temp.display()))?;
        fs::rename(temp, &path).map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
