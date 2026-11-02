// error: view<Pt> at byte offset 6, which is not a multiple of 4, the size of field x of Pt, i32
// Of a struct, the widest scalar is a field's, which the error names.
struct Pt { x: i32, y: i16, pad 2 }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("pts");
    print(view<Pt>(sh, m, 6, 1).len);
}
