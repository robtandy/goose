// resource<U> (§3.12): a handle, one u64 that only its kind's binding
// reads. Goose code stores one wherever a fixed-size value can be, copies
// it, passes it and returns it. No binding runs here, so every handle is the
// zero handle, which names nothing: the default of every kind, which
// default<T>(), a global with its type alone, a literal's `..` and an empty
// limited array's growth all give. A handle's text is its type alone, which
// shows that a handle is there without showing its bits (§3.7).
struct GpuBuffer {}
struct Slot { id: i32, buf: resource<GpuBuffer>, tag: u8 }
// A bare pad aligns a handle to its eight bytes (§3.2).
struct Aligned { a: u8, pad, buf: resource<GpuBuffer> }
struct Defaulted { n: i64 = 1, buf: resource<GpuBuffer> = default<resource<GpuBuffer>>() }
enum Held { Empty, One { b: resource<GpuBuffer> }, Two { a: resource<GpuBuffer>, n: i64 } }
// A variable-mode payload holds one too.
enum Named { Anonymous, Called { name: u8[], b: resource<GpuBuffer> } }

var global:  resource<GpuBuffer>;
var globals: resource<GpuBuffer>[2];
let fixed = default<resource<GpuBuffer>>();

fn pass(b: resource<GpuBuffer>) -> resource<GpuBuffer> { return b; }
fn pair(b: resource<GpuBuffer>) -> resource<GpuBuffer>, bool { return b, true; }
fn field(s: Slot&) -> resource<GpuBuffer> { s.buf }
fn exchange(a: resource<GpuBuffer>&, b: resource<GpuBuffer>&) {
    let t = a;
    a = b;
    b = t;
}
fn each<F>(bs: resource<GpuBuffer>[:]) {
    for b in bs { F(b); }
}

fn main() {
    // Locals: bound, assigned, declared with the type alone and assigned
    // later, and copied.
    let z = default<resource<GpuBuffer>>();
    var v = z;
    v = pass(v);
    var later: resource<GpuBuffer>;
    later = v;
    let c = copy(later);
    let p, ok = pair(c);
    print(z, " ", v, " ", later, " ", c, " ", p, " ", ok);

    // Globals.
    global = v;
    globals[1] = global;
    print(global, " ", globals, " ", fixed);

    // Fields.
    var s = Slot { id: 1, buf: v, tag: 2 };
    s.buf = field(s);
    let s2 = Slot { id: 3, .. };
    let al = Aligned { a: 4, buf: s2.buf };
    print(s, " ", s2, " ", al, " ", Defaulted {});

    // Array elements, of every kind of array.
    var grow: resource<GpuBuffer>[>..] = [];
    grow.push(v);
    grow.append([s.buf, al.buf]);
    var gs: resource<GpuBuffer>[>..<] = [v, v];
    let last = gs.pop();
    var lim: resource<GpuBuffer>[..4] = [];
    lim.push(last);
    let fx: resource<GpuBuffer>[3] = [v; 3];
    let va: resource<GpuBuffer>[]  = [v, v];
    print(grow, " ", gs, " ", lim, " ", fx, " ", va, " ", grow[1..]);

    // Payloads, bound by value and, in variable mode, by reference.
    let hs: Held[3] = [Held.Empty, Held.One { b: v }, Held.Two { a: v, n: 7 }];
    for h in hs {
        match h {
            One o => print("one ", o.b),
            Two t => print("two ", t.a, " ", t.n),
            Empty => print(h),
        }
    }
    var ns: Named..[>..] = [];
    ns.push(Named.Called { name: "first", b: v });
    for nm in ns {
        match nm {
            Called &k => print(k.name, " ", k.b, " ", nm),
            _ => {},
        }
    }

    // References to a handle's storage, and through them, the handles.
    var x = v;
    var y = grow[0];
    exchange(x, y);
    let r = &grow[2];
    var o: resource<GpuBuffer>? = null;
    print(o);
    o .= &x;
    if o { print(o, " ", r, " ", &x .== o, " ", &y .== o); }

    // Captured by a nested function, and handed to a block.
    fn show() { print("captured ", v); }
    show();
    var seen = 0;
    each(grow) { b => seen++; };
    print(seen, " seen");

    // Text: str and format give what print does.
    var out: u8[>..] = "";
    out.format(s);
    print(str(v), " ", out);
}
