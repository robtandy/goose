// error: mapping is the kind of a mapped file's handle, written only as resource's argument: resource<mapping>
// A runtime kind names a handle's kind and no value's type (§3.12, §11.4).
fn main() {
    var m: mapping;
}
