// A kind is named whole (§3.12), the extents of the arrays in its type
// arguments included, also where no field of its declaration uses them: the
// queue of each kind here is named for it. Each kind is written once, since
// a second mention of a type evaluates its extents on the way.
struct Tag<T> {}

fn main() {
    print(qput(default<resource<Tag<i64[1 + 1]>>>()));
    print(qput(default<resource<Tag<u8[..2 * 2]>>>()));
    print(qput(default<resource<Tag<Tag<i32[3]>[4 - 1]>>>()));
}
