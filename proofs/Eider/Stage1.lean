/-!
# Stage 1 of the formal model (docs/design/formal-model.md, #246 workstream G)

A definitional interpreter for the smallest fragment that has the memory-safety question in it: integers, immutable
lists, `let`, and a checked index. No aliases, no mutation, no threads (those are stages 2 to 5).

The theorem is Milner's "well-typed programs do not go wrong": for a typed expression and an environment that fits
its context, evaluation never reaches `stuck` (a type confusion, an unbound variable, a read of a non-list), and when
it produces a value, the value has the type. An index outside the list is the defined outcome `trap`, never a read:
`Val.list` has no way to produce a cell that is not there.
-/
namespace Eider

inductive Ty where
  | int
  | list
  deriving DecidableEq

inductive Expr where
  | lit : Int → Expr
  | var : Nat → Expr
  | add : Expr → Expr → Expr
  | letE : Expr → Expr → Expr
  | mk : List Int → Expr
  | idx : Expr → Expr → Expr
  | len : Expr → Expr

inductive Val where
  | int : Int → Val
  | list : List Int → Val

/-- What running an expression gives: a value, a trap (a failed check: defined, safe), or `stuck` (what the rules must make impossible). -/
inductive Out where
  | ok : Val → Out
  | trap : Out
  | stuck : Out

def Out.bind : Out → (Val → Out) → Out
  | .ok v, f => f v
  | .trap, _ => .trap
  | .stuck, _ => .stuck

def eval : List Val → Expr → Out
  | _, .lit n => .ok (.int n)
  | env, .var i =>
      match env[i]? with
      | some v => .ok v
      | none => .stuck
  | env, .add a b =>
      (eval env a).bind fun va =>
        (eval env b).bind fun vb =>
          match va, vb with
          | .int x, .int y => .ok (.int (x + y))
          | _, _ => .stuck
  | env, .letE a b =>
      (eval env a).bind fun va => eval (va :: env) b
  | _, .mk xs => .ok (.list xs)
  | env, .idx a b =>
      (eval env a).bind fun va =>
        (eval env b).bind fun vb =>
          match va, vb with
          | .list xs, .int n =>
              if n < 0 then .trap
              else
                match xs[n.toNat]? with
                | some x => .ok (.int x)
                | none => .trap
          | _, _ => .stuck
  | env, .len a =>
      (eval env a).bind fun va =>
        match va with
        | .list xs => .ok (.int xs.length)
        | _ => .stuck

inductive HasType : List Ty → Expr → Ty → Prop where
  | lit : HasType Γ (.lit n) .int
  | var : Γ[i]? = some τ → HasType Γ (.var i) τ
  | add : HasType Γ a .int → HasType Γ b .int → HasType Γ (.add a b) .int
  | letE : HasType Γ a σ → HasType (σ :: Γ) b τ → HasType Γ (.letE a b) τ
  | mk : HasType Γ (.mk xs) .list
  | idx : HasType Γ a .list → HasType Γ b .int → HasType Γ (.idx a b) .int
  | len : HasType Γ a .list → HasType Γ (.len a) .int

inductive HasVal : Val → Ty → Prop where
  | int : HasVal (.int n) .int
  | list : HasVal (.list xs) .list

/-- The environment fits the context: each value has the type the context gives its slot. -/
inductive EnvOk : List Val → List Ty → Prop where
  | nil : EnvOk [] []
  | cons : HasVal v t → EnvOk env Γ → EnvOk (v :: env) (t :: Γ)

/-- The outcome is safe at type `τ`: a trap, or a value of that type. Never `stuck`. -/
def Good (o : Out) (τ : Ty) : Prop :=
  match o with
  | .ok v => HasVal v τ
  | .trap => True
  | .stuck => False

theorem Good.bind {o : Out} {f : Val → Out} {σ τ : Ty}
    (ho : Good o σ) (hf : ∀ v, HasVal v σ → Good (f v) τ) : Good (o.bind f) τ := by
  cases o with
  | ok v => exact hf v ho
  | trap => exact trivial
  | stuck => exact ho.elim

theorem env_lookup {env : List Val} {Γ : List Ty}
    (h : EnvOk env Γ) {i : Nat} {τ : Ty} (hi : Γ[i]? = some τ) :
    ∃ v, env[i]? = some v ∧ HasVal v τ := by
  induction h generalizing i with
  | nil => simp at hi
  | cons hv _ ih =>
    cases i with
    | zero => simp at hi ⊢; subst hi; exact hv
    | succ j => simp at hi ⊢; exact ih hi

/-- Type safety: a typed expression in a fitting environment never gets stuck, and its value has its type. -/
theorem type_safety {Γ : List Ty} {e : Expr} {τ : Ty} (ht : HasType Γ e τ) :
    ∀ env, EnvOk env Γ → Good (eval env e) τ := by
  induction ht with
  | lit => intro env _; exact HasVal.int
  | var hi =>
      intro env h
      obtain ⟨v, hv, hvt⟩ := env_lookup h hi
      simp only [eval, hv]; exact hvt
  | add _ _ iha ihb =>
      intro env h
      refine Good.bind (iha env h) fun va hva => Good.bind (ihb env h) fun vb hvb => ?_
      cases hva <;> cases hvb <;> exact HasVal.int
  | letE _ _ iha ihb =>
      intro env h
      exact Good.bind (iha env h) fun va hva => ihb (va :: env) (EnvOk.cons hva h)
  | mk => intro env _; exact HasVal.list
  | idx _ _ iha ihb =>
      intro env h
      refine Good.bind (iha env h) fun va hva => Good.bind (ihb env h) fun vb hvb => ?_
      cases hva
      cases hvb
      rename_i xs n
      show Good (if n < 0 then Out.trap
                 else match xs[n.toNat]? with
                   | some x => Out.ok (Val.int x)
                   | none => Out.trap) Ty.int
      by_cases hn : n < 0
      · simp only [hn, ite_true]; exact trivial
      · simp only [hn, ite_false]
        split
        · exact HasVal.int
        · exact trivial
  | len _ iha =>
      intro env h
      refine Good.bind (iha env h) fun va hva => ?_
      cases hva
      exact HasVal.int

/-- An index outside the list is a trap, and one inside reads exactly that cell: there is no third outcome. -/
theorem idx_out_of_range (xs : List Int) (n : Int) (h : n < 0 ∨ xs.length ≤ n.toNat) :
    eval [] (.idx (.mk xs) (.lit n)) = .trap := by
  rcases h with h | h
  · simp [eval, Out.bind, h]
  · by_cases hn : n < 0
    · simp [eval, Out.bind, hn]
    · simp [eval, Out.bind, hn, List.getElem?_eq_none h]

theorem idx_in_range (xs : List Int) (n : Int) (hn : 0 ≤ n) (h : n.toNat < xs.length) :
    eval [] (.idx (.mk xs) (.lit n)) = .ok (.int xs[n.toNat]) := by
  have hn' : ¬ n < 0 := by omega
  simp [eval, Out.bind, hn', List.getElem?_eq_getElem h]

end Eider
