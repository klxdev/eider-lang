/-!
# Stage 5 of the formal model (docs/design/formal-model.md): a buffer is never reachable from two threads

Buffer reference counts (`ei_buf_inc`, `ei_buf_dec` in core/eider_rt.c) are NOT atomic. That is sound only because
no buffer is ever reachable from two threads (rule S11 of docs/design/memory-safety.md; core/RUNTIME.md
"Threads"): every value that crosses to another thread (spawn arguments, channel send, Mutex store, ...) first goes
through generated glue that makes it DEEPLY UNIQUE, a fresh deep copy of the whole buffer graph. This file is the
multi-thread extension of the Stage 2 model (copy-on-write buffers with reference counts) and proves that rule.

## The model

* `Val := int n | buf b`: a cell holds an integer or the id of another buffer (so buffers nest: lists of lists).
* `St`: `env : Thread → Var → Option BufId` (thread `t`'s variable to a buffer id), one global
  `heap : BufId → Option (count, cells)`, and `next` (the next fresh id; a freed id is never reused).
* `Reach s t b` (inductive): `b` is bound to a variable of thread `t`, or a cell of a reachable (live) buffer holds
  `buf b`.
* Steps (`Step`, `step`), acting thread `t`: `new` (release the old value, then a fresh buffer with count 1),
  `share t d src` (`ei_share_String`: increment, release the old `d`, bind), `write t x i n` (`ei_str_unique` then
  the store: in place if the count is 1, else a fresh copy replaces the buffer for `x` and the old count is
  decremented), `nest t x i y` (the same store, but the cell receives `buf b_y`: count of `b_y` incremented; this is
  how graphs with nested buffers arise), `drop t x` (`ei_drop_String`), and the crossing `send k t x u y`: a deep
  copy (`cpBuf`) of the buffer graph reachable from `t`'s variable `x`, into FRESH ids, whose root is bound to
  variable `y` of thread `u`.

## Simplifications (deviations from the C runtime), all conservative for the theorem

* `release` decrements and frees only the buffer bound to the variable; it does not recursively drop the buffers
  held in its cells (a leak in the model; freeing only shrinks reachability, so nothing is lost for S11).
* `send` binds `y` of `u` without releasing `u`'s old value of `y` (the receiver drops it itself; a `drop u y`
  before the receive is an ordinary step).
* The deep copy is bounded by the depth `k` (a parameter of `send`): a node at depth `k` or a dead id is replaced by
  a fresh EMPTY buffer. For graphs of depth `< k` this is the exact deep copy, and the copy duplicates a node
  reached twice (a tree unfolding, i.e. value semantics). Only the fresh-id and closure properties (`cpBuf_ok`) are
  proved about the copy, not its shape; that is all S11 needs. All copied counts are 1.
* Counts are not tracked as an invariant here (that is Stage 2's `Inv`, I3); this stage is about WHO can reach what.
  The runtime check that blocks the in-place write on a shared buffer is the Stage 2 result.

## Results

* `Inv s := Disjoint s ∧ Bounded s`, where `Disjoint s` says that for `t ≠ u` no buffer id is reachable from both,
  and `Bounded s` says that every reachable id is below `next` (ids from `next` on are unallocated: a fresh id is
  really fresh).
* `inv_empty`, `step_inv`, `disjoint_run` (THE THEOREM, S11): `Disjoint` holds initially and is preserved by every
  step, so it holds in every reachable state.
* `step_foot_reach`, `step_writes`, `no_race` (the corollary): every buffer whose count or cells a step of thread `t`
  reads or writes is in `Reach s t` (or a freshly allocated id), so by `Disjoint` two threads never touch the same
  count or cell: no data race on a non-atomic count.
* `unsafe_send_breaks_disjoint` (the NEGATIVE result): without the deep copy (binding the shared buffer id itself)
  `Disjoint` is not preserved, with a concrete 1-buffer counterexample. This is why the list of crossing points must
  be complete.
-/
namespace Eider
namespace Stage5

def upd {α : Type} (f : Nat → α) (k : Nat) (v : α) : Nat → α :=
  fun j => if j = k then v else f j

theorem upd_same {α : Type} (f : Nat → α) (k : Nat) (v : α) : upd f k v k = v := by simp [upd]

theorem upd_ne {α : Type} (f : Nat → α) {k j : Nat} (v : α) (h : j ≠ k) : upd f k v j = f j := by
  simp [upd, h]

inductive Val where
  | int (n : Int)
  | buf (b : Nat)

abbrev Heap := Nat → Option (Nat × List Val)

structure St where
  env : Nat → Nat → Option Nat
  heap : Heap
  next : Nat

def St.empty : St := ⟨fun _ _ => none, fun _ => none, 0⟩

/-- Rebinding variable `x` of thread `t` in the two-level environment. -/
def bindE (e : Nat → Nat → Option Nat) (t x : Nat) (o : Option Nat) : Nat → Nat → Option Nat :=
  fun w y => if w = t ∧ y = x then o else e w y

theorem bindE_same (e : Nat → Nat → Option Nat) (t x : Nat) (o : Option Nat) : bindE e t x o t x = o := by
  simp [bindE]

theorem bindE_ne_thread (e : Nat → Nat → Option Nat) {t x w : Nat} (o : Option Nat) (h : w ≠ t) (y : Nat) :
    bindE e t x o w y = e w y := by
  simp [bindE, h]

theorem bindE_ne_var (e : Nat → Nat → Option Nat) {t x y : Nat} (o : Option Nat) (h : y ≠ x) :
    bindE e t x o t y = e t y := by
  simp [bindE, h]

/-! ## Reachability and the invariant -/

/-- `b` is reachable from thread `t`: bound by a variable, or held in a cell of a reachable live buffer. -/
inductive Reach (s : St) (t : Nat) : Nat → Prop where
  | var {x b : Nat} : s.env t x = some b → Reach s t b
  | cell {b' c b : Nat} {cs : List Val} :
      Reach s t b' → s.heap b' = some (c, cs) → Val.buf b ∈ cs → Reach s t b

/-- S11: no buffer id is reachable from two different threads. -/
def Disjoint (s : St) : Prop := ∀ t u b, t ≠ u → Reach s t b → Reach s u b → False

/-- Every bound id and every id held in a live cell is below `next` (so `next` is fresh). -/
def Bounded (s : St) : Prop :=
  (∀ t x b, s.env t x = some b → b < s.next) ∧
  (∀ j c cs b, s.heap j = some (c, cs) → Val.buf b ∈ cs → b < s.next)

def Inv (s : St) : Prop := Disjoint s ∧ Bounded s

theorem reach_lt {s : St} (hB : Bounded s) {t b : Nat} (h : Reach s t b) : b < s.next := by
  induction h with
  | var h => exact hB.1 _ _ _ h
  | cell _ hc hm _ => exact hB.2 _ _ _ _ hc hm

theorem inv_empty : Inv St.empty := by
  refine ⟨?_, ?_, ?_⟩
  · intro t u b _ h _
    cases h with
    | var h => simp [St.empty] at h
    | cell _ hc _ => simp [St.empty] at hc
  · intro t x b h; simp [St.empty] at h
  · intro j c cs b h; simp [St.empty] at h

/-- A transition of the state by thread `u` that keeps `Inv`, only grows `u`'s reach by fresh ids, and writes
only buffers reachable from `u` (or fresh ones). -/
structure Safe (u : Nat) (s s' : St) : Prop where
  inv : Inv s'
  grow : ∀ b, Reach s' u b → Reach s u b ∨ s.next ≤ b
  writes : ∀ j, s'.heap j ≠ s.heap j → Reach s u j ∨ s.next ≤ j
  next_le : s.next ≤ s'.next

theorem Safe.refl {u : Nat} {s : St} (h : Inv s) : Safe u s s :=
  ⟨h, fun _ hb => Or.inl hb, fun _ hj => absurd rfl hj, Nat.le_refl _⟩

theorem Safe.trans {u : Nat} {s s1 s2 : St} (h1 : Safe u s s1) (h2 : Safe u s1 s2) : Safe u s s2 := by
  refine ⟨h2.inv, ?_, ?_, Nat.le_trans h1.next_le h2.next_le⟩
  · intro b hb
    rcases h2.grow b hb with h | h
    · rcases h1.grow b h with h | h
      · exact Or.inl h
      · exact Or.inr h
    · exact Or.inr (Nat.le_trans h1.next_le h)
  · intro j hj
    by_cases h : s2.heap j = s1.heap j
    · have : s1.heap j ≠ s.heap j := by rw [← h]; exact hj
      exact h1.writes j this
    · rcases h2.writes j h with h | h
      · rcases h1.grow j h with h | h
        · exact Or.inl h
        · exact Or.inr h
      · exact Or.inr (Nat.le_trans h1.next_le h)

/-- The workhorse: a transition by thread `u` is `Safe` when it changes only `u`'s environment, writes only
reachable-from-`u` or fresh buffers, and everything `u` can reach afterwards is old-reachable or fresh. -/
theorem safe_intro {s s' : St} {u : Nat} (hI : Inv s)
    (he : ∀ w, w ≠ u → s'.env w = s.env w) (hn : s.next ≤ s'.next)
    (hh : ∀ j, s'.heap j ≠ s.heap j → Reach s u j ∨ s.next ≤ j)
    (hE : ∀ x b, s'.env u x = some b → Reach s u b ∨ (s.next ≤ b ∧ b < s'.next))
    (hH : ∀ j c cs b, s'.heap j = some (c, cs) → Val.buf b ∈ cs →
      (Reach s u j ∨ (s.next ≤ j ∧ j < s'.next)) → (Reach s u b ∨ (s.next ≤ b ∧ b < s'.next)))
    (hB : Bounded s') : Safe u s s' := by
  have grow : ∀ b, Reach s' u b → Reach s u b ∨ (s.next ≤ b ∧ b < s'.next) := by
    intro b h
    induction h with
    | var h => exact hE _ _ h
    | cell _ hc hm ih => exact hH _ _ _ _ hc hm ih
  have frame : ∀ w, w ≠ u → ∀ b, Reach s' w b → Reach s w b := by
    intro w hw b h
    induction h with
    | var h => exact Reach.var (by rw [← he w hw]; exact h)
    | cell hr hc hm ih =>
      rename_i b' c b cs
      have hsame : s'.heap b' = s.heap b' := by
        refine Classical.byContradiction fun hne => ?_
        rcases hh b' hne with h | h
        · exact hI.1 u w b' (Ne.symm hw) h ih
        · have := reach_lt hI.2 ih; omega
      exact Reach.cell ih (by rw [← hsame]; exact hc) hm
  refine ⟨⟨?_, hB⟩, ?_, hh, hn⟩
  · intro t w b htw h1 h2
    by_cases ht : t = u
    · subst ht
      have h2' := frame w (Ne.symm htw) b h2
      rcases grow b h1 with h | h
      · exact hI.1 t w b htw h h2'
      · have := reach_lt hI.2 h2'; omega
    · by_cases hw : w = u
      · subst hw
        have h1' := frame t ht b h1
        rcases grow b h2 with h | h
        · exact hI.1 t w b htw h1' h
        · have := reach_lt hI.2 h1'; omega
      · exact hI.1 t w b htw (frame t ht b h1) (frame w hw b h2)
  · intro b hb
    rcases grow b hb with h | h
    · exact Or.inl h
    · exact Or.inr h.1

/-! ## The primitive operations -/

/-- Change the count of buffer `b` with `g` (`none` frees it); the cells are untouched. -/
def countOp (s : St) (b : Nat) (g : Nat → Option Nat) : St :=
  match s.heap b with
  | some (c, cs) => { s with heap := upd s.heap b ((g c).map fun c' => (c', cs)) }
  | none => s

/-- `ei_buf_inc`. -/
abbrev incOp (s : St) (b : Nat) : St := countOp s b (fun c => some (c + 1))

/-- `ei_buf_dec`: free at count 1 (or 0). -/
abbrev decOp (s : St) (b : Nat) : St := countOp s b (fun c => if c ≤ 1 then none else some (c - 1))

theorem countOp_env (s : St) (b : Nat) (g : Nat → Option Nat) : (countOp s b g).env = s.env := by
  unfold countOp; split <;> rfl

theorem countOp_next (s : St) (b : Nat) (g : Nat → Option Nat) : (countOp s b g).next = s.next := by
  unfold countOp; split <;> rfl

theorem countOp_cells {s : St} {b j c' : Nat} {g : Nat → Option Nat} {cs : List Val}
    (h : (countOp s b g).heap j = some (c', cs)) : ∃ c0, s.heap j = some (c0, cs) := by
  unfold countOp at h
  split at h
  · rename_i c cs0 heq
    by_cases hj : j = b
    · subst hj
      simp only [upd_same] at h
      cases hg : g c with
      | none => simp [hg] at h
      | some c2 =>
        simp [hg] at h
        exact ⟨c, by rw [heq, h.2]⟩
    · exact ⟨c', by simpa [upd, hj] using h⟩
  · exact ⟨c', h⟩

theorem countOp_safe {s : St} {t b : Nat} (g : Nat → Option Nat) (hI : Inv s) (hb : Reach s t b) :
    Safe t s (countOp s b g) := by
  have hE := countOp_env s b g
  have hN := countOp_next s b g
  apply safe_intro hI
  · intro w _; rw [hE]
  · rw [hN]; exact Nat.le_refl _
  · intro j hj
    by_cases hjb : j = b
    · subst hjb; exact Or.inl hb
    · exfalso; apply hj
      unfold countOp; split
      · simp [upd, hjb]
      · rfl
  · intro x b' h; rw [hE] at h; exact Or.inl (Reach.var h)
  · intro j c cs b' h hm hj
    rw [hN] at hj
    have hj' : Reach s t j := by
      rcases hj with hj | hj
      · exact hj
      · omega
    obtain ⟨c0, hc0⟩ := countOp_cells h
    exact Or.inl (Reach.cell hj' hc0 hm)
  · refine ⟨?_, ?_⟩
    · intro t' x b' h; rw [hE] at h; rw [hN]; exact hI.2.1 _ _ _ h
    · intro j c cs b' h hm
      rw [hN]
      obtain ⟨c0, hc0⟩ := countOp_cells h
      exact hI.2.2 _ _ _ _ hc0 hm

/-- Unbind variable `x` of thread `t`. -/
def unbind (s : St) (t x : Nat) : St := { s with env := bindE s.env t x none }

theorem unbind_safe {s : St} (t x : Nat) (hI : Inv s) : Safe t s (unbind s t x) := by
  apply safe_intro hI
  · intro w hw; exact funext fun y => bindE_ne_thread _ _ hw y
  · exact Nat.le_refl _
  · intro j hj; exact absurd rfl hj
  · intro z b h
    by_cases hz : z = x
    · subst hz; simp [unbind, bindE_same] at h
    · exact Or.inl (Reach.var (by simpa [unbind, bindE_ne_var _ _ hz] using h))
  · intro j c cs b h hm hj
    have : Reach s t j := by
      rcases hj with hj | hj
      · exact hj
      · have : s.next ≤ j ∧ j < s.next := hj; omega
    exact Or.inl (Reach.cell this h hm)
  · refine ⟨?_, ?_⟩
    · intro t' z b h
      by_cases ht : t' = t
      · subst ht
        by_cases hz : z = x
        · subst hz; simp [unbind, bindE_same] at h
        · exact hI.2.1 _ _ _ (by simpa [unbind, bindE_ne_var _ _ hz] using h)
      · exact hI.2.1 _ _ _ (by simpa [unbind, bindE_ne_thread _ _ ht] using h)
    · exact hI.2.2

/-- Bind variable `d` of thread `t` to an already reachable buffer `b`. -/
def bindTo (s : St) (t d b : Nat) : St := { s with env := bindE s.env t d (some b) }

theorem bindTo_safe {s : St} {t d b : Nat} (hI : Inv s) (hb : Reach s t b) : Safe t s (bindTo s t d b) := by
  apply safe_intro hI
  · intro w hw; exact funext fun y => bindE_ne_thread _ _ hw y
  · exact Nat.le_refl _
  · intro j hj; exact absurd rfl hj
  · intro z b' h
    by_cases hz : z = d
    · subst hz
      have : b' = b := by simpa [bindTo, bindE_same] using h.symm
      subst this; exact Or.inl hb
    · exact Or.inl (Reach.var (by simpa [bindTo, bindE_ne_var _ _ hz] using h))
  · intro j c cs b' h hm hj
    have : Reach s t j := by
      rcases hj with hj | hj
      · exact hj
      · have : s.next ≤ j ∧ j < s.next := hj; omega
    exact Or.inl (Reach.cell this h hm)
  · refine ⟨?_, hI.2.2⟩
    intro t' z b' h
    by_cases ht : t' = t
    · subst ht
      by_cases hz : z = d
      · subst hz
        have : b' = b := by simpa [bindTo, bindE_same] using h.symm
        subst this; exact reach_lt hI.2 hb
      · exact hI.2.1 _ _ _ (by simpa [bindTo, bindE_ne_var _ _ hz] using h)
    · exact hI.2.1 _ _ _ (by simpa [bindTo, bindE_ne_thread _ _ ht] using h)

/-- `ei_drop_String`: decrement (free at zero) and unbind. -/
def release (s : St) (t x : Nat) : St :=
  match s.env t x with
  | none => s
  | some o => unbind (decOp s o) t x

theorem release_safe {s : St} (t x : Nat) (hI : Inv s) : Safe t s (release s t x) := by
  unfold release
  split
  · exact Safe.refl hI
  · rename_i o heq
    exact (countOp_safe _ hI (Reach.var heq)).trans (unbind_safe t x (countOp_safe _ hI (Reach.var heq)).inv)

/-- `str_new`: a fresh buffer with count 1 holding integers, bound to `x`. -/
def alloc (s : St) (t x : Nat) (xs : List Int) : St :=
  { env := bindE s.env t x (some s.next),
    heap := upd s.heap s.next (some (1, xs.map Val.int)),
    next := s.next + 1 }

theorem alloc_safe {s : St} (t x : Nat) (xs : List Int) (hI : Inv s) : Safe t s (alloc s t x xs) := by
  apply safe_intro hI
  · intro w hw; exact funext fun y => bindE_ne_thread _ _ hw y
  · show s.next ≤ s.next + 1; omega
  · intro j hj
    by_cases h : j = s.next
    · exact Or.inr (by omega)
    · exfalso; apply hj; simp [alloc, upd, h]
  · intro z b h
    by_cases hz : z = x
    · subst hz
      have : b = s.next := by simpa [alloc, bindE_same] using h.symm
      subst this; exact Or.inr ⟨Nat.le_refl _, by simp [alloc]⟩
    · exact Or.inl (Reach.var (by simpa [alloc, bindE_ne_var _ _ hz] using h))
  · intro j c cs b h hm hj
    by_cases hjn : j = s.next
    · subst hjn
      simp [alloc, upd] at h
      obtain ⟨_, rfl⟩ := h
      simp at hm
    · have hj' : Reach s t j := by
        rcases hj with hj | hj
        · exact hj
        · have : j < s.next + 1 := hj.2
          have : s.next ≤ j := hj.1
          omega
      have h' : s.heap j = some (c, cs) := by simpa [alloc, upd, hjn] using h
      exact Or.inl (Reach.cell hj' h' hm)
  · refine ⟨?_, ?_⟩
    · intro t' z b h
      by_cases ht : t' = t
      · subst ht
        by_cases hz : z = x
        · subst hz
          have : b = s.next := by simpa [alloc, bindE_same] using h.symm
          subst this; show s.next < s.next + 1; omega
        · have := hI.2.1 _ _ _ (by simpa [alloc, bindE_ne_var _ _ hz] using h)
          show b < s.next + 1; omega
      · have := hI.2.1 _ _ _ (by simpa [alloc, bindE_ne_thread _ _ ht] using h)
        show b < s.next + 1; omega
    · intro j c cs b h hm
      show b < s.next + 1
      by_cases hjn : j = s.next
      · subst hjn
        simp [alloc, upd] at h
        obtain ⟨_, rfl⟩ := h
        simp at hm
      · have h' : s.heap j = some (c, cs) := by simpa [alloc, upd, hjn] using h
        have := hI.2.2 _ _ _ _ h' hm
        omega

/-- `new x xs`: release the old `x`, then allocate. -/
def newS (s : St) (t x : Nat) (xs : List Int) : St := alloc (release s t x) t x xs

/-- `share d src` (`ei_share_String` then assignment): increment first, then release the old `d`'s buffer, then
bind. An unbound `src` just releases `d`. -/
def shareS (s : St) (t d src : Nat) : St :=
  match s.env t src with
  | none => release s t d
  | some b =>
    let s1 := incOp s b
    let s2 := match s.env t d with
      | none => s1
      | some o => decOp s1 o
    bindTo s2 t d b

theorem shareS_safe {s : St} (t d src : Nat) (hI : Inv s) : Safe t s (shareS s t d src) := by
  unfold shareS
  split
  · exact release_safe t d hI
  · rename_i b hsrc
    have h1 := countOp_safe (t := t) (fun c => some (c + 1)) hI (Reach.var hsrc)
    have henv1 : (countOp s b (fun c => some (c + 1))).env = s.env := countOp_env _ _ _
    have h2 : Safe t (countOp s b (fun c => some (c + 1)))
        (match s.env t d with
          | none => countOp s b (fun c => some (c + 1))
          | some o => countOp (countOp s b (fun c => some (c + 1))) o
              (fun c => if c ≤ 1 then none else some (c - 1))) := by
      split
      · exact Safe.refl h1.inv
      · rename_i o hd
        exact countOp_safe _ h1.inv (Reach.var (by rw [henv1]; exact hd))
    have henv2 : (match s.env t d with
          | none => countOp s b (fun c => some (c + 1))
          | some o => countOp (countOp s b (fun c => some (c + 1))) o
              (fun c => if c ≤ 1 then none else some (c - 1))).env = s.env := by
      split
      · exact henv1
      · rw [countOp_env, henv1]
    exact (h1.trans h2).trans (bindTo_safe h2.inv (Reach.var (by rw [henv2]; exact hsrc)))

/-- `ei_str_unique` and the store of `v` into cell `i` of `x`: in place when the count is 1, otherwise a fresh
copy replaces the buffer for `x` and the old count is decremented. -/
def setCell (s : St) (t x i : Nat) (v : Val) : St :=
  match s.env t x with
  | none => s
  | some b =>
    match s.heap b with
    | none => s
    | some (c, cs) =>
      if c = 1 then { s with heap := upd s.heap b (some (1, cs.set i v)) }
      else
        { env := bindE s.env t x (some s.next),
          heap := upd (upd s.heap b (some (c - 1, cs))) s.next (some (1, cs.set i v)),
          next := s.next + 1 }

theorem mem_set_cases {cs : List Val} {i : Nat} {v w : Val} (h : w ∈ cs.set i v) : w ∈ cs ∨ w = v :=
  List.mem_or_eq_of_mem_set h

theorem setCell_safe {s : St} {t : Nat} (x i : Nat) {v : Val} (hI : Inv s)
    (hv : ∀ r, v = Val.buf r → Reach s t r) : Safe t s (setCell s t x i v) := by
  unfold setCell
  split
  · exact Safe.refl hI
  · rename_i b hx
    split
    · exact Safe.refl hI
    · rename_i c cs hb
      have hbn : b < s.next := hI.2.1 _ _ _ hx
      have hrb : Reach s t b := Reach.var hx
      -- everything stored in the new cells is reachable
      have hcs : ∀ r, Val.buf r ∈ cs.set i v → Reach s t r := by
        intro r hr
        rcases mem_set_cases hr with h | h
        · exact Reach.cell hrb hb h
        · exact hv r h.symm
      have hcslt : ∀ r, Val.buf r ∈ cs.set i v → r < s.next := fun r hr => reach_lt hI.2 (hcs r hr)
      by_cases hc : c = 1
      · simp only [hc, ↓reduceIte]
        apply safe_intro hI
        · intro w _; rfl
        · exact Nat.le_refl _
        · intro j hj
          by_cases hjb : j = b
          · subst hjb; exact Or.inl hrb
          · exfalso; apply hj; simp [upd, hjb]
        · intro z b' h; exact Or.inl (Reach.var h)
        · intro j c' cs' b' h hm hj
          have hj' : Reach s t j := by
            rcases hj with hj | hj
            · exact hj
            · have h1 := hj.1; have h2 : j < s.next := hj.2; omega
          by_cases hjb : j = b
          · subst hjb
            simp only [upd_same] at h
            have : cs' = cs.set i v := by simp at h; exact h.2.symm
            subst this
            exact Or.inl (hcs _ hm)
          · have h' : s.heap j = some (c', cs') := by simpa [upd, hjb] using h
            exact Or.inl (Reach.cell hj' h' hm)
        · refine ⟨hI.2.1, ?_⟩
          intro j c' cs' b' h hm
          by_cases hjb : j = b
          · subst hjb
            simp only [upd_same] at h
            have : cs' = cs.set i v := by simp at h; exact h.2.symm
            subst this
            exact hcslt _ hm
          · have h' : s.heap j = some (c', cs') := by simpa [upd, hjb] using h
            exact hI.2.2 _ _ _ _ h' hm
      · simp only [hc, ↓reduceIte]
        have hbne : b ≠ s.next := by omega
        apply safe_intro hI
        · intro w hw; exact funext fun y => bindE_ne_thread _ _ hw y
        · show s.next ≤ s.next + 1; omega
        · intro j hj
          by_cases hjn : j = s.next
          · exact Or.inr (by omega)
          · by_cases hjb : j = b
            · subst hjb; exact Or.inl hrb
            · exfalso; apply hj; simp [upd, hjn, hjb]
        · intro z b' h
          by_cases hz : z = x
          · subst hz
            have : b' = s.next := by simpa [bindE_same] using h.symm
            subst this; exact Or.inr ⟨Nat.le_refl _, by show s.next < s.next + 1; omega⟩
          · exact Or.inl (Reach.var (by simpa [bindE_ne_var _ _ hz] using h))
        · intro j c' cs' b' h hm hj
          by_cases hjn : j = s.next
          · subst hjn
            have h2 : cs' = cs.set i v := by simp [upd] at h; exact h.2.symm
            subst h2
            exact Or.inl (hcs _ hm)
          · have hj' : Reach s t j := by
              rcases hj with hj | hj
              · exact hj
              · have h1 := hj.1; have h2 : j < s.next + 1 := hj.2; omega
            by_cases hjb : j = b
            · subst hjb
              have h2 : cs' = cs := by simp [upd, hjn] at h; exact h.2.symm
              subst h2
              exact Or.inl (Reach.cell hj' hb hm)
            · have h' : s.heap j = some (c', cs') := by simpa [upd, hjn, hjb] using h
              exact Or.inl (Reach.cell hj' h' hm)
        · refine ⟨?_, ?_⟩
          · intro t' z b' h
            by_cases ht : t' = t
            · subst ht
              by_cases hz : z = x
              · subst hz
                have : b' = s.next := by simpa [bindE_same] using h.symm
                subst this; show s.next < s.next + 1; omega
              · have := hI.2.1 _ _ _ (by simpa [bindE_ne_var _ _ hz] using h)
                show b' < s.next + 1; omega
            · have := hI.2.1 _ _ _ (by simpa [bindE_ne_thread _ _ ht] using h)
              show b' < s.next + 1; omega
          · intro j c' cs' b' h hm
            show b' < s.next + 1
            by_cases hjn : j = s.next
            · subst hjn
              have h2 : cs' = cs.set i v := by simp [upd] at h; exact h.2.symm
              subst h2
              have := hcslt _ hm; omega
            · by_cases hjb : j = b
              · subst hjb
                have h2 : cs' = cs := by simp [upd, hjn] at h; exact h.2.symm
                subst h2
                have := hI.2.2 _ _ _ _ hb hm; omega
              · have h' : s.heap j = some (c', cs') := by simpa [upd, hjn, hjb] using h
                have := hI.2.2 _ _ _ _ h' hm; omega

/-- `write x i n`. -/
def writeS (s : St) (t x i : Nat) (n : Int) : St := setCell s t x i (Val.int n)

/-- `nest x i y`: store `buf (buffer of y)` into cell `i` of `x`, incrementing the count of `y`'s buffer. -/
def nestS (s : St) (t x i y : Nat) : St :=
  match s.env t y with
  | none => s
  | some r => setCell (incOp s r) t x i (Val.buf r)

theorem nestS_safe {s : St} (t x i y : Nat) (hI : Inv s) : Safe t s (nestS s t x i y) := by
  unfold nestS
  split
  · exact Safe.refl hI
  · rename_i r hy
    have h1 := countOp_safe (t := t) (fun c => some (c + 1)) hI (Reach.var hy)
    have henv1 : (countOp s r (fun c => some (c + 1))).env = s.env := countOp_env _ _ _
    exact h1.trans (setCell_safe x i h1.inv (fun r' hr' => by
      cases hr'; exact Reach.var (by rw [henv1]; exact hy)))

/-! ## The deep copy at a crossing -/

structure Cp (α : Type) where
  nx : Nat
  heap : Heap
  out : α

/-- Copy a list of cells: ints stay, buffers are copied by `f` (the copy of one buffer). -/
def cpList (f : Nat → Heap → Nat → Cp Nat) : Nat → Heap → List Val → Cp (List Val)
  | nx, H, [] => ⟨nx, H, []⟩
  | nx, H, Val.int n :: vs =>
    let r2 := cpList f nx H vs
    ⟨r2.nx, r2.heap, Val.int n :: r2.out⟩
  | nx, H, Val.buf b :: vs =>
    let r1 := f nx H b
    let r2 := cpList f r1.nx r1.heap vs
    ⟨r2.nx, r2.heap, Val.buf r1.out :: r2.out⟩

/-- A fresh empty buffer with count 1 at id `nx` (the cut-off of the copy at depth `k`, or a dead id). -/
def leaf (nx : Nat) (H : Heap) : Cp Nat := ⟨nx + 1, upd H nx (some (1, [])), nx⟩

/-- `cpBuf h k nx H b`: deep copy of the graph of `h` below buffer `b` down to depth `k`; new buffers get the
ids `nx, nx+1, ...` and are written into `H`. Returns the next fresh id, the new heap and the id of the copy of `b`. -/
def cpBuf (h : Heap) : Nat → Nat → Heap → Nat → Cp Nat
  | 0, nx, H, _ => leaf nx H
  | k + 1, nx, H, b =>
    match h b with
    | none => leaf nx H
    | some (_, cells) =>
      let r1 := cpList (cpBuf h k) nx H cells
      ⟨r1.nx + 1, upd r1.heap r1.nx (some (1, r1.out)), r1.nx⟩

/-- `lo ≤ b < hi` for every buffer id in the cell. -/
def VI (lo hi : Nat) (w : Val) : Prop := ∀ b, w = Val.buf b → lo ≤ b ∧ b < hi

theorem VI_mono {lo hi lo' hi' : Nat} {w : Val} (h : VI lo hi w) (h1 : lo' ≤ lo) (h2 : hi ≤ hi') : VI lo' hi' w := by
  intro b hb; have := h b hb; omega

/-- `H'` extends `H` from `nx` to `nx'` only: ids below `nx` or from `nx'` on are unchanged, and the new ids
`[nx, nx')` are live buffers all of whose cells point into `[nx, nx')`. -/
def OkP (nx : Nat) (H : Heap) (nx' : Nat) (H' : Heap) : Prop :=
  nx ≤ nx' ∧ (∀ j, (j < nx ∨ nx' ≤ j) → H' j = H j) ∧
  (∀ j, nx ≤ j → j < nx' → ∃ c cs, H' j = some (c, cs) ∧ ∀ w ∈ cs, VI nx nx' w)

theorem okp_seq {a b c : Nat} {H H1 H2 : Heap} (h1 : OkP a H b H1) (h2 : OkP b H1 c H2) : OkP a H c H2 := by
  obtain ⟨l1, f1, r1⟩ := h1
  obtain ⟨l2, f2, r2⟩ := h2
  refine ⟨by omega, ?_, ?_⟩
  · intro j hj
    rw [f2 j (by omega), f1 j (by omega)]
  · intro j hj1 hj2
    by_cases hjb : j < b
    · obtain ⟨c0, cs, hc, hw⟩ := r1 j hj1 hjb
      exact ⟨c0, cs, by rw [f2 j (by omega)]; exact hc, fun w hw' => VI_mono (hw w hw') (Nat.le_refl _) l2⟩
    · obtain ⟨c0, cs, hc, hw⟩ := r2 j (by omega) hj2
      exact ⟨c0, cs, hc, fun w hw' => VI_mono (hw w hw') l1 (Nat.le_refl _)⟩

theorem okp_refl (a : Nat) (H : Heap) : OkP a H a H := by
  refine ⟨Nat.le_refl _, fun _ _ => rfl, fun j h1 h2 => by omega⟩

theorem cpList_ok (f : Nat → Heap → Nat → Cp Nat)
    (hf : ∀ nx H b, OkP nx H (f nx H b).nx (f nx H b).heap ∧ nx ≤ (f nx H b).out ∧ (f nx H b).out < (f nx H b).nx) :
    ∀ (vs : List Val) (nx : Nat) (H : Heap),
      OkP nx H (cpList f nx H vs).nx (cpList f nx H vs).heap ∧
      ∀ w ∈ (cpList f nx H vs).out, VI nx (cpList f nx H vs).nx w
  | [], nx, H => by
    simp only [cpList]
    exact ⟨okp_refl _ _, fun w hw => by simp at hw⟩
  | Val.int n :: vs, nx, H => by
    obtain ⟨h2, h2w⟩ := cpList_ok f hf vs nx H
    simp only [cpList]
    refine ⟨h2, ?_⟩
    intro w hw
    simp at hw
    rcases hw with rfl | hw
    · intro b hb; cases hb
    · exact h2w w hw
  | Val.buf b :: vs, nx, H => by
    obtain ⟨h1, h1a, h1b⟩ := hf nx H b
    obtain ⟨h2, h2w⟩ := cpList_ok f hf vs (f nx H b).nx (f nx H b).heap
    simp only [cpList]
    refine ⟨okp_seq h1 h2, ?_⟩
    intro w hw
    simp at hw
    rcases hw with rfl | hw
    · intro b' hb'
      cases hb'
      have := h2.1
      omega
    · exact VI_mono (h2w w hw) h1.1 (Nat.le_refl _)

theorem leaf_ok (nx : Nat) (H : Heap) :
    OkP nx H (leaf nx H).nx (leaf nx H).heap ∧ nx ≤ (leaf nx H).out ∧ (leaf nx H).out < (leaf nx H).nx := by
  refine ⟨⟨by simp [leaf], ?_, ?_⟩, by simp [leaf], by simp [leaf]⟩
  · intro j hj
    have : j ≠ nx := by simp [leaf] at hj; omega
    simp [leaf, upd, this]
  · intro j h1 h2
    have : j = nx := by simp [leaf] at h2; omega
    subst this
    exact ⟨1, [], by simp [leaf, upd], by simp⟩

/-- Closing a node: the copy of the cells is wrapped in one more fresh buffer. -/
theorem cpNode_ok (nx : Nat) (H : Heap) (r1 : Cp (List Val)) (h1 : OkP nx H r1.nx r1.heap)
    (h1w : ∀ w ∈ r1.out, VI nx r1.nx w) :
    OkP nx H (r1.nx + 1) (upd r1.heap r1.nx (some (1, r1.out))) ∧ nx ≤ r1.nx ∧ r1.nx < r1.nx + 1 := by
  obtain ⟨hle, hsame, hrange⟩ := h1
  refine ⟨⟨by omega, ?_, ?_⟩, hle, by omega⟩
  · intro j hj
    have hjn : j ≠ r1.nx := by omega
    rw [upd_ne _ _ hjn]
    exact hsame j (by omega)
  · intro j hj1 hj2
    by_cases hjn : j = r1.nx
    · subst hjn
      exact ⟨1, r1.out, upd_same _ _ _, fun w hw => VI_mono (h1w w hw) (Nat.le_refl _) (by omega)⟩
    · obtain ⟨c0, cs, hc, hw⟩ := hrange j hj1 (by omega)
      exact ⟨c0, cs, by rw [upd_ne _ _ hjn]; exact hc,
        fun w hw' => VI_mono (hw w hw') (Nat.le_refl _) (by omega)⟩

/-- The deep copy produces fresh ids only, leaves every old buffer untouched, and its root is a fresh id whose whole
graph lies in the fresh range. -/
theorem cpBuf_ok (h : Heap) : ∀ (k nx : Nat) (H : Heap) (b : Nat),
    OkP nx H (cpBuf h k nx H b).nx (cpBuf h k nx H b).heap ∧
    nx ≤ (cpBuf h k nx H b).out ∧ (cpBuf h k nx H b).out < (cpBuf h k nx H b).nx
  | 0, nx, H, b => by simp only [cpBuf]; exact leaf_ok nx H
  | k + 1, nx, H, b => by
    simp only [cpBuf]
    split
    · exact leaf_ok nx H
    · rename_i c cells hb
      obtain ⟨h1, h1w⟩ := cpList_ok (cpBuf h k) (cpBuf_ok h k) cells nx H
      exact cpNode_ok nx H _ h1 h1w

/-- The crossing `send k t x u y`: deep-copy (depth `k`) the graph reachable from `t`'s variable `x` into fresh
ids and bind the root of the copy to variable `y` of thread `u`. -/
def sendS (k : Nat) (s : St) (t x u y : Nat) : St :=
  match s.env t x with
  | none => s
  | some b0 =>
    let r := cpBuf s.heap k s.next s.heap b0
    { env := bindE s.env u y (some r.out), heap := r.heap, next := r.nx }

theorem sendS_safe {s : St} (k t x u y : Nat) (hI : Inv s) : Safe u s (sendS k s t x u y) := by
  unfold sendS
  split
  · exact Safe.refl hI
  · rename_i b0 hx
    have hcp := cpBuf_ok s.heap k s.next s.heap b0
    generalize cpBuf s.heap k s.next s.heap b0 = r at hcp ⊢
    obtain ⟨⟨hle, hsame, hrange⟩, hlo, hhi⟩ := hcp
    apply safe_intro hI
    · intro w hw; exact funext fun z => bindE_ne_thread _ _ hw z
    · exact hle
    · intro j hj
      by_cases h : j < s.next
      · exact absurd (hsame j (Or.inl h)) hj
      · exact Or.inr (by omega)
    · intro z b h
      by_cases hz : z = y
      · subst hz
        have : b = r.out := by simpa [bindE_same] using h.symm
        subst this; exact Or.inr ⟨hlo, hhi⟩
      · exact Or.inl (Reach.var (by simpa [bindE_ne_var _ _ hz] using h))
    · intro j c cs b h hm hj
      rcases hj with hj | hj
      · have hjl := reach_lt hI.2 hj
        have h' : s.heap j = some (c, cs) := by rw [← hsame j (Or.inl hjl)]; exact h
        exact Or.inl (Reach.cell hj h' hm)
      · obtain ⟨c0, cs0, hc0, hw⟩ := hrange j hj.1 hj.2
        have : cs0 = cs := by
          have := hc0.symm.trans h
          simp at this; exact this.2
        subst this
        exact Or.inr (hw _ hm b rfl)
    · refine ⟨?_, ?_⟩
      · intro t' z b h
        show b < r.nx
        by_cases hty : t' = u
        · subst hty
          by_cases hz : z = y
          · subst hz
            have : b = r.out := by simpa [bindE_same] using h.symm
            subst this; exact hhi
          · have := hI.2.1 _ _ _ (by simpa [bindE_ne_var _ _ hz] using h); omega
        · have := hI.2.1 _ _ _ (by simpa [bindE_ne_thread _ _ hty] using h); omega
      · intro j c cs b h hm
        show b < r.nx
        by_cases hj1 : j < s.next
        · have h' : s.heap j = some (c, cs) := by rw [← hsame j (Or.inl hj1)]; exact h
          have := hI.2.2 _ _ _ _ h' hm; omega
        · by_cases hj2 : j < r.nx
          · obtain ⟨c0, cs0, hc0, hw⟩ := hrange j (by omega) hj2
            have : cs0 = cs := by
              have := hc0.symm.trans h
              simp at this; exact this.2
            subst this
            exact (hw _ hm b rfl).2
          · have h' : s.heap j = some (c, cs) := by rw [← hsame j (Or.inr (by omega))]; exact h
            have := hI.2.2 _ _ _ _ h' hm; omega

/-! ## The steps and the theorem -/

inductive Step where
  | new (t x : Nat) (xs : List Int)
  | share (t d src : Nat)
  | write (t x i : Nat) (n : Int)
  | nest (t x i y : Nat)
  | drop (t x : Nat)
  /-- the crossing: deep copy to depth `k` of `t`'s `x` into variable `y` of thread `u` -/
  | send (k t x u y : Nat)

/-- The thread that acts. -/
def Step.actor : Step → Nat
  | .new t _ _ => t
  | .share t _ _ => t
  | .write t _ _ _ => t
  | .nest t _ _ _ => t
  | .drop t _ => t
  | .send _ t _ _ _ => t

/-- The thread whose variables change. -/
def Step.recv : Step → Nat
  | .send _ _ _ u _ => u
  | st => st.actor

def step (s : St) : Step → St
  | .new t x xs => newS s t x xs
  | .share t d src => shareS s t d src
  | .write t x i n => writeS s t x i n
  | .nest t x i y => nestS s t x i y
  | .drop t x => release s t x
  | .send k t x u y => sendS k s t x u y

theorem step_safe {s : St} (hI : Inv s) (st : Step) : Safe st.recv s (step s st) := by
  cases st with
  | new t x xs =>
    exact (release_safe t x hI).trans (alloc_safe t x xs (release_safe t x hI).inv)
  | share t d src => exact shareS_safe t d src hI
  | write t x i n => exact setCell_safe x i hI (fun r hr => by cases hr)
  | nest t x i y => exact nestS_safe t x i y hI
  | drop t x => exact release_safe t x hI
  | send k t x u y => exact sendS_safe k t x u y hI

/-- The invariant is preserved by every step. -/
theorem step_inv {s : St} (hI : Inv s) (st : Step) : Inv (step s st) := (step_safe hI st).inv

/-- Reachable states: the empty state, closed under steps (of any thread, interleaved). -/
inductive Run : St → Prop where
  | init : Run St.empty
  | step {s : St} (st : Step) : Run s → Run (step s st)

theorem run_inv {s : St} (h : Run s) : Inv s := by
  induction h with
  | init => exact inv_empty
  | step st _ ih => exact step_inv ih st

/-- S11, THE THEOREM: `Disjoint` holds initially and is preserved by every step (`step_inv`), so in every
reachable state no buffer id is reachable from two different threads. -/
theorem disjoint_run {s : St} (h : Run s) : Disjoint s := (run_inv h).1

/-- The initial state satisfies `Disjoint`. -/
theorem disjoint_init : Disjoint St.empty := inv_empty.1

/-- One step preserves `Disjoint` (given the bound invariant, which every reachable state has). -/
theorem disjoint_step {s : St} (hI : Inv s) (st : Step) : Disjoint (step s st) := (step_inv hI st).1

/-! ## Corollary: no data race on a count or a cell -/

/-- Buffer ids reachable from `b0` by following cells of the heap `h`. -/
inductive RFrom (h : Heap) : Nat → Nat → Prop where
  | refl (b : Nat) : RFrom h b b
  | cell {b0 b' c b : Nat} {cs : List Val} : RFrom h b0 b' → h b' = some (c, cs) → Val.buf b ∈ cs → RFrom h b0 b

theorem rfrom_reach {s : St} {t b0 b : Nat} (hr : Reach s t b0) (h : RFrom s.heap b0 b) : Reach s t b := by
  induction h with
  | refl => exact hr
  | cell _ hc hm ih => exact Reach.cell ih hc hm

/-- The pre-existing buffers whose count or cells a step READS or WRITES (fresh buffers are private to the
step until it publishes them): the buffers of the variables it names (counts: `ei_buf_inc`, `ei_buf_dec`, the
unique check; cells: the store), and for the crossing every buffer of the graph it copies. -/
def Step.foot (s : St) : Step → Nat → Prop
  | .new t x _ => fun b => s.env t x = some b
  | .share t d src => fun b => s.env t d = some b ∨ s.env t src = some b
  | .write t x _ _ => fun b => s.env t x = some b
  | .nest t x _ y => fun b => s.env t x = some b ∨ s.env t y = some b
  | .drop t x => fun b => s.env t x = some b
  | .send _ t x _ _ => fun b => ∃ b0, s.env t x = some b0 ∧ RFrom s.heap b0 b

/-- Everything a step of thread `t` reads is in `Reach s t`. -/
theorem step_foot_reach {s : St} (st : Step) {b : Nat} (h : Step.foot s st b) : Reach s st.actor b := by
  cases st with
  | new t x xs => exact Reach.var h
  | share t d src => rcases h with h | h <;> exact Reach.var h
  | write t x i n => exact Reach.var h
  | nest t x i y => rcases h with h | h <;> exact Reach.var h
  | drop t x => exact Reach.var h
  | send k t x u y =>
    obtain ⟨b0, hb0, hr⟩ := h
    exact rfrom_reach (Reach.var hb0) hr

/-- Everything a step of thread `t` WRITES (the count or the cells of a buffer) is in `Reach s t`, or is a freshly
allocated id (`≥ next`, not yet visible to any thread). -/
theorem step_writes {s : St} (hI : Inv s) (st : Step) :
    ∀ j, (step s st).heap j ≠ s.heap j → Reach s st.actor j ∨ s.next ≤ j := by
  cases st with
  | send k t x u y =>
    intro j hj
    simp only [step, Step.actor] at hj ⊢
    unfold sendS at hj
    split at hj
    · exact absurd rfl hj
    · rename_i b0 hx
      obtain ⟨⟨_, hsame, _⟩, _, _⟩ := cpBuf_ok s.heap k s.next s.heap b0
      by_cases h : j < s.next
      · exact absurd (hsame j (Or.inl h)) hj
      · exact Or.inr (by omega)
  | new t x xs => exact (step_safe hI (.new t x xs)).writes
  | share t d src => exact (step_safe hI (.share t d src)).writes
  | write t x i n => exact (step_safe hI (.write t x i n)).writes
  | nest t x i y => exact (step_safe hI (.nest t x i y)).writes
  | drop t x => exact (step_safe hI (.drop t x)).writes

/-- The point of the rule (no data race): when two different threads each take a step from a state where `Disjoint`
holds, the pre-existing buffers they read or write are disjoint, so they never touch the same count or cell. (What
they write at fresh ids is not shared either: a fresh id is `≥ next` and reachable from no thread.) -/
theorem no_race {s : St} (hD : Disjoint s) {st1 st2 : Step} (hne : st1.actor ≠ st2.actor) {b : Nat}
    (h1 : Step.foot s st1 b) (h2 : Step.foot s st2 b) : False :=
  hD _ _ b hne (step_foot_reach st1 h1) (step_foot_reach st2 h2)

/-- The writes version: a buffer written by one thread's step is not read or written by another thread's step. -/
theorem no_race_writes {s : St} (hI : Inv s) {st1 st2 : Step} (hne : st1.actor ≠ st2.actor) {b : Nat}
    (hw : (step s st1).heap b ≠ s.heap b) (h2 : Step.foot s st2 b) : False := by
  rcases step_writes hI st1 b hw with h | h
  · exact hI.1 _ _ b hne h (step_foot_reach st2 h2)
  · have := reach_lt hI.2 (step_foot_reach st2 h2); omega

/-! ## The negative result: without the deep copy, `Disjoint` is lost -/

/-- A crossing WITHOUT the deep copy: the receiving thread is given the very same buffer id. -/
def unsafeSend (s : St) (t x u y : Nat) : St :=
  match s.env t x with
  | none => s
  | some b => { s with env := bindE s.env u y (some b) }

/-- The one-buffer state: thread 0 holds buffer 0 (count 1) in variable 0. It is reachable (`new 0 0 [1]`). -/
def s0 : St := step St.empty (.new 0 0 [1])

theorem s0_inv : Inv s0 := step_inv inv_empty _

theorem s0_run : Run s0 := Run.step _ Run.init

/-- Sending the shared buffer id itself (no deep copy) to thread 1 makes buffer 0 reachable from both threads:
`Disjoint` is NOT preserved by `unsafeSend`. This is why the list of crossing points must be complete: one
crossing that forgets the deep copy breaks S11 (and the non-atomic count is then raced on). -/
theorem unsafe_send_breaks_disjoint : Inv s0 ∧ ¬ Disjoint (unsafeSend s0 0 0 1 0) := by
  refine ⟨s0_inv, ?_⟩
  intro hD
  have h0 : s0.env 0 0 = some 0 := by
    simp [s0, step, newS, alloc, release, St.empty, bindE]
  have hr0 : Reach (unsafeSend s0 0 0 1 0) 0 0 :=
    Reach.var (x := 0) (by simp [unsafeSend, h0, bindE])
  have hr1 : Reach (unsafeSend s0 0 0 1 0) 1 0 :=
    Reach.var (x := 0) (by simp [unsafeSend, h0, bindE])
  exact hD 0 1 0 (by decide) hr0 hr1

/-- The same state with the real, deep-copying crossing: `Disjoint` holds (an instance of `disjoint_step`). -/
theorem safe_send_keeps_disjoint (k : Nat) : Disjoint (step s0 (.send k 0 0 1 0)) :=
  disjoint_step s0_inv _

end Stage5
end Eider
