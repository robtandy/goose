// error: extern fn forge cannot return Pair: it holds a resource<shared>, and C takes the runtime's handles
// Nor a value holding one (§7.10, §11.4).
struct Pair { arena: resource<shared>, n: i64 }
extern fn forge(n: i64) -> Pair = "forge";

fn main() {
    print(forge(1).n);
}
