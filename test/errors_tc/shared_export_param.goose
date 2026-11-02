// error: export fn sum: parameter m of type resource<mapping> would take a resource<mapping> from C, which only the runtime makes
// C calls an export with the arguments it makes (§7.11, §11.4).
let gsh = shared {};

export "goose_sum" fn sum(m: resource<mapping>) -> i64 {
    view<i64>(gsh, m, 0, 1)[0]
}

fn main() {}
