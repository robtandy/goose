// error: root owners cannot be copied; bind a reference instead
// Nor copied: an attachment counts once, where it is declared (§11.4).
fn main() {
    let sh = shared {};
    var other = copy(sh);
}
