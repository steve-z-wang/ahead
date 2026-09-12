use otter_compiler::{check_fence, compile, reconcile_history};
#[test]
fn versions_retain_original_inputs() {
    let v1 =
        compile("model A { id UUID title String @@id(id) } mutation Save { a A.create }").unwrap();
    let history = reconcile_history(&v1, None).unwrap();
    let changed =
        compile("model A { id UUID title String count Int @@id(id) } mutation Save { a A.create }")
            .unwrap();
    assert!(reconcile_history(&changed, Some(&history)).is_err());
    let v2=compile("model A { id UUID title String count Int @@id(id) } mutation Save { a A.create @@version(2) }").unwrap();
    let next = reconcile_history(&v2, Some(&history)).unwrap();
    assert_eq!(
        next["mutations"]["Save"]["1"]["input"]["models"][0]["fields"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(reconcile_history(&v1, Some(&next)).is_err());
}
#[test]
fn nullable_addition_compatible_and_fence_blocks_removal() {
    let before =
        compile("model A { id UUID title String @@id(id) } mutation Save { a A.create }").unwrap();
    let history = reconcile_history(&before, None).unwrap();
    let after = compile(
        "model A { id UUID title String note String? @@id(id) } mutation Save { a A.create }",
    )
    .unwrap();
    assert!(reconcile_history(&after, Some(&history)).is_ok());
    assert!(check_fence(&before["schema"], &after["schema"]).is_ok());
    assert!(check_fence(&after["schema"], &before["schema"]).is_err());
}
