(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id$ *)

open Pp
open Util
open Pcoq
open Extend
open Ppextend
open Topconstr
open Genarg
open Libnames
open Nameops
open Tacexpr
open Names
open Vernacexpr

(**************************************************************************)
(*
 * --- Note on the mapping of grammar productions to camlp4 actions ---
 *
 * Translation of environments: a production
 *   [ nt1(x1) ... nti(xi) ] -> act(x1..xi)
 * is written (with camlp4 conventions):
 *   (fun vi -> .... (fun v1 -> act(v1 .. vi) )..)
 * where v1..vi are the values generated by non-terminals nt1..nti.
 * Since the actions are executed by substituting an environment,
 * the make_*_action family build the following closure:
 *
 *      ((fun env ->
 *          (fun vi ->
 *             (fun env -> ...
 *
 *                  (fun v1 ->
 *                     (fun env -> gram_action .. env act)
 *                     ((x1,v1)::env))
 *                  ...)
 *             ((xi,vi)::env)))
 *         [])
 *)

(**********************************************************************)
(** Declare Notations grammar rules                                   *)

let constr_expr_of_name (loc,na) = match na with
  | Anonymous -> CHole (loc,None)
  | Name id -> CRef (Ident (loc,id))

let cases_pattern_expr_of_name (loc,na) = match na with
  | Anonymous -> CPatAtom (loc,None)
  | Name id -> CPatAtom (loc,Some (Ident (loc,id)))

type grammar_constr_prod_item =
  | GramConstrTerminal of Token.pattern
  | GramConstrNonTerminal of constr_prod_entry_key * identifier option
  | GramConstrListMark of int * bool
    (* tells action rule to make a list of the n previous parsed items; 
       concat with last parsed list if true *)

type 'a action_env = 'a list * 'a list list

let make_constr_action
  (f : loc -> constr_expr action_env -> constr_expr) pil =
  let rec make (env,envlist as fullenv : constr_expr action_env) = function
  | [] ->
      Gramext.action (fun loc -> f loc fullenv)
  | (GramConstrTerminal _ | GramConstrNonTerminal (_,None)) :: tl ->
      (* parse a non-binding item *)
      Gramext.action (fun _ -> make fullenv tl)
  | GramConstrNonTerminal (typ, Some _) :: tl ->
      (* parse a binding non-terminal *)
    (match typ with
    | (ETConstr _| ETOther _) ->
        Gramext.action (fun (v:constr_expr) -> make (v :: env, envlist) tl)
    | ETReference ->
        Gramext.action (fun (v:reference) -> make (CRef v :: env, envlist) tl)
    | ETName ->
        Gramext.action (fun (na:name located) ->
	  make (constr_expr_of_name na :: env, envlist) tl)
    | ETBigint ->
        Gramext.action (fun (v:Bigint.bigint) ->
	  make (CPrim (dummy_loc,Numeral v) :: env, envlist) tl)
    | ETConstrList (_,n) ->
	Gramext.action (fun (v:constr_expr list) -> make (env, v::envlist) tl)
    | ETPattern ->
	failwith "Unexpected entry of type cases pattern")
  | GramConstrListMark (n,b) :: tl ->
      (* Rebuild expansions of ConstrList *)
      let heads,env = list_chop n env in
      if b then make (env,(heads@List.hd envlist)::List.tl envlist) tl
      else make (env,heads::envlist) tl
  in
  make ([],[]) (List.rev pil)

let make_cases_pattern_action
  (f : loc -> cases_pattern_expr action_env -> cases_pattern_expr) pil =
  let rec make (env,envlist as fullenv : cases_pattern_expr action_env) = function
  | [] ->
      Gramext.action (fun loc -> f loc fullenv)
  | (GramConstrTerminal _ | GramConstrNonTerminal (_,None)) :: tl ->
      (* parse a non-binding item *)
      Gramext.action (fun _ -> make fullenv tl)
  | GramConstrNonTerminal (typ, Some _) :: tl ->
      (* parse a binding non-terminal *)
    (match typ with
    | ETConstr _ -> (* pattern non-terminal *)
        Gramext.action (fun (v:cases_pattern_expr) -> make (v::env,envlist) tl)
    | ETReference ->
        Gramext.action (fun (v:reference) ->
	  make (CPatAtom (dummy_loc,Some v) :: env, envlist) tl)
    | ETName ->
        Gramext.action (fun (na:name located) ->
	  make (cases_pattern_expr_of_name na :: env, envlist) tl)
    | ETBigint ->
        Gramext.action (fun (v:Bigint.bigint) ->
	  make (CPatPrim (dummy_loc,Numeral v) :: env, envlist) tl)
    | ETConstrList (_,_) ->
        Gramext.action  (fun (vl:cases_pattern_expr list) ->
	  make (env, vl :: envlist) tl)
    | (ETPattern | ETOther _) ->
	failwith "Unexpected entry of type cases pattern or other")
  | GramConstrListMark (n,b) :: tl ->
      (* Rebuild expansions of ConstrList *)
      let heads,env = list_chop n env in
      if b then make (env,(heads@List.hd envlist)::List.tl envlist) tl
      else make (env,heads::envlist) tl
  in
  make ([],[]) (List.rev pil)

let rec make_constr_prod_item assoc from forpat = function
  | GramConstrTerminal tok :: l ->
      Gramext.Stoken tok :: make_constr_prod_item assoc from forpat l
  | GramConstrNonTerminal (nt, ovar) :: l ->
      symbol_of_constr_prod_entry_key assoc from forpat nt
      :: make_constr_prod_item assoc from forpat l
  | GramConstrListMark _ :: l ->
      make_constr_prod_item assoc from forpat l
  | [] ->
      []

let prepare_empty_levels forpat (pos,p4assoc,name,reinit) =
  let entry = 
    if forpat then weaken_entry Constr.pattern
    else weaken_entry Constr.operconstr in
  grammar_extend entry pos reinit [(name, p4assoc, [])]

let pure_sublevels level symbs =
  map_succeed (function
  | Gramext.Snterml (_,n) when Some (int_of_string n) <> level ->
      int_of_string n
  | _ ->
      failwith "") symbs

let extend_constr (entry,level) (n,assoc) mkact forpat rules =
  List.iter (fun pt ->
  let symbs = make_constr_prod_item assoc n forpat pt in
  let pure_sublevels = pure_sublevels level symbs in
  let needed_levels = register_empty_levels forpat pure_sublevels in
  let pos,p4assoc,name,reinit = find_position forpat assoc level in
  List.iter (prepare_empty_levels forpat) needed_levels;
  grammar_extend entry pos reinit [(name, p4assoc, [symbs, mkact pt])]) rules

let extend_constr_notation (n,assoc,ntn,rules) =
  (* Add the notation in constr *)
  let mkact loc env = CNotation (loc,ntn,env) in
  let e = interp_constr_entry_key false (ETConstr (n,())) in
  extend_constr e (ETConstr(n,()),assoc) (make_constr_action mkact) false rules;
  (* Add the notation in cases_pattern *)
  let mkact loc env = CPatNotation (loc,ntn,env) in
  let e = interp_constr_entry_key true (ETConstr (n,())) in
  extend_constr e (ETConstr (n,()),assoc) (make_cases_pattern_action mkact)
    true rules

(**********************************************************************)
(** Making generic actions in type generic_argument                   *)

let make_generic_action
  (f:loc -> ('b * raw_generic_argument) list -> 'a) pil =
  let rec make env = function
    | [] ->
	Gramext.action (fun loc -> f loc env)
    | None :: tl -> (* parse a non-binding item *)
        Gramext.action (fun _ -> make env tl)
    | Some (p, t) :: tl -> (* non-terminal *)
        Gramext.action (fun v -> make ((p,in_generic t v) :: env) tl) in
  make [] (List.rev pil)

let make_rule univ f g pt =
  let (symbs,ntl) = List.split (List.map g pt) in
  let act = make_generic_action f ntl in
  (symbs, act)

(**********************************************************************)
(** Grammar extensions declared at ML level                           *)

type grammar_prod_item =
  | GramTerminal of string
  | GramNonTerminal of
      loc * argument_type * Gram.te prod_entry_key * identifier option

let make_prod_item = function
  | GramTerminal s -> (Gramext.Stoken (Lexer.terminal s), None)
  | GramNonTerminal (_,t,e,po) ->
      (symbol_of_prod_entry_key e, Option.map (fun p -> (p,t)) po)

(* Tactic grammar extensions *)

let extend_tactic_grammar s gl =
  let univ = get_univ "tactic" in
  let mkact loc l = Tacexpr.TacExtend (loc,s,List.map snd l) in
  let rules = List.map (make_rule univ mkact make_prod_item) gl in
  Gram.extend Tactic.simple_tactic None [(None, None, List.rev rules)]

(* Vernac grammar extensions *)

let vernac_exts = ref []
let get_extend_vernac_grammars () = !vernac_exts

let extend_vernac_command_grammar s nt gl =
  let nt = Option.default Vernac_.command nt in
  vernac_exts := (s,gl) :: !vernac_exts;
  let univ = get_univ "vernac" in
  let mkact loc l = VernacExtend (s,List.map snd l) in
  let rules = List.map (make_rule univ mkact make_prod_item) gl in
  Gram.extend nt None [(None, None, List.rev rules)]

(**********************************************************************)
(** Grammar declaration for Tactic Notation (Coq level)               *)

let get_tactic_entry n =
  if n = 0 then
    weaken_entry Tactic.simple_tactic, None
  else if n = 5 then
    weaken_entry Tactic.binder_tactic, None
  else if 1<=n && n<5 then
    weaken_entry Tactic.tactic_expr, Some (Gramext.Level (string_of_int n))
  else
    error ("Invalid Tactic Notation level: "^(string_of_int n)^".")

(* Declaration of the tactic grammar rule *)

let head_is_ident = function GramTerminal _::_ -> true | _ -> false

let add_tactic_entry (key,lev,prods,tac) =
  let univ = get_univ "tactic" in
  let entry, pos = get_tactic_entry lev in
  let rules =
    if lev = 0 then begin
      if not (head_is_ident prods) then
	error "Notation for simple tactic must start with an identifier.";
      let mkact s tac loc l =
	(TacAlias(loc,s,l,tac):raw_atomic_tactic_expr) in
      make_rule univ (mkact key tac) make_prod_item prods
    end
    else
      let mkact s tac loc l =
	(TacAtom(loc,TacAlias(loc,s,l,tac)):raw_tactic_expr) in
      make_rule univ (mkact key tac) make_prod_item prods in
  synchronize_level_positions ();
  grammar_extend entry pos None [(None, None, List.rev [rules])]

(**********************************************************************)
(** State of the grammar extensions                                   *)

type notation_grammar =
    int * Gramext.g_assoc option * notation * grammar_constr_prod_item list list

type all_grammar_command =
  | Notation of (precedence * tolerability list) * notation_grammar
  | TacticGrammar of
      (string * int * grammar_prod_item list *
         (dir_path * Tacexpr.glob_tactic_expr))

let (grammar_state : all_grammar_command list ref) = ref []

let extend_grammar gram =
  (match gram with
  | Notation (_,a) -> extend_constr_notation a
  | TacticGrammar g -> add_tactic_entry g);
  grammar_state := gram :: !grammar_state

let recover_notation_grammar ntn prec =
  let l = map_succeed (function
    | Notation (prec',(_,_,ntn',_ as x)) when prec = prec' & ntn = ntn' -> x
    | _ -> failwith "") !grammar_state in
  assert (List.length l = 1);
  List.hd l

(* Summary functions: the state of the lexer is included in that of the parser.
   Because the grammar affects the set of keywords when adding or removing
   grammar rules. *)
type frozen_t = all_grammar_command list * Lexer.frozen_t

let freeze () = (!grammar_state, Lexer.freeze ())

(* We compare the current state of the grammar and the state to unfreeze,
   by computing the longest common suffixes *)
let factorize_grams l1 l2 =
  if l1 == l2 then ([], [], l1) else list_share_tails l1 l2

let number_of_entries gcl =
  List.fold_left
    (fun n -> function
      | Notation _ -> n + 2 (* 1 for operconstr, 1 for pattern *)
      | TacticGrammar _ -> n + 1)
    0 gcl

let unfreeze (grams, lex) =
  let (undo, redo, common) = factorize_grams !grammar_state grams in
  let n = number_of_entries undo in
  remove_grammars n;
  remove_levels n;
  grammar_state := common;
  Lexer.unfreeze lex;
  List.iter extend_grammar (List.rev redo)

let init_grammar () =
  remove_grammars (number_of_entries !grammar_state);
  grammar_state := []

let init () =
  init_grammar ()

open Summary

let _ =
  declare_summary "GRAMMAR_LEXER"
    { freeze_function = freeze;
      unfreeze_function = unfreeze;
      init_function = init }
