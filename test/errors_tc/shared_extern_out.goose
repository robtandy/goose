// error: parameter out of type resource<mapping>& lets C write a resource<mapping>, which only the runtime makes
// Nor writes one into storage it is given (§7.10, §11.4); a const one it
// reads.
extern fn peek(m: const resource<mapping>&) -> i64 = "peek";
extern fn fill(out: resource<mapping>&) = "fill";

fn main() {
    let sh = shared {};
    let m, ok = sh.map_file("col.i64");
    print(peek(m));
}
