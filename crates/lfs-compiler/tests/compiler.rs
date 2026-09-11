use lfs_compiler::compile;
#[test]
fn schema_and_mutations() {
    let v=compile("enum Status { active archived } model Entry { owner UUID id UUID title String note String? labels String[] at DateTime status Status @@id(owner,id) @@unique(title) } mutation Edit { entry Entry.update<title,note> @@version(2) }").unwrap();
    assert_eq!(
        v["schema"]["models"][0]["identity"],
        serde_json::json!(["owner", "id"])
    );
    assert_eq!(v["mutations"][0]["version"], 2);
    assert_eq!(
        v["mutations"][0]["slots"][0]["allowedPatchFields"],
        serde_json::json!(["title", "note"])
    );
}
#[test]
fn rejects_unknown_with_location() {
    let e = compile("model A { id UUID @@id(id) }\nunknown Stuff {}").unwrap_err();
    assert!(e.contains("2:"), "{e}");
}
#[test]
fn rejects_invalid_identity() {
    assert!(compile("model A { id UUID? @@id(id) }").is_err());
}
#[test]
fn emitters_include_typed_conversion() {
    let v = compile(include_str!("../../../fixtures/compiler/example.model")).unwrap();
    let ts = lfs_compiler::typescript(&v);
    assert!(ts.contains("export interface EntryIdentity"));
    assert!(ts.contains("new Date("));
    assert!(ts.contains("EditEntry"));
    let dart = lfs_compiler::dart(&v);
    assert!(dart.contains("class EntryPatch"));
    assert!(dart.contains("DateTime.parse("));
}
#[test]
fn relationships_bindings_and_dependency_metadata() {
    let v=compile(r#"prerequisite Uploaded(key String)
 model Parent { id UUID children Child[] @@id(id) }
 model Child { id UUID parentId UUID label String @requires(Uploaded(key: self)) parent Parent @reference(via: [parentId], onTargetDelete: delete) @@id(id) }
 mutation Add { parent Parent.create children Child.create(parent: parent)[] @@sequence(after: [Rename(parent: parent)]) }
 mutation Rename { parent Parent.update<> }
 "#).unwrap();
    assert_eq!(
        v["schema"]["models"][1]["relations"][0]["fields"],
        serde_json::json!(["parentId"])
    );
    assert_eq!(
        v["mutations"][0]["slots"][1]["bindings"][0]["slot"],
        "parent"
    );
    assert_eq!(v["prerequisites"][0]["name"], "Uploaded");
}
#[test]
fn rejects_dependency_typos() {
    assert!(compile("prerequisite Exists(key String) model A { id UUID label String @requires(Missing(key: self)) @@id(id) }").is_err());
    assert!(
        compile(
            "model A { id UUID @@id(id) } mutation Add { a A.create @@version(2) @@version(3) }"
        )
        .is_err()
    );
}
#[test]
fn singular_inverse_requires_a_unique_foreign_key() {
    assert!(compile("model Parent { id String child Child? @@id(id) } model Child { id String parentId String parent Parent @reference(via:[parentId]) @@id(id) }").is_err());
    assert!(compile("model Parent { id String child Child? @@id(id) } model Child { id String parentId String parent Parent @reference(via:[parentId]) @@id(id) @@unique(parentId) }").is_ok());
}
