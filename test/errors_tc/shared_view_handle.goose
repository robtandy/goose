// error: field m of Entry is resource<mapping>, a handle, which only its kind's binding makes
// Nor a handle, which C or a file could forge (§3.12, §11.4).
struct Entry { m: resource<mapping>, n: i64 }

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("entries");
    print(view<Entry>(sh, m, 0, 1).len);
}
