// error: field kind of Row is Kind, an enum, whose tag holds only its variants' numbers
// The error names the part of the type at fault (§11.4).
enum Kind { A, B }
struct Row { key: i64, kind: Kind }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("rows");
    print(view<Row>(sh, m, 0, 4).len);
}
