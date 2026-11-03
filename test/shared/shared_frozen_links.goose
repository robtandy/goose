// Relative references inside frozen data (§3.9, §11.4): a tree whose nodes
// link their children, parents and next nodes by u16, u32 and u8 offsets,
// and a circular list whose
// links are `self` at first, built in place on dynamic stacks and frozen;
// main and a worker walk them in place, each load an addition, and each link
// loaded is a const reference rooted at the attachment, which a function
// given the attachment returns. A link that a pop left past the end reads
// the element it named, which the region keeps.
import std;

struct Tree { key: i64, sib: Tree&<u8>?, left: Tree&<u16>?, right: Tree&<u32>?, up: Tree&<u32>? }
struct Ring { key: i64, prev: Ring&<u32>, next: Ring&<u32> }
struct Handles { arena: resource<shared>, tree: resource<frozen<Tree>>, ring: resource<frozen<Ring>> }

// Node i's children are 2i + 1 and 2i + 2, and its sibling i + 1: an
// array of n nodes, linked after they are all in place.
fn tree(t: Tree[>..]&, n: i64) {
    for i in n { t.push(Tree { key: i * 10, sib: null, left: null, right: null, up: null }); }
    for i in n {
        if i + 1 < n { t[i].sib .= t[i + 1]; }
        if 2 * i + 1 < n { t[i].left .= t[2 * i + 1]; }
        if 2 * i + 2 < n { t[i].right .= t[2 * i + 2]; }
        if i > 0 { t[i].up .= t[(i - 1) / 2]; }
    }
}

recursive fn total(t: const Tree&) -> i64 {
    var s = t.key;
    let l = t.left;
    if l { s += total(l); }
    let r = t.right;
    if r { s += total(r); }
    s
}

// How deep the leftmost node lies, times 1000, and the key of the node its
// parent links lead back up to.
fn depth(t: const Tree&) -> i64 {
    var n = t.left;
    var up = t.up;
    var d = 0;
    while n {
        d++;
        up .= n.up;
        n .= n.left;
    }
    var top = -1;
    while up {
        top = up.key;
        up .= up.up;
    }
    d * 1000 + top
}

// The nodes counted by their u8 links, from t on.
fn siblings(t: const Tree&) -> i64 {
    var n = t.sib;
    var k = 1;
    while n {
        k++;
        n .= n.sib;
    }
    k
}

// A ring of n nodes in the order inserted: each new one before the
// sentinel, whose links are its own at first.
fn ring(r: Ring[>..]&, n: i64) {
    r.push(Ring { key: -1, prev: self, next: self });
    for i in n {
        let e .= r.push(Ring { key: i, prev: self, next: self });
        e.prev .= r[0].prev;
        e.next .= r[0];
        r[0].prev.next .= e;
        r[0].prev .= e;
    }
}

fn forward(r: const Ring&) -> i64 {
    var s = 0;
    var e .= r.next;
    while e.key >= 0 {
        s = s * 3 + e.key;
        e .= e.next;
    }
    s
}

// A link out of a frozen array, rooted where the attachment is.
fn root_of(sh: shared&, h: resource<frozen<Tree>>) -> const Tree& { sh.view(h)[0] }

fn walk(sh: shared&, h: Handles) -> i64 {
    let t .= root_of(sh, h.tree);
    let r = sh.view(h.ring);
    (total(t) * 1000 + siblings(t)) * 10000 + depth(t) + forward(r[0])
}

thread_fn walker(h: Handles) {
    let sh = attach(h.arena);
    qput(walk(sh, h));
}

fn main() {
    let sh = shared {};
    var t = dynamic_stack<Tree> {};
    tree(t.items, 100);
    var r = dynamic_stack<Ring> {};
    ring(r.items, 7);
    let h = Handles { arena: sh.handle, tree: sh.freeze(t), ring: sh.freeze(r) };
    let tv = sh.view(h.tree);
    print(tv.len, " nodes, keys summing to ", total(tv[0]), ", ", siblings(tv[0]),
          " by their u8 links; the leftmost ", depth(tv[0]) / 1000,
          " levels down, and its parents' links lead up to key ", depth(tv[0]) % 1000);
    print("the ring forward: ", forward(sh.view(h.ring)[0]));
    let id = thread_spawn(walker, h);
    print("a worker walks the same: ", qget<i64>() == walk(sh, h));
    thread_wait(id);

    // A pop leaves the first node's link past the end of what is frozen.
    var p = dynamic_stack<Tree> {};
    p.items.push(Tree { key: 1, sib: null, left: null, right: null, up: null });
    p.items.push(Tree { key: 2, sib: null, left: null, right: null, up: null });
    p.items[0].sib .= p.items[1];
    p.items.pop();
    let pv = sh.view(sh.freeze(p));
    let past = pv[0].sib;
    assert(past);
    print(pv.len, " node frozen, its link past the end reads key ", past.key);
}
