// A view converts as any slice does (§11.4): an array declared from one,
// assigned one, passed one by value, returned as one, a field initialized
// from one and an append of one each copy its elements, and the copies are
// the program's own, written to freely and kept after the attachment ends.
// A resizable array takes a function's u8[] result made from a view too,
// from a recursive function as well, which -O2 does not inline.
import os;

struct Tagged { tag: u8[..5], n: i64 }

let DIR = "gs_shared_view_copies";

fn head(sh: shared&, m: resource<mapping>) -> u8[] { view<u8>(sh, m, 0, 5) }

recursive fn tail_of(sh: shared&, m: resource<mapping>, n: i64) -> u8[] {
    if n > 0 { return tail_of(sh, m, n - 1); }
    view<u8>(sh, m, 6, 5)
}

fn ells(word: u8[]) -> i64 {
    var n = 0;
    for c in word {
        if c == 'l' { n += 1; }
    }
    n
}

fn main() {
    make_dir(DIR);
    let p = str(DIR, "/words");
    write_file(p, "hello world");
    var kept:  u8[..8] = [];
    var grown: u8[>..] = [];
    var tagged = Tagged { tag: [], n: 0 };
    {
        let sh = shared {};
        let m, ok = sh.map_file(p);
        let a: u8[] = view<u8>(sh, m, 0, 5);
        var b: u8[..5] = view<u8>(sh, m, 6, 5);
        b[0] = 'W';
        print(str(a), " ", str(b), " ", b.cap);                 // hello World 5
        print(str(view<u8>(sh, m, 6, 5)));                      // world: the file is unchanged
        kept = view<u8>(sh, m, 6, 5);
        b = view<u8>(sh, m, 0, 5);
        print(str(b));                                          // hello
        print(ells(view<u8>(sh, m, 0, 11)));                    // 3
        print(str(head(sh, m)));                                // hello
        tagged = Tagged { tag: view<u8>(sh, m, 6, 5), n: 2 };
        grown.append(view<u8>(sh, m, 0, 6));
        grown.append(view<u8>(sh, m, 6, 5));
        var run: u8[>..] = head(sh, m);
        run.push('!');
        var deep: u8[>..] = tail_of(sh, m, 3);
        print(str(run), " ", str(deep), " ", deep.len);         // hello! world 5
    }
    print(str(kept), " ", str(tagged.tag), " ", tagged.n, " ", str(grown));   // world world 2 hello world

    delete_file(p);
    delete_dir(DIR);
}
