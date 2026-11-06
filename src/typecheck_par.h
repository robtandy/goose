// Goose compiler — the typechecker's `par for` (definitions of TypeCheck
// members, typecheck.h): what the body of a loop whose iterations may run on
// several threads at once may touch (docs/design/child_threads.md §4.3-§4.6).
//
// The body is a block of the enclosing function, checked as a `for`'s is,
// with every variable outside it -- the enclosing function's, those of the
// functions it is nested in, and the globals -- viewed read-only (R1): their
// values, and every reference or slice read out of them, carry no writable
// provenance (ParView), so the writability rule of §9.5 rejects a write
// through them wherever it is made, in a callee too, whose specialization
// takes its arguments' writability. What one iteration owns is writable
// (R2): the element `par for &x` binds, a[k] for the iteration's index k,
// and a.chunk(k, n) or a.chunk_at(bounds, k) of the loop's count or bounds,
// each of an array of flat elements in one known storage (ParPart), which
// the rest of the body may then not reach otherwise (FinishParFor). An
// integer of the enclosing function accumulated by one operation and not
// otherwise used is a reduction, kept per chunk and combined in chunk order
// at the join (§4.6). Neither the body nor anything it calls may print,
// use a queue, a thread or a pool, or exit (R3), nor leave the body but by
// ending an iteration (R4). A function the body calls is specialized for it
// (FnSpec::inpar), and so held to these rules, globals read-only included.
#pragma once

namespace goose {

// Whether the body of the innermost par for being checked sees vd from
// outside: a global, or a variable declared before the loop, of the function
// the loop is in or of one that function is nested in. Every variable the
// body declares, and every one a function checked for it declares, is deeper
// than the loop's own scope (VarDef::depth counts the scopes on the
// compile-time call path).
inline bool TypeCheck::ParCaptured(const VarDef *vd) {
    return InPar() && vd && (vd->isglobal || vd->depth <= Par().depth);
}

// A name in the body (or in a function checked for it) that reads or writes
// vd, a variable from outside it: FinishParFor judges each.
inline void TypeCheck::NoteParUse(Node *at, VarDef *vd) {
    if (ParCaptured(vd)) Par().uses.push_back({ at, vd });
}

// The loop's header, checked: what chunk(k, n) and chunk_at(bounds, k) of
// the iteration's index must take to be the iteration's own run. `par for k
// in n` and `par for k in 0..n` run k over the n runs of chunk(k, n), and
// `par for k in b.len - 1` over the runs between b's offsets.
inline void TypeCheck::StartParFor(ForLoop *x, ParCtx &ctx) {
    ctx.loop = x;
    if (auto r = Is<RangeExpr>(x->iter)) {
        if (auto lo = Is<IntLit>(r->lo); lo && !lo->uns && lo->val == 0) ctx.count = r->hi;
    } else if (x->iterkind == IK_COUNT) {
        ctx.count = x->iter;
    }
    if (auto b = Is<Binary>(ctx.count); b && b->op == T_MINUS) {
        auto one = Is<IntLit>(b->right);
        auto len = Is<Dot>(b->left);
        if (one && !one->uns && one->val == 1 && len && len->name == "len" &&
            len->member == B_LEN && Is<Ident>(len->obj))
            ctx.bounds = len->obj;
    }
}

// One pass over the body (CheckLoopPasses), in the loop's scope, its binders
// made: where the variables outside the body end, and the iteration's index.
inline void TypeCheck::ParPass(ForLoop *x, ParCtx &ctx) {
    ctx.depth = (int)scopes.size() - 1;
    ctx.scope = (int)scopes.size() - 1;
    ctx.frame = (int)frames.size() - 1;
    ctx.ordinal = ctx.ordinal2 = ctx.shifted = nullptr;
    if (x->iterkind == IK_RANGE || x->iterkind == IK_COUNT) {
        auto r = Is<RangeExpr>(x->iter);
        auto lo = r ? Is<IntLit>(r->lo) : nullptr;
        if (!r || (lo && !lo->uns && lo->val == 0)) ctx.ordinal = x->vdef;
        else ctx.shifted = x->vdef;
        ctx.ordinal2 = x->idxdef;
    } else {
        ctx.ordinal = x->idxdef;
    }
}

// Whether two expressions are the same partition's: the loop's count and a
// chunk's, or its bounds and a chunk_at's. `a` may be unchecked yet, so a
// name is looked up where it is.
inline bool TypeCheck::SameParExpr(Node *a, Node *b) {
    if (!a || !b) return false;
    if (auto x = Is<IntLit>(a)) {
        auto y = Is<IntLit>(b);
        return y && x->val == y->val && x->uns == y->uns;
    }
    if (auto x = Is<Ident>(a)) {
        auto y = Is<Ident>(b);
        if (!y || !x->expansionerror.empty() || !y->expansionerror.empty()) return false;
        auto xv = x->vdef ? x->vdef : LookupVar(x->name, x->ns);
        auto yv = y->vdef ? y->vdef : LookupVar(y->name, y->ns);
        return xv && xv == yv;
    }
    if (auto x = Is<Dot>(a)) {
        auto y = Is<Dot>(b);
        return y && x->name == y->name && SameParExpr(x->obj, y->obj);
    }
    if (auto x = Is<Binary>(a)) {
        auto y = Is<Binary>(b);
        return y && x->op == y->op && SameParExpr(x->left, y->left) &&
               SameParExpr(x->right, y->right);
    }
    return false;
}

// Where vd's value may reach: its own storage and what the references it
// holds point at, or, for a reference or slice, where it points.
inline Roots TypeCheck::ParRootsOf(VarDef *vd) {
    Roots r;
    if (vd->type && IsRefOrSlice(vd->type)) {
        r.Add(vd->ref.AsRoots());
        return r;
    }
    r.Set(vd, true);
    if (vd->type && HoldsPlainRef(vd->type)) r.Add(vd->contents);
    return r;
}

// A part an iteration owns (§4.4): of vd, lying in `root`, cut as `form`
// takes it with `key`, at `at`, where `name` names vd.
inline void TypeCheck::AddParPart(VarDef *vd, VarDef *root, ParForm form, Node *key, Node *at,
                                  Node *name) {
    auto &ctx = Par();
    ctx.parts.push_back({ vd, root, form, key, at });
    if (name) ctx.partuses.insert(name);
}

// a[k], a a variable outside the body and k a binder of the loop that tells
// the iterations apart: the element the iteration owns (§4.3 R2), whose path
// is as writable as a is outside the body. `owned` is a, `by` the binder
// where it is not the iteration's ordinal (ParPart::by).
inline bool TypeCheck::ParIndexPart(Index *ix, VarDef *&owned, VarDef *&by) {
    if (!InPar()) return false;
    auto id = Is<Ident>(ix->obj);
    auto kid = Is<Ident>(ix->idx);
    if (!id || !kid || !id->expansionerror.empty() || !kid->expansionerror.empty()) return false;
    auto vd = LookupVar(id->name, id->ns);
    if (!vd || vd->isglobal || !ParCaptured(vd)) return false;
    auto kd = LookupVar(kid->name, kid->ns);
    if (!kd || (!ParOrdinal(kd) && kd != Par().shifted)) return false;
    owned = vd;
    by = ParOrdinal(kd) ? nullptr : kd;
    return true;
}

// a.chunk(k, n) of the loop's count n, or a.chunk_at(bounds, k) of the
// loop's bounds, k the iteration's index and a a variable outside the body:
// the run the iteration owns (§4.4).
inline bool TypeCheck::ParChunkPart(Call *c, const BuiltinDef &d, vector<Node *> &args,
                                    VarDef *&owned) {
    if (!InPar() || args.size() != 3) return false;
    auto id = Is<Ident>(args[0]);
    if (!id || !id->expansionerror.empty()) return false;
    auto vd = LookupVar(id->name, id->ns);
    if (!vd || vd->isglobal || !ParCaptured(vd)) return false;
    auto kid = Is<Ident>(d.kind == B_CHUNK ? args[1] : args[2]);
    if (!kid || !kid->expansionerror.empty() || !ParOrdinal(LookupVar(kid->name, kid->ns)))
        return false;
    auto key = d.kind == B_CHUNK ? args[2] : args[1];
    if (!SameParExpr(key, d.kind == B_CHUNK ? Par().count : Par().bounds)) return false;
    (void)c;
    owned = vd;
    return true;
}

[[noreturn]] inline void TypeCheck::ParWriteError(Node *at, VarDef *vd, const char *what) {
    if (vd->isglobal)
        Error(at, cat(what, " ", vd->name, " in a par for: a global is read-only in a par for's "
                      "body and in every function it calls, since every iteration may run at "
                      "once (docs/design/child_threads.md §4.3 R1, R3)"));
    Error(at, cat(what, " ", vd->name, " in a par for: ", vd->name, " is a variable of the "
                  "enclosing function, which every iteration sees and may run beside the "
                  "others, so the body may only read it (docs/design/child_threads.md §4.3 R1); "
                  "write what one iteration owns instead -- the element `par for &x` binds, "
                  "a[k] for the loop's index k, a.chunk(k, n) of the loop's count -- or, for "
                  "an integer accumulated by one operation, make it a reduction (x += ...)"));
}

// `x op= v`, `x++`, `x--` or `x = v` (op T_ASSIGN), `x .= r` (T_DOTASSIGN),
// on x, a variable from outside the body as a whole: a reduction of an
// integer local by an associative operation (§4.6), or no write at all.
inline void TypeCheck::ParAssign(Node *at, LVal &lv, TType op) {
    auto vd = lv.var;
    auto t = vd->type;
    auto reducing = op == T_PLUSEQ || op == T_MINUSEQ || op == T_OREQ || op == T_ANDEQ ||
                    op == T_XOREQ || op == T_INC || op == T_DEC;
    if (vd->isglobal || !reducing)
        ParWriteError(at, vd, op == T_DOTASSIGN ? "cannot rebind" : "cannot assign");
    if (t && t->kind == TY_FLT)
        Error(at, cat("cannot accumulate ", vd->name, " in a par for: a float is no reduction, "
                      "since its sum would depend on how the iterations are cut into chunks "
                      "(docs/design/child_threads.md §4.6); write each iteration's part into an "
                      "element (partial[k] = acc) and add them up after the loop, in the order "
                      "you choose"));
    if (!t || t->kind != TY_INT || t->intstorage == IS_VARINT || t->ix)
        ParWriteError(at, vd, "cannot update");
    auto cls = op == T_MINUSEQ || op == T_INC || op == T_DEC ? T_PLUSEQ : op;
    auto name = Is<Assign>(at) ? Is<Assign>(at)->lval : Is<IncDec>(at) ? Is<IncDec>(at)->lval
                                                                       : at;
    auto &ctx = Par();
    ctx.redtargets.insert(name);
    for (auto &[v, o, first] : ctx.reductions) {
        if (v != vd) continue;
        auto opname = [](TType k) {
            return k == T_PLUSEQ ? "+= and -=" : k == T_OREQ ? "|=" : k == T_ANDEQ ? "&=" : "^=";
        };
        if (o != cls)
            Error(at, cat(vd->name, " is a reduction of this par for by ", opname(o), " (at ",
                          Where(first->line), "), and cannot be updated by ", opname(cls),
                          " too: a reduction has one operation (docs/design/child_threads.md "
                          "§4.6)"));
        return;
    }
    ctx.reductions.push_back({ vd, cls, at });
}

// A builtin (`builtin`), or a function (`callee`), that a par for's body or
// a function checked for it calls: none whose effect is other than the
// writes the iteration owns (§4.3 R3), since the order of those effects
// would show how the iterations were scheduled.
inline void TypeCheck::ParEffect(Call *c, int builtin, SFunction *callee) {
    string what;
    switch (builtin) {
        case B_PRINT: case B_EXIT: case B_QPUT: case B_QGET: case B_QPOLL: case B_QLIMIT:
        case B_THREAD_SPAWN: case B_THREAD_SPAWN_CONTAINED: case B_THREAD_WAIT:
        case B_THREAD_POOL: case B_APPLY: case B_APPLY_CONTAINED: case B_POOL_CLOSE:
            what = BuiltinByKind(builtin).name;
            break;
        default: break;
    }
    // The standard library's input and output, its clocks and environment,
    // and its raw memory access are C whose effects are the world's.
    if (callee && callee->isextern && ast.StdlibFile(callee->line.fileidx)) {
        auto &file = ast.sources[callee->line.fileidx].first;
        auto ends = [&](const char *s) {
            auto n = strlen(s);
            return file.size() >= n && file.compare(file.size() - n, n, s) == 0 &&
                   (file.size() == n || file[file.size() - n - 1] == '/' ||
                    file[file.size() - n - 1] == '\\');
        };
        if (ends("os.goose") || ends("ffi.goose")) what = string(callee->qname);
    }
    if (what.empty()) return;
    auto direct = (int)frames.size() - 1 == Par().frame || frames.back().isfunval;
    Error(c, cat(what, " in a par for", direct ? "" : "'s callee", ": an iteration's only effect "
                 "may be its writes to what it owns, and the order of anything else -- output, "
                 "a queue, a thread or pool, exit -- would show how the iterations were "
                 "scheduled (docs/design/child_threads.md §4.3 R3); do it before or after the "
                 "loop, or run the program with GOOSE_THREADS=1 to debug"));
}

// A return (`what`), from the function of frame `targetframe`, in a par
// for's body or a function checked for it: none may leave the body (§4.3
// R4), whose iterations end only by running to its end or a continue.
inline void TypeCheck::ParExit(Node *at, int targetframe, const char *what) {
    if (!InPar() || targetframe > Par().frame) return;
    Error(at, cat(what, " out of a par for: an iteration ends by running to the end of the "
                  "body or by continue, and nothing leaves the loop early, since the "
                  "other iterations may be running (docs/design/child_threads.md §4.3 R4)"));
}

// A call in a par for's body, or in a function checked for it, to a function
// whose check returned out of the functions enclosing every call of it
// (FnSpec::needs), which a reused check does not do again.
inline void TypeCheck::ParCallNeeds(Node *at, FnSpec *callee) {
    if (!InPar() || !callee) return;
    for (auto t : callee->needs) {
        auto f = FrameOfSpec(t);
        if (f >= 0 && f <= Par().frame)
            Error(at, cat("this call returns from ", t->sf->name, " out of a par for: an "
                          "iteration ends by running to the end of the body or by continue "
                          "(docs/design/child_threads.md §4.3 R4)"));
    }
}

// The body is checked: its parts must each be cut one way and reached no
// other way, and its reductions used no other way (§4.4, §4.6). What
// codegen needs of them goes on the loop.
inline void TypeCheck::FinishParFor(ForLoop *x, ParCtx &ctx) {
    auto formname = [&](const ParPart &p) -> string {
        auto of = p.var ? string(p.var->name) : string("the sequence");
        switch (p.form) {
            case PF_ELEMENT:
                return p.by ? cat(of, "[", p.by->name, "]")
                            : cat("the element of ", of, " the iteration's index names");
            case PF_CHUNK: return cat(of, ".chunk(k, ", ExprStr(p.key), ")");
            case PF_CHUNK_AT: return cat(of, ".chunk_at(", ExprStr(p.key), ", k)");
        }
        return "";
    };
    for (size_t i = 0; i < ctx.parts.size(); i++) {
        auto &b = ctx.parts[i];
        for (size_t j = 0; j < i; j++) {
            auto &a = ctx.parts[j];
            if (a.root != b.root || a.at == b.at) continue;
            auto same = a.form == b.form &&
                        (a.form == PF_ELEMENT ? a.by == b.by : SameParExpr(a.key, b.key));
            if (!same)
                Error(b.at, cat("a par for's iterations own ", formname(b), " here and ",
                                formname(a), " at ", Where(a.at->line), ", which are cut "
                                "differently and so overlap between iterations "
                                "(docs/design/child_threads.md §4.4)"));
        }
    }
    for (auto &[at, vd] : ctx.uses) {
        if (ctx.partuses.count(at)) continue;
        auto roots = ParRootsOf(vd);
        for (auto &p : ctx.parts) {
            if (vd != p.var && !roots.Has(p.root)) continue;
            Error(at, cat(vd->name, " is ", vd == p.var ? "" : "or may point into storage ",
                          "partitioned by this par for, each iteration owning ", formname(p),
                          " (", Where(p.at->line), "), so no iteration may read or write ",
                          vd == p.var ? "it" : "that storage", " any other way: another "
                          "iteration may be writing what this one reads "
                          "(docs/design/child_threads.md §4.4)"));
        }
        for (auto &[rv, op, first] : ctx.reductions) {
            if (rv != vd || ctx.redtargets.count(at)) continue;
            Error(at, cat(vd->name, " is a reduction of this par for (", Where(first->line),
                          "), so the body may only accumulate it, never read it or write it "
                          "otherwise: each chunk of iterations keeps a total of its own, "
                          "which the loop combines once they all end "
                          "(docs/design/child_threads.md §4.6)"));
        }
    }
    x->reductions.clear();
    for (auto &[rv, op, first] : ctx.reductions) x->reductions.push_back({ rv, op });
    x->chunkats.clear();
    for (auto &p : ctx.parts) {
        if (p.form != PF_CHUNK_AT || !p.var) continue;
        auto b = Is<Ident>(p.key);
        if (!b || !b->vdef) continue;
        auto known = false;
        for (auto &[a, bv] : x->chunkats) known = known || (a == p.var && bv == b->vdef);
        if (!known) x->chunkats.push_back({ p.var, b->vdef });
    }
}

}  // namespace goose
