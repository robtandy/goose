// error: extern fn forge cannot return resource<frozen<i64>>
// C takes a frozen array's handle but never makes one (§7.10, §11.4).
extern fn forge() -> resource<frozen<i64>>;

fn main() { let r = forge(); }
