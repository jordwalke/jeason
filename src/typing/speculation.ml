(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* Various data structures and functions used to prepare for and execute
   speculative matching. *)

(* First up, a model for flow and unify actions that are deferred during
   speculative matching (and possibly fired afterwards). *)
module Action = struct

  type t =
  | Flow of Type.t * Type.use_t
  | Unify of Type.t * Type.t

  (* Extract types involved in an action. Actually we're only interested in
     tvars and filter the types further (see below); but for now we don't mind
     the redundancy. *)
  let types = Type.(function
    | Flow ((AnyT _ | EmptyT _), _)
    | Flow (_, UseT (_, (AnyT _ | MixedT _)))
      -> []
    | Flow (t1, UseT (_, t2)) -> [t1; t2]
    | Flow (t1, _) -> [t1]
    | Unify (t1, t2) -> [t1; t2]
  )

  (* Decide when two actions are the same. We use reasonless compare for types
     involved in the actions. *)
  let rec eq = function
    | Flow (t1, t2), Flow (t1_, t2_) ->
      eq_t (t1, t1_) && eq_use_t (t2, t2_)
    | Unify (t1, t2), Unify (t1_, t2_) ->
      eq_t (t1, t1_) && eq_t (t2, t2_)
    | _ -> false

  and eq_t (t, t_) =
    Type.reasonless_compare t t_ = 0

  and eq_use_t = function
    | Type.UseT (_, t), Type.UseT (_, t_) -> eq_t (t, t_)
    | _ -> false

  (* Action extended with a bit that determines whether the action is "benign."
     Roughly, actions that don't cause serious side effects are considered
     benign. See ignore, ignore_type, and defer_if_relevant below for
     details. *)
  type extended_t = bool * t

end

type unresolved = Type.TypeSet.t

(* Next, a model for "cases." A case serves as the context for a speculative
   match. In other words, while we're trying to execute a flow in speculation
   mode, we use this data structure to record stuff. *)
module Case = struct

  (* A case carries a (local) index that identifies which type we're currently
     considering among the members of a union or intersection type. This is used
     only for error reporting.

     Other than that, a case carries the unresolved tvars encountered and the
     actions deferred during a speculative match. These start out empty and grow
     as the speculative match proceeds. At the end of the speculative match,
     they are used to decide where the type under consideration should be
     selected, or otherwise how the match state should be updated. See the
     speculative_matches function in Flow_js. *)
  type t = {
    case_id: int;
    mutable unresolved: unresolved;
    mutable actions: Action.extended_t list;
  }

  (* A case could be diff'd with a later case to determine whether it is "less
     constrained," i.e., whether it's failure would also imply the failure of
     the later case. This is approximated by diff'ing the set of unresolved
     tvars that are involved in non-benign actions in the two cases. *)
  let diff case1 case2 =
    let { unresolved = ts1; actions = actions1; _ } = case1 in
    let { actions = actions2; _ } = case2 in
    (* collect those actions in actions1 that are not benign and don't appear in
       actions2 *)
    let diff_actions1 =
      List.filter (fun (benign, action1) ->
        not benign &&
        List.for_all (fun (_, action2) -> not (Action.eq (action1, action2)))
          actions2
      ) actions1 in
    (* collect those unresolved tvars in ts1 that are involved in actions in
       diff_actions1 *)
    let diff_ts1 =
      List.fold_left (fun diff_ts1 (_, diff_action1) ->
        List.fold_left (fun diff_ts1 t1 ->
          if Type.TypeSet.mem t1 ts1
          then Type.TypeSet.add t1 diff_ts1
          else diff_ts1
        ) diff_ts1 (Action.types diff_action1)
      ) Type.TypeSet.empty diff_actions1 in
    (* return *)
    Type.TypeSet.elements diff_ts1

end

(* Functions used to initialize and add unresolved tvars during type resolution
   of lower/upper bounds of union/intersection types, respectively *)

let init_speculation cx speculation_id =
  Context.set_all_unresolved cx
    (IMap.add speculation_id Type.TypeSet.empty (Context.all_unresolved cx))

let add_unresolved_to_speculation cx speculation_id t =
  let map = Context.all_unresolved cx in
  let ts = IMap.find_unsafe speculation_id map in
  Context.set_all_unresolved cx
    (IMap.add speculation_id (Type.TypeSet.add t ts) map)

(* Actions that involve some "ignored" unresolved tvars are considered
   benign. Such tvars can be explicitly designated to be ignored. Also, tvars
   that instantiate type parameters, this types, existentials, etc. are
   ignored. *)
type ignore = Type.t option
let ignore_type ignore t =
  match ignore with
  | Some ignore_t when ignore_t = t -> true
  | _ -> begin match t with
    | Type.OpenT (r, _) -> Reason.is_instantiable_reason r
    | _ -> false
  end

(* A branch is a wrapper around a case, that also carries the speculation id of
   the spec currently being processed, as well as any explicitly designated
   ignored tvar. *)
type branch = {
  ignore: ignore;
  speculation_id: int;
  case: Case.t;
}

(* Decide, for a flow or unify action encountered during a speculative match,
   whether that action should be deferred. Only a relevant action is deferred. A
   relevant action is not benign, and it must involve a tvar that was marked
   unresolved during full type resolution of the lower/upper bound of the
   union/intersection type being processed.

   As a side effect, whenever we decide to defer an action, we record the
   deferred action and the unresolved tvars involved in it in the current case.
*)
let defer_if_relevant cx branch action =
  let { ignore; speculation_id; case } = branch in
  let action_types = Action.types action in
  let all_unresolved =
    IMap.find_unsafe speculation_id (Context.all_unresolved cx) in
  let relevant_action_types =
    List.filter (fun t -> Type.TypeSet.mem t all_unresolved) action_types in
  let defer = relevant_action_types <> [] in
  if defer then Case.(
    let is_benign = List.exists (ignore_type ignore) action_types in
    if not is_benign
    then case.unresolved <-
      List.fold_left (fun unresolved t -> Type.TypeSet.add t unresolved)
        case.unresolved relevant_action_types;
    case.actions <- case.actions @ [is_benign, action]
  );
  defer

(* The state maintained by speculative_matches when trying each case of a
   union/intersection in turn. *)
type match_state =
| NoMatch of ErrorsFlow.error list
| ConditionalMatch of Case.t
