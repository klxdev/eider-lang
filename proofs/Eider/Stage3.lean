/-!
# Stages 3 and 4 of the formal model (docs/design/formal-model.md): the protection rule and mutable aliases

A reference in Eider is not a pointer: `let r = p` makes `r` a name for the *place* `p`, re-derived on every use
(memory-safety.md S6). This file models that with paths, not addresses.

## The model

* `Val`: an integer or a (nested) list of values. A `Place` is a root variable plus a path of indices
  (`x[i][j]`). `read env p` follows the path (`none` when the root is unbound or an index is out of range);
  `write env p v` replaces the subvalue at `p`, and changes nothing when the path does not exist (an index
  out of range is a trap in the language, which is a safe terminal state; the model keeps the store unchanged).
* `overlap p q`: the two places have the same root and one path is a prefix of the other (one contains the
  other). This is the relation behind both E0301 and E0308.

## Constructs and the Eider rules they model

| model                      | Eider                      | rule                                                         |
|----------------------------|----------------------------|--------------------------------------------------------------|
| `bind r p`                 | `let r = p`                | S6: a read-only reference to the place `p`; the snapshot is ghost |
| `use r`                    | a read of `r`              | S6: re-derives `p`; the trace records what is observed       |
| `set q v`                  | `q = v`                    | a write to the place `q`                                     |
| `alias a p`                | `let mut a = p`            | S8: `a` is a mutable alias, a second name for `p`            |
| `setvia a v`               | `a = v`                    | writes the original place `p`, not a copy                    |
| `call2 p q v w`            | `f(inout p, inout q)`      | S7 / E0301: `p`, `q` must not overlap; the body writes both  |
| `accepted` (`chk`)         | the checker                | S9 / E0308: no write overlaps a reference that is used later |

The *snapshot* stored with a reference (`Ref.snap`, the value read at bind time) is a ghost: execution never reads
it, only the statement of the theorem does. The trace entry of a `use` is the pair (observed now, snapshot at bind).

## Results

* `read_write_ne` (the key lemma): a write to a place that does not overlap `p` cannot change what `p` names.
* `protection` (stage 3): in an accepted program every `use r` observes exactly the value read when `r` was bound.
* `alias_writes_original`, `write_comm`, `call2_order`, `call2_exclusive` (stage 4).
-/
namespace Eider
namespace Stage3

/-! ## Values, places, reads and writes -/

inductive Val where
  | int (n : Int)
  | list (xs : List Val)

/-- Follow a path of indices. -/
def Val.get : Val → List Nat → Option Val
  | v, [] => some v
  | .list xs, i :: is => (xs[i]?).bind (fun c => c.get is)
  | .int _, _ :: _ => none

/-- Replace the subvalue at a path; unchanged when the path does not exist. -/
def Val.put : Val → List Nat → Val → Val
  | _, [], w => w
  | .list xs, i :: is, w =>
    match xs[i]? with
    | some c => .list (xs.set i (c.put is w))
    | none => .list xs
  | .int n, _ :: _, _ => .int n

structure Place where
  root : Nat
  path : List Nat

abbrev Env := Nat → Option Val

def read (env : Env) (p : Place) : Option Val := (env p.root).bind (fun v => v.get p.path)

def write (env : Env) (p : Place) (w : Val) : Env :=
  fun x => if x = p.root then (env x).map (fun v => v.put p.path w) else env x

/-- `isPre p q`: the path `p` is a prefix of `q`. -/
def isPre : List Nat → List Nat → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => a == b && isPre as bs

/-- Same root, and one path contains the other. -/
def overlap (p q : Place) : Bool :=
  p.root == q.root && (isPre p.path q.path || isPre q.path p.path)

theorem overlap_comm (p q : Place) : overlap p q = overlap q p := by
  unfold overlap
  by_cases hr : p.root = q.root
  · have e1 : (p.root == q.root) = true := by simpa using hr
    have e2 : (q.root == p.root) = true := by simpa using hr.symm
    rw [e1, e2]; simp [Bool.or_comm]
  · have e1 : (p.root == q.root) = false := by simpa using hr
    have e2 : (q.root == p.root) = false := by simpa using (fun h : q.root = p.root => hr h.symm)
    rw [e1, e2]; rfl

theorem overlap_self (p : Place) : overlap p p = true := by
  have : ∀ l : List Nat, isPre l l = true := by
    intro l; induction l with
    | nil => rfl
    | cons a t ih => simp [isPre, ih]
  simp [overlap, this]

/-! ### Reading what was written -/

theorem get_cons_some {xs : List Val} {i : Nat} {c : Val} (h : xs[i]? = some c) (is : List Nat) :
    (Val.list xs).get (i :: is) = c.get is := by simp [Val.get, h]

theorem get_cons_none {xs : List Val} {i : Nat} (h : xs[i]? = none) (is : List Nat) :
    (Val.list xs).get (i :: is) = none := by simp [Val.get, h]

theorem put_cons_some {xs : List Val} {i : Nat} {c : Val} (h : xs[i]? = some c) (is : List Nat) (w : Val) :
    (Val.list xs).put (i :: is) w = Val.list (xs.set i (c.put is w)) := by simp [Val.put, h]

theorem put_cons_none {xs : List Val} {i : Nat} (h : xs[i]? = none) (is : List Nat) (w : Val) :
    (Val.list xs).put (i :: is) w = Val.list xs := by simp [Val.put, h]

theorem get_list_exists {xs : List Val} {i : Nat} {is : List Nat} {x : Val}
    (h : (Val.list xs).get (i :: is) = some x) : ∃ c, xs[i]? = some c ∧ c.get is = some x := by
  cases hc : xs[i]? with
  | none => rw [get_cons_none hc] at h; cases h
  | some c => rw [get_cons_some hc] at h; exact ⟨c, rfl, h⟩

theorem set_getElem_self {xs : List Val} {i : Nat} {c : Val} (h : xs[i]? = some c) (y : Val) :
    (xs.set i y)[i]? = some y := by
  have hi : i < xs.length := (List.getElem?_eq_some_iff.mp h).1
  simp [hi]


theorem get_put_same : ∀ (p : List Nat) (v w : Val), (∃ x, v.get p = some x) →
    (v.put p w).get p = some w := by
  intro p
  induction p with
  | nil => intro v w _; simp [Val.get, Val.put]
  | cons i ps ih =>
    intro v w ⟨x, hx⟩
    cases v with
    | int n => simp [Val.get] at hx
    | list xs =>
      obtain ⟨c, hc, hcx⟩ := get_list_exists hx
      rw [put_cons_some hc, get_cons_some (set_getElem_self hc _)]
      exact ih c w ⟨x, hcx⟩

/-- Read after write: a place that exists reads back what was written to it. -/
theorem read_write_same (env : Env) (p : Place) (w : Val) (h : (read env p).isSome = true) :
    read (write env p w) p = some w := by
  simp only [read, write, ite_true]
  cases he : env p.root with
  | none => simp [he, read] at h
  | some v =>
    simp [he, read] at h
    obtain ⟨x, hx⟩ := Option.isSome_iff_exists.mp h
    simp [get_put_same p.path v w ⟨x, hx⟩]

theorem set_same {xs : List Val} {i : Nat} {c : Val} (h : xs[i]? = some c) : xs.set i c = xs := by
  apply List.ext_getElem?
  intro n
  by_cases hn : n = i
  · subst hn; rw [set_getElem_self h, h]
  · rw [List.getElem?_set_ne (Ne.symm hn)]

theorem put_missing : ∀ (ps : List Nat) (v w : Val), v.get ps = none → v.put ps w = v := by
  intro ps
  induction ps with
  | nil => intro v w hv; simp [Val.get] at hv
  | cons i is ih =>
    intro v w hv
    cases v with
    | int n => simp [Val.put]
    | list xs =>
      cases hc : xs[i]? with
      | none => rw [put_cons_none hc]
      | some c =>
        rw [get_cons_some hc] at hv
        rw [put_cons_some hc, ih c w hv]
        rw [set_same hc]

/-- Writing a place that does not exist changes nothing. -/
theorem write_missing (env : Env) (p : Place) (w : Val) (h : read env p = none) :
    write env p w = env := by
  funext x
  simp only [write]
  split
  · rename_i hx
    subst hx
    cases he : env p.root with
    | none => simp
    | some v =>
      simp only [read, he, Option.bind_some] at h
      simp [put_missing p.path v w h]
  · rfl

/-! ### The key lemma: a write to a non-overlapping place cannot change what a place names -/

theorem get_put_disjoint : ∀ (p q : List Nat) (v w : Val),
    isPre p q = false → isPre q p = false → (v.put q w).get p = v.get p := by
  intro p
  induction p with
  | nil => intro q v w h; simp [isPre] at h
  | cons i ps ih =>
    intro q v w h1 h2
    cases q with
    | nil => simp [isPre] at h2
    | cons j qs =>
      cases v with
      | int n => simp [Val.put, Val.get]
      | list xs =>
        by_cases hij : i = j
        · subst hij
          have h1' : isPre ps qs = false := by
            cases h : isPre ps qs <;> simp_all [isPre]
          have h2' : isPre qs ps = false := by
            cases h : isPre qs ps <;> simp_all [isPre]
          cases hc : xs[i]? with
          | none => rw [put_cons_none hc]
          | some c =>
            rw [put_cons_some hc, get_cons_some (set_getElem_self hc _), get_cons_some hc]
            exact ih qs c w h1' h2'
        · cases hc : xs[j]? with
          | none => rw [put_cons_none hc]
          | some c =>
            rw [put_cons_some hc]
            cases hd : xs[i]? with
            | none => rw [get_cons_none hd, get_cons_none (by rw [List.getElem?_set_ne (Ne.symm hij)]; exact hd)]
            | some d =>
              rw [get_cons_some hd, get_cons_some (by rw [List.getElem?_set_ne (Ne.symm hij)]; exact hd)]

theorem overlap_false_iff (p q : Place) :
    overlap p q = false ↔ p.root ≠ q.root ∨ (isPre p.path q.path = false ∧ isPre q.path p.path = false) := by
  simp [overlap]
  constructor <;> intro h
  · by_cases hr : p.root = q.root
    · right; exact h hr
    · left; exact hr
  · intro hr; rcases h with h | h
    · exact absurd hr h
    · exact h

/-- THE KEY LEMMA. A write to a place that neither contains nor is contained in `p` (nor shares its root)
cannot change what `p` names. -/
theorem read_write_ne (env : Env) (p q : Place) (w : Val) (h : overlap p q = false) :
    read (write env q w) p = read env p := by
  rcases (overlap_false_iff p q).mp h with hr | ⟨h1, h2⟩
  · simp [read, write, hr]
  · simp only [read, write]
    by_cases hr : p.root = q.root
    · simp only [hr, ite_true]
      cases he : env q.root with
      | none => simp
      | some v => simp [get_put_disjoint p.path q.path v w h1 h2]
    · simp [hr]

/-- A write inside a place (or at it) never removes that place: if `p` exists and is a prefix of the written
path `q` (same root), `p` still exists afterwards. -/
theorem get_put_prefix : ∀ (p q : List Nat) (v w : Val), isPre p q = true →
    (∃ x, v.get p = some x) → ∃ y, (v.put q w).get p = some y := by
  intro p
  induction p with
  | nil => intro q v w _ _; cases q <;> simp [Val.get, Val.put]
  | cons i ps ih =>
    intro q v w h ⟨x, hx⟩
    cases q with
    | nil => simp [isPre] at h
    | cons j qs =>
      simp [isPre] at h
      obtain ⟨rfl, h'⟩ := h
      cases v with
      | int n => simp [Val.get] at hx
      | list xs =>
        obtain ⟨c, hc, hcx⟩ := get_list_exists hx
        obtain ⟨y, hy⟩ := ih qs c w h' ⟨x, hcx⟩
        exact ⟨y, by rw [put_cons_some hc, get_cons_some (set_getElem_self hc _)]; exact hy⟩

theorem read_write_prefix_exists (env : Env) (p q : Place) (w : Val) (hr : p.root = q.root)
    (hp : isPre p.path q.path = true) (h : (read env p).isSome = true) :
    (read (write env q w) p).isSome = true := by
  simp only [read, write, hr, ite_true]
  simp only [read, hr] at h
  cases he : env q.root with
  | none => simp [he] at h
  | some v =>
    simp [he] at h
    obtain ⟨x, hx⟩ := Option.isSome_iff_exists.mp h
    obtain ⟨y, hy⟩ := get_put_prefix p.path q.path v w hp ⟨x, hx⟩
    simp [hy]

/-! ## The program language, the semantics and the checker -/

inductive Stmt where
  | bind (r : Nat) (p : Place)
  | use (r : Nat)
  | set (q : Place) (v : Val)
  | alias (a : Nat) (p : Place)
  | setvia (a : Nat) (v : Val)
  | call2 (p q : Place) (v w : Val)

abbrev Prog := List Stmt

/-- A bound read-only reference: its name, the place it names, and the ghost snapshot read at bind time. -/
structure Ref where
  name : Nat
  place : Place
  snap : Option Val

structure State where
  env : Env
  refs : List Ref
  als : List (Nat × Place)
  /-- `use` entries: (observed now, snapshot at bind time) -/
  trace : List (Option Val × Option Val)

def findRef : List Ref → Nat → Option Ref
  | [], _ => none
  | e :: t, r => if e.name = r then some e else findRef t r

def findAl : List (Nat × Place) → Nat → Option Place
  | [], _ => none
  | (k, p) :: t, a => if k = a then some p else findAl t a

def step (s : State) : Stmt → State
  | .bind r p => { s with refs := ⟨r, p, read s.env p⟩ :: s.refs }
  | .use r =>
    match findRef s.refs r with
    | some e => { s with trace := s.trace ++ [(read s.env e.place, e.snap)] }
    | none => s
  | .set q v => { s with env := write s.env q v }
  | .alias a p => { s with als := (a, p) :: s.als }
  | .setvia a v =>
    match findAl s.als a with
    | some q => { s with env := write s.env q v }
    | none => s
  | .call2 p q v w => { s with env := write (write s.env p v) q w }

def run : State → Prog → State
  | s, [] => s
  | s, i :: rest => run (step s i) rest

def init (env : Env) : State := ⟨env, [], [], []⟩

/-- Is `r` read (`use r`) somewhere in the rest of the program? (A LATER USE.) -/
def usedLater (r : Nat) (rest : Prog) : Bool :=
  rest.any (fun i => match i with | .use r' => r' == r | _ => false)

/-- A write to `q` is safe: it overlaps no reference (place `pr`) that is used later. -/
def safeW (rs : List (Nat × Place)) (rest : Prog) (q : Place) : Bool :=
  rs.all (fun e => !usedLater e.1 rest || !overlap q e.2)

/-- The checker (S9 / E0308, with S7 / E0301 for `call2`). `rs` are the references in scope (name, place),
`als` the aliases in scope. -/
def chk (rs : List (Nat × Place)) (als : List (Nat × Place)) : Prog → Bool
  | [] => true
  | .bind r p :: rest => chk ((r, p) :: rs) als rest
  | .use _ :: rest => chk rs als rest
  | .set q _ :: rest => safeW rs rest q && chk rs als rest
  | .alias a p :: rest => chk rs ((a, p) :: als) rest
  | .setvia a _ :: rest =>
    (match findAl als a with
     | some q => safeW rs rest q
     | none => true) && chk rs als rest
  | .call2 p q _ _ :: rest =>
    !overlap p q && safeW rs rest p && safeW rs rest q && chk rs als rest

def accepted (prog : Prog) : Bool := chk [] [] prog

def view (refs : List Ref) : List (Nat × Place) := refs.map (fun e => (e.name, e.place))

/-! ## Stage 3: the protection theorem -/

/-- Loop invariant: every reference that is used later still names what it named at bind time. -/
def Inv (env : Env) (refs : List Ref) (rest : Prog) : Prop :=
  ∀ e ∈ refs, usedLater e.name rest = true → read env e.place = e.snap

theorem usedLater_cons (r : Nat) (i : Stmt) (rest : Prog) :
    usedLater r rest = true → usedLater r (i :: rest) = true := by
  intro h; simp [usedLater] at h ⊢; exact Or.inr h

theorem Inv_tail {env refs i rest} (h : Inv env refs (i :: rest)) : Inv env refs rest :=
  fun e he hu => h e he (usedLater_cons _ _ _ hu)

theorem safeW_spec {refs : List Ref} {rest : Prog} {q : Place}
    (h : safeW (view refs) rest q = true) :
    ∀ e ∈ refs, usedLater e.name rest = true → overlap q e.place = false := by
  intro e he hu
  simp only [safeW, view, List.all_map, List.all_eq_true] at h
  have := h e he
  simpa [hu] using this

theorem Inv_write {env refs rest} (h : Inv env refs rest) {q : Place}
    (hs : safeW (view refs) rest q = true) (w : Val) : Inv (write env q w) refs rest := by
  intro e he hu
  have hov := safeW_spec hs e he hu
  rw [read_write_ne env e.place q w (by rw [overlap_comm]; exact hov)]
  exact h e he hu

theorem findRef_spec : ∀ (l : List Ref) (r : Nat) (e : Ref), findRef l r = some e → e ∈ l ∧ e.name = r := by
  intro l r e
  induction l with
  | nil => simp [findRef]
  | cons a t ih =>
    simp only [findRef]
    split
    · intro h; cases h; simp_all
    · intro h; have := ih h; exact ⟨List.mem_cons_of_mem _ this.1, this.2⟩

/-- Every statement preserves: checker acceptance of the rest, the invariant, and the goodness of the trace. -/
theorem step_ok (s : State) (i : Stmt) (rest : Prog)
    (hc : chk (view s.refs) s.als (i :: rest) = true) (hi : Inv s.env s.refs (i :: rest)) :
    chk (view (step s i).refs) (step s i).als rest = true ∧
    Inv (step s i).env (step s i).refs rest ∧
    (∀ o ∈ (step s i).trace, o ∈ s.trace ∨ o.1 = o.2) := by
  have hit := Inv_tail hi
  cases i with
  | bind r p =>
    refine ⟨by simpa [step, view, chk] using hc, ?_, fun o ho => Or.inl ho⟩
    intro e he hu
    simp only [step, List.mem_cons] at he
    rcases he with rfl | he
    · rfl
    · exact hit e he hu
  | use r =>
    simp only [step]
    cases hf : findRef s.refs r with
    | none => exact ⟨by simpa [chk] using hc, hit, by intro o ho; left; simpa [step, hf] using ho⟩
    | some e =>
      obtain ⟨hm, hn⟩ := findRef_spec _ _ _ hf
      have heq : read s.env e.place = e.snap :=
        hi e hm (by subst hn; simp [usedLater])
      refine ⟨by simpa [step, hf, chk] using hc, by simpa [step, hf] using hit, ?_⟩
      intro o ho
      simp only [step, hf, List.mem_append, List.mem_singleton] at ho
      rcases ho with ho | rfl
      · exact Or.inl ho
      · exact Or.inr heq
  | set q v =>
    simp only [chk, Bool.and_eq_true] at hc
    exact ⟨by simpa [step] using hc.2, by simpa [step] using Inv_write hit hc.1 v, fun o ho => Or.inl ho⟩
  | alias a p =>
    exact ⟨by simpa [step, chk] using hc, by simpa [step] using hit, fun o ho => Or.inl ho⟩
  | setvia a v =>
    simp only [chk, Bool.and_eq_true] at hc
    cases hf : findAl s.als a with
    | none => exact ⟨by simpa [step, hf] using hc.2, by simpa [step, hf] using hit, by intro o ho; left; simpa [step, hf] using ho⟩
    | some q =>
      rw [hf] at hc
      exact ⟨by simpa [step, hf] using hc.2, by simpa [step, hf] using Inv_write hit hc.1 v,
        by intro o ho; left; simpa [step, hf] using ho⟩
  | call2 p q v w =>
    simp only [chk, Bool.and_eq_true] at hc
    obtain ⟨⟨⟨_, hp⟩, hq⟩, hr⟩ := hc
    exact ⟨by simpa [step] using hr, by simpa [step] using Inv_write (Inv_write hit hp v) hq w,
      fun o ho => Or.inl ho⟩

def Good (t : List (Option Val × Option Val)) : Prop := ∀ o ∈ t, o.1 = o.2

theorem run_good : ∀ (prog : Prog) (s : State),
    chk (view s.refs) s.als prog = true → Inv s.env s.refs prog → Good s.trace →
    Good (run s prog).trace := by
  intro prog
  induction prog with
  | nil => intro s _ _ hg; exact hg
  | cons i rest ih =>
    intro s hc hi hg
    obtain ⟨h1, h2, h3⟩ := step_ok s i rest hc hi
    exact ih (step s i) h1 h2 (fun o ho => (h3 o ho).elim (hg o) id)

/-- PROTECTION (S9 / E0308). In an accepted program, from any initial environment, every `use r` observes
exactly the value that was read from the place of `r` when `r` was bound. -/
theorem protection (prog : Prog) (hacc : accepted prog = true) (env : Env) :
    ∀ o ∈ (run (init env) prog).trace, o.1 = o.2 :=
  run_good prog (init env) hacc (by intro e he; simp [init] at he) (by intro o ho; simp [init] at ho)

/-- Reading through the single reference of a one-bind, one-write, one-use program: the accepted shape
`bind; set q; use` forces `q` not to overlap the reference's place. -/
theorem protection_rejects_overlap (r : Nat) (p q : Place) (v : Val) (h : overlap q p = true) :
    accepted [.bind r p, .set q v, .use r] = false := by
  simp [accepted, chk, safeW, usedLater, h]

/-! ## Stage 4: aliases write the original, `inout` exclusivity -/

/-- (a) `let mut a = p; a = v` writes the original place `p`, exactly as `p = v` does. -/
theorem alias_is_set (env : Env) (a : Nat) (p : Place) (v : Val) :
    (run (init env) [.alias a p, .setvia a v]).env = (run (init env) [.set p v]).env := by
  simp [run, step, init, findAl]

theorem alias_writes_original (env : Env) (a : Nat) (p : Place) (v : Val)
    (h : (read env p).isSome = true) :
    read (run (init env) [.alias a p, .setvia a v]).env p = some v := by
  rw [alias_is_set]
  simpa [run, step, init] using read_write_same env p v h

theorem set_set_same (xs : List Val) (i : Nat) (a b : Val) : (xs.set i a).set i b = xs.set i b := by
  apply List.ext_getElem?
  intro n
  by_cases hn : n = i
  · subst hn
    by_cases hl : n < xs.length <;> simp [hl]
  · rw [List.getElem?_set_ne (Ne.symm hn), List.getElem?_set_ne (Ne.symm hn), List.getElem?_set_ne (Ne.symm hn)]

theorem set_set_comm (xs : List Val) {i j : Nat} (hij : i ≠ j) (a b : Val) :
    (xs.set i a).set j b = (xs.set j b).set i a := by
  apply List.ext_getElem?
  intro n
  simp only [List.getElem?_set]
  by_cases hn : i = n
  · subst hn; have : ¬ j = i := fun h => hij h.symm
    simp [this]
  · by_cases hm : j = n
    · subst hm; simp [hn]
    · simp [hn, hm]

/-- Writes to non-overlapping paths of one value commute. -/
theorem put_put_comm : ∀ (p q : List Nat) (a v w : Val),
    isPre p q = false → isPre q p = false → (a.put p v).put q w = (a.put q w).put p v := by
  intro p
  induction p with
  | nil => intro q a v w h; simp [isPre] at h
  | cons i ps ih =>
    intro q a v w h1 h2
    cases q with
    | nil => simp [isPre] at h2
    | cons j qs =>
      cases a with
      | int n => simp [Val.put]
      | list xs =>
        by_cases hij : i = j
        · subst hij
          have h1' : isPre ps qs = false := by
            cases h : isPre ps qs <;> simp_all [isPre]
          have h2' : isPre qs ps = false := by
            cases h : isPre qs ps <;> simp_all [isPre]
          cases hc : xs[i]? with
          | none => simp only [put_cons_none hc]
          | some c =>
            rw [put_cons_some hc, put_cons_some (set_getElem_self hc _), put_cons_some hc,
              put_cons_some (set_getElem_self hc _), set_set_same, set_set_same, ih qs c v w h1' h2']
        · cases hx : xs[i]? with
          | none =>
            cases hy : xs[j]? with
            | none => simp only [put_cons_none hx, put_cons_none hy]
            | some d =>
              have hx' : (xs.set j (d.put qs w))[i]? = none := by rw [List.getElem?_set_ne (Ne.symm hij)]; exact hx
              simp only [put_cons_none hx, put_cons_some hy, put_cons_none hx']
          | some c =>
            have hy' : (xs.set i (c.put ps v))[j]? = xs[j]? := List.getElem?_set_ne hij
            cases hy : xs[j]? with
            | none =>
              have hy'' : (xs.set i (c.put ps v))[j]? = none := by rw [hy']; exact hy
              simp only [put_cons_some hx, put_cons_none hy, put_cons_none hy'']
            | some d =>
              have hy'' : (xs.set i (c.put ps v))[j]? = some d := by rw [hy']; exact hy
              have hx'' : (xs.set j (d.put qs w))[i]? = some c := by
                rw [List.getElem?_set_ne (Ne.symm hij)]; exact hx
              rw [put_cons_some hx, put_cons_some hy'', put_cons_some hy, put_cons_some hx'',
                set_set_comm xs hij]

/-- (b) EXCLUSIVITY. Two writes to places that do not overlap commute: the outcome of
`f(inout p, inout q)` does not depend on the order in which the body writes them. -/
theorem write_comm (env : Env) (p q : Place) (v w : Val) (h : overlap p q = false) :
    write (write env p v) q w = write (write env q w) p v := by
  rcases (overlap_false_iff p q).mp h with hr | ⟨h1, h2⟩
  · funext x
    simp only [write]
    by_cases hp : x = p.root
    · subst hp; simp [hr]
    · by_cases hq : x = q.root
      · subst hq; simp [hp, Ne.symm hr]
      · simp [hp, hq]
  · obtain ⟨px, pp⟩ := p
    obtain ⟨qx, qp⟩ := q
    dsimp only at h1 h2 ⊢
    funext x
    simp only [write]
    by_cases hp : x = px
    · by_cases hq : x = qx
      · subst hp; subst hq
        cases he : env x with
        | none => simp [he]
        | some a => simp [he, put_put_comm pp qp a v w h1 h2]
      · subst hp; simp [hq]
    · by_cases hq : x = qx
      · subst hq; simp [hp]
      · simp [hp, hq]

/-- The semantics of `call2` is order independent. -/
theorem call2_order (s : State) (p q : Place) (v w : Val) (h : overlap p q = false) :
    (step s (.call2 p q v w)).env = (step s (.call2 q p w v)).env := by
  simp [step, write_comm s.env p q v w h]

/-- Exclusivity: a write through one place does not change what the other reads, and after the call
each place reads what its own write produced. -/
theorem call2_exclusive (env : Env) (p q : Place) (v w : Val) (h : overlap p q = false) :
    read (write env p v) q = read env q ∧ read (write env q w) p = read env p ∧
    read (write (write env p v) q w) p = read (write env p v) p ∧
    read (write (write env p v) q w) q = read (write env q w) q := by
  have h' : overlap q p = false := by rw [overlap_comm]; exact h
  refine ⟨read_write_ne env q p v h', read_write_ne env p q w h, ?_, ?_⟩
  · exact read_write_ne (write env p v) p q w h
  · rw [write_comm env p q v w h]
    exact read_write_ne (write env q w) q p v h'

/-- The checker rejects `call2` on overlapping places (S7 / E0301). -/
theorem call2_checked (p q : Place) (v w : Val) (h : overlap p q = true) :
    accepted [.call2 p q v w] = false := by
  simp [accepted, chk, h]

end Stage3
end Eider
