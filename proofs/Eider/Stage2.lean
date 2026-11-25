/-!
# Stage 2 of the formal model (docs/design/formal-model.md): copy-on-write refines value semantics

Eider lists/strings have value semantics: `b := a` behaves as an eager copy. The runtime does not copy: it
shares one reference-counted buffer and copies only when a write finds the buffer shared (core/eider_rt.c, "Shared
buffers"). This file proves that this is unobservable.

Two semantics for a four-statement language over integer lists:

* Value semantics (`vstep`): `VEnv := Var → Option (List Int)`; `copy` copies the list.
* COW semantics (`cstep`): `St` has `env : Var → Option Nat` (variable to buffer id), `heap` (buffer id to
  `(reference count, cells)`) and `next` (the next fresh buffer id, so a freed id is never reused).
  - `release x` is `ei_drop_String`: `ei_buf_dec` the buffer of `x`, free it when the count reaches zero, unbind `x`.
  - `copy d s` is `ei_share_String` (`ei_buf_inc`) and then `d := s`. The increment comes before the release of the
    old value of `d`, so `d = s` leaves the count unchanged.
  - `set x i n` is `ei_str_unique` followed by the write: a buffer with count 1 (`!ei_buf_shared`) is written in
    place, otherwise a fresh buffer with the updated cells replaces it (the copy, `str_new`, then `ei_drop_String`
    on the old buffer).
  - `new x xs` allocates a buffer with count 1 (`str_new`), after releasing the old value of `x`.
  - `drop x` is scope exit (`ei_drop_String`).

Out-of-range `set` leaves the list unchanged (`List.set`), in both semantics; a statement on an unbound variable
changes nothing (`set`) or unbinds (`copy` from an unbound source).

`denote` reads a COW state as a value environment. The invariant `Inv N` (for variables below the bound `N`) is the
code's `EI_INV` set: (I1) no variable at or above `N` is bound, (I2) a bound variable's buffer is live (no use after
free), (I3) every live buffer's count is at least 1 and at least the number of variables bound to it (so a count
of 1 means no other variable sees the buffer: this is what makes the in-place write safe), (I4) ids at or above
`next` are unallocated (a fresh id is really fresh).

Main results: `step_refines` (one statement), `cow_refines_value` (whole programs), and the safety lemmas
`write_in_place_sole`, `write_cow_keeps_buffers`, `release_keeps_bound`.
-/
namespace Eider
namespace Stage2

abbrev Var := Nat

/-- Pointwise update of a total function. -/
def upd {α : Type} (f : Nat → α) (k : Nat) (v : α) : Nat → α :=
  fun j => if j = k then v else f j

theorem upd_same {α : Type} (f : Nat → α) (k : Nat) (v : α) : upd f k v k = v := by simp [upd]

theorem upd_ne {α : Type} (f : Nat → α) {k j : Nat} (v : α) (h : j ≠ k) : upd f k v j = f j := by
  simp [upd, h]

inductive Stmt where
  | new (x : Var) (xs : List Int)
  | copy (d s : Var)
  | set (x : Var) (i : Nat) (n : Int)
  | drop (x : Var)

/-! ## Value semantics -/

abbrev VEnv := Var → Option (List Int)

def vstep (e : VEnv) : Stmt → VEnv
  | .new x xs => upd e x (some xs)
  | .copy d s => upd e d (e s)
  | .set x i n =>
      match e x with
      | some l => upd e x (some (l.set i n))
      | none => e
  | .drop x => upd e x none

def vrun (e : VEnv) : List Stmt → VEnv
  | [] => e
  | st :: p => vrun (vstep e st) p

/-! ## COW semantics -/

structure St where
  env : Var → Option Nat
  heap : Nat → Option (Nat × List Int)
  next : Nat

/-- `ei_drop_String`: decrement the count (free at zero) and unbind. -/
def release (s : St) (x : Var) : St :=
  match s.env x with
  | none => s
  | some b =>
    let heap :=
      match s.heap b with
      | some (c, cells) => if c ≤ 1 then upd s.heap b none else upd s.heap b (some (c - 1, cells))
      | none => s.heap
    { s with env := upd s.env x none, heap := heap }

/-- `ei_buf_inc`. -/
def inc (s : St) (b : Nat) : St :=
  match s.heap b with
  | some (c, cells) => { s with heap := upd s.heap b (some (c + 1, cells)) }
  | none => s

/-- `str_new`: a fresh buffer with count 1 bound to `x` (which must already be released). -/
def alloc (s : St) (x : Var) (xs : List Int) : St :=
  { env := upd s.env x (some s.next), heap := upd s.heap s.next (some (1, xs)), next := s.next + 1 }

/-- `ei_share_String` then assignment: increment first, then release the old `d`, then bind. -/
def share (s : St) (d t : Var) : St :=
  match s.env t with
  | none => release s d
  | some b =>
    let s2 := release (inc s b) d
    { s2 with env := upd s2.env d (some b) }

/-- `ei_str_unique` and the write: in place when the count is 1, copy-on-write otherwise. -/
def write (s : St) (x : Var) (i : Nat) (n : Int) : St :=
  match s.env x with
  | none => s
  | some b =>
    match s.heap b with
    | none => s
    | some (c, cells) =>
      if c = 1 then { s with heap := upd s.heap b (some (1, cells.set i n)) }
      else
        { env := upd s.env x (some s.next),
          heap := upd (upd s.heap b (some (c - 1, cells))) s.next (some (1, cells.set i n)),
          next := s.next + 1 }

def cstep (s : St) : Stmt → St
  | .new x xs => alloc (release s x) x xs
  | .copy d t => share s d t
  | .set x i n => write s x i n
  | .drop x => release s x

def crun (s : St) : List Stmt → St
  | [] => s
  | st :: p => crun (cstep s st) p

def denote (s : St) : VEnv := fun x =>
  match s.env x with
  | some b => (s.heap b).map Prod.snd
  | none => none

def St.empty : St := ⟨fun _ => none, fun _ => none, 0⟩

/-! ## Counting the variables bound to a buffer -/

/-- The number of variables below `k` bound to buffer `b`. -/
def refsUpTo (env : Nat → Option Nat) (b : Nat) : Nat → Nat
  | 0 => 0
  | k + 1 => refsUpTo env b k + (if env k = some b then 1 else 0)

/-- Additive update lemma (no subtraction): rebinding `x` moves one reference from the old buffer to the new. -/
theorem refsUpTo_upd (env : Nat → Option Nat) (x : Nat) (v : Option Nat) (b : Nat) :
    ∀ k, refsUpTo (upd env x v) b k + (if x < k ∧ env x = some b then 1 else 0)
       = refsUpTo env b k + (if x < k ∧ v = some b then 1 else 0)
  | 0 => by simp [refsUpTo]
  | k + 1 => by
    have ih := refsUpTo_upd env x v b k
    simp only [refsUpTo]
    by_cases h1 : x = k
    · subst h1
      have : refsUpTo (upd env x v) b x = refsUpTo env b x := by simpa using ih
      rw [this]
      by_cases h2 : env x = some b <;> by_cases h3 : v = some b <;> simp [upd, h2, h3]
      <;> omega
    · have h4 : upd env x v k = env k := upd_ne env v (Ne.symm h1)
      rw [h4]
      by_cases h5 : x < k
      · have h6 : x < k + 1 := by omega
        simp only [h5, h6, true_and] at ih ⊢
        by_cases h2 : env x = some b <;> by_cases h3 : v = some b <;> by_cases h7 : env k = some b <;>
          simp [h2, h3, h7] at ih ⊢ <;> omega
      · have h6 : ¬ x < k + 1 := by omega
        simp only [h5, h6, false_and, ite_false] at ih ⊢
        by_cases h7 : env k = some b <;> simp [h7] <;> omega

theorem refsUpTo_pos (env : Nat → Option Nat) (b x : Nat) :
    ∀ k, x < k → env x = some b → 1 ≤ refsUpTo env b k
  | 0, h, _ => by omega
  | k + 1, h, hx => by
    simp only [refsUpTo]
    by_cases hk : x = k
    · subst hk; simp [hx]
    · have := refsUpTo_pos env b x k (by omega) hx
      omega

/-- Two distinct variables bound to the same buffer give a count of at least 2. -/
theorem refsUpTo_two (env : Nat → Option Nat) (b x y : Nat) (hxy : x ≠ y) :
    ∀ k, x < k → y < k → env x = some b → env y = some b → 2 ≤ refsUpTo env b k
  | 0, h, _, _, _ => by omega
  | k + 1, hx, hy, ex, ey => by
    simp only [refsUpTo]
    by_cases h1 : x = k
    · subst h1
      have := refsUpTo_pos env b y x (by omega) ey
      simp [ex]; omega
    · by_cases h2 : y = k
      · subst h2
        have := refsUpTo_pos env b x y (by omega) ex
        simp [ey]; omega
      · have := refsUpTo_two env b x y hxy k (by omega) (by omega) ex ey
        omega

theorem refsUpTo_zero (env : Nat → Option Nat) (b : Nat) :
    ∀ k, (∀ j : Nat, j < k → env j ≠ some b) → refsUpTo env b k = 0
  | 0, _ => rfl
  | k + 1, h => by
    simp only [refsUpTo]
    have := refsUpTo_zero env b k (fun j hj => h j (by omega))
    have h2 := h k (by omega)
    simp [this, h2]

/-! ## The invariant -/

def Inv (N : Nat) (s : St) : Prop :=
  (∀ x, N ≤ x → s.env x = none) ∧
  (∀ x b, s.env x = some b → ∃ v, s.heap b = some v) ∧
  (∀ b c cells, s.heap b = some (c, cells) → refsUpTo s.env b N ≤ c ∧ 1 ≤ c) ∧
  (∀ b, s.next ≤ b → s.heap b = none)

theorem bound_lt_next {N : Nat} {s : St} (hI : Inv N s) {y b : Nat} (h : s.env y = some b) :
    b < s.next := by
  obtain ⟨_, I2, _, I4⟩ := hI
  obtain ⟨v, hv⟩ := I2 y b h
  refine Nat.lt_of_not_ge fun hc => ?_
  have := I4 b hc
  simp [hv] at this

theorem bound_lt_N {N : Nat} {s : St} (hI : Inv N s) {y b : Nat} (h : s.env y = some b) : y < N := by
  obtain ⟨I1, _⟩ := hI
  refine Nat.lt_of_not_ge fun hc => ?_
  have := I1 y hc
  simp [h] at this

/-- No variable is bound to the fresh id. -/
theorem refs_fresh {N : Nat} {s : St} (hI : Inv N s) : refsUpTo s.env s.next N = 0 := by
  apply refsUpTo_zero
  intro j _ hj
  have := bound_lt_next hI hj
  omega

/-- A count of 1 means sole ownership: any variable bound to the buffer is `x` itself. -/
theorem sole_owner {N : Nat} {s : St} (hI : Inv N s) {x b : Nat} {cells : List Int}
    (hx : s.env x = some b) (hb : s.heap b = some (1, cells)) :
    ∀ y, s.env y = some b → y = x := by
  intro y hy
  refine Classical.byContradiction fun hne => ?_
  have h2 := refsUpTo_two s.env b y x hne N (bound_lt_N hI hy) (bound_lt_N hI hx) hy hx
  have h3 := hI.2.2.1 b 1 cells hb
  omega

/-- Two variables bound to the same buffer force count at least 2. -/
theorem shared_count {N : Nat} {s : St} (hI : Inv N s) {x y b c : Nat} {cells : List Int} (hxy : y ≠ x)
    (hx : s.env x = some b) (hy : s.env y = some b) (hb : s.heap b = some (c, cells)) : 2 ≤ c := by
  have h2 := refsUpTo_two s.env b y x hxy N (bound_lt_N hI hy) (bound_lt_N hI hx) hy hx
  have h3 := hI.2.2.1 b c cells hb
  omega

/-! ## release -/

theorem release_unbound {s : St} {x : Nat} (h : s.env x = none) : release s x = s := by
  simp [release, h]

theorem release_env (s : St) (x : Nat) : (release s x).env = upd s.env x none := by
  unfold release
  split
  · rename_i h
    funext y
    by_cases hy : y = x
    · subst hy; simp [upd, h]
    · simp [upd, hy]
  · rfl

theorem release_next (s : St) (x : Nat) : (release s x).next = s.next := by
  unfold release
  split <;> rfl

theorem release_heap_ne {s : St} {x b b' : Nat} (h : s.env x = some b) (hne : b' ≠ b) :
    (release s x).heap b' = s.heap b' := by
  simp only [release, h]
  cases hh : s.heap b with
  | none => simp
  | some v =>
    obtain ⟨c, cells⟩ := v
    by_cases hc : c ≤ 1 <;> simp [hc, upd, hne]

theorem release_heap_eq {s : St} {x b c : Nat} {cells : List Int} (h : s.env x = some b)
    (hb : s.heap b = some (c, cells)) :
    (release s x).heap b = if c ≤ 1 then none else some (c - 1, cells) := by
  simp only [release, h, hb]
  by_cases hc : c ≤ 1 <;> simp [hc, upd]

/-- Releasing keeps the cells of any live buffer alive unless it frees the last reference, and keeps the
slack between the references and the count. -/
theorem release_slack {s : St} {x N b c : Nat} {cells : List Int} (hx : x < N)
    (hb : s.heap b = some (c, cells)) (hr : refsUpTo s.env b N + 1 ≤ c) :
    ∃ c', (release s x).heap b = some (c', cells) ∧ refsUpTo (release s x).env b N + 1 ≤ c' := by
  have hu := refsUpTo_upd s.env x none b N
  rw [← release_env] at hu
  cases h : s.env x with
  | none => rw [release_unbound h]; exact ⟨c, hb, hr⟩
  | some b0 =>
    by_cases hbb : b = b0
    · subst hbb
      simp [hx, h] at hu
      refine ⟨c - 1, ?_, by omega⟩
      rw [release_heap_eq h hb]
      have : ¬ c ≤ 1 := by omega
      simp [this]
    · have hbb' : b0 ≠ b := fun e => hbb e.symm
      simp [hx, h, hbb'] at hu
      refine ⟨c, ?_, by omega⟩
      rw [release_heap_ne h hbb]; exact hb
      <;> omega

theorem release_inv {N : Nat} {s : St} {x : Nat} (hI : Inv N s) (hx : x < N) :
    Inv N (release s x) ∧ denote (release s x) = upd (denote s) x none := by
  have hu := fun b' => refsUpTo_upd s.env x none b' N
  simp only [← release_env] at hu
  cases h : s.env x with
  | none =>
    rw [release_unbound h]
    refine ⟨hI, ?_⟩
    funext y
    by_cases hy : y = x
    · subst hy; simp [denote, upd, h]
    · simp [upd, hy]
  | some b =>
    obtain ⟨I1, I2, I3, I4⟩ := hI
    obtain ⟨⟨c, cells⟩, hb⟩ := I2 x b h
    have hbN := bound_lt_next ⟨I1, I2, I3, I4⟩ h
    have h2 : ∀ y, y ≠ x → s.env y = some b → 2 ≤ c := fun y hy ey =>
      shared_count ⟨I1, I2, I3, I4⟩ hy h ey hb
    have henv := release_env s x
    have hnext := release_next s x
    have hc := I3 b c cells hb
    have hub := hu b
    simp [hx, h] at hub
    refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_⟩
    · intro y hy
      rw [henv]
      by_cases hyx : y = x
      · simp [upd, hyx]
      · simp [upd, hyx, I1 y hy]
    · intro y b' hy
      rw [henv] at hy
      by_cases hyx : y = x
      · simp [upd, hyx] at hy
      · have ey : s.env y = some b' := by simpa [upd, hyx] using hy
        by_cases hbb : b' = b
        · subst hbb
          have := h2 y hyx ey
          rw [release_heap_eq h hb]
          have : ¬ c ≤ 1 := by omega
          simp [this]
        · rw [release_heap_ne h hbb]; exact I2 y b' ey
    · intro b' c' cells' hh
      by_cases hbb : b' = b
      · subst hbb
        rw [release_heap_eq h hb] at hh
        by_cases hc1 : c ≤ 1
        · simp [hc1] at hh
        · simp [hc1] at hh
          obtain ⟨rfl, rfl⟩ := hh
          omega
      · rw [release_heap_ne h hbb] at hh
        have h3 := I3 b' c' cells' hh
        have hub' := hu b'
        have hne : ¬ (some b = some b') := fun e => hbb (Option.some.inj e).symm
        simp [hx, h, hne] at hub'
        omega
    · intro b' hb'
      rw [hnext] at hb'
      have hbb : b' ≠ b := by omega
      rw [release_heap_ne h hbb]; exact I4 b' hb'
    · funext y
      by_cases hyx : y = x
      · subst hyx; simp [denote, henv, upd]
      · simp only [denote, henv, upd, hyx, ite_false]
        cases ey : s.env y with
        | none => rfl
        | some b' =>
          simp only
          by_cases hbb : b' = b
          · subst hbb
            have := h2 y hyx ey
            rw [release_heap_eq h hb, hb]
            have : ¬ c ≤ 1 := by omega
            simp [this]
          · rw [release_heap_ne h hbb]

/-- No use after free: releasing `x` never frees a buffer that another variable is still bound to. -/
theorem release_keeps_bound {N : Nat} {s : St} {x y b : Nat} (hI : Inv N s) (hyx : y ≠ x)
    (hy : s.env y = some b) :
    ∃ c c' cells, s.heap b = some (c, cells) ∧ (release s x).heap b = some (c', cells) := by
  obtain ⟨⟨c, cells⟩, hb⟩ := hI.2.1 y b hy
  have hr := hI.2.2.1 b c cells hb
  cases h : s.env x with
  | none => rw [release_unbound h]; exact ⟨c, c, cells, hb, hb⟩
  | some b0 =>
    by_cases hbb : b = b0
    · subst hbb
      have := shared_count hI hyx h hy hb
      rw [release_heap_eq h hb]
      have : ¬ c ≤ 1 := by omega
      exact ⟨c, c - 1, cells, hb, by simp [this]⟩
    · rw [release_heap_ne h hbb]; exact ⟨c, c, cells, hb, hb⟩

/-! ## inc and alloc -/

theorem inc_inv {N : Nat} {s : St} {t b : Nat} (hI : Inv N s) (h : s.env t = some b) :
    Inv N (inc s b) ∧ denote (inc s b) = denote s ∧ (inc s b).env = s.env ∧ (inc s b).next = s.next ∧
    ∃ c cells, s.heap b = some (c, cells) ∧ (inc s b).heap b = some (c + 1, cells) := by
  obtain ⟨I1, I2, I3, I4⟩ := hI
  obtain ⟨⟨c, cells⟩, hb⟩ := I2 t b h
  have e : inc s b = { s with heap := upd s.heap b (some (c + 1, cells)) } := by simp [inc, hb]
  rw [e]
  refine ⟨⟨I1, ?_, ?_, ?_⟩, ?_, rfl, rfl, c, cells, hb, by simp [upd]⟩
  · intro y b' hy
    by_cases hbb : b' = b
    · subst hbb; exact ⟨(c + 1, cells), by simp [upd]⟩
    · simp only [upd, hbb, ite_false]; exact I2 y b' hy
  · intro b' c' cells' hh
    by_cases hbb : b' = b
    · subst hbb
      simp [upd] at hh
      obtain ⟨rfl, rfl⟩ := hh
      have := I3 b' c cells hb
      simp only
      omega
    · simp only [upd, hbb, ite_false] at hh
      exact I3 b' c' cells' hh
  · intro b' hb'
    have hbb : b' ≠ b := by
      intro e; subst e
      have := I4 b' hb'
      simp [hb] at this
    simp only [upd, hbb, ite_false]; exact I4 b' hb'
  · funext y
    simp only [denote]
    cases ey : s.env y with
    | none => rfl
    | some b' =>
      by_cases hbb : b' = b
      · subst hbb; simp [upd, hb]
      · simp [upd, hbb]

theorem alloc_inv {N : Nat} {s : St} {x : Nat} {xs : List Int} (hI : Inv N s) (hx : x < N)
    (hn : s.env x = none) :
    Inv N (alloc s x xs) ∧ denote (alloc s x xs) = upd (denote s) x (some xs) := by
  have hfresh := refs_fresh hI
  have hnext : ∀ y b, s.env y = some b → b ≠ s.next := fun y b hy e => by
    have := bound_lt_next hI hy; omega
  obtain ⟨I1, I2, I3, I4⟩ := hI
  have hu := fun b' => refsUpTo_upd s.env x (some s.next) b' N
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_⟩
  · intro y hy
    have : y ≠ x := by omega
    simp [alloc, upd, this, I1 y hy]
  · intro y b' hy
    simp only [alloc] at hy ⊢
    by_cases hyx : y = x
    · subst hyx; simp [upd] at hy; subst hy; exact ⟨(1, xs), by simp [upd]⟩
    · have ey : s.env y = some b' := by simpa [upd, hyx] using hy
      have := hnext y b' ey
      simp only [upd, this, ite_false]
      exact I2 y b' ey
  · intro b' c' cells' hh
    simp only [alloc] at hh ⊢
    by_cases hbb : b' = s.next
    · subst hbb
      simp [upd] at hh
      obtain ⟨rfl, rfl⟩ := hh
      have hub := hu s.next
      simp [hx, hn, hfresh] at hub
      simp [hub]
    · simp only [upd, hbb, ite_false] at hh
      have h3 := I3 b' c' cells' hh
      have hub := hu b'
      have hne : ¬ (some s.next = some b') := fun e => hbb (Option.some.inj e).symm
      simp [hx, hn, hne] at hub
      simp only [hub]; exact h3
  · intro b' hb'
    simp only [alloc] at hb' ⊢
    have hbb : b' ≠ s.next := by omega
    simp only [upd, hbb, ite_false]
    exact I4 b' (by omega)
  · funext y
    by_cases hyx : y = x
    · subst hyx; simp [denote, alloc, upd]
    · simp only [denote, alloc, upd, hyx, ite_false]
      cases ey : s.env y with
      | none => rfl
      | some b' =>
        have := hnext y b' ey
        simp [this]

/-! ## set -/

/-- The key safety fact: the in-place branch is taken only when the buffer has a single owner, `x` itself. -/
theorem write_in_place_sole {N : Nat} {s : St} {x b : Nat} {cells : List Int} {i : Nat} {n : Int}
    (hI : Inv N s) (hx : s.env x = some b) (hb : s.heap b = some (1, cells)) :
    write s x i n = { s with heap := upd s.heap b (some (1, cells.set i n)) } ∧
    ∀ y, s.env y = some b → y = x := by
  refine ⟨by simp [write, hx, hb], sole_owner hI hx hb⟩

/-- The copy-on-write branch never touches any existing buffer's cells (it only allocates a fresh one and
drops one reference from the old), and leaves every other variable's binding alone. -/
theorem write_cow_keeps_buffers {N : Nat} {s : St} {x b c : Nat} {cells : List Int} {i : Nat} {n : Int}
    (hI : Inv N s) (hx : s.env x = some b) (hb : s.heap b = some (c, cells)) (hc : c ≠ 1) :
    (∀ b', s.heap b' ≠ none → ((write s x i n).heap b').map Prod.snd = (s.heap b').map Prod.snd) ∧
    (∀ y, y ≠ x → (write s x i n).env y = s.env y) := by
  have e : write s x i n =
      { env := upd s.env x (some s.next),
        heap := upd (upd s.heap b (some (c - 1, cells))) s.next (some (1, cells.set i n)),
        next := s.next + 1 } := by simp [write, hx, hb, hc]
  rw [e]
  constructor
  · intro b' hne
    have hlt : b' < s.next :=
      Nat.lt_of_not_ge fun hh => hne (hI.2.2.2 b' hh)
    have hn : b' ≠ s.next := by omega
    by_cases hbb : b' = b
    · subst hbb; simp [upd, hn, hb]
    · simp [upd, hn, hbb]
  · intro y hy; simp [upd, hy]

theorem write_inv {N : Nat} {s : St} {x : Nat} {i : Nat} {n : Int} (hI : Inv N s) (hx : x < N) :
    Inv N (write s x i n) ∧ denote (write s x i n) = vstep (denote s) (.set x i n) := by
  cases h : s.env x with
  | none =>
    have : write s x i n = s := by simp [write, h]
    rw [this]
    refine ⟨hI, ?_⟩
    simp [vstep, denote, h]
  | some b =>
    obtain ⟨⟨c, cells⟩, hb⟩ := hI.2.1 x b h
    have hlt := bound_lt_next hI h
    have hdx : denote s x = some cells := by simp [denote, h, hb]
    have hc := hI.2.2.1 b c cells hb
    by_cases hc1 : c = 1
    · subst hc1
      obtain ⟨e, hsole⟩ := write_in_place_sole (i := i) (n := n) hI h hb
      rw [e]
      obtain ⟨I1, I2, I3, I4⟩ := hI
      refine ⟨⟨I1, ?_, ?_, ?_⟩, ?_⟩
      · intro y b' hy
        by_cases hbb : b' = b
        · subst hbb; exact ⟨(1, cells.set i n), by simp [upd]⟩
        · simp only [upd, hbb, ite_false]; exact I2 y b' hy
      · intro b' c' cells' hh
        by_cases hbb : b' = b
        · subst hbb
          simp [upd] at hh
          obtain ⟨rfl, rfl⟩ := hh
          exact I3 b' 1 cells hb
        · simp only [upd, hbb, ite_false] at hh
          exact I3 b' c' cells' hh
      · intro b' hb'
        have hb'' : s.next ≤ b' := hb'
        have hbb : b' ≠ b := by omega
        simp only [upd, hbb, ite_false]; exact I4 b' hb''
      · funext y
        simp only [vstep, hdx]
        by_cases hyx : y = x
        · subst hyx; simp [denote, h, upd]
        · simp only [denote, upd, hyx, ite_false]
          cases ey : s.env y with
          | none => rfl
          | some b' =>
            have hbb : b' ≠ b := fun e => hyx (hsole y (by rw [ey, e]))
            simp [hbb]
    · have hc2 : 2 ≤ c := by omega
      have e : write s x i n =
          { env := upd s.env x (some s.next),
            heap := upd (upd s.heap b (some (c - 1, cells))) s.next (some (1, cells.set i n)),
            next := s.next + 1 } := by simp [write, h, hb, hc1]
      rw [e]
      have hfresh := refs_fresh hI
      have hnext : ∀ y b', s.env y = some b' → b' ≠ s.next := fun y b' hy e => by
        have := bound_lt_next hI hy; omega
      have hu := fun b' => refsUpTo_upd s.env x (some s.next) b' N
      obtain ⟨I1, I2, I3, I4⟩ := hI
      have hbn : b ≠ s.next := by omega
      refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_⟩
      · intro y hy
        have : y ≠ x := by omega
        simp [upd, this, I1 y hy]
      · intro y b' hy
        simp only at hy ⊢
        by_cases hyx : y = x
        · subst hyx; simp [upd] at hy; subst hy; exact ⟨(1, cells.set i n), by simp [upd]⟩
        · have ey : s.env y = some b' := by simpa [upd, hyx] using hy
          have hn' := hnext y b' ey
          simp only [upd, hn', ite_false]
          by_cases hbb : b' = b
          · subst hbb; exact ⟨(c - 1, cells), by simp⟩
          · simp only [hbb, ite_false]; exact I2 y b' ey
      · intro b' c' cells' hh
        simp only at hh ⊢
        by_cases hbn' : b' = s.next
        · subst hbn'
          simp [upd] at hh
          obtain ⟨rfl, rfl⟩ := hh
          have hub := hu s.next
          simp [hx, h, hfresh, hbn] at hub
          simp [hub]
        · by_cases hbb : b' = b
          · subst hbb
            simp [upd, hbn'] at hh
            obtain ⟨rfl, rfl⟩ := hh
            have hub := hu b'
            have hne : ¬ (some s.next = some b') := fun e => hbn' (Option.some.inj e).symm
            simp [hx, h, hne] at hub
            refine ⟨?_, by omega⟩
            show refsUpTo (upd s.env x (some s.next)) b' N ≤ c - 1
            omega
          · simp only [upd, hbn', hbb, ite_false] at hh
            have h3 := I3 b' c' cells' hh
            have hub := hu b'
            have hne : ¬ (some s.next = some b') := fun e => hbn' (Option.some.inj e).symm
            have hne2 : ¬ (some b = some b') := fun e => hbb (Option.some.inj e).symm
            simp [hx, h, hne, hne2] at hub
            simp only [hub]; exact h3
      · intro b' hb'
        have hb'' : s.next + 1 ≤ b' := hb'
        have hbn' : b' ≠ s.next := by omega
        have hbb : b' ≠ b := by omega
        simp only [upd, hbn', hbb, ite_false]
        exact I4 b' (by omega)
      · funext y
        simp only [vstep, hdx]
        by_cases hyx : y = x
        · subst hyx; simp [denote, upd]
        · simp only [denote, upd, hyx, ite_false]
          cases ey : s.env y with
          | none => rfl
          | some b' =>
            have hn' := hnext y b' ey
            simp only [hn', ite_false]
            by_cases hbb : b' = b
            · subst hbb; simp [hb]
            · simp [hbb]

/-! ## copy -/

theorem share_inv {N : Nat} {s : St} {d t : Nat} (hI : Inv N s) (hd : d < N) :
    Inv N (share s d t) ∧ denote (share s d t) = vstep (denote s) (.copy d t) := by
  cases h : s.env t with
  | none =>
    have : share s d t = release s d := by simp [share, h]
    rw [this]
    obtain ⟨hI', hden⟩ := release_inv hI hd
    refine ⟨hI', ?_⟩
    rw [hden]
    have : denote s t = none := by simp [denote, h]
    simp [vstep, this]
  | some b =>
    obtain ⟨hI1, hden1, henv1, hnext1, c, cells, hb, hb1⟩ := inc_inv hI h
    have hr1 := hI.2.2.1 b c cells hb
    obtain ⟨hI2, hden2⟩ := release_inv hI1 hd
    obtain ⟨c2, hb2, hslack⟩ := release_slack (x := d) (N := N) hd hb1 (by rw [henv1]; omega)

    have hunb : (release (inc s b) d).env d = none := by simp [release_env, upd]
    have hnext2 := release_next (inc s b) d
    have hs3 : share s d t = { release (inc s b) d with
        env := upd (release (inc s b) d).env d (some b) } := by simp [share, h]
    rw [hs3]
    have hdt : denote s t = some cells := by simp [denote, h, hb]
    have hu := fun b' => refsUpTo_upd (release (inc s b) d).env d (some b) b' N
    obtain ⟨J1, J2, J3, J4⟩ := hI2
    refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_⟩
    · intro y hy
      have : y ≠ d := by omega
      simp [upd, this, J1 y hy]
    · intro y b' hy
      simp only at hy ⊢
      by_cases hyd : y = d
      · subst hyd; simp [upd] at hy; subst hy; exact ⟨(c2, cells), hb2⟩
      · have ey : (release (inc s b) d).env y = some b' := by simpa [upd, hyd] using hy
        exact J2 y b' ey
    · intro b' c' cells' hh
      simp only at hh ⊢
      have hub := hu b'
      by_cases hbb : b' = b
      · subst hbb
        rw [hb2] at hh
        simp at hh
        obtain ⟨rfl, rfl⟩ := hh
        simp [hd, hunb] at hub
        simp only [hub]
        exact ⟨hslack, by omega⟩
      · have hne : ¬ (some b = some b') := fun e => hbb (Option.some.inj e).symm
        simp [hd, hunb, hne] at hub
        simp only [hub]
        exact J3 b' c' cells' hh
    · intro b' hb'
      simp only at hb' ⊢
      exact J4 b' hb'
    · funext y
      simp only [vstep]
      by_cases hyd : y = d
      · subst hyd; simp [denote, upd, hb2, h, hb]
      · have := congrFun hden2 y
        rw [hden1] at this
        simp only [upd, hyd, ite_false] at this ⊢
        rw [← this]
        simp [denote, upd, hyd]

/-! ## The refinement theorems -/

def Stmt.wf (N : Nat) : Stmt → Prop
  | .new x _ => x < N
  | .copy d s => d < N ∧ s < N
  | .set x _ _ => x < N
  | .drop x => x < N

/-- One COW step preserves the invariant and does exactly what the value semantics does. -/
theorem step_refines {N : Nat} {s : St} {st : Stmt} (hI : Inv N s) (hw : st.wf N) :
    Inv N (cstep s st) ∧ denote (cstep s st) = vstep (denote s) st := by
  cases st with
  | new x xs =>
    obtain ⟨hI1, hd1⟩ := release_inv hI hw
    have hn : (release s x).env x = none := by simp [release_env, upd]
    obtain ⟨hI2, hd2⟩ := alloc_inv (xs := xs) hI1 hw hn
    refine ⟨hI2, ?_⟩
    simp only [cstep, vstep]
    rw [hd2, hd1]
    funext y
    by_cases hy : y = x <;> simp [upd, hy]
  | copy d t => exact share_inv hI hw.1
  | set x i n => exact write_inv hI hw
  | drop x => exact release_inv hI hw

def WFProg (N : Nat) (p : List Stmt) : Prop := ∀ st, st ∈ p → st.wf N

theorem run_refines {N : Nat} (p : List Stmt) : ∀ {s : St}, Inv N s → WFProg N p →
    Inv N (crun s p) ∧ denote (crun s p) = vrun (denote s) p := by
  induction p with
  | nil => intro s hI _; exact ⟨hI, rfl⟩
  | cons st p ih =>
    intro s hI hw
    obtain ⟨h1, h2⟩ := step_refines hI (hw st (by simp))
    obtain ⟨h3, h4⟩ := ih h1 (fun st' hs => hw st' (by simp [hs]))
    refine ⟨h3, ?_⟩
    simp only [crun, vrun]
    rw [h4, h2]

theorem inv_empty (N : Nat) : Inv N St.empty :=
  ⟨fun _ _ => rfl, fun _ _ h => by simp [St.empty] at h, fun _ _ _ h => by simp [St.empty] at h,
   fun _ _ => rfl⟩

/-- Copy-on-write is a refinement of value semantics: running any well-formed program from the empty
state under COW, then reading the result as a value environment, equals running it under value semantics. -/
theorem cow_refines_value (N : Nat) (p : List Stmt) (hp : WFProg N p) :
    denote (crun St.empty p) = vrun (fun _ => none) p := by
  have := (run_refines (N := N) p (inv_empty N) hp).2
  rw [this]
  have : denote St.empty = fun _ => none := by funext y; simp [denote, St.empty]
  rw [this]

end Stage2
end Eider
