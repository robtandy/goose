// error: extern fn forge cannot return resource<mapping>
// error: C takes the runtime's handles, but only the runtime makes one
// C takes the runtime's handles, by value, but never makes one (§7.10,
// §11.4): a handle C made could name a mapping of another arena, or none.
extern fn forge(n: i64) -> resource<mapping> = "forge";

fn main() {
    print(forge(1));
}
