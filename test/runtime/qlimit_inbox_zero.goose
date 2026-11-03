// An inbox's limit is one message or more (§11.2), as a queue's is.
fn main() {
    qlimit_inbox<i64>(1);
    print("one");
    qlimit_inbox<i64>(0);
}
